// Fork-only (phone-hub, wake): tests for WakeLoopEngine, the pure decision logic of the phone wake
// alarm. A port of the Mac loop's tests (the Health Analysis repo's tests/test_wake_loop.py) onto
// events and a fake clock. All numbers are synthetic.
import XCTest

final class WakeLoopEngineTests: XCTestCase {
    let cfg = WakeConfig()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    func sample(_ s: TimeInterval, _ bpm: Int) -> WakeEvent { .sample(WakeSample(ts: at(s), bpm: bpm)) }

    /// A run started at t0 with fixed lines (up 75, back asleep 68) and no warm-up.
    func makeRun(up: Double = 75, asleep: Double = 68) -> WakeRunState {
        WakeRunState.begin(started: t0, upLine: up, asleepLine: asleep, warmup: [], config: cfg)
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
    func logs(_ acts: [WakeAction]) -> [String] {
        acts.compactMap { if case .log(let l) = $0 { return l } else { return nil } }
    }
    /// A run that went quiet at t = 120 (HR 90 held from 0 through 120).
    func quietRun() -> WakeRunState {
        var s = makeRun()
        feed(&s, from: 0, secs: 121, bpm: 90)
        XCTAssertEqual(s.mode, .quiet)
        return s
    }
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
        var c = cfg
        c.medianCap = 70
        let (thr, _) = WakeLoopEngine.pickThreshold(restingHR: 65, recent: [], config: c)
        XCTAssertEqual(thr, 80)
    }

    func testRestingHRSanityGuardAcceptsThirtyFiveToSixtyFive() {
        for r in [35, 49, 65] {
            XCTAssertEqual(WakeLoopEngine.pickThreshold(restingHR: r, recent: [], config: cfg).1, .restingHR(r))
            XCTAssertEqual(WakeLoopEngine.acceptedRestingHR(r, config: cfg), r)
        }
        XCTAssertEqual(WakeLoopEngine.pickThreshold(restingHR: 49, recent: [], config: cfg).0, 64)
        for r in [34, 66] { XCTAssertNil(WakeLoopEngine.acceptedRestingHR(r, config: cfg)) }
        XCTAssertNil(WakeLoopEngine.acceptedRestingHR(nil, config: cfg))
    }

    func testRestingHR68IsRejectedForTheMedian() {
        // A misread night (e.g. around a DST change) can report a resting HR far above normal.
        let recent = [50, 52, 54, 56, 58].enumerated().map { WakeSample(ts: at(Double($0.offset)), bpm: $0.element) }
        let (up, src) = WakeLoopEngine.pickThreshold(restingHR: 68, recent: recent, config: cfg)
        XCTAssertEqual(up, 69)
        XCTAssertEqual(src, .rejected(restingHR: 68, then: .median(bpm: 54, n: 5, capped: false)))
        XCTAssertEqual(src.logDescription, "median_last_20min=54(n=5) (resting_hr 68 rejected)")
        XCTAssertEqual(WakeLoopEngine.asleepLine(upLine: up, source: src, config: cfg), 60)
        let (fb, fbSrc) = WakeLoopEngine.pickThreshold(restingHR: 30, recent: [], config: cfg)
        XCTAssertEqual(fb, 70)
        XCTAssertEqual(fbSrc.logDescription, "fallback (resting_hr 30 rejected)")
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

    func testAsleepLineFromRestingHR() {
        let (up, src) = WakeLoopEngine.pickThreshold(restingHR: 49, recent: [], config: cfg)
        XCTAssertEqual(up, 64)
        XCTAssertEqual(WakeLoopEngine.asleepLine(upLine: up, source: src, config: cfg), 55)
    }

    func testAsleepLineForMedianAndFallbackKeepsTheMarginGap() {
        let recent = [50, 52, 54, 56, 58].enumerated().map { WakeSample(ts: at(Double($0.offset)), bpm: $0.element) }
        let (up, src) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: recent, config: cfg)
        XCTAssertEqual(WakeLoopEngine.asleepLine(upLine: up, source: src, config: cfg), 60)   // 69 - 9
        let high = (0..<20).map { WakeSample(ts: at(Double($0)), bpm: 95) }
        let (capUp, capSrc) = WakeLoopEngine.pickThreshold(restingHR: nil, recent: high, config: cfg)
        XCTAssertEqual(WakeLoopEngine.asleepLine(upLine: capUp, source: capSrc, config: cfg), 81) // 90 - 9
        XCTAssertEqual(WakeLoopEngine.asleepLine(upLine: 70, source: .fallback, config: cfg), 61)
    }

