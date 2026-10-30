// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// One upload run: decide whether to run, plan day-sized requests, send them one at a time, and move the
// watermarks only on an ack. All store access goes through `HubDataSource` (the iOS adapter in
// HubUploader.swift reads NOOP's Repository), so the whole run is unit-tested with fakes.
import Foundation

/// The light, per-run inputs: device status, the recent daily rows and sleep sessions, and steps.
struct HubRunContext {
    var device: HubDevice
    var timeZone: TimeZone
    var daily: [HubDailyInput]
    var sleep: [HubSleepInput]
    var steps: [HubStepRow]
}

protocol HubDataSource: AnyObject {
    /// nil when the store isn't open yet (the run is skipped, nothing changes).
    func context(now: Int) async -> HubRunContext?
    /// Rows with `from <= ts <= to`, oldest first.
    func hrSamples(from: Int, to: Int) async -> [HubHRSampleInput]
    func events(from: Int, to: Int) async -> [HubEventInput]
    func battery(from: Int, to: Int) async -> [HubBatteryInput]
    /// The oldest row time in [from, to] for that stream, or nil when there is none.
    func firstTs(_ s: HubStream, from: Int, to: Int) async -> Int?
    /// For each range: row count + newest ts in it (exactly the rows the read above returns, e.g. HR
    /// measured ∪ PPG-derived). Must change whenever a row is added to that range. One call per stream
    /// and step, so the adapter can answer many hours with a single store read.
    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async -> [HubFingerprint]
}

enum HubTrigger: String { case backfill, foreground, manual }

enum HubRunOutcome: Equatable {
    case skipped(String)
    case uploaded(requests: Int, more: Bool)
    case failed(HubFailure)
    /// Background time ran out mid-run; nothing unacked advanced. The next trigger continues.
    case cancelled
}

/// One planned request: per stream, the inclusive time ranges whose rows it carries.
struct HubChunk: Equatable {
    var ranges: [HubStream: [ClosedRange<Int>]] = [:]
    var isResend = false
    var isEmpty: Bool { ranges.values.allSatisfy { $0.isEmpty } }
}

