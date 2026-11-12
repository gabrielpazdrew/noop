// Fork-only (phone-hub, wake): tests for WakeLoopEngine, the pure decision logic of the phone wake
// alarm. A port of the Mac loop's tests (the Health Analysis repo's tests/test_wake_loop.py) onto
// events and a fake clock. All numbers are synthetic.
import XCTest

final class WakeLoopEngineTests: XCTestCase {
    let cfg = WakeConfig()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func sample(_ s: TimeInterval, _ bpm: Int) -> WakeEvent { .sample(WakeSample(ts: at(s), bpm: bpm)) }

    /// A run started at t0 with a fixed threshold and no warm-up.
    func run(threshold: Double = 75) -> WakeRunState {
        WakeRunState.begin(started: t0, threshold: threshold, warmup: [], config: cfg)
    }

    @discardableResult
    func step(_ s: inout WakeRunState, _ e: WakeEvent, now: TimeInterval, link: Bool = true) -> [WakeAction] {
        WakeLoopEngine.step(&s, e, now: at(now), linkReady: link, config: cfg)
    }

    /// Feeds one sample per second for `secs` seconds starting at `from` (event time = sample time),
    /// answering every buzz with `ok`. Returns every action produced.
    @discardableResult
    func feed(_ s: inout WakeRunState, from: Int, secs: Int, bpm: Int) -> [WakeAction] {
        var all: [WakeAction] = []
        for i in 0..<secs {
            let t = TimeInterval(from + i)
            let acts = step(&s, sample(t, bpm), now: t)
            all += acts
            if acts.contains(.buzz) { all += step(&s, .buzzResult(ok: true, detail: "ok"), now: t) }
        }
        return all
    }

    func stops(_ acts: [WakeAction]) -> [WakeStopReason] {
        acts.compactMap { if case .stop(let r) = $0 { return r } else { return nil } }
    }
    func buzzes(_ acts: [WakeAction]) -> Int { acts.filter { $0 == .buzz }.count }
    func skips(_ acts: [WakeAction]) -> [String] {
        acts.compactMap { if case .skipBuzz(let r) = $0 { return r } else { return nil } }
    }

    // MARK: threshold

    func testThresholdFromRestingHR() {
        let recent = (0..<30).map { WakeSample(ts: t0.addingTimeInterval(Double(-$0)), bpm: 50) }
        let (thr, src) = WakeLoopEngine.pickThreshold(restingHR: 55, recent: recent, config: cfg)
        XCTAssertEqual(thr, 70)
        XCTAssertEqual(src, .restingHR(55))
        XCTAssertEqual(src.logDescription, "resting_hr=55")
    }

    func testRestingHRFromRestingHRIsNotCapped() {
        let (thr, _) = WakeLoopEngine.pickThreshold(restingHR: 85, recent: [], config: cfg)
        XCTAssertEqual(thr, 100)
    }

    func testRestingHRSkipsNilRowsAndTakesNewestDayWhateverTheOrder() {
        let rows: [(day: String, restingHr: Int?)] = [
            ("2026-01-03", 52), ("2026-01-05", nil), ("2026-01-01", 60), ("2026-01-04", 54), ("2026-01-02", nil),
        ]
        XCTAssertEqual(WakeLoopEngine.newestRestingHR(rows), 54)
        XCTAssertNil(WakeLoopEngine.newestRestingHR([("2026-01-01", nil)]))
        XCTAssertNil(WakeLoopEngine.newestRestingHR([]))
    }