    func testConfigDefaults() {
        XCTAssertEqual(cfg.upMargin, 15)
        XCTAssertEqual(cfg.asleepMargin, 6)
        XCTAssertEqual(cfg.upSustain, 120)
        XCTAssertEqual(cfg.minOverSamples, 60)
        XCTAssertEqual(cfg.asleepSustain, 300)
        XCTAssertEqual(cfg.minUnderSamples, 150)
        XCTAssertEqual(cfg.restingMin, 35)
        XCTAssertEqual(cfg.restingMax, 65)
        XCTAssertEqual(cfg.watchWindow, 2700)
        XCTAssertEqual(cfg.buzzBudget, 600)
        XCTAssertEqual(cfg.noHRLimit, 120)
    }

    // MARK: start values

    func testStartValues() {
        let warm = [WakeSample(ts: at(-600), bpm: 48), WakeSample(ts: at(-300), bpm: 61), WakeSample(ts: at(-10), bpm: 55)]
        let s = WakeRunState.begin(started: t0, upLine: 70, asleepLine: 63, warmup: warm, config: cfg)
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(s.lastLiveAt, t0)
        XCTAssertEqual(s.lastNewAt, t0)
        XCTAssertEqual(s.maxBpm, 61)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.buzzCount, 0)
        XCTAssertEqual(s.quietCount, 0)
        XCTAssertEqual(s.rearmCount, 0)
        XCTAssertEqual(s.buzzingSeconds(at: at(30)), 30)
        XCTAssertLessThanOrEqual(s.lastBuzzAt, at(-1_000_000))
        XCTAssertNil(WakeRunState.begin(started: t0, upLine: 70, asleepLine: 63, warmup: [], config: cfg).maxBpm)
    }

    // MARK: buzzing → quiet

    func testAwakeAtStartStillBuzzesTwoMinutesThenGoesQuiet() {
        var s = makeRun()
        let before = feed(&s, from: 0, secs: 120, bpm: 90)     // 0..119: buzzing only 119 s, not yet
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(buzzes(before), 60)
        XCTAssertEqual(stops(before), [])
        let acts = step(&s, sample(120, 90), now: 120)          // 2 min buzzing, mean 90 → quiet
        XCTAssertEqual(acts, [.stopHaptics, .log("quiet (2-min average ≥ 75 bpm) after 120s, 60 buzz(es)")])
        XCTAssertEqual(s.window, [], "quiet starts with an empty window")
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertEqual(s.quietCount, 1)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(s.buzzingSeconds(at: at(500)), 120, "quiet time is not buzzing time")
        XCTAssertEqual(s.maxBpm, 90)
    }

    func testTheAverageDecidesSoDipsBelowTheUpLineDontReset() {
        var s = makeRun()
        for t in 0...119 {                                       // every 10th second dips to 60
            step(&s, sample(TimeInterval(t), t % 10 == 0 ? 60 : 90), now: TimeInterval(t))
        }
        XCTAssertEqual(s.mode, .buzzing)
        step(&s, sample(120, 60), now: 120)                      // a dip, but the 2-min mean is ~87
        XCTAssertEqual(s.mode, .quiet)
    }

    func testAMeanBelowTheUpLineNeverGoesQuiet() {
        var s = makeRun()
        // Alternating 80 / 66: half the samples are over the line, the mean (73) is not.
        for t in 0...590 { step(&s, sample(TimeInterval(t), t % 2 == 0 ? 80 : 66), now: TimeInterval(t)) }
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(s.quietCount, 0)
    }

    func testTheUpWindowIsTheLastTwoMinutesOnly() {
        var s = makeRun()
        feed(&s, from: 0, secs: 200, bpm: 60)                   // two low minutes and more
        feed(&s, from: 200, secs: 60, bpm: 90)                  // 200..259: window 139..259 = 61 × 60 + 60 × 90
        XCTAssertEqual(s.mode, .buzzing, "mean 74.9 < 75")
        step(&s, sample(260, 90), now: 260)                     // window 140..260 = 60 × 60 + 61 × 90: 75.1
        XCTAssertEqual(s.mode, .quiet)
    }

    func testModeMustLastTwoMinutesBeforeGoingQuiet() {
        var s = makeRun()
        // 2 samples a second: 60 samples and a high mean well before two minutes.
        var t = 0.0
        while t < 120 { step(&s, sample(t, 90), now: t); t += 0.5 }
        XCTAssertEqual(s.mode, .buzzing)
        step(&s, sample(120, 90), now: 120)
        XCTAssertEqual(s.mode, .quiet)
    }

    func testUpLineItselfCountsAsUp() {
        var s = makeRun(up: 75)
        feed(&s, from: 0, secs: 121, bpm: 75)
        XCTAssertEqual(s.mode, .quiet)
    }

    func testASparseUpWindowDoesNotGoQuiet() {
        var s = makeRun()
        for t in stride(from: 0, through: 300, by: 3) {          // 41 samples per 2 min < 60
            step(&s, sample(TimeInterval(t), 90), now: TimeInterval(t))
        }
        XCTAssertEqual(s.mode, .buzzing)
        var s2 = makeRun()
        for t in stride(from: 0, through: 120, by: 2) {          // 61 samples in 2 min
            step(&s2, sample(TimeInterval(t), 90), now: TimeInterval(t))
        }
        XCTAssertEqual(s2.mode, .quiet)
    }

    func testGoingQuietIsJudgedBeforeTheBuzzDecision() {
        var s = makeRun()
        feed(&s, from: 0, secs: 120, bpm: 90)
        let acts = step(&s, sample(120, 90), now: 121)           // a buzz would be due at 121
        XCTAssertFalse(acts.contains(.buzz))
        XCTAssertEqual(acts.first, .stopHaptics)
    }

    func testLateFlushedSamplesStillCountOlderThanSixtyFiveIgnored() {
        var s = makeRun()
        // A burst flushed at t = 70 carrying samples stamped 20..55 (15–50 s old, all unseen).
        for ts in 20...55 { step(&s, sample(TimeInterval(ts), 90), now: 70) }
        XCTAssertEqual(s.window.count, 36)

        var s2 = makeRun()
        // Stamped 0..4 but delivered at t = 70: 66–70 s old → outside the read window.
        for ts in 0...4 { step(&s2, sample(TimeInterval(ts), 90), now: 70) }
        XCTAssertEqual(s2.window.count, 0)
        XCTAssertEqual(s2.lastSeenTs, .distantPast)
    }

    func testLateSampleIsWalkedButNotLive() {
        var s = makeRun()
        step(&s, sample(10, 99), now: 50)   // 40 s old: walked, not live
        XCTAssertEqual(s.lastSeenTs, at(10))
        XCTAssertEqual(s.lastNewAt, at(50))
        XCTAssertEqual(s.lastLiveAt, t0)
        XCTAssertNil(s.maxBpm)
    }

    func testSamplesFromTheFutureAreIgnored() {
        var s = makeRun()
        step(&s, sample(40, 90), now: 10)
        XCTAssertEqual(s.lastSeenTs, .distantPast)
        XCTAssertEqual(s.window.count, 0)
        XCTAssertEqual(s.lastNewAt, t0)
        // The sample can still be walked once the clock reaches it.
        step(&s, sample(40, 90), now: 40)
        XCTAssertEqual(s.window.count, 1)
    }

    func testDuplicateAndOutOfOrderSamplesIgnored() {
        var s = makeRun()
        step(&s, sample(5, 90), now: 5)
        step(&s, sample(5, 90), now: 6)
        step(&s, sample(3, 90), now: 7)
        XCTAssertEqual(s.window.count, 1)
        XCTAssertEqual(s.lastNewAt, at(5))
    }

    func testSamplesFromBeforeTheStartNeverCount() {
        var s = makeRun()
        // v1 replayed a 31 s look-back; v2 walks only samples stamped at or after the start.
        for ts in -30...(-1) { step(&s, sample(TimeInterval(ts), 90), now: 0) }
        XCTAssertEqual(s.window.count, 0)
        XCTAssertEqual(s.lastSeenTs, .distantPast)
        XCTAssertNil(s.maxBpm)
        step(&s, sample(0, 90), now: 0)
        XCTAssertEqual(s.window.count, 1)
    }

    // MARK: quiet → buzzing

    func testQuietRearmsWhenTheFiveMinuteAverageIsAtOrBelowTheAsleepLine() {
        var s = quietRun()
        let quiet = feed(&s, from: 121, secs: 299, bpm: 60)      // 121..419: quiet only 299 s
        XCTAssertEqual(buzzes(quiet), 0)
        XCTAssertEqual(s.mode, .quiet)
        let acts = step(&s, sample(420, 60), now: 420)          // 5 min quiet, 300 samples, mean 60
        XCTAssertEqual(logs(acts), ["back asleep? 5-min average ≤ 68 bpm — buzzing again"])
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(s.rearmCount, 1)
        XCTAssertEqual(s.window, [], "buzzing starts with an empty window")
        XCTAssertEqual(acts.last, .buzz, "the first eligible event after re-arming buzzes")
        XCTAssertEqual(buzzes(feed(&s, from: 421, secs: 10, bpm: 60)), 5)   // 422, 424 … 430
    }

    func testRestingPlusSixReArmsAndPlusSevenDoesNot() {
        // Resting 49: up line 64, back-asleep line 55.
        var s = makeRun(up: 64, asleep: 55)
        feed(&s, from: 0, secs: 121, bpm: 80)
        XCTAssertEqual(s.mode, .quiet)
        // Mixed 50 / 60: mean exactly 55, half the samples above the line.
        for t in 121...420 { step(&s, sample(TimeInterval(t), t % 2 == 0 ? 50 : 60), now: TimeInterval(t)) }
        XCTAssertEqual(s.mode, .buzzing)

        var s2 = makeRun(up: 64, asleep: 55)
        feed(&s2, from: 0, secs: 121, bpm: 80)
        let acts = feed(&s2, from: 121, secs: 1500, bpm: 56)  // resting + 7
        XCTAssertEqual(s2.mode, .quiet)
        XCTAssertEqual(s2.rearmCount, 0)
        XCTAssertEqual(buzzes(acts), 0)
    }

    func testQuietMustLastFiveMinutesBeforeReArming() {
        var s = quietRun()
        // 2 samples a second: 150 low samples well before five minutes.
        var t = 120.5
        while t < 420 { step(&s, sample(t, 55), now: t); t += 0.5 }
        XCTAssertEqual(s.mode, .quiet)
        step(&s, sample(420, 55), now: 420)
        XCTAssertEqual(s.mode, .buzzing)
    }

    func testBuzzingSamplesNeverCountTowardAsleep() {
        // Low HR while buzzing, then a high stretch that goes quiet: the low samples stay behind.
        var s = makeRun()
        feed(&s, from: 0, secs: 200, bpm: 50)
        feed(&s, from: 200, secs: 121, bpm: 90)                 // quiet at 275 (2-min mean reaches 75)
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertEqual(s.window.map(\.ts), (276...320).map { at(TimeInterval($0)) }, "only samples walked while quiet")
    }

    func testALateSampleStampedBeforeTheModeChangeBelongsToTheOldMode() {
        var s = makeRun()
        feed(&s, from: 0, secs: 120, bpm: 90)
        step(&s, sample(120, 90), now: 125)                     // delivered late: quiet from 125
        XCTAssertEqual(s.mode, .quiet)
        step(&s, sample(122, 50), now: 126)                     // walked, but stamped before 125
        XCTAssertEqual(s.window, [])
        step(&s, sample(125, 50), now: 126.5)
        XCTAssertEqual(s.window.count, 1)
    }

    func testAsleepLineItselfCountsAsAsleep() {
        var s = quietRun()
        feed(&s, from: 121, secs: 300, bpm: 68)
        XCTAssertEqual(s.mode, .buzzing)
    }

    func testHRBetweenTheLinesInQuietStaysQuiet() {
        var s = quietRun()
        let acts = feed(&s, from: 121, secs: 1200, bpm: 70)     // above 68, below 75
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertEqual(s.rearmCount, 0)
        XCTAssertEqual(buzzes(acts), 0)
        XCTAssertEqual(stops(acts), [])
    }

    func testASparseAsleepWindowDoesNotReArm() {
        var s = quietRun()
        for t in stride(from: 123, through: 1000, by: 3) {       // ~100 samples per 5 min < 150
            step(&s, sample(TimeInterval(t), 55), now: TimeInterval(t))
        }
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertLessThanOrEqual(s.window.count, 101)
    }

    func testNoBuzzOrSkipIsEverEmittedWhileQuiet() {
        var s = quietRun()
        var all: [WakeAction] = []
        for i in 0..<300 {
            let t = 121 + Double(i) * 0.5
            all += step(&s, sample(t, 72), now: t, link: i % 2 == 0)
            all += step(&s, .tick, now: t + 0.1)
            all += step(&s, .buzzResult(ok: true, detail: "ok"), now: t + 0.2)
        }
        // A stall while quiet (no new sample for 60 s, still under the no-HR limit): no skip either.
        for t in stride(from: 272.0, through: 330.0, by: 2.0) { all += step(&s, .tick, now: t) }
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(buzzes(all), 0)
        XCTAssertEqual(skips(all), [])
        XCTAssertEqual(all.filter { $0 == .stopHaptics }.count, 1, "only the one re-send, 3 s into quiet")
    }

    func testQuietResendsStopHapticsExactlyOnceThreeSecondsIn() {
        var s = makeRun()
        feed(&s, from: 0, secs: 120, bpm: 90)
        XCTAssertEqual(step(&s, sample(120, 90), now: 120).first, .stopHaptics)   // immediate
        XCTAssertEqual(step(&s, .tick, now: 121), [])
        XCTAssertEqual(step(&s, sample(122, 72), now: 122.9), [])               // 2.9 s: not yet
        XCTAssertEqual(step(&s, .buzzResult(ok: true, detail: "ok"), now: 123), [.stopHaptics])
        var later: [WakeAction] = []
        for t in 124...400 { later += step(&s, sample(TimeInterval(t), 72), now: TimeInterval(t)) }
        XCTAssertFalse(later.contains(.stopHaptics))
        XCTAssertFalse(s.quietResendPending)
    }

    func testNoStopHapticsResendWhenRearmedWithinThreeSeconds() {
        var cfg2 = cfg
        cfg2.asleepSustain = 1; cfg2.minUnderSamples = 2
        var s = makeRun()
        for t in 0...120 { _ = WakeLoopEngine.step(&s, sample(TimeInterval(t), 90), now: at(TimeInterval(t)), linkReady: true, config: cfg2) }
        XCTAssertEqual(s.mode, .quiet)
        _ = WakeLoopEngine.step(&s, sample(121, 60), now: at(121), linkReady: true, config: cfg2)
        _ = WakeLoopEngine.step(&s, sample(122, 60), now: at(122), linkReady: true, config: cfg2)
        XCTAssertEqual(s.mode, .buzzing, "re-armed 2 s into quiet")
        var later: [WakeAction] = []
        for t in 123...140 { later += WakeLoopEngine.step(&s, sample(TimeInterval(t), 60), now: at(TimeInterval(t)), linkReady: true, config: cfg2) }
        XCTAssertFalse(later.contains(.stopHaptics))
        XCTAssertFalse(s.quietResendPending)
    }

    func testBuzzFailuresDuringQuietNeverEndTheRun() {
        var s = makeRun()
        feed(&s, from: 0, secs: 118, bpm: 90)
        step(&s, .buzzResult(ok: false, detail: "x"), now: 118.2)
        step(&s, .buzzResult(ok: false, detail: "x"), now: 118.4)
        XCTAssertEqual(s.consecutiveFailures, 2)
        step(&s, sample(118, 90), now: 119)
        step(&s, sample(119, 90), now: 119.5)
        step(&s, sample(120, 90), now: 120)
        XCTAssertEqual(s.mode, .quiet)
        // In-flight results of buzzes sent just before quiet: failures are ignored while quiet.
        var all: [WakeAction] = []
        for k in 0..<5 { all += step(&s, .buzzResult(ok: false, detail: "late"), now: 120.5 + Double(k) * 0.1) }
        XCTAssertEqual(stops(all), [])
        XCTAssertNil(s.stopReason)
        let confirmed = s.confirmedBuzzCount
        step(&s, .buzzResult(ok: true, detail: "ok"), now: 121.5)
        XCTAssertEqual(s.confirmedBuzzCount, confirmed + 1, "a late success still counts as confirmed")
    }

    func testFailureCountStartsAtZeroAfterRearm() {
        var s = makeRun()
        feed(&s, from: 0, secs: 118, bpm: 90)
        step(&s, .buzzResult(ok: false, detail: "x"), now: 118.2)
        step(&s, .buzzResult(ok: false, detail: "x"), now: 118.4)
        step(&s, sample(118, 90), now: 119)                     // a buzz, never answered
        step(&s, sample(119, 90), now: 119.5)
        step(&s, sample(120, 90), now: 120)                     // quiet
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertEqual(s.consecutiveFailures, 2)
        // No buzz results answered, so only the re-arm can bring the count back to 0.
        for t in 121...420 { step(&s, sample(TimeInterval(t), 60), now: TimeInterval(t)) }
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(s.consecutiveFailures, 0)
        step(&s, .buzzResult(ok: false, detail: "x"), now: 420.5)
        XCTAssertNil(s.stopReason, "one failure after re-arm is 1/3, not 3/3")
        XCTAssertEqual(s.consecutiveFailures, 1)
    }

    func testRearmBuzzesImmediatelyThenKeepsTheTwoSecondSpacing() {
        var s = quietRun()
        feed(&s, from: 121, secs: 299, bpm: 60)                 // 121..419
        var times: [Double] = []
        for i in 0..<40 {                                        // 420 .. 423.9, 10 events a second
            let t = 420 + Double(i) * 0.1
            if step(&s, sample(t, 60), now: t).contains(.buzz) { times.append(t) }
        }
        XCTAssertEqual(times.first, 420, "the re-arming sample buzzes")
        XCTAssertEqual(times.count, 2)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 2) }
    }

    func testUpAgainAfterRearmGoesQuietAgain() {
        var s = quietRun()
        feed(&s, from: 121, secs: 300, bpm: 60)                 // re-armed at 420
        XCTAssertEqual(s.mode, .buzzing)
        feed(&s, from: 421, secs: 119, bpm: 90)                 // up again 421..539: buzzing only 119 s
        XCTAssertEqual(s.mode, .buzzing, "quiet-mode samples never count toward up")
        step(&s, sample(540, 90), now: 540)
        XCTAssertEqual(s.mode, .quiet)
        XCTAssertEqual(s.quietCount, 2)
        XCTAssertEqual(s.rearmCount, 1)
        XCTAssertEqual(s.buzzingSeconds(at: at(1000)), 120 + 120)
    }

    // MARK: other stops

    func testWatchWindowEndsTheRunEvenWhenOnlySparseEventsArrive() {
        var s = quietRun()
        // Quiet, HR between the lines and live, but events arrive only every 100 s; then they stall.
        for t in stride(from: 200, through: 2600, by: 100) { step(&s, sample(TimeInterval(t), 70), now: TimeInterval(t)) }
        XCTAssertNil(s.stopReason)
        // 3000 s: past both the watch window and the no-HR limit; the window is checked first.
        let acts = step(&s, .tick, now: 3000)
        XCTAssertEqual(acts, [.stop(.timeout)])
        XCTAssertEqual(s.stopReason, .timeout)
    }

    func testWatchWindowIsExactlyFortyFiveMinutes() {
        var s = quietRun()
        let acts = feed(&s, from: 121, secs: 2579, bpm: 70)    // through 2699
        XCTAssertEqual(stops(acts), [])
        XCTAssertEqual(step(&s, sample(2699.5, 70), now: 2699.5).filter { if case .stop = $0 { return true } else { return false } }, [])
        XCTAssertEqual(step(&s, .tick, now: 2700), [.stop(.timeout)])
    }

    func testBuzzBudgetEndsARunThatNeverWakes() {
        var s = makeRun()
        let acts = feed(&s, from: 0, secs: 700, bpm: 55)
        XCTAssertEqual(stops(acts), [.buzzBudget])
        XCTAssertEqual(s.stopReason, .buzzBudget)
        XCTAssertEqual(buzzes(acts), 300)
    }

    func testBuzzBudgetIsExactlyTenMinutesOfBuzzing() {
        var s = makeRun()
        for t in stride(from: 0, through: 500, by: 100) { step(&s, sample(TimeInterval(t), 55), now: TimeInterval(t)) }
        step(&s, sample(599, 55), now: 599.5)
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(step(&s, .tick, now: 600), [.stop(.buzzBudget)])
    }

    func testBuzzBudgetCountsOnlyBuzzingStretches() {
        var s = quietRun()                                     // buzzed 0..120
        feed(&s, from: 121, secs: 300, bpm: 60)                // quiet 121..420, re-armed at 420
        XCTAssertEqual(s.mode, .buzzing)
        XCTAssertEqual(s.rearmCount, 1)
        let more = feed(&s, from: 421, secs: 479, bpm: 60)     // through 899: 120 + 479 = 599 s buzzing
        XCTAssertEqual(stops(more), [])
        XCTAssertEqual(step(&s, sample(900, 60), now: 900), [.stop(.buzzBudget)])
        XCTAssertEqual(s.buzzingSeconds(at: at(900)), 600)
    }

    func testNoHRAfterTwoMinutesOfTicksWithoutSamples() {
        var s = makeRun()
        var all: [WakeAction] = []
        for t in stride(from: 0, through: 130, by: 5) {
            all += step(&s, .tick, now: TimeInterval(t))
            if s.stopReason != nil { break }
        }
        XCTAssertEqual(stops(all), [.noHR])
        XCTAssertEqual(s.stopReason, .noHR)
    }

    func testStaleSamplesCountAsNoHR() {
        var s = makeRun()
        var all: [WakeAction] = []
        // Every sample arrives 40 s old: walked once, never live.
        for t in stride(from: 40, through: 200, by: 2) {
            all += step(&s, sample(TimeInterval(t - 40), 55), now: TimeInterval(t))
            if s.stopReason != nil { break }
        }
        XCTAssertEqual(stops(all), [.noHR])
    }

    func testNoHREndsTheRunWhileQuietToo() {
        var s = quietRun()                                     // last live sample at 120
        XCTAssertEqual(step(&s, .tick, now: 239.5), [.stopHaptics])   // the one re-send
        XCTAssertEqual(step(&s, .tick, now: 239.7), [])
        XCTAssertEqual(step(&s, .tick, now: 240), [.stop(.noHR)])
    }

    // MARK: boundaries

    func testNoHRLimitIsExactlyOneTwentySeconds() {
        var s = makeRun()
        XCTAssertFalse(stops(step(&s, .tick, now: 119.5)).contains(.noHR))
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(step(&s, .tick, now: 120), [.stop(.noHR)])
    }

    func testLiveWindowIncludesExactlyThirtyFiveSeconds() {
        var s = makeRun()
        step(&s, sample(10, 60), now: 45)          // exactly 35 s old: live
        XCTAssertEqual(s.lastLiveAt, at(45))
        XCTAssertEqual(s.maxBpm, 60)
        step(&s, sample(20, 70), now: 55.5)        // 35.5 s old: walked, not live
        XCTAssertEqual(s.lastLiveAt, at(45))
        XCTAssertEqual(s.lastSeenTs, at(20))
        XCTAssertEqual(s.maxBpm, 60)
    }

    func testLookBackIncludesExactlySixtyFiveSeconds() {
        var s = makeRun()
        step(&s, sample(5, 90), now: 70)           // exactly 65 s old: walked
        XCTAssertEqual(s.lastSeenTs, at(5))
        XCTAssertEqual(s.window.count, 1)
        var s2 = makeRun()
        step(&s2, sample(5, 90), now: 70.5)        // 65.5 s old: ignored
        XCTAssertEqual(s2.lastSeenTs, .distantPast)
        XCTAssertEqual(s2.window.count, 0)
    }

    // MARK: clock jumps

    func testBackwardClockJumpStopsTheRunAtOnce() {
        var s = makeRun()
        feed(&s, from: 0, secs: 10, bpm: 55)
        let acts = step(&s, sample(-3600, 55), now: -3600)
        XCTAssertEqual(acts, [.stop(.clockMoved)])
        XCTAssertEqual(s.stopReason, .clockMoved)
        XCTAssertEqual(step(&s, .tick, now: -3598), [])
        XCTAssertEqual(step(&s, .tick, now: 5), [])
    }

    func testBackwardJumpOnATickStopsToo() {
        var s = makeRun()
        XCTAssertEqual(step(&s, .tick, now: -1), [.stop(.clockMoved)])
    }

    func testBackwardStepMidRunPastToleranceStops() {
        var s = makeRun()
        feed(&s, from: 0, secs: 300, bpm: 55)
        // Back 200 s: still after the start, but the run would otherwise get 200 s more than its limits.
        XCTAssertEqual(step(&s, .tick, now: 99), [.stop(.clockMoved)])
        XCTAssertEqual(s.stopReason, .clockMoved)
    }

    func testBackwardStepWithinToleranceIsTolerated() {
        var s = makeRun()
        feed(&s, from: 0, secs: 20, bpm: 55)
        XCTAssertEqual(stops(step(&s, .tick, now: 14)), [], "5 s back is a stamping jitter, not a clock change")
        XCTAssertNil(s.stopReason)
        XCTAssertEqual(stops(step(&s, .tick, now: 13.9)), [.clockMoved], "more than 5 s behind the newest now")
    }

    func testToleranceMeasuredFromNewestNowNotLast() {
        var s = makeRun()
        feed(&s, from: 0, secs: 30, bpm: 55)            // newest now = 29
        _ = step(&s, .tick, now: 26)                    // 3 s back: tolerated
        XCTAssertEqual(stops(step(&s, .tick, now: 23.5)), [.clockMoved], "5.5 s behind 29, though only 2.5 s behind 26")
    }

    // MARK: buzz gate

    func testFirstEventBuzzesWhenLinkReady() {
        var s = makeRun()
        XCTAssertEqual(step(&s, .tick, now: 0), [.buzz])
        XCTAssertEqual(s.buzzCount, 1)
        XCTAssertEqual(s.lastBuzzAt, t0)
    }

    func testBuzzPausesWhileStreamStalled() {
        var s = makeRun()
        feed(&s, from: 0, secs: 5, bpm: 55)          // newest sample at t = 4
        var all: [WakeAction] = []
        for t in stride(from: 26, through: 40, by: 2) { all += step(&s, .tick, now: TimeInterval(t)) }
        XCTAssertEqual(buzzes(all), 0)
        XCTAssertEqual(skips(all).count, 8)
        XCTAssertEqual(skips(all).first, "no new HR sample for 22s")
        XCTAssertEqual(s.skippedCount, 8)
    }

    func testBuzzResumesWhenStreamReturns() {
        var s = makeRun()
        feed(&s, from: 0, secs: 5, bpm: 55)
        let paused = step(&s, .tick, now: 30)
        XCTAssertEqual(buzzes(paused), 0)
        let resumed = step(&s, sample(32, 55), now: 32)
        XCTAssertEqual(resumed, [.buzz])
    }

    func testStallIsStrictlyMoreThanTwentySeconds() {
        var s = makeRun()
        step(&s, sample(0, 55), now: 0)
        XCTAssertEqual(step(&s, .tick, now: 20), [.buzz])
        XCTAssertEqual(skips(step(&s, .tick, now: 22.5)).count, 1)
    }

    func testNeverMoreThanOneBuzzDecisionPerTwoSeconds() {
        var s = makeRun()
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
        var s = makeRun()
        var all: [WakeAction] = []
        for i in 0..<40 { all += step(&s, .tick, now: 25 + Double(i) * 0.1) }   // stalled, 4 s of ticks
        XCTAssertEqual(skips(all).count, 2)
    }

    func testLinkNotReadySkipsAndIsNeverAFailure() {
        var s = makeRun()
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
        var s = makeRun()
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
        var s = makeRun()
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
        var s = makeRun()
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
        var s = makeRun()
        step(&s, sample(0, 55), now: 0)
        let acts = step(&s, .buzzResult(ok: true, detail: "ok"), now: 5)
        XCTAssertFalse(acts.contains(.buzz))
    }

    // MARK: no re-arm

    func testNoActionOfAnyKindAfterAStop() {
        var s = makeRun()
        feed(&s, from: 0, secs: 700, bpm: 55)
        XCTAssertEqual(s.stopReason, .buzzBudget)
        let before = s
        XCTAssertEqual(step(&s, .tick, now: 40), [])
        XCTAssertEqual(step(&s, sample(41, 55), now: 41), [])
        XCTAssertEqual(step(&s, .buzzResult(ok: false, detail: "x"), now: 42), [])
        XCTAssertEqual(step(&s, .tick, now: 10_000), [])
        XCTAssertEqual(s, before)
    }

    func testAStopWhileQuietIsFinalToo() {
        var s = quietRun()
        XCTAssertEqual(WakeLoopEngine.stop(&s, reason: .stopped), [.stop(.stopped)])
        // Asleep-looking HR after the stop never re-arms or buzzes.
        XCTAssertEqual(feed(&s, from: 121, secs: 600, bpm: 50), [])
        XCTAssertEqual(s.rearmCount, 0)
    }

    func testExplicitStopIsFinalAndOnlyOnce() {
        var s = makeRun()
        XCTAssertEqual(WakeLoopEngine.stop(&s, reason: .stopped), [.stop(.stopped)])
        XCTAssertEqual(s.stopReason, .stopped)
        XCTAssertEqual(WakeLoopEngine.stop(&s, reason: .interrupted), [])
        XCTAssertEqual(s.stopReason, .stopped)
        XCTAssertEqual(step(&s, .tick, now: 1), [])
    }
}
