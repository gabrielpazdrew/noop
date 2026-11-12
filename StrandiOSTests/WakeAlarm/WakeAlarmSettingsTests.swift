// Fork-only (phone-hub, wake): tests for the wake alarm's switch, "Skip tomorrow" and run record.
// Synthetic dates only, in a fixed UTC calendar so the results don't depend on the test machine.
import XCTest

final class WakeAlarmSettingsTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        super.setUp()
        suiteName = "wake.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: settings

    func testDefaultOnWithNoKeys() {
        let s = WakeAlarmSettings(defaults: defaults)
        XCTAssertTrue(s.enabled)
        XCTAssertNil(s.skipDay)
    }

    func testSwitchAndSkipPersistAcrossInstances() {
        var a = WakeAlarmSettings(defaults: defaults)
        a.enabled = false
        a.skipDay = "2026-03-10"
        let b = WakeAlarmSettings(defaults: defaults)
        XCTAssertFalse(b.enabled)
        XCTAssertEqual(b.skipDay, "2026-03-10")
        a.enabled = true
        a.skipDay = nil
        let c = WakeAlarmSettings(defaults: defaults)
        XCTAssertTrue(c.enabled)
        XCTAssertNil(c.skipDay)
        XCTAssertNil(defaults.object(forKey: "wake.skipDay"))
    }

    func testSkipTargetBeforeFourAmIsToday() {
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 3, 10, 0, 30), calendar: cal), "2026-03-10")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 3, 10, 3, 59), calendar: cal), "2026-03-10")
    }

    func testSkipTargetFromFourAmIsTomorrow() {
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 3, 10, 4, 0), calendar: cal), "2026-03-11")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 3, 10, 22, 15), calendar: cal), "2026-03-11")
    }

    func testSkipTargetAcrossAMonthAndYearEnd() {
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 1, 31, 21), calendar: cal), "2026-02-01")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 2, 28, 21), calendar: cal), "2026-03-01")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: date(2026, 12, 31, 21), calendar: cal), "2027-01-01")
    }

    func testSkipClearsItselfTheDayAfterAndNotBefore() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.skipDay = "2026-03-11"
        s.clearSkipIfPassed(now: date(2026, 3, 10, 23, 59), calendar: cal)
        XCTAssertEqual(s.skipDay, "2026-03-11")
        s.clearSkipIfPassed(now: date(2026, 3, 11, 6, 0), calendar: cal)   // the skipped morning itself
        XCTAssertEqual(s.skipDay, "2026-03-11")
        s.clearSkipIfPassed(now: date(2026, 3, 11, 23, 59), calendar: cal)
        XCTAssertEqual(s.skipDay, "2026-03-11")
        s.clearSkipIfPassed(now: date(2026, 3, 12, 0, 0), calendar: cal)
        XCTAssertNil(s.skipDay)
    }

    func testClearSkipAcrossAMonthEnd() {
        var s = WakeAlarmSettings(defaults: defaults)
        s.skipDay = "2026-01-31"
        s.clearSkipIfPassed(now: date(2026, 2, 1, 0, 1), calendar: cal)
        XCTAssertNil(s.skipDay)
    }

    // MARK: run record

    func record(_ k: Int) -> WakeRunRecord {
        WakeRunRecord(started: Date(timeIntervalSince1970: 1_700_000_000 + Double(k) * 86_400),
                      ended: Date(timeIntervalSince1970: 1_700_000_300 + Double(k) * 86_400),
                      stopReason: .awake, thresholdSource: "fallback",
                      buzzCount: k, skippedCount: 1, maxBpm: k % 2 == 0 ? nil : 80)
    }

    func testRecordRoundTrip() throws {
        let log = WakeRunLog(defaults: defaults)
        let r = WakeRunRecord(started: Date(timeIntervalSince1970: 1_700_000_000),
                              ended: Date(timeIntervalSince1970: 1_700_000_123),
                              stopReason: .buzzFailed, thresholdSource: "median_last_20min=60(n=40) capped",
                              buzzCount: 7, skippedCount: 2, maxBpm: 88)
        log.append(r)
        let again = WakeRunLog(defaults: defaults).records
        XCTAssertEqual(again, [r])
        let noMax = record(2)
        log.append(noMax)
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [r, noMax])
    }

    func testRunLogKeepsTheLastFourteen() {
        let log = WakeRunLog(defaults: defaults)
        for k in 0..<20 { log.append(record(k)) }
        let kept = WakeRunLog(defaults: defaults).records
        XCTAssertEqual(kept.count, 14)
        XCTAssertEqual(kept.first, record(6))
        XCTAssertEqual(kept.last, record(19))
    }

    func testRunLogEmptyAndCorruptReadAsEmpty() {
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [])
        defaults.set(Data("not json".utf8), forKey: "wake.runs")
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [])
    }

    func testActiveRunMarkerPersistsAndClears() {
        let log = WakeRunLog(defaults: defaults)
        XCTAssertNil(log.activeRunStartedAt)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        log.activeRunStartedAt = t
        XCTAssertEqual(WakeRunLog(defaults: defaults).activeRunStartedAt, t)
        log.activeRunStartedAt = nil
        XCTAssertNil(WakeRunLog(defaults: defaults).activeRunStartedAt)
        XCTAssertNil(defaults.object(forKey: "wake.activeRunStartedAt"))
    }
}
