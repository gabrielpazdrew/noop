// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// What the hub has acknowledged, so each upload sends only what it hasn't. Everything here moves ONLY
// when a response acks it (`HubUploadEngine.applyAck`); a failed, refused or cancelled request leaves it
// untouched, and the next upload resends the same rows (the server upserts by natural key).
//
// - Streams (`hr_minute`, `events`, `battery`): `stream[table]` = the newest acked row time. The
//   forward scan restarts at the start of that hour, so a minute that was still filling is resent.
// - `hours[table][hourStart]`: a cheap fingerprint (row count + newest ts) of each acked hour over the
//   last 48 h. A Bluetooth backfill can land rows in an hour that was already sent (the strap buffers and
//   offloads history after a link drop); a changed fingerprint resends exactly that hour.
// - `rows[daily|sleep][key]`: a hash of each acked row. Daily scores and sleep sessions are rewritten
//   after the fact (re-scores, edited nights), so a changed hash resends that row.
// Holds no health values: times, counts and opaque hashes only. Stored in UserDefaults, never the token.
import Foundation

enum HubStream: String, CaseIterable, Codable {
    case hr_minute, events, battery
}

struct HubFingerprint: Codable, Equatable {
    var count: Int
    var maxTs: Int
    static let empty = HubFingerprint(count: 0, maxTs: 0)
}

struct HubHourMark: Codable, Equatable {
    /// The fingerprint covers [hourStart, clip].
    var clip: Int
    var fp: HubFingerprint
}

struct HubWatermarks: Codable, Equatable {
    var stream: [String: Int] = [:]
    var hours: [String: [String: HubHourMark]] = [:]
    var rows: [String: [String: String]] = [:]
    /// R23: per sleep window (key = window `from`), the hash of the rows last confirmed by an ack.
    var windows: [String: String] = [:]
    /// The last run stopped with chunks still to send (catch-up), so the 10-minute floor doesn't apply.
    var catchUpPending = false
    var lastAttemptAt: Int?

    init() {}

    private enum CodingKeys: String, CodingKey { case stream, hours, rows, windows, catchUpPending, lastAttemptAt }

    /// Tolerant: a field added in a later build decodes as empty instead of dropping every watermark.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream = try c.decodeIfPresent([String: Int].self, forKey: .stream) ?? [:]
        hours = try c.decodeIfPresent([String: [String: HubHourMark]].self, forKey: .hours) ?? [:]
        rows = try c.decodeIfPresent([String: [String: String]].self, forKey: .rows) ?? [:]
        windows = try c.decodeIfPresent([String: String].self, forKey: .windows) ?? [:]
        catchUpPending = try c.decodeIfPresent(Bool.self, forKey: .catchUpPending) ?? false
        lastAttemptAt = try c.decodeIfPresent(Int.self, forKey: .lastAttemptAt)
    }

    func streamMark(_ s: HubStream) -> Int? { stream[s.rawValue] }

    func hourMark(_ s: HubStream, _ hour: Int) -> HubHourMark? { hours[s.rawValue]?[String(hour)] }

    mutating func setHourMark(_ s: HubStream, _ hour: Int, _ m: HubHourMark) {
        hours[s.rawValue, default: [:]][String(hour)] = m
    }

    func rowHash(_ t: HubTable, _ key: String) -> String? { rows[t.rawValue]?[key] }

    /// Advance a stream to `t`, never backwards.
    mutating func advance(_ s: HubStream, to t: Int) {
        stream[s.rawValue] = Swift.max(stream[s.rawValue] ?? Int.min, t)
    }

    /// Drop hour marks older than `before` and row hashes for keys that are no longer in the window.
    mutating func prune(hoursBefore before: Int, keepRowKeys: [HubTable: Set<String>], windowsBefore: Int? = nil) {
        if let wb = windowsBefore { windows = windows.filter { (Int($0.key) ?? 0) >= wb } }
        for (k, marks) in hours {
            hours[k] = marks.filter { (Int($0.key) ?? 0) >= before }
        }
        for (t, keep) in keepRowKeys {
            if let cur = rows[t.rawValue] { rows[t.rawValue] = cur.filter { keep.contains($0.key) } }
        }
    }
}

/// Persistence for HubWatermarks (JSON in UserDefaults key `hub.watermarks`).
final class HubWatermarkStore {
    static let key = "hub.watermarks"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> HubWatermarks {
        guard let data = defaults.data(forKey: Self.key),
              let w = try? JSONDecoder().decode(HubWatermarks.self, from: data) else { return HubWatermarks() }
        return w
    }

    func save(_ w: HubWatermarks) {
        if let data = try? JSONEncoder().encode(w) { defaults.set(data, forKey: Self.key) }
    }
}
