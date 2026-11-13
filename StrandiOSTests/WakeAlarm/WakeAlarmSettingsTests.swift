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

    func testSkipTargetAcrossDaylightSavingInLosAngeles() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func local(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            la.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
        }
        // Spring forward, 2026-03-08: 2:00 am jumps to 3:00 am.
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: local(3, 8, 3, 30), calendar: la), "2026-03-08")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: local(3, 8, 4, 0), calendar: la), "2026-03-09")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: local(3, 7, 22, 0), calendar: la), "2026-03-08")
        // Fall back, 2026-11-01: 1:00–2:00 am happens twice (08:00–09:00 and 09:00–10:00 UTC).
        let firstOneThirty = Date(timeIntervalSince1970: 1_793_521_800)    // 2026-11-01 08:30 UTC = 1:30 am PDT
        let secondOneThirty = firstOneThirty.addingTimeInterval(3600)       // 1:30 am PST
        XCTAssertEqual(la.component(.hour, from: firstOneThirty), 1)
        XCTAssertEqual(la.component(.hour, from: secondOneThirty), 1)
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: firstOneThirty, calendar: la), "2026-11-01")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: secondOneThirty, calendar: la), "2026-11-01")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: local(11, 1, 4, 0), calendar: la), "2026-11-02")
        XCTAssertEqual(WakeAlarmSettings.skipTargetDay(now: local(10, 31, 22, 0), calendar: la), "2026-11-01")
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

    func makeRecord(_ k: Int) -> WakeRunRecord {
        WakeRunRecord(started: Date(timeIntervalSince1970: 1_700_000_000 + Double(k) * 86_400),
                      ended: Date(timeIntervalSince1970: 1_700_000_300 + Double(k) * 86_400),
                      stopReason: .awake, thresholdSource: "fallback",
                      buzzCount: k, confirmedBuzzCount: k / 2, skippedCount: 1, maxBpm: k % 2 == 0 ? nil : 80)
    }

    func testRecordRoundTrip() throws {
        let log = WakeRunLog(defaults: defaults)
        let r = WakeRunRecord(started: Date(timeIntervalSince1970: 1_700_000_000),
                              ended: Date(timeIntervalSince1970: 1_700_000_123),
                              stopReason: .buzzFailed, thresholdSource: "median_last_20min=60(n=40) capped",
                              buzzCount: 7, confirmedBuzzCount: 5, skippedCount: 2, maxBpm: 88)
        log.append(r)
        let again = WakeRunLog(defaults: defaults).records
        XCTAssertEqual(again, [r])
        let noMax = makeRecord(2)
        log.append(noMax)
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [r, noMax])
        var v2 = makeRecord(3)
        v2.stopReason = .buzzBudget; v2.quietCount = 2; v2.rearmCount = 1; v2.buzzingSeconds = 600
        log.append(v2)
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [r, noMax, v2])
    }

    func testInterruptedRecordCarriesNilForTheLoopCounts() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let r = WakeRunRecord.interrupted(started: start, ended: start.addingTimeInterval(400))
        XCTAssertEqual(r.stopReason, .interrupted)
        XCTAssertEqual(r.thresholdSource, "unknown")
        XCTAssertEqual(r.buzzCount, 0)
        XCTAssertNil(r.maxBpm)
        XCTAssertNil(r.quietCount)
        XCTAssertNil(r.rearmCount)
        XCTAssertNil(r.buzzingSeconds)
        let log = WakeRunLog(defaults: defaults)
        log.append(r)
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [r])
    }

    func testV1RecordWithoutTheLoopCountsStillDecodes() throws {
        // A record written by v1 (no quietCount / rearmCount / buzzingSeconds, stop reason "awake").
        let old: [[String: Any]] = [[
            "started": 700_000_000.0, "ended": 700_000_095.0, "stopReason": "awake",
            "thresholdSource": "resting_hr=49", "buzzCount": 1, "confirmedBuzzCount": 1, "skippedCount": 0,
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "wake.runs")
        let got = WakeRunLog(defaults: defaults).records
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.stopReason, .awake)
        XCTAssertNil(got.first?.quietCount)
        XCTAssertNil(got.first?.rearmCount)
        XCTAssertNil(got.first?.buzzingSeconds)
        XCTAssertNil(got.first?.maxBpm)
    }

    func testRunLogKeepsTheLastFourteen() {
        let log = WakeRunLog(defaults: defaults)
        for k in 0..<20 { log.append(makeRecord(k)) }
        let kept = WakeRunLog(defaults: defaults).records
        XCTAssertEqual(kept.count, 14)
        XCTAssertEqual(kept.first, makeRecord(6))
        XCTAssertEqual(kept.last, makeRecord(19))
    }

    func testRunLogEmptyAndCorruptReadAsEmpty() {
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [])
        defaults.set(Data("not json".utf8), forKey: "wake.runs")
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [])
    }

    func testOneUndecodableRecordDoesNotDropTheHistory() throws {
        let log = WakeRunLog(defaults: defaults)
        log.append(makeRecord(1))
        log.append(makeRecord(3))
        let data = try XCTUnwrap(defaults.data(forKey: "wake.runs"))
        var list = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        list.insert(["started": "garbage"], at: 1)
        list.append(42)
        defaults.set(try JSONSerialization.data(withJSONObject: list), forKey: "wake.runs")
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [makeRecord(1), makeRecord(3)])
        log.append(makeRecord(5))
        XCTAssertEqual(WakeRunLog(defaults: defaults).records, [makeRecord(1), makeRecord(3), makeRecord(5)])
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
