// Fork-only (phone-hub, wake): tests for the wake alarm's strap-log lines. Synthetic values.
import XCTest

final class WakeLogTextTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartLine() {
        XCTAssertEqual(WakeLogText.start(threshold: 70, source: .fallback, bandAlarmOn: false),
                       "Wake: start, threshold 70 bpm (source fallback), band alarm off")
        XCTAssertEqual(WakeLogText.start(threshold: 75, source: .restingHR(60), bandAlarmOn: true),
                       "Wake: start, threshold 75 bpm (source resting_hr=60), band alarm ON")
    }

    func testBuzzSkipAndEngineLines() {
        XCTAssertEqual(WakeLogText.buzz(3), "Wake: buzz #3")
        XCTAssertEqual(WakeLogText.skipped("link not ready"), "Wake: buzz skipped (link not ready)")
        XCTAssertEqual(WakeLogText.engine("buzz FAILED (1/3): x"), "Wake: buzz FAILED (1/3): x")
    }

    func testStopLine() {
        var s = WakeRunState.begin(started: t0, threshold: 70, warmup: [], config: WakeConfig())
        s.buzzCount = 12; s.confirmedBuzzCount = 11; s.skippedCount = 2; s.maxBpm = 88
        XCTAssertEqual(WakeLogText.stop(s, reason: .awake, now: t0.addingTimeInterval(95.7)),
                       "Wake: stop awake after 95s, 12 buzz(es) (11 confirmed), 2 skipped, max HR 88")
        s.maxBpm = nil
        XCTAssertEqual(WakeLogText.stop(s, reason: .clockMoved, now: t0.addingTimeInterval(-50)),
                       "Wake: stop clockMoved after 0s, 12 buzz(es) (11 confirmed), 2 skipped, max HR none")
    }

    func testSkippedLines() {
        XCTAssertEqual(WakeLogText.skippedOff, "Wake: skipped (switch off)")
        XCTAssertEqual(WakeLogText.ignoredLiveRun, "Wake: trigger ignored (run already live)")
        XCTAssertEqual(WakeLogText.skippedTomorrow(day: "2026-03-13", calendar: cal),
                       "Wake: skipped (skip tomorrow, Fri Mar 13)")
        XCTAssertEqual(WakeLogText.shortDay("garbage", calendar: cal), "garbage")
    }
}
