// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// Pure mapping from NOOP store rows to v1 wire rows (hub/test/fixtures/CONTRACT.md). The input types
// below carry ONLY the columns the contract allows: the iOS adapter (HubUploader.swift) copies them out
// of NOOP's `DailyMetric` / `CachedSleepSession` / `HRSample` / `WhoopEvent` / `BatterySample`, so stage
// minutes, SpO2, stage JSON, RR intervals and event payloads never reach this layer at all.
import Foundation

struct HubHRSampleInput: Equatable { var ts: Int; var bpm: Int }
struct HubEventInput: Equatable { var ts: Int; var kind: String }
struct HubBatteryInput: Equatable { var ts: Int; var soc: Double?; var mv: Int?; var charging: Bool? }

/// The allowed columns of NOOP `dailyMetric` (CONTRACT `daily[]`).
struct HubDailyInput: Equatable {
    var day: String
    var recovery: Double?
    var strain: Double?
    var restingHr: Int?
    var avgHrv: Double?
    var avgSdnn: Double?
    var respRateBpm: Double?
    var skinTempDevC: Double?
    var totalSleepMin: Double?
    var efficiency: Double?
    var disturbances: Int?
    var exerciseCount: Int?
    var steps: Int?
    var activeKcalEst: Double?
}

/// The allowed columns of NOOP `sleepSession` (CONTRACT `sleep[]`).
struct HubSleepInput: Equatable {
    var startTs: Int
    var endTs: Int
    /// As NOOP stores it: usually a 0–1 fraction, a percentage on some imported rows.
    var efficiency: Double?
    var restingHr: Int?
    var avgHrv: Double?
    var startTsAdjusted: Int?
    var userEdited: Bool
    /// Asleep minutes decoded by NOOP itself (`SleepView.decodeStages/decodeSegments`), computed on the
    /// phone; only this total leaves it, never the stages. nil = no decodable stages.
    var asleepMin: Double? = nil
    /// NOOP's own main-night grouping (`SleepView.mainNightGroup`). nil = not known: the builder's
    /// fallback rule decides.
    var isMain: Bool? = nil
}

enum HubBatchBuilder {
    static let maxHRRowsPerRequest = 2_000
    static let maxBytesPerRequest = 256 * 1024
    /// The four event kinds that may leave the phone (CONTRACT `events[].kind`).
    static let eventWhitelist: Set<String> = ["WRIST_ON", "WRIST_OFF", "CHARGING_ON", "CHARGING_OFF"]
    /// Same 90-minute bridge NOOP's sparse-night bridging uses (SleepStager.sparseBridgeGapMin).
    static let napBridgeGapSeconds = 90 * 60

    // MARK: HR

    /// Per-minute aggregates of per-second samples: `t = floor(ts/60)*60`, exact mean, min, max, n.
    /// Samples with bpm <= 0 are not heart beats (NOOP stores 0 for no contact) and are dropped; a
    /// minute with no valid sample produces no row.
    static func minuteAggregates(_ samples: [HubHRSampleInput]) -> [HubHRMinute] {
        var acc: [Int: (sum: Int, min: Int, max: Int, n: Int)] = [:]
        for s in samples where s.bpm > 0 {
            let t = floorDiv(s.ts, 60) * 60
            if let a = acc[t] {
                acc[t] = (a.sum + s.bpm, Swift.min(a.min, s.bpm), Swift.max(a.max, s.bpm), a.n + 1)
            } else {
                acc[t] = (s.bpm, s.bpm, s.bpm, 1)
            }
        }
        return acc.keys.sorted().map { t in
            let a = acc[t]!
            return HubHRMinute(t: t, mean: Double(a.sum) / Double(a.n), min: a.min, max: a.max, n: a.n)
        }
    }

    // MARK: events, battery

    static func events(_ rows: [HubEventInput]) -> [HubEventRow] {
        var seen = Set<String>()
        return rows.filter { eventWhitelist.contains($0.kind) }
            .sorted { ($0.ts, $0.kind) < ($1.ts, $1.kind) }
            .compactMap { seen.insert("\($0.ts)|\($0.kind)").inserted ? HubEventRow(t: $0.ts, kind: $0.kind) : nil }
    }

    static func battery(_ rows: [HubBatteryInput]) -> [HubBatteryRow] {
        var seen = Set<Int>()
        return rows.sorted { $0.ts < $1.ts }.compactMap {
            seen.insert($0.ts).inserted
                ? HubBatteryRow(t: $0.ts, soc: $0.soc, mv: $0.mv, charging: $0.charging.map { $0 ? 1 : 0 })
                : nil
        }
    }

    // MARK: daily, sleep, steps

    /// R22: efficiency travels as a 0–1 fraction. NOOP's column is bimodal (its own scores are fractions,
    /// some imports percentages; `SleepView.efficiencyPct` reads it the same way): > 1 is a percentage.
    /// Clamped to 0…1; nil or non-finite → nil.
    static func efficiencyFraction(_ e: Double?) -> Double? {
        guard let e, e.isFinite else { return nil }
        return Swift.min(1, Swift.max(0, e > 1 ? e / 100 : e))
    }

    /// NOOP's `skinTempDevC` is bimodal too: CSV/Apple imports put an ABSOLUTE wrist °C there.
    /// Same threshold as NOOP's `VitalBands.isAbsoluteSkinTemp` (>= 20 °C); an absolute is never sent as a deviation.
    static let absoluteSkinTempFloor = 20.0

