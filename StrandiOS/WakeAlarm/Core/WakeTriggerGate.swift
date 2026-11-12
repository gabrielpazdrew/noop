// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The guard between the "Start Wake Alarm" Shortcuts action and a buzzing run. One run at a time;
// the switch and "Skip tomorrow" are honoured. A live-run marker counts only while it is less than
// the run cap + 60 s away from now, in either direction: a run whose events died, or a marker left in
// the future by a clock change, can never block the next morning.
import Foundation

enum WakeTriggerDecision: Equatable {
    case start
    case ignoredLiveRun
    case skippedOff
    case skippedTomorrow
}

enum WakeTriggerGate {
    /// Grace past the cap before a stale "live run" marker stops counting.
    static let liveGrace: TimeInterval = 60

    /// Order: live run → ignored; switch off → skippedOff; skip day == today → skippedTomorrow; else start.
    static func decide(settings: WakeAlarmSettings, activeRunStartedAt: Date?, now: Date,
                       cap: TimeInterval, calendar: Calendar = .current) -> WakeTriggerDecision {
        if let started = activeRunStartedAt, abs(now.timeIntervalSince(started)) < cap + liveGrace {
            return .ignoredLiveRun
        }
        if !settings.enabled { return .skippedOff }
        if let skip = settings.skipDay, skip == WakeAlarmSettings.dayString(now, calendar: calendar) {
            return .skippedTomorrow
        }
        return .start
    }
}
