// Fork-only (phone-hub, wake): tests for the wake alarm's trigger gate, the guard between the
// Shortcuts action and a buzzing run. Synthetic dates, fixed UTC calendar.
import XCTest

final class WakeTriggerGateTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let cap: TimeInterval = 600
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        super.setUp()
        suiteName = "wake.gate.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 2026-03-11 06:30 UTC: a synthetic morning.
    var morning: Date { cal.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 6, minute: 30))! }

    func decide(_ s: WakeAlarmSettings, live: Date? = nil, now: Date? = nil) -> WakeTriggerDecision {
        WakeTriggerGate.decide(settings: s, activeRunStartedAt: live, now: now ?? morning, cap: cap, calendar: cal)
    }

    func testDefaultSettingsStart() {
        XCTAssertEqual(decide(WakeAlarmSettings(defaults: defaults)), .start)
    }

    func testSwitchOffIsSkippedOff() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.enabled = false
        XCTAssertEqual(decide(s), .skippedOff)
    }

    func testSkipSetForTodaySkips() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.skipDay = "2026-03-11"
        XCTAssertEqual(decide(s), .skippedTomorrow)
    }

    func testSkipSetForTomorrowStillStartsToday() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.skipDay = "2026-03-12"
        XCTAssertEqual(decide(s), .start)
    }

    func testSkipFromLastNightAppliesThisMorning() {
        // Set at 10:15 pm the night before → targets this morning → this morning's trigger is skipped.
        var s = WakeAlarmSettings(defaults: defaults)
        let lastNight = morning.addingTimeInterval(-(8 * 3600 + 15 * 60))
        s.skipDay = WakeAlarmSettings.skipTargetDay(now: lastNight, calendar: cal)
        XCTAssertEqual(decide(s), .skippedTomorrow)
    }

    func testTriggerFiveSecondsIntoALiveRunIsIgnored() {
        let s = WakeAlarmSettings(defaults: defaults)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(-5)), .ignoredLiveRun)
    }

    func testLiveRunWinsOverOffAndSkip() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.enabled = false
        s.skipDay = "2026-03-11"
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(-5)), .ignoredLiveRun)
    }

    func testOffWinsOverSkip() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.enabled = false
        s.skipDay = "2026-03-11"
        XCTAssertEqual(decide(s), .skippedOff)
    }

    func testLiveMarkerExpiresAtCapPlusSixty() {
        let s = WakeAlarmSettings(defaults: defaults)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(-(cap + 59))), .ignoredLiveRun)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(-(cap + 60))), .start)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(-86_400)), .start)
    }

    func testFutureMarkerCountsOnlyWithinCapPlusSixty() {
        let s = WakeAlarmSettings(defaults: defaults)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(5)), .ignoredLiveRun)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(cap + 59)), .ignoredLiveRun)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(cap + 60)), .start)
        XCTAssertEqual(decide(s, live: morning.addingTimeInterval(3 * 86_400)), .start)
    }
}