    static func daily(_ d: HubDailyInput) -> HubDailyRow {
        HubDailyRow(day: d.day, recovery: d.recovery, strain: d.strain, restingHr: d.restingHr,
                    avgHrv: d.avgHrv, avgSdnn: d.avgSdnn, respRateBpm: d.respRateBpm,
                    skinTempDevC: d.skinTempDevC.flatMap { $0 >= absoluteSkinTempFloor ? nil : $0 },
                    totalSleepMin: d.totalSleepMin, efficiency: efficiencyFraction(d.efficiency),
                    disturbances: d.disturbances, exerciseCount: d.exerciseCount, steps: d.steps,
                    activeKcalEst: d.activeKcalEst)
    }

    /// Sleep rows. `local_day` = local day the session STARTED (contract). `total_min` = NOOP's own
    /// decoded asleep minutes when the adapter has them; otherwise in-bed minutes (from the effective onset)
    /// × the efficiency FRACTION (R22); null when neither exists. `efficiency` is sent as a fraction.
    /// `is_nap` = not in NOOP's main-night group when the adapter supplies `isMain`; otherwise the
    /// fallback: per local END day, the longest session and every session chained to it by gaps of at most
    /// 90 minutes form the main night (0), every other session that day is a nap (1).
    static func sleep(_ sessions: [HubSleepInput], timeZone: TimeZone) -> [HubSleepRow] {
        let sorted = sessions.sorted { $0.startTs < $1.startTs }
        var byEndDay: [String: [HubSleepInput]] = [:]
        for s in sorted { byEndDay[localDay(s.endTs, timeZone), default: []].append(s) }
        var mainStarts = Set<Int>()
        for (_, group) in byEndDay {
            guard let longest = group.max(by: { dur($0) < dur($1) || (dur($0) == dur($1) && $0.startTs > $1.startTs) })
            else { continue }
            var lo = effStart(longest), hi = longest.endTs
            mainStarts.insert(longest.startTs)
            var grew = true
            while grew {
                grew = false
                for s in group where !mainStarts.contains(s.startTs) {
                    if s.endTs >= lo - napBridgeGapSeconds && effStart(s) <= hi + napBridgeGapSeconds {
                        mainStarts.insert(s.startTs)
                        lo = Swift.min(lo, effStart(s)); hi = Swift.max(hi, s.endTs); grew = true
                    }
                }
            }
        }
        return sorted.map { s in
            let inBedMin = Double(Swift.max(0, s.endTs - effStart(s))) / 60.0
            let frac = efficiencyFraction(s.efficiency)
            let isMain = s.isMain ?? mainStarts.contains(s.startTs)
            return HubSleepRow(startTs: s.startTs, endTs: s.endTs, localDay: localDay(s.startTs, timeZone),
                               totalMin: s.asleepMin ?? frac.map { inBedMin * $0 },
                               efficiency: frac, restingHr: s.restingHr, avgHrv: s.avgHrv,
                               isNap: isMain ? 0 : 1,
                               startTsAdjusted: s.startTsAdjusted, userEdited: s.userEdited ? 1 : 0)
        }
    }

    /// Step rows: only when the status is `ok` (R10: a non-ok upload carries no step rows, never zeros).
    static func steps(_ snap: HubStepsSnapshot) -> [HubStepRow] {
        guard snap.status == .ok else { return [] }
        return snap.days.map { HubStepRow(day: $0.date, steps: $0.steps, distanceM: $0.distanceM, flights: $0.floorsAscended) }
    }

    // MARK: time helpers

    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
    static func floorHour(_ ts: Int) -> Int { floorDiv(ts, 3600) * 3600 }

    static func calendar(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
    }

    static func localDay(_ ts: Int, _ tz: TimeZone) -> String {
        let c = calendar(tz).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// First second of the local day containing `ts`.
    static func startOfLocalDay(_ ts: Int, _ tz: TimeZone) -> Int {
        Int(calendar(tz).startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))).timeIntervalSince1970)
    }

    /// Segments are hours cut additionally at local midnight (identical to hours in whole-hour zones).
    /// Every fingerprint mark and every range the uploader reads starts on a segment start, so no part of
    /// an hour that straddles midnight (half-hour zones) can fall between two requests.
    static func segmentStart(_ ts: Int, _ tz: TimeZone) -> Int { Swift.max(floorHour(ts), startOfLocalDay(ts, tz)) }
    static func segmentEnd(_ start: Int, _ tz: TimeZone) -> Int { Swift.min(floorHour(start) + 3_599, endOfLocalDay(start, tz)) }

    /// Last second of the local day containing `ts` (DST-correct: days can be 23 or 25 hours).
    static func endOfLocalDay(_ ts: Int, _ tz: TimeZone) -> Int {
        let cal = calendar(tz)
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        let next = cal.date(byAdding: .day, value: 1, to: start)!
        return Int(cal.startOfDay(for: next).timeIntervalSince1970) - 1
    }

    private static func effStart(_ s: HubSleepInput) -> Int { s.startTsAdjusted ?? s.startTs }
    private static func dur(_ s: HubSleepInput) -> Int { s.endTs - effStart(s) }
}
