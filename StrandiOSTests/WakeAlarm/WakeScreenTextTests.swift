// Fork-only (phone-hub, wake): tests for the Wake Alarm screen's plain-words text. Synthetic values.
import XCTest

final class WakeScreenTextTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-03-13 (a Friday) at h:m:s UTC.
    func at(_ h: Int, _ m: Int, _ s: Int = 0, day: Int = 13) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: h, minute: m, second: s))!
    }

    func makeRecord(_ start: Date, _ end: Date, _ reason: WakeStopReason,
                buzz: Int = 0, confirmed: Int = 0, skipped: Int = 0) -> WakeRunRecord {
        WakeRunRecord(started: start, ended: end, stopReason: reason, thresholdSource: "fallback",
                      buzzCount: buzz, confirmedBuzzCount: confirmed, skippedCount: skipped, maxBpm: nil)
    }

    func testBandAlarmWarningOnlyWhenUpstreamAlarmIsOn() {
        XCTAssertNil(WakeScreenText.bandAlarmWarning(smartAlarmOn: false))
        XCTAssertEqual(WakeScreenText.bandAlarmWarning(smartAlarmOn: true),
                       "NOOP's own Alarms toggle is on. It buzzes the band at a set clock time every day, separately from this wake alarm. Turn it off under More → App → Alarms.")
    }

    func testTwelveHourTimeWithLowercaseAmPm() {
        XCTAssertEqual(WakeScreenText.time(at(6, 5), calendar: cal), "6:05 am")
        XCTAssertEqual(WakeScreenText.time(at(0, 0), calendar: cal), "12:00 am")
        XCTAssertEqual(WakeScreenText.time(at(12, 30), calendar: cal), "12:30 pm")
        XCTAssertEqual(WakeScreenText.time(at(18, 45), calendar: cal), "6:45 pm")
    }

    func testEveryStopReasonHasPlainWords() {
        XCTAssertEqual(WakeScreenText.stopReason(.awake), "you were up (heart rate stayed high)")
        XCTAssertEqual(WakeScreenText.stopReason(.timeout), "the 45-minute watch window ended")
        XCTAssertEqual(WakeScreenText.stopReason(.buzzBudget), "10 minutes of buzzing in total")
        XCTAssertEqual(WakeScreenText.stopReason(.noHR), "no heart rate from the band for 2 minutes")
        XCTAssertEqual(WakeScreenText.stopReason(.buzzFailed), "the band missed 3 buzzes in a row")
        XCTAssertEqual(WakeScreenText.stopReason(.stopped), "you tapped Stop or turned the alarm off")
        XCTAssertEqual(WakeScreenText.stopReason(.interrupted), "NOOP was closed or restarted mid-run")
        XCTAssertEqual(WakeScreenText.stopReason(.clockMoved), "the phone's clock moved back")
    }

    func testRunTitleSameDay() {
        let r = makeRecord(at(6, 30), at(6, 34, 10), .awake)
        XCTAssertEqual(WakeScreenText.runTitle(r, calendar: cal), "Fri Mar 13, 6:30 am to 6:34 am (4 min)")
    }

    func testRunTitleUnderAMinuteAndAcrossMidnight() {
        XCTAssertEqual(WakeScreenText.runTitle(makeRecord(at(6, 30), at(6, 30, 42), .stopped), calendar: cal),
                       "Fri Mar 13, 6:30 am to 6:30 am (42 s)")
        XCTAssertEqual(WakeScreenText.runTitle(makeRecord(at(23, 58), at(0, 3, day: 14), .timeout), calendar: cal),
                       "Fri Mar 13, 11:58 pm to Sat Mar 14, 12:03 am (5 min)")
        // An end before the start (clock moved) never shows a negative length.
        XCTAssertEqual(WakeScreenText.runTitle(makeRecord(at(6, 30), at(6, 29), .clockMoved), calendar: cal),
                       "Fri Mar 13, 6:30 am to 6:29 am (0 s)")
    }

    func testRunDetailCounts() {
        XCTAssertEqual(WakeScreenText.runDetail(makeRecord(at(6, 30), at(6, 34), .awake, buzz: 3, confirmed: 3, skipped: 1)),
                       "Stopped: you were up (heart rate stayed high). 3 buzzes (3 confirmed), 1 skipped.")
        XCTAssertEqual(WakeScreenText.runDetail(makeRecord(at(6, 30), at(6, 32), .noHR, buzz: 1, confirmed: 0)),
                       "Stopped: no heart rate from the band for 2 minutes. 1 buzz (0 confirmed), 0 skipped.")
        XCTAssertEqual(WakeScreenText.runDetail(makeRecord(at(6, 30), at(6, 30), .interrupted)),
                       "Stopped: NOOP was closed or restarted mid-run. No buzzes, 0 skipped.")
    }

    func testRunDetailShowsTheV2LoopCountsWhenPresent() {
        var r = makeRecord(at(6, 30), at(7, 15), .timeout, buzz: 63, confirmed: 62, skipped: 4)
        r.quietCount = 1; r.rearmCount = 1; r.buzzingSeconds = 310
        XCTAssertEqual(WakeScreenText.runDetail(r),
                       "Stopped: the 45-minute watch window ended. Up 1× · back asleep 1× · buzzing 5 min · 63 buzzes (62 confirmed), 4 skipped.")
        r.stopReason = .buzzBudget; r.quietCount = 0; r.rearmCount = 0; r.buzzingSeconds = 42
        XCTAssertEqual(WakeScreenText.runDetail(r),
                       "Stopped: 10 minutes of buzzing in total. Up 0× · back asleep 0× · buzzing 42 s · 63 buzzes (62 confirmed), 4 skipped.")
    }

    func testRecentRunsNewestFirstCappedAtSeven() {
        let rs = (0..<10).map { i in makeRecord(at(6, i), at(6, i, 30), .awake) }
        let out = WakeScreenText.recentRuns(rs)
        XCTAssertEqual(out.count, 7)
        XCTAssertEqual(out.first, rs[9])
        XCTAssertEqual(out.last, rs[3])
        XCTAssertEqual(WakeScreenText.recentRuns([]), [])
    }

    func testSkipLines() {
        XCTAssertEqual(WakeScreenText.skipButtonTitle(target: "2026-03-14", calendar: cal), "Skip tomorrow (Sat Mar 14)")
        XCTAssertEqual(WakeScreenText.skipActiveLine(day: "2026-03-14", calendar: cal),
                       "Skipping the morning of Sat Mar 14. Tap again to cancel.")
    }
}
