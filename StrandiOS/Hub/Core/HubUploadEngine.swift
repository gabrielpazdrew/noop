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
    /// R23 completeness guard: true only when NOOP's sleep list is loaded and non-empty, so a window
    /// (which supersedes everything the hub holds in it) is never built from a partial list.
    var sleepLoaded: Bool = false
    /// NOOP's sync signals (`LiveState.backfilling`, `.historyPendingSync`) and when `backfilling` last
    /// turned off; HubHoldPolicy turns them into a hold of the band streams.
    var backfilling: Bool = false
    var historyPendingSync: Bool = false
    var lastBackfillingEndedAt: Int? = nil
}

protocol HubDataSource: AnyObject {
    /// nil when the store isn't open yet (the run is skipped, nothing changes).
    func context(now: Int) async -> HubRunContext?
    /// Rows with `from <= ts <= to`, oldest first. A read that fails THROWS (never an empty answer):
    /// the run then fails and nothing is marked as sent.
    func hrSamples(from: Int, to: Int) async throws -> [HubHRSampleInput]
    func events(from: Int, to: Int) async throws -> [HubEventInput]
    func battery(from: Int, to: Int) async throws -> [HubBatteryInput]
    /// The oldest row time in [from, to] for that stream, or nil when there is none.
    func firstTs(_ s: HubStream, from: Int, to: Int) async throws -> Int?
    /// For each range: row count + newest ts in it (exactly the rows the read above returns, e.g. HR
    /// measured ∪ PPG-derived). Must change whenever a row is added to that range. One call per stream
    /// and step, so the adapter can answer many segments with a single store read.
    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async throws -> [HubFingerprint]
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
    static let sleepWindowDays = 14              // R23 windows: the band's buffer
    /// R26 addendum: a window's start must be >= now − 13 days (the server refuses < now − 14 days).
    static let sleepWindowMaxAge = 13 * 86_400

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

    /// Pure throttle. Manual runs always go. Otherwise once per 10 minutes, except:
    /// - the last run left a catch-up unfinished (out of background time, or the per-run cap);
    /// - a backfill whose data landed after the last attempt started (the offload a foreground run
    ///   itself kicked off must not wait for the next Bluetooth wake).
    static func shouldRun(trigger: HubTrigger, now: Int, lastAttemptAt: Int?, catchUpPending: Bool,
                          dataLandedAt: Int? = nil) -> Bool {
        if trigger == .manual || catchUpPending { return true }
        guard let last = lastAttemptAt else { return true }
        if trigger == .backfill, let landed = dataLandedAt, landed > last { return true }
        return now - last >= minInterval || now < last
    }

    /// `dataLandedAt`: for a `.backfill` trigger, when the offload completed (`LiveState.lastSyncedAt`).
    func run(_ trigger: HubTrigger, now: @escaping () -> Date = Date.init, dataLandedAt: Int? = nil,
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
                             catchUpPending: w.catchUpPending, dataLandedAt: dataLandedAt) else { return .skipped("throttled") }
        guard let ctx = await source.context(now: nowTs) else { return .skipped("store not ready") }
        let hold = HubHoldPolicy.decide(trigger: trigger, now: nowTs, backfilling: ctx.backfilling,
                                        historyPendingSync: ctx.historyPendingSync,
                                        lastBackfillingEndedAt: ctx.lastBackfillingEndedAt,
                                        holdingSince: state.holdingSince.map { Int($0.timeIntervalSince1970) })
        let since = hold.holdingSince.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if state.holdingSince != since { state.holdingSince = since }
        // A held run sends no band data, so it gets no exemption from the 10-minute floor: a deep offload
        // fires the backfill hook once per ~60 s pass and must not turn into ~24 near-empty uploads.
        if hold.hold && !Self.shouldRun(trigger: trigger, now: nowTs, lastAttemptAt: w.lastAttemptAt,
                                        catchUpPending: w.catchUpPending) {
            return .skipped("held: strap sync running")
        }
        w.lastAttemptAt = nowTs
        marks.save(w)