    func testThresholdFallsBackToRecentMedian() {
        let recent = [50, 52, 54, 56, 58].enumerated().map { WakeSample(ts: at(Double($0.offset)), bpm: $0.element) }
        let (thr, src) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: recent, config: cfg)
        XCTAssertEqual(thr, 69)
        XCTAssertEqual(src, .median(bpm: 54, n: 5, capped: false))
        XCTAssertEqual(src.logDescription, "median_last_20min=54(n=5)")
    }

    func testEvenLengthMedianIsTheMeanOfTheMiddleTwo() {
        let recent = [60, 50, 53, 70].enumerated().map { WakeSample(ts: at(Double($0.offset)), bpm: $0.element) }
        let (thr, src) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: recent, config: cfg)
        XCTAssertEqual(thr, 71.5)
        XCTAssertEqual(src, .median(bpm: 56.5, n: 4, capped: false))
    }

    func testMedianThresholdCappedWhenAlreadyAwake() {
        let recent = (0..<20).map { WakeSample(ts: at(Double($0)), bpm: 95) }
        let (thr, src) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: recent, config: cfg)
        XCTAssertEqual(thr, 90)
        XCTAssertEqual(src, .median(bpm: 95, n: 20, capped: true))
        XCTAssertEqual(src.logDescription, "median_last_20min=95(n=20) capped")
    }

    func testFlatFallbackWithNoHR() {
        let (thr, src) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: [], config: cfg)
        XCTAssertEqual(thr, 70)
        XCTAssertEqual(src, .fallback)
        XCTAssertEqual(src.logDescription, "fallback")
    }

    // MARK: start values

    func testStartValues() {
        let warm = [WakeSample(ts: at(-600), bpm: 48), WakeSample(ts: at(-300), bpm: 61), WakeSample(ts: at(-10), bpm: 55)]
        let s = WakeRunState.begin(started: t0, threshold: 70, warmup: warm, config: cfg)
        XCTAssertEqual(s.lastSeenTs, at(-31))
        XCTAssertEqual(s.lastLiveAt, t0)
        XCTAssertEqual(s.lastNewAt, t0)
        XCTAssertEqual(s.maxBpm, 61)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.buzzCount, 0)
        XCTAssertLessThanOrEqual(s.lastBuzzAt, at(-1_000_000))
        XCTAssertNil(WakeRunState.begin(started: t0, threshold: 70, warmup: [], config: cfg).maxBpm)
    }

    // MARK: awake

    func testAwakeWhenHRHeldThirtySecondsWithTenSamples() {
        var s = run()
        let acts = feed(&s, from: 0, secs: 31, bpm: 90)
        XCTAssertEqual(stops(acts), [.awake])
        XCTAssertEqual(s.stopReason, .awake)
        XCTAssertEqual(s.maxBpm, 90)
    }

    func testAwakeIsCheckedBeforeTheBuzzDecision() {
        var s = run()
        feed(&s, from: 0, secs: 30, bpm: 90)          // 0..29: span 29 s, not yet
        XCTAssertNil(s.stopReason)
        let acts = step(&s, sample(30, 90), now: 30.5) // span 30 s → awake, no buzz with it
        XCTAssertEqual(acts.last, .stop(.awake))
        XCTAssertFalse(acts.contains(.buzz))
    }

    func testNotAwakeWithFewerThanTenSamplesOverThirtySeconds() {
        var s = run()
        for t in stride(from: 0, through: 40, by: 5) {    // 9 samples spanning 40 s
            step(&s, sample(TimeInterval(t), 90), now: TimeInterval(t))
        }
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.overN, 9)
        step(&s, sample(45, 90), now: 45)                // the 10th
        XCTAssertEqual(s.stopReason, .awake)
    }

    func testUnderThresholdSampleResetsTheRun() {
        var s = run()
        feed(&s, from: 0, secs: 25, bpm: 90)
        step(&s, sample(25, 60), now: 25)
        feed(&s, from: 26, secs: 20, bpm: 90)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.overN, 20)
    }

    func testAtThresholdCountsAsOver() {
        var s = run(threshold: 75)
        let acts = feed(&s, from: 0, secs: 31, bpm: 75)
        XCTAssertEqual(stops(acts), [.awake])
    }

    func testLateFlushedSamplesStillCountOlderThanSixtyFiveIgnored() {
        var s = run()
        // A burst flushed at t = 70 carrying samples stamped 20..55 (15–50 s old, all unseen).
        for ts in 20...55 { step(&s, sample(TimeInterval(ts), 90), now: 70) }
        XCTAssertEqual(s.stopReason, .awake)

        var s2 = run()
        // Stamped 0..4 but delivered at t = 70: 66–70 s old → outside the read window.
        for ts in 0...4 { step(&s2, sample(TimeInterval(ts), 90), now: 70) }
        XCTAssertEqual(s2.overN, 0)
        XCTAssertEqual(s2.lastSeenTs, at(-31))
    }

    func testLateSampleIsWalkedButNotLive() {
        var s = run()
        step(&s, sample(10, 99), now: 50)   // 40 s old: walked, not live
        XCTAssertEqual(s.lastSeenTs, at(10))
        XCTAssertEqual(s.lastNewAt, at(50))
        XCTAssertEqual(s.lastLiveAt, t0)
        XCTAssertNil(s.maxBpm)
    }

    func testSamplesFromTheFutureAreIgnored() {
        var s = run()
        step(&s, sample(40, 90), now: 10)
        XCTAssertEqual(s.lastSeenTs, at(-31))
        XCTAssertEqual(s.overN, 0)
        XCTAssertEqual(s.lastNewAt, t0)
        // The sample can still be walked once the clock reaches it.
        step(&s, sample(40, 90), now: 40)
        XCTAssertEqual(s.overN, 1)
    }

    func testDuplicateAndOutOfOrderSamplesIgnored() {
        var s = run()
        step(&s, sample(5, 90), now: 5)
        step(&s, sample(5, 90), now: 6)
        step(&s, sample(3, 90), now: 7)
        XCTAssertEqual(s.overN, 1)
        XCTAssertEqual(s.lastNewAt, at(5))
    }

    func testSampleFromThirtyOneSecondsBeforeStartCounts() {
        var s = run()
        // Ring replay at start: samples from -30..0 (-31 itself is the seen mark and is excluded).
        for ts in -30...0 { step(&s, sample(TimeInterval(ts), 90), now: 0) }
        XCTAssertEqual(s.stopReason, .awake)

        var s2 = run()
        step(&s2, sample(-31, 90), now: 0)
        XCTAssertEqual(s2.overN, 0)
        step(&s2, sample(-30, 90), now: 0)
        XCTAssertEqual(s2.overN, 1)
    }

    // MARK: other stops

    func testTimeoutAtTenMinutesEvenWhenOnlySparseTicksArrive() {
        var s = run()
        // HR stays low and live, but events arrive only every 100 s; then they stall for minutes.
        for t in stride(from: 0, through: 500, by: 100) { step(&s, sample(TimeInterval(t), 55), now: TimeInterval(t)) }
        XCTAssertNil(s.stopReason)
        XCTAssertNil(step(&s, sample(599, 55), now: 599).first { if case .stop = $0 { return true } else { return false } })
        // 900 s: past both the cap and the no-HR limit; the cap is checked first.
        let acts = step(&s, .tick, now: 900)
        XCTAssertEqual(acts, [.stop(.timeout)])
        XCTAssertEqual(s.stopReason, .timeout)
    }

    func testTimeoutWhenHRStaysLowAndLive() {
        var s = run()
        let acts = feed(&s, from: 0, secs: 700, bpm: 55)
        XCTAssertEqual(stops(acts), [.timeout])
        XCTAssertEqual(s.stopReason, .timeout)
    }

    func testNoHRAfterTwoMinutesOfTicksWithoutSamples() {
        var s = run()
        var all: [WakeAction] = []
        for t in stride(from: 0, through: 130, by: 5) {
            all += step(&s, .tick, now: TimeInterval(t))
            if s.stopReason != nil { break }
        }
        XCTAssertEqual(stops(all), [.noHR])
        XCTAssertEqual(s.stopReason, .noHR)
    }

    func testStaleSamplesCountAsNoHR() {
        var s = run()
        var all: [WakeAction] = []
        // Every sample arrives 40 s old: walked once, never live.
        for t in stride(from: 40, through: 200, by: 2) {
            all += step(&s, sample(TimeInterval(t - 40), 55), now: TimeInterval(t))
            if s.stopReason != nil { break }
        }
        XCTAssertEqual(stops(all), [.noHR])
    }

    // MARK: boundaries

    func testCapIsExactlySixHundredSeconds() {
        var s = run()
        for t in stride(from: 0, through: 500, by: 100) { step(&s, sample(TimeInterval(t), 55), now: TimeInterval(t)) }
        step(&s, sample(599, 55), now: 599.5)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(step(&s, .tick, now: 600), [.stop(.timeout)])
    }

    func testNoHRLimitIsExactlyOneTwentySeconds() {
        var s = run()
        XCTAssertFalse(stops(step(&s, .tick, now: 119.5)).contains(.noHR))
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(step(&s, .tick, now: 120), [.stop(.noHR)])
    }

    func testLiveWindowIncludesExactlyThirtyFiveSeconds() {
        var s = run()
        step(&s, sample(10, 60), now: 45)          // exactly 35 s old: live
        XCTAssertEqual(s.lastLiveAt, at(45))
        XCTAssertEqual(s.maxBpm, 60)
        step(&s, sample(20, 70), now: 55.5)        // 35.5 s old: walked, not live
        XCTAssertEqual(s.lastLiveAt, at(45))
        XCTAssertEqual(s.lastSeenTs, at(20))
        XCTAssertEqual(s.maxBpm, 60)
    }

    func testLookBackIncludesExactlySixtyFiveSeconds() {
        var s = run()
        step(&s, sample(5, 90), now: 70)           // exactly 65 s old: walked
        XCTAssertEqual(s.lastSeenTs, at(5))
        XCTAssertEqual(s.overN, 1)
        var s2 = run()
        step(&s2, sample(5, 90), now: 70.5)        // 65.5 s old: ignored
        XCTAssertEqual(s2.lastSeenTs, at(-31))
        XCTAssertEqual(s2.overN, 0)
    }

    // MARK: clock jumps

    func testBackwardClockJumpStopsTheRunAtOnce() {
        var s = run()
        feed(&s, from: 0, secs: 10, bpm: 55)
        let acts = step(&s, sample(-3600, 55), now: -3600)
        XCTAssertEqual(acts, [.stop(.clockMoved)])
        XCTAssertEqual(s.stopReason, .clockMoved)
        XCTAssertEqual(step(&s, .tick, now: -3598), [])
        XCTAssertEqual(step(&s, .tick, now: 5), [])
    }

    func testBackwardJumpOnATickStopsToo() {
        var s = run()
        XCTAssertEqual(step(&s, .tick, now: -1), [.stop(.clockMoved)])
    }

    func testBackwardStepMidRunPastToleranceStops() {
        var s = run()
        feed(&s, from: 0, secs: 300, bpm: 55)
        // Back 200 s: still after the start, but the run would otherwise get 200 s more than 10 minutes.
        XCTAssertEqual(step(&s, .tick, now: 99), [.stop(.clockMoved)])
        XCTAssertEqual(s.stopReason, .clockMoved)
    }

    func testBackwardStepWithinToleranceIsTolerated() {
        var s = run()
        feed(&s, from: 0, secs: 20, bpm: 55)
        XCTAssertEqual(stops(step(&s, .tick, now: 14)), [], "5 s back is a stamping jitter, not a clock change")
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(stops(step(&s, .tick, now: 13.9)), [.clockMoved], "more than 5 s behind the newest now")
    }

    func testToleranceMeasuredFromNewestNowNotLast() {
        var s = run()
        feed(&s, from: 0, secs: 30, bpm: 55)            // newest now = 29
        _ = step(&s, .tick, now: 26)                    // 3 s back: tolerated
        XCTAssertEqual(stops(step(&s, .tick, now: 23.5)), [.clockMoved], "5.5 s behind 29, though only 2.5 s behind 26")
    }

    // MARK: buzz gate

    func testFirstEventBuzzesWhenLinkReady() {
        var s = run()
        XCTAssertEqual(step(&s, .tick, now: 0), [.buzz])
        XCTAssertEqual(s.buzzCount, 1)
        XCTAssertEqual(s.lastBuzzAt, t0)
    }

    func testBuzzPausesWhileStreamStalled() {
        var s = run()
        feed(&s, from: 0, secs: 5, bpm: 55)          // newest sample at t = 4
        var all: [WakeAction] = []
        for t in stride(from: 26, through: 40, by: 2) { all += step(&s, .tick, now: TimeInterval(t)) }
        XCTAssertEqual(buzzes(all), 0)
        XCTAssertEqual(skips(all).count, 8)
        XCTAssertEqual(skips(all).first, "no new HR sample for 22s")
        XCTAssertEqual(s.skippedCount, 8)
    }

    func testBuzzResumesWhenStreamReturns() {
        var s = run()
        feed(&s, from: 0, secs: 5, bpm: 55)
        let paused = step(&s, .tick, now: 30)
        XCTAssertEqual(buzzes(paused), 0)
        let resumed = step(&s, sample(32, 55), now: 32)
        XCTAssertEqual(resumed, [.buzz])
    }

    func testStallIsStrictlyMoreThanTwentySeconds() {
        var s = run()
        step(&s, sample(0, 55), now: 0)
        XCTAssertEqual(step(&s, .tick, now: 20), [.buzz])
        XCTAssertEqual(skips(step(&s, .tick, now: 22.5)).count, 1)
    }

    func testNeverMoreThanOneBuzzDecisionPerTwoSeconds() {
        var s = run()
        var all: [WakeAction] = []
        var times: [Date] = []
        // 20 events a second for 20 seconds, all with fresh samples.
        for i in 0..<400 {
            let t = Double(i) * 0.05
            let acts = step(&s, sample(t, 55), now: t)
            if acts.contains(.buzz) { times.append(at(t)) }
            all += acts
        }
        XCTAssertEqual(buzzes(all), 10)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 2)
        }
    }

    func testSkippedBuzzAlsoRespectsTheSpacing() {
        var s = run()
        var all: [WakeAction] = []
        for i in 0..<40 { all += step(&s, .tick, now: 25 + Double(i) * 0.1) }   // stalled, 4 s of ticks
        XCTAssertEqual(skips(all).count, 2)
    }

    func testLinkNotReadySkipsAndIsNeverAFailure() {
        var s = run()
        var all: [WakeAction] = []
        for t in stride(from: 0, through: 20, by: 2) {
            all += step(&s, sample(TimeInterval(t), 55), now: TimeInterval(t), link: false)
        }
        XCTAssertEqual(buzzes(all), 0)
        XCTAssertEqual(Set(skips(all)), ["link not ready"])
        XCTAssertEqual(s.consecutiveFailures, 0)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(step(&s, sample(22, 55), now: 22, link: true), [.buzz])
    }

    func testThreeFailedWritesStopBuzzFailed() {
        var s = run()
        var all: [WakeAction] = []
        for k in 0..<3 {
            let t = TimeInterval(k * 2)
            all += step(&s, sample(t, 55), now: t)
            all += step(&s, .buzzResult(ok: false, detail: "write error"), now: t + 0.5)
        }
        XCTAssertEqual(stops(all), [.buzzFailed])
        XCTAssertEqual(s.consecutiveFailures, 3)
        XCTAssertTrue(all.contains(.log("buzz FAILED (3/3): write error")))
    }

    func testConfirmedBuzzesCountedSeparatelyFromRequested() {
        var s = run()
        let results = [true, false, true]
        for (k, ok) in results.enumerated() {
            let t = TimeInterval(k * 2)
            step(&s, sample(t, 55), now: t)
            step(&s, .buzzResult(ok: ok, detail: "x"), now: t + 0.5)
        }
        step(&s, sample(6, 55), now: 6)              // requested, no result yet
        XCTAssertEqual(s.buzzCount, 4)
        XCTAssertEqual(s.confirmedBuzzCount, 2)
    }

    func testASuccessInBetweenResetsTheFailureCount() {
        var s = run()
        let results = [false, false, true, false, false]
        for (k, ok) in results.enumerated() {
            let t = TimeInterval(k * 2)
            step(&s, sample(t, 55), now: t)
            step(&s, .buzzResult(ok: ok, detail: "x"), now: t + 0.5)
        }
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.consecutiveFailures, 2)
    }

    func testBuzzResultNeverItselfBuzzes() {
        var s = run()
        step(&s, sample(0, 55), now: 0)
        let acts = step(&s, .buzzResult(ok: true, detail: "ok"), now: 5)
        XCTAssertFalse(acts.contains(.buzz))
    }

    // MARK: no re-arm

    func testNoActionOfAnyKindAfterAStop() {
        var s = run()
        feed(&s, from: 0, secs: 31, bpm: 90)
        XCTAssertEqual(s.stopReason, .awake)
        let before = s
        XCTAssertEqual(step(&s, .tick, now: 40), [])
        XCTAssertEqual(step(&s, sample(41, 55), now: 41), [])
        XCTAssertEqual(step(&s, .buzzResult(ok: false, detail: "x"), now: 42), [])
        XCTAssertEqual(step(&s, .tick, now: 10_000), [])
        XCTAssertEqual(s, before)
    }

    func testExplicitStopIsFinalAndOnlyOnce() {
        var s = run()
        XCTAssertEqual(WakeLoopEngine.stop(&s, reason: .stopped), [.stop(.stopped)])
        XCTAssertEqual(s.stopReason, .stopped)
        XCTAssertEqual(WakeLoopEngine.stop(&s, reason: .interrupted), [])
        XCTAssertEqual(s.stopReason, .stopped)
        XCTAssertEqual(step(&s, .tick, now: 1), [])
    }
}
