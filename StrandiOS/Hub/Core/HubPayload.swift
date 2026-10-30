// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The v1 wire payload for `POST /ingest/phone` (hub/test/fixtures/CONTRACT.md, ruling R1).
// Every row type lists exactly the contract's columns. There is deliberately no field anywhere for
// SpO2, sleep stages, RR intervals or per-second samples: they cannot be encoded because they
// cannot be represented. Nullable columns are encoded as an explicit `null` (the contract says
// "nullable = key present with null allowed"), so every row has the full key set.
import Foundation

struct HubDevice: Equatable {
    var appVersion: String
    var build: String
    var bandFw: String?
    var bandBattery: Double?
    var embeddedExpiry: Int?
    var tz: String
    /// One of `ok | denied | unavailable | not_determined | error` (ruling R10).
    var stepsStatus: String
}

struct HubDailyRow: Equatable {
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

struct HubSleepRow: Equatable {
    var startTs: Int
    var endTs: Int
    var localDay: String
    var totalMin: Double?
    var efficiency: Double?
    var restingHr: Int?
    var avgHrv: Double?
    var isNap: Int
    var startTsAdjusted: Int?
    var userEdited: Int
}

struct HubHRMinute: Equatable {
    var t: Int
    var mean: Double
    var min: Int
    var max: Int
    var n: Int
}

struct HubEventRow: Equatable {
    var t: Int
    var kind: String
}

struct HubBatteryRow: Equatable {
    var t: Int
    var soc: Double?
    var mv: Int?
    var charging: Int?
}

struct HubStepRow: Equatable {
    var day: String
    var steps: Int?
    var distanceM: Double?
    var flights: Int?
}

/// R23: `[from, to)` epoch seconds. Present = `sleep[]` holds ALL sessions NOOP has starting in the
/// window; the server supersedes stored sessions in it that are missing. The phone uses one local day.
struct HubSleepWindow: Equatable {
    var from: Int
    var to: Int
    static let maxSpan = 8 * 86_400
}

struct HubPayload: Equatable {
    var device: HubDevice
    var sleepWindow: HubSleepWindow? = nil
    var daily: [HubDailyRow] = []
    var sleep: [HubSleepRow] = []
    var hrMinute: [HubHRMinute] = []
    var events: [HubEventRow] = []
    var battery: [HubBatteryRow] = []
    var steps: [HubStepRow] = []
}

/// The payload's tables, by their wire (and ack) names.
enum HubTable: String, CaseIterable, Codable {
    case daily, sleep, hr_minute, events, battery, steps
}

// MARK: - Encoding

/// Encodes to JSON with explicit nulls and sorted keys (deterministic bytes, so row hashes are stable).
enum HubWireError: Error { case badSleepWindow }

enum HubWire {
    /// Throws (never sends) when a sleep window breaks R23: `from < to`, span ≤ 8 days, every `sleep[]`
    /// row's `start_ts` in `[from, to)`. The server would 422 it; the phone refuses it first.
    static func encode(_ p: HubPayload) throws -> Data {
        if let w = p.sleepWindow {
            guard w.from < w.to, w.to - w.from <= HubSleepWindow.maxSpan,
                  p.sleep.allSatisfy({ $0.startTs >= w.from && $0.startTs < w.to }) else { throw HubWireError.badSleepWindow }
        }
        return try JSONSerialization.data(withJSONObject: object(p), options: [.sortedKeys])
    }

    static func object(_ p: HubPayload) -> [String: Any] {
        var o = base(p)
        if let w = p.sleepWindow { o["sleep_window"] = ["from": w.from, "to": w.to] }   // absent when not set
        return o
    }

    private static func base(_ p: HubPayload) -> [String: Any] {
        [
            "schema": 1,
            "device": device(p.device),
            "daily": p.daily.map(daily),
            "sleep": p.sleep.map(sleep),
            "hr_minute": p.hrMinute.map(hr),
            "events": p.events.map(event),
            "battery": p.battery.map(battery),
            "steps": p.steps.map(step),
        ]
    }

    static func device(_ d: HubDevice) -> [String: Any] {
        ["app_version": d.appVersion, "build": d.build, "band_fw": v(d.bandFw), "band_battery": v(d.bandBattery),
         "embedded_expiry": v(d.embeddedExpiry), "tz": d.tz, "steps_status": d.stepsStatus]
    }

    static func daily(_ r: HubDailyRow) -> [String: Any] {
        ["day": r.day, "recovery": v(r.recovery), "strain": v(r.strain), "resting_hr": v(r.restingHr),
         "avg_hrv": v(r.avgHrv), "avg_sdnn": v(r.avgSdnn), "resp_rate_bpm": v(r.respRateBpm),
         "skin_temp_dev_c": v(r.skinTempDevC), "total_sleep_min": v(r.totalSleepMin),
         "efficiency": v(r.efficiency), "disturbances": v(r.disturbances),
         "exercise_count": v(r.exerciseCount), "steps": v(r.steps), "active_kcal_est": v(r.activeKcalEst)]
    }

    static func sleep(_ r: HubSleepRow) -> [String: Any] {
        ["start_ts": r.startTs, "end_ts": r.endTs, "local_day": r.localDay, "total_min": v(r.totalMin),
         "efficiency": v(r.efficiency), "resting_hr": v(r.restingHr), "avg_hrv": v(r.avgHrv),
         "is_nap": r.isNap, "start_ts_adjusted": v(r.startTsAdjusted), "user_edited": r.userEdited]
    }

    static func hr(_ r: HubHRMinute) -> [String: Any] {
        ["t": r.t, "mean": r.mean, "min": r.min, "max": r.max, "n": r.n]
    }

    static func event(_ r: HubEventRow) -> [String: Any] { ["t": r.t, "kind": r.kind] }

    static func battery(_ r: HubBatteryRow) -> [String: Any] {
        ["t": r.t, "soc": v(r.soc), "mv": v(r.mv), "charging": v(r.charging)]
    }

    static func step(_ r: HubStepRow) -> [String: Any] {
        ["day": r.day, "steps": v(r.steps), "distance_m": v(r.distanceM), "flights": v(r.flights)]
    }

    /// R23: one hash for a whole window's rows (order-free). An empty window has its own hash, so a vanished
    /// session changes it.
    static func windowHash(_ rows: [HubSleepRow]) -> String {
        fnv(Data(rows.map { rowHash(sleep($0)) }.sorted().joined(separator: ",").utf8) + Data("|w".utf8))
    }

    /// Stable 64-bit FNV-1a of a row's canonical JSON. Swift's `Hasher` is seeded per launch, so it
    /// can't remember "this row was already acked" across launches; this can.
    static func rowHash(_ row: [String: Any]) -> String {
        fnv((try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data())
    }

    private static func fnv(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    private static func v<T>(_ x: T?) -> Any { x.map { $0 as Any } ?? NSNull() }
}
