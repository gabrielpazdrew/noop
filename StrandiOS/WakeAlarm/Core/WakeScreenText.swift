// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The Wake Alarm screen's plain-words text (PLAN-WAKE-PHONE T6): 12-hour times, why a run stopped,
// the run list and the "Skip tomorrow" lines. Pure formatting; no decisions about whether to run.
import Foundation

enum WakeScreenText {
    /// How many past runs the screen lists.
    static let shownRuns = 7

    /// "6:05 am" (12-hour, lowercase am/pm, in the calendar's time zone).
    static func time(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// Why a run stopped, in plain words (completes "Stopped: …").
    static func stopReason(_ reason: WakeStopReason) -> String {
        let config = WakeConfig()
        switch reason {
        case .awake: return "you were up (heart rate stayed high)"
        case .timeout: return "the \(Int(config.cap) / 60)-minute limit"
        case .noHR: return "no heart rate from the band for \(Int(config.noHRLimit) / 60) minutes"
        case .buzzFailed: return "the band missed \(config.maxBuzzFailures) buzzes in a row"
        case .stopped: return "you tapped Stop or turned the alarm off"
        case .interrupted: return "NOOP was closed or restarted mid-run"
        case .clockMoved: return "the phone's clock moved back"
        }
    }

    /// "Fri Mar 13, 6:30 am to 6:34 am (4 min)"; the end carries its own day when it differs.
    static func runTitle(_ r: WakeRunRecord, calendar: Calendar) -> String {
        let startDay = WakeAlarmSettings.dayString(r.started, calendar: calendar)
        let endDay = WakeAlarmSettings.dayString(r.ended, calendar: calendar)
        let start = "\(WakeLogText.shortDay(startDay, calendar: calendar)), \(time(r.started, calendar: calendar))"
        let end = endDay == startDay || r.ended < r.started
            ? time(r.ended, calendar: calendar)
            : "\(WakeLogText.shortDay(endDay, calendar: calendar)), \(time(r.ended, calendar: calendar))"
        let secs = max(0, Int(r.ended.timeIntervalSince(r.started)))
        let length = secs < 60 ? "\(secs) s" : "\(secs / 60) min"
        return "\(start) to \(end) (\(length))"
    }

    /// "Stopped: <reason>. 3 buzzes (3 confirmed), 1 skipped."
    static func runDetail(_ r: WakeRunRecord) -> String {
        let buzzes: String
        switch r.buzzCount {
        case 0: buzzes = "No buzzes"
        case 1: buzzes = "1 buzz (\(r.confirmedBuzzCount) confirmed)"
        default: buzzes = "\(r.buzzCount) buzzes (\(r.confirmedBuzzCount) confirmed)"
        }
        return "Stopped: \(stopReason(r.stopReason)). \(buzzes), \(r.skippedCount) skipped."
    }

    /// The newest `shownRuns` records, newest first (`WakeRunLog.records` is oldest first).
    static func recentRuns(_ records: [WakeRunRecord]) -> [WakeRunRecord] {
        Array(records.suffix(shownRuns).reversed())
    }

    /// "Skip tomorrow (Sat Mar 14)" for the morning a tap would skip.
    static func skipButtonTitle(target: String, calendar: Calendar) -> String {
        "Skip tomorrow (\(WakeLogText.shortDay(target, calendar: calendar)))"
    }

    /// Shown while a skip is set.
    static func skipActiveLine(day: String, calendar: Calendar) -> String {
        "Skipping the morning of \(WakeLogText.shortDay(day, calendar: calendar)). Tap again to cancel."
    }
}
