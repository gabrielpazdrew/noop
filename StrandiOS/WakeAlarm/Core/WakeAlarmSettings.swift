// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The wake alarm's two user settings, over an injected UserDefaults: the "Wake alarm" switch (on by
// default) and the one-shot "Skip tomorrow" day, which clears itself once that morning has passed.
import Foundation

struct WakeAlarmSettings {
    enum Key {
        static let enabled = "wake.enabled"
        static let skipDay = "wake.skipDay"
    }

    /// Before this hour, "Skip tomorrow" means the coming morning (today's date).
    static let skipCutoffHour = 4

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// On when the key was never written.
    var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) == nil ? true : defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// The local `yyyy-MM-dd` morning to skip, or nil.
    var skipDay: String? {
        get { defaults.string(forKey: Key.skipDay) }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.skipDay) } else { defaults.removeObject(forKey: Key.skipDay) }
        }
    }

    /// The day "Skip tomorrow" targets when tapped at `now`: before 4:00 am it is today (the coming
    /// morning), otherwise tomorrow. The screen shows the resolved date, so there is no guessing.
    static func skipTargetDay(now: Date, calendar: Calendar) -> String {
        if calendar.component(.hour, from: now) < skipCutoffHour {
            return dayString(now, calendar: calendar)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return dayString(tomorrow, calendar: calendar)
    }

    /// Clears the skip once today's date is after the skipped day (never on the day itself).
    mutating func clearSkipIfPassed(now: Date, calendar: Calendar) {
        guard let day = skipDay else { return }
        if Self.dayString(now, calendar: calendar) > day { skipDay = nil }
    }

    /// Local `yyyy-MM-dd` (zero-padded, so string order is date order).
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