        do {
            return try await send(trigger: trigger, ctx: ctx, hold: hold.hold, base: base, nowTs: nowTs, now: now,
                                  shouldContinue: shouldContinue, w: &w)
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Background time ran out during a store read: not a hub failure (re-review Minor b).
                w.catchUpPending = true; marks.save(w)
                return .cancelled
            }
            // A store read failed: nothing in this request was sent, nothing advances. Counted as a failed
            // upload so a persistent read problem reaches the 6-hour notice like any other failure.
            state.recordUploadFailure(at: now(), reason: HubFailure.storeRead.reason)
            marks.save(w)
            afterAttempt()
            return .failed(.storeRead)
        }
    }

    private func send(trigger: HubTrigger, ctx: HubRunContext, hold: Bool, base: URL, nowTs: Int, now: @escaping () -> Date,
                      shouldContinue: @escaping () -> Bool, w: inout HubWatermarks) async throws -> HubRunOutcome {
        let tz = ctx.timeZone
        let streams: [HubStream] = hold ? [] : HubStream.allCases
        // Keyed tables: rows whose hash differs from the acked one.
        var pendingDaily = ctx.daily.map(HubBatchBuilder.daily).filter {
            w.rowHash(.daily, $0.day) != HubWire.rowHash(HubWire.daily($0))
        }
        // R23 sleep windows: one per local day over the last 14 days (never older than the oldest loaded
        // session), sent whole whenever its content hash differs from the acked one, including emptied.
        var pendingWindows: [(window: HubSleepWindow, rows: [HubSleepRow], hash: String)] = []
        if ctx.sleepLoaded, let oldest = ctx.sleep.map(\.startTs).min() {
            let rows = HubBatchBuilder.sleep(ctx.sleep, timeZone: tz)
            let floor = HubBatchBuilder.startOfLocalDay(oldest, tz)
            var win = HubBatchBuilder.sleepWindow(containing: nowTs, tz)
            let ageFloor = nowTs - Self.sleepWindowMaxAge
            for _ in 0..<Self.sleepWindowDays where win.from >= floor && win.from >= ageFloor {
                let inWin = rows.filter { $0.startTs >= win.from && $0.startTs < win.to }
                let hash = HubWire.windowHash(inWin)
                let key = String(win.from)
                if w.windows[key] != hash && w.rejectedWindows[key] != hash { pendingWindows.append((win, inWin, hash)) }
                win = HubBatchBuilder.sleepWindow(containing: win.from - 1, tz)
            }
            pendingWindows.reverse()   // oldest first
        }
        // Streams: acked segments whose fingerprint changed since (late backfill). Late rows only arrive
        // through a strap offload, so the scan runs for a backfill (and "Upload now"), not every foreground.
        var dirty: [HubStream: [Int]] = [:]
        if trigger != .foreground {
            for s in streams {
                guard let wm = w.streamMark(s) else { continue }
                let stop = HubBatchBuilder.segmentStart(wm, tz)
                var segs: [Int] = []
                var t = HubBatchBuilder.segmentStart(nowTs - Self.hourLookback, tz)
                while t < stop { segs.append(t); t = HubBatchBuilder.segmentEnd(t, tz) + 1 }
                let clips = segs.map { w.hourMark(s, $0)?.clip ?? HubBatchBuilder.segmentEnd($0, tz) }
                let fps = segs.isEmpty ? [] : try await source.fingerprints(s, ranges: zip(segs, clips).map { $0...$1 })
                for (i, seg) in segs.enumerated() where i < fps.count {
                    let fp = fps[i]
                    if let mark = w.hourMark(s, seg) {
                        if fp != mark.fp { dirty[s, default: []].append(seg) }
                    } else if fp.count == 0 {
                        w.setHourMark(s, seg, HubHourMark(clip: clips[i], fp: fp))   // nothing there, nothing to send
                    } else {
                        dirty[s, default: []].append(seg)
                    }
                }
            }
        }
        var cursor: [HubStream: Int] = [:]
        for s in streams {
            cursor[s] = w.streamMark(s).map { HubBatchBuilder.segmentStart($0, tz) }
                ?? HubBatchBuilder.segmentStart(nowTs - Self.initialLookback, tz)
        }

        var sent = 0
        var forwardDone = streams.isEmpty
        while sent < Self.maxRequestsPerRun {
            guard shouldContinue() else {
                w.catchUpPending = true; marks.save(w)
                return sent > 0 ? .uploaded(requests: sent, more: true) : .cancelled
            }
            // Switched off, or pointed elsewhere, mid-run: stop before the next request.
            if sent > 0 && (!state.enabled || state.hubURL != base) {
                w.catchUpPending = false; marks.save(w)
                afterAttempt()
                return .uploaded(requests: sent, more: true)
            }
            // Plan: late-backfilled segments first (one local day per request), then the forward scan.
            var chunk = HubChunk()
            if let first = dirty.values.compactMap({ $0.min() }).min() {
                let dayEnd = HubBatchBuilder.endOfLocalDay(first, tz)
                chunk.isResend = true
                for s in streams {
                    let segs = (dirty[s] ?? []).filter { $0 <= dayEnd }
                    dirty[s] = (dirty[s] ?? []).filter { $0 > dayEnd }
                    if !segs.isEmpty {
                        chunk.ranges[s] = segs.sorted().map { $0...Swift.min(HubBatchBuilder.segmentEnd($0, tz), nowTs) }
                    }
                }
            } else if !forwardDone {
                var firsts: [HubStream: Int] = [:]
                for s in streams {
                    let from = cursor[s]!
                    if from <= nowTs, let f = try await source.firstTs(s, from: from, to: nowTs) { firsts[s] = f }
                }
                if let earliest = firsts.values.min() {
                    let dayEnd = Swift.min(HubBatchBuilder.endOfLocalDay(earliest, tz), nowTs)
                    for (s, f) in firsts where f <= dayEnd {
                        chunk.ranges[s] = [Swift.max(HubBatchBuilder.segmentStart(f, tz), cursor[s]!)...dayEnd]
                    }
                } else {
                    forwardDone = true
                }
            }
            // Always send at least one request per run (it carries device status and steps, and brings
            // back the lock flag and renewal estimate); after that, only while there is something to send.
            if chunk.isEmpty && sent > 0 && pendingDaily.isEmpty && pendingWindows.isEmpty { break }

            // Fingerprint BEFORE reading rows: a row landing in between makes the stored mark stale, which
            // only ever causes a harmless resend later, never a skipped row. Marks are per segment.
            var hourMarks: [HubStream: [(Int, HubHourMark)]] = [:]
            for (s, rs) in chunk.ranges {
                var spans: [ClosedRange<Int>] = []
                for r in rs {
                    var t = r.lowerBound
                    while t <= r.upperBound {
                        let e = Swift.min(HubBatchBuilder.segmentEnd(t, tz), r.upperBound)
                        spans.append(t...e)
                        t = e + 1
                    }
                }
                let fps = spans.isEmpty ? [] : try await source.fingerprints(s, ranges: spans)
                hourMarks[s] = zip(spans, fps).map { ($0.lowerBound, HubHourMark(clip: $0.upperBound, fp: $1)) }
            }
            var payload = HubPayload(device: ctx.device)
            for r in chunk.ranges[.hr_minute] ?? [] {
                payload.hrMinute += HubBatchBuilder.minuteAggregates(try await source.hrSamples(from: r.lowerBound, to: r.upperBound))
            }
            for r in chunk.ranges[.events] ?? [] {
                payload.events += HubBatchBuilder.events(try await source.events(from: r.lowerBound, to: r.upperBound))
            }
            for r in chunk.ranges[.battery] ?? [] {
                payload.battery += HubBatchBuilder.battery(try await source.battery(from: r.lowerBound, to: r.upperBound))
            }
            payload.daily = Array(pendingDaily.prefix(Self.maxKeyedRowsPerRequest))
            let window = pendingWindows.first
            payload.sleepWindow = window?.window
            payload.sleep = window?.rows ?? []
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
                if f == .rejected, let win = window {
                    // R26: the whole request was refused and it carried a window. Drop that window (with this
                    // content) from future requests, so it can't block HR/daily on every retry. The next run
                    // resends the rest without it.
                    w.rejectedWindows[String(win.window.from)] = win.hash
                    state.recordUploadFailure(at: now(), reason: "Sleep window rejected (HTTP 422); dropped")
                    marks.save(w)
                    afterAttempt()
                    return .failed(f)
                }
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
                if let win = window {
                    // Confirmed by this 2xx + parseable ack (one batch server-side), even with zero rows.
                    w.windows[String(win.window.from)] = win.hash
                    pendingWindows.removeFirst()
                }
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
        w.rows[HubTable.sleep.rawValue] = nil   // per-row sleep hashes are superseded by R23 windows
        w.prune(hoursBefore: HubBatchBuilder.floorHour(nowTs - Self.hourLookback - 3_600), keepRowKeys: keep,
                windowsBefore: HubBatchBuilder.startOfLocalDay(nowTs - (Self.sleepWindowDays + 1) * 86_400, tz))
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
        return true
    }

    static func applyServerState(_ r: HubServerResponse, to state: HubState) {
        state.serverRenewalEstimate = r.renewalEstimate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if state.locked != r.locked { state.locked = r.locked }
        if state.openAlerts != r.openAlerts { state.openAlerts = r.openAlerts }
        if let t = r.tripwire, state.tripwire != t { state.tripwire = t }
    }
}