actor HubUploadEngine {
    static let minInterval = 600                 // at most once every 10 minutes …
    static let initialLookback = 14 * 86_400     // first run: the band's whole buffer
    static let hourLookback = 48 * 3_600         // late-backfill check window
    static let maxRequestsPerRun = 48
    static let maxKeyedRowsPerRequest = 60

    let source: HubDataSource
    let client: HubClient
    let state: HubState
    let marks: HubWatermarkStore
    /// Called after every attempt that reached (or tried to reach) the hub. The iOS adapter refreshes the
    /// hub notifications here (T4.3 handoff).
    let afterAttempt: () -> Void

    private var running = false

    init(source: HubDataSource, client: HubClient, state: HubState, marks: HubWatermarkStore,
         afterAttempt: @escaping () -> Void = {}) {
        self.source = source; self.client = client; self.state = state; self.marks = marks
        self.afterAttempt = afterAttempt
    }

    /// Pure throttle: manual runs always; otherwise once per 10 minutes unless the last run left a
    /// catch-up unfinished (more than a day behind, or out of background time).
    static func shouldRun(trigger: HubTrigger, now: Int, lastAttemptAt: Int?, catchUpPending: Bool) -> Bool {
        if trigger == .manual || catchUpPending { return true }
        guard let last = lastAttemptAt else { return true }
        return now - last >= minInterval || now < last
    }

    func run(_ trigger: HubTrigger, now: @escaping () -> Date = Date.init,
             shouldContinue: @escaping () -> Bool = { true }) async -> HubRunOutcome {
        guard !running else { return .skipped("already running") }
        guard state.enabled else { return .skipped("hub off") }
        guard let base = state.hubURL else { return .skipped("no hub URL") }
        guard let tok = client.token(), !tok.isEmpty else { return .skipped("no token") }
        running = true
        defer { running = false }

        let nowTs = Int(now().timeIntervalSince1970)
        var w = marks.load()
        guard Self.shouldRun(trigger: trigger, now: nowTs, lastAttemptAt: w.lastAttemptAt,
                             catchUpPending: w.catchUpPending) else { return .skipped("throttled") }
        guard let ctx = await source.context(now: nowTs) else { return .skipped("store not ready") }
        w.lastAttemptAt = nowTs
        marks.save(w)

        let tz = ctx.timeZone
        // Keyed tables: rows whose hash differs from the acked one.
        var pendingDaily = ctx.daily.map(HubBatchBuilder.daily).filter {
            w.rowHash(.daily, $0.day) != HubWire.rowHash(HubWire.daily($0))
        }
        var pendingSleep = HubBatchBuilder.sleep(ctx.sleep, timeZone: tz).filter {
            w.rowHash(.sleep, String($0.startTs)) != HubWire.rowHash(HubWire.sleep($0))
        }
        // Streams: acked hours whose fingerprint changed since (late backfill).
        var dirty: [HubStream: [Int]] = [:]
        for s in HubStream.allCases {
            guard let wm = w.streamMark(s) else { continue }
            let stop = HubBatchBuilder.floorHour(wm)
            let hours = Array(stride(from: HubBatchBuilder.floorHour(nowTs - Self.hourLookback), to: stop, by: 3_600))
            let clips = hours.map { w.hourMark(s, $0)?.clip ?? ($0 + 3_599) }
            let fps = hours.isEmpty ? [] : await source.fingerprints(s, ranges: zip(hours, clips).map { $0...$1 })
            for (i, h) in hours.enumerated() where i < fps.count {
                let fp = fps[i]
                if let mark = w.hourMark(s, h) {
                    if fp != mark.fp { dirty[s, default: []].append(h) }
                } else if fp.count == 0 {
                    w.setHourMark(s, h, HubHourMark(clip: clips[i], fp: fp))   // nothing there, nothing to send
                } else {
                    dirty[s, default: []].append(h)
                }
            }
        }
        var cursor: [HubStream: Int] = [:]
        for s in HubStream.allCases {
            cursor[s] = w.streamMark(s).map(HubBatchBuilder.floorHour)
                ?? HubBatchBuilder.floorHour(nowTs - Self.initialLookback)
        }

        var sent = 0
        var forwardDone = false
        while sent < Self.maxRequestsPerRun {
            guard shouldContinue() else {
                w.catchUpPending = true; marks.save(w)
                return sent > 0 ? .uploaded(requests: sent, more: true) : .cancelled
            }
            // Plan: late-backfilled hours first (one local day per request), then the forward scan.
            var chunk = HubChunk()
            if let first = dirty.values.compactMap({ $0.min() }).min() {
                let dayEnd = HubBatchBuilder.endOfLocalDay(first, tz)
                chunk.isResend = true
                for s in HubStream.allCases {
                    let hours = (dirty[s] ?? []).filter { $0 <= dayEnd }
                    dirty[s] = (dirty[s] ?? []).filter { $0 > dayEnd }
                    if !hours.isEmpty {
                        chunk.ranges[s] = hours.sorted().map { $0...Swift.min($0 + 3_599, dayEnd, nowTs) }
                    }
                }
            } else if !forwardDone {
                var firsts: [HubStream: Int] = [:]
                for s in HubStream.allCases {
                    let from = cursor[s]!
                    if from <= nowTs, let f = await source.firstTs(s, from: from, to: nowTs) { firsts[s] = f }
                }
                if let earliest = firsts.values.min() {
                    let dayEnd = Swift.min(HubBatchBuilder.endOfLocalDay(earliest, tz), nowTs)
                    for (s, f) in firsts where f <= dayEnd {
                        chunk.ranges[s] = [HubBatchBuilder.floorHour(f)...dayEnd]
                    }
                } else {
                    forwardDone = true
                }
            }
            // Always send at least one request per run (it carries device status and steps, and brings
            // back the lock flag and renewal estimate); after that, only while there is something to send.
            if chunk.isEmpty && sent > 0 && pendingDaily.isEmpty && pendingSleep.isEmpty { break }

            // Fingerprint BEFORE reading rows: a row landing in between makes the stored mark stale, which
            // only ever causes a harmless resend later, never a skipped row.
            var hourMarks: [HubStream: [(Int, HubHourMark)]] = [:]
            for (s, rs) in chunk.ranges {
                var spans: [ClosedRange<Int>] = []
                for r in rs {
                    for h in stride(from: r.lowerBound, through: r.upperBound, by: 3_600) {
                        spans.append(h...Swift.min(h + 3_599, r.upperBound))
                    }
                }
                let fps = spans.isEmpty ? [] : await source.fingerprints(s, ranges: spans)
                hourMarks[s] = zip(spans, fps).map { ($0.lowerBound, HubHourMark(clip: $0.upperBound, fp: $1)) }
            }
            var payload = HubPayload(device: ctx.device)
            for r in chunk.ranges[.hr_minute] ?? [] {
                payload.hrMinute += HubBatchBuilder.minuteAggregates(await source.hrSamples(from: r.lowerBound, to: r.upperBound))
            }
            for r in chunk.ranges[.events] ?? [] {
                payload.events += HubBatchBuilder.events(await source.events(from: r.lowerBound, to: r.upperBound))
            }
            for r in chunk.ranges[.battery] ?? [] {
                payload.battery += HubBatchBuilder.battery(await source.battery(from: r.lowerBound, to: r.upperBound))
            }
            payload.daily = Array(pendingDaily.prefix(Self.maxKeyedRowsPerRequest))
            payload.sleep = Array(pendingSleep.prefix(Self.maxKeyedRowsPerRequest))
            if sent == 0 { payload.steps = ctx.steps }

            let result: HubSendResult
            if payload.hrMinute.count > HubBatchBuilder.maxHRRowsPerRequest {
                result = .failed(.tooLarge)
            } else if let json = try? HubWire.encode(payload) {
                result = json.count > HubBatchBuilder.maxBytesPerRequest
                    ? .failed(.tooLarge) : await client.send(json: json, base: base)
            } else {
                result = .failed(.encoding)
            }
            switch result {
            case .cancelled:
                w.catchUpPending = true; marks.save(w)
                return .cancelled
            case .failed(let f):
                state.recordUploadFailure(at: now(), reason: f.reason)
                marks.save(w)
                afterAttempt()
                return .failed(f)
            case .acked(let resp):
                guard Self.applyAck(resp, payload: payload, hourMarks: hourMarks, to: &w) else {
                    state.recordUploadFailure(at: now(), reason: HubFailure.badResponse.reason)
                    marks.save(w)
                    afterAttempt()
                    return .failed(.badResponse)
                }
                pendingDaily.removeFirst(payload.daily.count)
                pendingSleep.removeFirst(payload.sleep.count)
                if !chunk.isResend {
                    for (s, rs) in chunk.ranges { if let last = rs.last { cursor[s] = last.upperBound + 1 } }
                }
                Self.applyServerState(resp, to: state)
                state.recordUploadSuccess(at: now())
                sent += 1
                marks.save(w)
            }
        }
        let more = sent >= Self.maxRequestsPerRun
        w.catchUpPending = more
        var keep: [HubTable: Set<String>] = [:]
        if !ctx.daily.isEmpty { keep[.daily] = Set(ctx.daily.map(\.day)) }
        if !ctx.sleep.isEmpty { keep[.sleep] = Set(ctx.sleep.map { String($0.startTs) }) }
        w.prune(hoursBefore: HubBatchBuilder.floorHour(nowTs - Self.hourLookback - 3_600), keepRowKeys: keep)
        marks.save(w)
        afterAttempt()
        return .uploaded(requests: sent, more: more)
    }

    /// Moves watermarks for one acked request. A table that carried rows counts as acked only when the
    /// response's ack for it reaches the newest row sent; otherwise nothing moves and false is returned
    /// (the run stops loudly). A table that carried no rows needs no ack. Streams advance to the newest
    /// row SENT (an ack above it is the server's own maximum, not something this request delivered).
    static func applyAck(_ r: HubServerResponse, payload: HubPayload,
                         hourMarks: [HubStream: [(Int, HubHourMark)]], to w: inout HubWatermarks) -> Bool {
        func timeAck(_ t: HubTable, _ maxSent: Int?) -> Bool {
            guard let maxSent else { return true }
            if case .time(let v)? = r.ack[t.rawValue] { return v >= maxSent }
            return false
        }
        let streamMax: [HubStream: Int?] = [.hr_minute: payload.hrMinute.map(\.t).max(),
                                            .events: payload.events.map(\.t).max(),
                                            .battery: payload.battery.map(\.t).max()]
        let maxDay = payload.daily.map(\.day).max()
        var dailyOK = maxDay == nil
        if let maxDay, case .day(let d)? = r.ack[HubTable.daily.rawValue] { dailyOK = d >= maxDay }
        guard dailyOK,
              timeAck(.sleep, payload.sleep.map(\.startTs).max()),
              timeAck(.hr_minute, streamMax[.hr_minute]!),
              timeAck(.events, streamMax[.events]!),
              timeAck(.battery, streamMax[.battery]!) else { return false }

        for s in HubStream.allCases {
            if let m = streamMax[s]!, m > (w.streamMark(s) ?? Int.min) { w.advance(s, to: m) }
            for (h, mark) in hourMarks[s] ?? [] { w.setHourMark(s, h, mark) }
        }
        for row in payload.daily { w.rows[HubTable.daily.rawValue, default: [:]][row.day] = HubWire.rowHash(HubWire.daily(row)) }
        for row in payload.sleep {
            w.rows[HubTable.sleep.rawValue, default: [:]][String(row.startTs)] = HubWire.rowHash(HubWire.sleep(row))
        }
        return true
    }

    static func applyServerState(_ r: HubServerResponse, to state: HubState) {
        state.serverRenewalEstimate = r.renewalEstimate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if state.locked != r.locked { state.locked = r.locked }
        if state.openAlerts != r.openAlerts { state.openAlerts = r.openAlerts }
        if let t = r.tripwire, state.tripwire != t { state.tripwire = t }
    }
}
