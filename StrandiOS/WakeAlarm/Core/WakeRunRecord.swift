// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// A short on-phone record of each wake run, for the Wake Alarm screen (the strap log stays the
// durable trace), plus the "a run is live" marker the trigger gate reads. Stays on the phone.
import Foundation

struct WakeRunRecord: Codable, Equatable {
    var started: Date
    var ended: Date
    var stopReason: WakeStopReason
    /// `WakeThresholdSource.logDescription`.
    var thresholdSource: String
    /// Buzzes requested.
    var buzzCount: Int
    /// Buzzes reported as written OK.
    var confirmedBuzzCount: Int
    var skippedCount: Int
    var maxBpm: Int?
    /// v2 (Nov 12, 2026). nil on v1 records and on interrupted runs (the killed process took them along).
    /// Times the run went quiet (HR showed he was up).
    var quietCount: Int? = nil
    /// Times it went back to buzzing (HR showed he fell back asleep).
    var rearmCount: Int? = nil
    /// Seconds spent buzzing, all buzzing stretches added up.
    var buzzingSeconds: Int? = nil

    /// What a relaunch records for a run the killed process left live: nothing about it is known.
    static func interrupted(started: Date, ended: Date) -> WakeRunRecord {
        WakeRunRecord(started: started, ended: ended, stopReason: .interrupted, thresholdSource: "unknown",
                      buzzCount: 0, confirmedBuzzCount: 0, skippedCount: 0, maxBpm: nil)
    }
}

final class WakeRunLog {
    enum Key {
        static let runs = "wake.runs"
        static let activeRunStartedAt = "wake.activeRunStartedAt"
    }

    static let keep = 14

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Oldest first; empty when nothing was stored or the stored value can't be read. A single
    /// record that won't decode is skipped, not the whole history.
    var records: [WakeRunRecord] {
        guard let data = defaults.data(forKey: Key.runs),
              let list = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return list.compactMap(\.record)
    }

    private struct Lenient: Decodable {
        let record: WakeRunRecord?
        init(from decoder: Decoder) throws { record = try? WakeRunRecord(from: decoder) }
    }

    /// Appends one record, keeping the newest `keep`.
    func append(_ record: WakeRunRecord) {
        let list = Array((records + [record]).suffix(Self.keep))
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Key.runs) }
    }

    /// Start of the run this process (or a killed earlier one) left live; nil when none.
    var activeRunStartedAt: Date? {
        get {
            guard defaults.object(forKey: Key.activeRunStartedAt) != nil else { return nil }
            return Date(timeIntervalSince1970: defaults.double(forKey: Key.activeRunStartedAt))
        }
        set {
            if let d = newValue {
                defaults.set(d.timeIntervalSince1970, forKey: Key.activeRunStartedAt)
            } else {
                defaults.removeObject(forKey: Key.activeRunStartedAt)
            }
        }
    }
}
