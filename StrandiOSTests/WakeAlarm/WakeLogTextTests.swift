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
        XCTAssertEqual(WakeLogText.start(upLine: 70, asleepLine: 63, source: .fallback, bandAlarmOn: false),
                       "Wake: start, up line 70 bpm, back-asleep line 63 bpm (source fallback), band alarm off")
        XCTAssertEqual(WakeLogText.start(upLine: 64, asleepLine: 57, source: .restingHR(49), bandAlarmOn: true),
                       "Wake: start, up line 64 bpm, back-asleep line 57 bpm (source resting_hr=49), band alarm ON")
    }

    func testBuzzSkipAndEngineLines() {
        XCTAssertEqual(WakeLogText.buzz(3), "Wake: buzz #3")
        XCTAssertEqual(WakeLogText.skipped("link not ready"), "Wake: buzz skipped (link not ready)")
        XCTAssertEqual(WakeLogText.engine("buzz FAILED (1/3): x"), "Wake: buzz FAILED (1/3): x")
    }

    func testStopLine() {
        var s = WakeRunState.begin(started: t0, upLine: 70, asleepLine: 63, warmup: [], config: WakeConfig())
        s.buzzCount = 12; s.confirmedBuzzCount = 11; s.skippedCount = 2; s.maxBpm = 88
        XCTAssertEqual(WakeLogText.stop(s, reason: .stopped, now: t0.addingTimeInterval(95.7)),
                       "Wake: stop stopped after 95s, 12 buzz(es) (11 confirmed), 2 skipped, buzzing 95s, quiet 0x, back asleep 0x, max HR 88")
        s.buzzingDone = 300; s.buzzingSince = nil; s.quietCount = 2; s.rearmCount = 1
        XCTAssertEqual(WakeLogText.stop(s, reason: .timeout, now: t0.addingTimeInterval(2700)),
                       "Wake: stop timeout after 2700s, 12 buzz(es) (11 confirmed), 2 skipped, buzzing 300s, quiet 2x, back asleep 1x, max HR 88")
        s.maxBpm = nil; s.buzzingDone = 0; s.buzzingSince = t0
        XCTAssertEqual(WakeLogText.stop(s, reason: .clockMoved, now: t0.addingTimeInterval(-50)),
                       "Wake: stop clockMoved after 0s, 12 buzz(es) (11 confirmed), 2 skipped, buzzing 0s, quiet 2x, back asleep 1x, max HR none")
    }

    func testNoLinkLines() {
        XCTAssertEqual(WakeLogText.noLinkStop(secs: 22, noLinkCase: .notConnected, reconnectRequested: true),
                       "Wake: stop noLink — band not connected after 22s (reconnect requested)")
        XCTAssertEqual(WakeLogText.noLinkStop(secs: 21, noLinkCase: .notConnected, reconnectRequested: false),
                       "Wake: stop noLink — band not connected after 21s (no reconnect requested)")
        for asked in [true, false] {
            XCTAssertEqual(WakeLogText.noLinkStop(secs: 22, noLinkCase: .connectedNoHR, reconnectRequested: asked),
                           "Wake: stop noLink — band connected but no heart rate after 22s")
        }
        XCTAssertEqual(WakeLogText.reconnectRequested, "Wake: no link at start, reconnect requested")
        XCTAssertEqual(WakeLogText.waitingForHR, "Wake: no fresh heart rate yet, waiting for the band")
    }

    func testSkippedLines() {
        XCTAssertEqual(WakeLogText.skippedOff, "Wake: skipped (switch off)")
        XCTAssertEqual(WakeLogText.ignoredLiveRun, "Wake: trigger ignored (run already live)")
        XCTAssertEqual(WakeLogText.skippedTomorrow(day: "2026-03-13", calendar: cal),
                       "Wake: skipped (skip tomorrow, Fri Mar 13)")
        XCTAssertEqual(WakeLogText.shortDay("garbage", calendar: cal), "garbage")
        XCTAssertTrue(WakeLogText.interruptedHapticsCleared.hasPrefix("Wake: "))
        XCTAssertTrue(WakeLogText.interrupted.hasPrefix("Wake: stop interrupted"))
    }
}
