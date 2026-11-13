// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The wake alarm's strap-log lines (PLAN-WAKE-PHONE T3), all prefixed "Wake:", so a pulled strap log
// can be read with one grep. Only run facts: the two lines and their source, counts, stop reason, max HR.
import Foundation

enum WakeLogText {
    static func start(upLine: Double, asleepLine: Double, source: WakeThresholdSource, bandAlarmOn: Bool) -> String {
        "Wake: start, up line \(bpm(upLine)) bpm, back-asleep line \(bpm(asleepLine)) bpm (source \(source.logDescription)), band alarm \(bandAlarmOn ? "ON" : "off")"
    }

    static func bpm(_ v: Double) -> String { String(format: "%.0f", v) }

    static func buzz(_ n: Int) -> String { "Wake: buzz #\(n)" }

    static func skipped(_ reason: String) -> String { "Wake: buzz skipped (\(reason))" }

    /// An engine `.log` line (e.g. "buzz FAILED (1/3): …", "quiet (2-min average ≥ 64 bpm) after 130s, 63 buzz(es)").
    static func engine(_ line: String) -> String { "Wake: \(line)" }

    static func stop(_ state: WakeRunState, reason: WakeStopReason, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(state.started)))
        let maxHR = state.maxBpm.map(String.init) ?? "none"
        let buzzing = Int(state.buzzingSeconds(at: max(now, state.started)))
        return "Wake: stop \(reason.rawValue) after \(secs)s, \(state.buzzCount) buzz(es) (\(state.confirmedBuzzCount) confirmed), \(state.skippedCount) skipped, buzzing \(buzzing)s, quiet \(state.quietCount)x, back asleep \(state.rearmCount)x, max HR \(maxHR)"
    }

    static let ignoredLiveRun = "Wake: trigger ignored (run already live)"
    static let skippedOff = "Wake: skipped (switch off)"

    /// "Wake: skipped (skip tomorrow, Fri Nov 14)" from the stored `yyyy-MM-dd`.
    static func skippedTomorrow(day: String, calendar: Calendar) -> String {
        "Wake: skipped (skip tomorrow, \(shortDay(day, calendar: calendar)))"
    }

    /// Previous process left a run marker: recorded as interrupted, never resumed.
    static let interrupted = "Wake: stop interrupted (app relaunched; the earlier run is not resumed)"
    /// The one best-effort stop sent after an interrupted run, once the link was ready.
    static let interruptedHapticsCleared = "Wake: sent stop-haptics after the interrupted run"

    /// `yyyy-MM-dd` → "Fri Nov 14" (English, the calendar's time zone); the raw string if it won't parse.
    static func shortDay(_ day: String, calendar: Calendar) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.calendar = calendar
        parse.timeZone = calendar.timeZone
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: day) else { return day }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.calendar = calendar
        out.timeZone = calendar.timeZone
        out.dateFormat = "EEE MMM d"
        return out.string(from: d)
    }
}
