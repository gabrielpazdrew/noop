// Fork-only (phone-hub, wake). PLAN-WAKE-PHONE T3: the wake alarm's iOS glue.
//
// Owns the single live wake run: starts it (only from `trigger`, which only the "Start Wake Alarm"
// Shortcuts action calls), feeds it every heart-rate sample and every other Bluetooth wake-up, carries
// out the engine's actions, and cleans up on every stop. Every decision lives in Core/ (engine, gate,
// ledger); this file only wires them to BLEManager, AppModel and UIKit. It is the ONLY caller of
// `BLEManager.wakeBuzz()`. Nothing here STARTS by the clock: the one timer (v2.1) exists only inside a run the
// intent started, is cancelled in `finish`, and only feeds `.tick` so the run's limits fire while no Bluetooth
// frames arrive; a tick can buzz only while live HR samples are still arriving (the engine's stall gate).
#if os(iOS)
import Foundation
import UIKit

/// What a "Start Wake Alarm" request came to.
enum WakeStartOutcome: Equatable {
    case decided(WakeTriggerDecision)
    /// The gate said start, but NOOP's app model didn't exist within the wait: no run, no marker.
    case notReady
    /// v2.1: the run started, but no live HR arrived within `WakeConfig.linkWait`: ended as `.noLink`.
    case noLink
}

@MainActor
final class WakeAlarmRunner {
    static let shared = WakeAlarmRunner()

    /// Where the switch, "Skip tomorrow", the run records and the live-run marker live (the Wake Alarm
    /// screen reads the same store).
    static let defaults = UserDefaults.standard
    /// How long a trigger waits for the app model (and for its first data load) on a cold launch.
    static let modelWaitSeconds: TimeInterval = 8

    let config = WakeConfig()

    private var ring = WakeSampleRing()
    private var run: WakeRunState?
    private var runSource: WakeThresholdSource = .fallback
    private var ledger = WakeBuzzLedger()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// A trigger is between the gate and the run start (it awaits the model): a second trigger is ignored.
    private var starting = false
    private var launched = false
    /// A relaunch found a run marker: the killed process may have left a pattern running on the band.
    /// One best-effort STOP_HAPTICS once the link is ready (never a buzz), then this clears.
    private var interruptedClearPending = false
    /// v2.1: feeds `.tick` every `config.tickInterval` while a run is live (cancelled in `finish`).
    private var ticker: Timer?
    /// v2.1: what this run's start-of-run link request did (nil when the link was ready).
    private var linkRequest: ForkLinkRecovery.WakeLinkRequest?

    private init() {}

    var isRunning: Bool { run != nil }

    private var settings: WakeAlarmSettings { WakeAlarmSettings(defaults: Self.defaults) }
    private var runLog: WakeRunLog { WakeRunLog(defaults: Self.defaults) }

    // MARK: launch

    /// Every process launch (StrandiOSApp.init, after AppModel exists). A marker left by an earlier
    /// process becomes an `interrupted` record and is cleared: a relaunched app never resumes a run.
    func appLaunched(now: Date = Date()) {
        guard !launched else { return }
        launched = true
        // The HR observer is always on: it only fills the in-memory 20-minute ring while no run is live.
        BLEManager.wakeHeartRateObserver = { bpm, at in
            Task { @MainActor in WakeAlarmRunner.shared.heartRate(bpm: bpm, at: at) }
        }
        let log = runLog
        if let started = log.activeRunStartedAt {
            log.append(WakeRunRecord.interrupted(started: started, ended: now))
            log.activeRunStartedAt = nil
            strapLog(WakeLogText.interrupted)
            interruptedClearPending = true
            installRunObservers()   // frames reach clearInterruptedHapticsIfReady(); cleared after the attempt
        }
        var s = settings
        s.clearSkipIfPassed(now: now, calendar: .current)
    }

    // MARK: trigger (the only way a run starts)

    func trigger(now: Date = Date()) async -> WakeStartOutcome {
        var s = settings
        s.clearSkipIfPassed(now: now, calendar: .current)

        // A run whose events died stays in memory until something steps it. Probe a copy with the link
        // reported down (so the probe can never ask for a buzz); only a stop it reaches is carried out, so a
        // stale run (timeout / buzzBudget / noHR / clockMoved) records itself before the gate looks.
        if var probe = run {
            let actions = WakeLoopEngine.step(&probe, .tick, now: now, linkReady: false, config: config)
            if let reason = probe.stopReason, actions.contains(.stop(reason)) {
                run = probe
                finish(reason: reason, now: now)
            }
        }

        let decision: WakeTriggerDecision
        if run != nil || starting {
            decision = .ignoredLiveRun
        } else {
            decision = WakeTriggerGate.decide(settings: s, activeRunStartedAt: runLog.activeRunStartedAt,
                                              now: now, cap: config.watchWindow)
        }
        if decision != .start {
            // Log the skip if the model is (or soon is) there; a skip never waits on anything else.
            _ = await waitForModel(until: now.addingTimeInterval(Self.modelWaitSeconds))
            logRefusal(decision, settings: s)
            return .decided(decision)
        }

        starting = true
        defer { starting = false }
        let deadline = now.addingTimeInterval(Self.modelWaitSeconds)
        guard let model = await waitForModel(until: deadline) else { return .notReady }
        // A cold background launch may not have loaded the daily rows yet. AppModel's own launch refresh is
        // already in flight: wait for it inside the same budget (a second refresh would supersede it with a
        // shorter window), then go on either way; the source line then says median or fallback.
        while !model.repo.loaded && Date() < deadline {
            guard !Task.isCancelled else { return .notReady }   // a cancelled intent starts no run
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard !Task.isCancelled else { return .notReady }
        let resting = WakeLoopEngine.newestRestingHR(model.repo.days.map { (day: $0.day, restingHr: $0.restingHr) })
        var stored: [WakeSample] = []
        if WakeLoopEngine.acceptedRestingHR(resting, config: config) == nil {   // missing or rejected: median fallback
            let to = Date()
            let rows = await model.repo.hrSamples(from: Int(to.addingTimeInterval(-config.medianWindow).timeIntervalSince1970),
                                                  to: Int(to.timeIntervalSince1970))
            stored = rows.map { WakeSample(ts: Date(timeIntervalSince1970: TimeInterval($0.ts)), bpm: $0.bpm) }
        }

        let started = Date()
        // The waits above can take up to 8 s: the switch turned off or a skip set meanwhile still refuses.
        var again = settings
        again.clearSkipIfPassed(now: started, calendar: .current)
        let recheck = WakeTriggerGate.decide(settings: again, activeRunStartedAt: runLog.activeRunStartedAt,
                                             now: started, cap: config.watchWindow)
        if recheck != .start {
            logRefusal(recheck, settings: again)
            return .decided(recheck)
        }
        let recent = WakeSampleRing.mergeRecent(ring: ring.samples, stored: stored, now: started,
                                                window: config.medianWindow)
        let (upLine, source) = WakeLoopEngine.pickThreshold(restingHR: resting, recent: recent, config: config)
        let asleepLine = WakeLoopEngine.asleepLine(upLine: upLine, source: source, config: config)
        // v2: no look-back replay (it ended a run started while awake after one buzz). The ring's last
        // seconds only seed the run's max HR; the engine walks samples stamped at or after the start.
        let warmup = ring.samples(after: started.addingTimeInterval(-config.warmupWindow), through: started)

        run = WakeRunState.begin(started: started, upLine: upLine, asleepLine: asleepLine,
                                 warmup: warmup, config: config)
        runSource = source
        ledger = WakeBuzzLedger()
        runLog.activeRunStartedAt = started
        installRunObservers()
        beginBackgroundTask()
        strapLog(WakeLogText.start(upLine: upLine, asleepLine: asleepLine, source: source,
                                   bandAlarmOn: model.behavior.smartAlarmEnabled))
        startTicker()
        linkRequest = nil

        // v2.1: never sit silent with no band. No fresh HR → ask for the link (if it's down), then wait for a
        // live sample until `linkWait` after the trigger; none → end the run as noLink and say so. The link
        // request is left pending after the run, so data resumes; nothing here buzzes.
        let deadline = now.addingTimeInterval(config.linkWait)
        if WakeLinkWait.decide(newestSampleAt: ring.samples.last?.ts, now: Date(), deadline: deadline,
                               config: config) != .proceed {
            if !model.ble.wakeLinkReady {
                linkRequest = model.ble.wakeRequestLink()
                if linkRequest == .requested { strapLog(WakeLogText.reconnectRequested) }
            }
            strapLog(WakeLogText.waitingForHR)
            while true {
                // Ended meanwhile (Stop now, a limit): nothing more to decide here.
                guard let live = run, live.started == started else { return .decided(.start) }
                let verdict = WakeLinkWait.decide(newestSampleAt: ring.samples.last?.ts, now: Date(),
                                                  deadline: deadline, config: config)
                if verdict == .proceed { break }
                if verdict == .noLink {
                    var state = live
                    let actions = WakeLoopEngine.stop(&state, reason: .noLink)
                    run = state
                    perform(actions, now: Date())
                    return .noLink
                }
                // A cancelled intent stops waiting; the run goes on and its own limits (ticks) end it.
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return .decided(.start)
    }

    /// v2.1: the run's clock while the app is awake. Main run loop, so it fires on the main thread; it only
    /// hops to `wake(now:)`, which is a no-op with no live run.
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: config.tickInterval, repeats: true) { _ in
            Task { @MainActor in WakeAlarmRunner.shared.wake(now: Date()) }
        }
    }

    private func logRefusal(_ decision: WakeTriggerDecision, settings s: WakeAlarmSettings) {
        switch decision {
        case .ignoredLiveRun:  strapLog(WakeLogText.ignoredLiveRun)
        case .skippedOff:      strapLog(WakeLogText.skippedOff)
        case .skippedTomorrow: strapLog(WakeLogText.skippedTomorrow(day: s.skipDay ?? "?", calendar: .current))
        case .start:           break
        }
    }

    private func waitForModel(until deadline: Date) async -> AppModel? {
        while AppModel.shared == nil && Date() < deadline {
            guard !Task.isCancelled else { return nil }   // cancelled: ends as "not ready", never spins
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return Task.isCancelled ? nil : AppModel.shared
    }

    // MARK: events

    /// Every readable HR sample, stamped on arrival. With no live run it only fills the ring.
    func heartRate(bpm: Int, at: Date) {
        let sample = WakeSample(ts: at, bpm: bpm)
        ring.append(sample)
        clearInterruptedHapticsIfReady()
        guard run != nil else { return }
        drive(.sample(sample), now: Date())
    }

    /// Any other app wake-up (an inbound Bluetooth frame). No-op with no live run.
    func wake(now: Date = Date()) {
        clearInterruptedHapticsIfReady()
        guard run != nil else { return }
        drive(.tick, now: now)
    }

    /// A failed acknowledged command write (`at` = when the observer saw it). Counted only when it falls
    /// inside a buzz's 3 s window, and at most once per buzz (WakeBuzzLedger).
    func writeError(_ detail: String, at: Date) {
        guard run != nil else { return }
        let now = Date()
        // Charge first: after a slow main-actor hop the buzz's window may look expired, and settling
        // first would credit a real failure as a success.
        let charged = ledger.writeError(at: at)
        settleBuzzes(now: now)
        guard charged, run != nil else { return }
        step(.buzzResult(ok: false, detail: detail), now: now)
    }

    /// The Wake Alarm screen's "Stop now", or its switch turned off mid-run.
    func stopNow(now: Date = Date()) {
        guard var state = run else { return }
        let actions = WakeLoopEngine.stop(&state, reason: .stopped)
        run = state
        perform(actions, now: now)
    }

    /// The interrupted-run clear: a single STOP_HAPTICS attempt the first time the link is ready, no retry.
    private func clearInterruptedHapticsIfReady() {
        guard interruptedClearPending, let model = AppModel.shared, model.ble.wakeLinkReady else { return }
        interruptedClearPending = false
        model.stopHaptics()
        strapLog(WakeLogText.interruptedHapticsCleared)
        if run == nil {
            BLEManager.wakeFrameObserver = nil
            BLEManager.wakeWriteErrorObserver = nil
        }
    }

    // MARK: engine plumbing

    private func drive(_ event: WakeEvent, now: Date) {
        settleBuzzes(now: now)
        step(event, now: now)
    }

    /// Buzzes whose 3 s passed with no write error are reported to the engine as written OK.
    private func settleBuzzes(now: Date) {
        let ok = ledger.expire(now: now)
        for _ in 0..<ok where run != nil {
            step(.buzzResult(ok: true, detail: ""), now: now)
        }
    }

    private func step(_ event: WakeEvent, now: Date) {
        guard var state = run else { return }
        let linkReady = AppModel.shared?.ble.wakeLinkReady ?? false
        let actions = WakeLoopEngine.step(&state, event, now: now, linkReady: linkReady, config: config)
        run = state
        perform(actions, now: now)
    }

    private func perform(_ actions: [WakeAction], now: Date) {
        for action in actions {
            guard run != nil else { return }
            switch action {
            case .buzz:
                // The one wakeBuzz() call site in the fork.
                if AppModel.shared?.ble.wakeBuzz() == true {
                    ledger.sent(at: now)
                    strapLog(WakeLogText.buzz(run?.buzzCount ?? 0))
                } else {
                    // Link dropped between the engine's check and the write: nothing was sent.
                    step(.buzzResult(ok: false, detail: "not sent, link not ready"), now: now)
                }
            case .skipBuzz(let reason):
                strapLog(WakeLogText.skipped(reason))
            case .log(let line):
                strapLog(WakeLogText.engine(line))
            case .stopHaptics:
                // Going quiet: the band stops vibrating, the run goes on watching. Never a buzz.
                AppModel.shared?.stopHaptics()
            case .stop(let reason):
                finish(reason: reason, now: now)
            }
        }
    }

    /// Every stop ends here, exactly once per run.
    private func finish(reason: WakeStopReason, now: Date) {
        guard let state = run else { return }
        run = nil
        ticker?.invalidate()
        ticker = nil
        BLEManager.wakeFrameObserver = nil
        BLEManager.wakeWriteErrorObserver = nil
        ledger = WakeBuzzLedger()
        if state.buzzCount > 0 { AppModel.shared?.stopHaptics() }   // clears a wedged pattern (#769)
        let log = runLog
        log.append(WakeRunRecord(started: state.started, ended: now, stopReason: reason,
                                 thresholdSource: runSource.logDescription,
                                 buzzCount: state.buzzCount, confirmedBuzzCount: state.confirmedBuzzCount,
                                 skippedCount: state.skippedCount, maxBpm: state.maxBpm,
                                 quietCount: state.quietCount, rearmCount: state.rearmCount,
                                 buzzingSeconds: Int(state.buzzingSeconds(at: max(now, state.started)))))
        log.activeRunStartedAt = nil
        if reason == .noLink {
            strapLog(WakeLogText.noLinkStop(secs: max(0, Int(now.timeIntervalSince(state.started))),
                                            reconnectRequested: linkRequest == .requested))
        } else {
            strapLog(WakeLogText.stop(state, reason: reason, now: now))
        }
        endBackgroundTask()
    }

    // MARK: hooks and process time

    /// Frame and write-error observers exist only while a run is live (set here, cleared in `finish`).
    /// Both run inside main-actor CoreBluetooth callbacks, so they only note the time and hop; nothing is
    /// decided, and nothing buzzes, inside the callback.
    private func installRunObservers() {
        final class Throttle { var last = Date.distantPast }
        let throttle = Throttle()
        BLEManager.wakeFrameObserver = { at in
            guard abs(at.timeIntervalSince(throttle.last)) >= 1 else { return }   // a sync can send hundreds/s
            throttle.last = at
            Task { @MainActor in WakeAlarmRunner.shared.wake(now: Date()) }
        }
        BLEManager.wakeWriteErrorObserver = { detail in
            let at = Date()
            Task { @MainActor in WakeAlarmRunner.shared.writeError(detail, at: at) }
        }
    }

    /// Asks iOS for background time while the run is live. The expiry handler only ends the assertion: the
    /// run goes on, driven by Bluetooth wake-ups, and still stops by its own limits.
    private func beginBackgroundTask() {
        endBackgroundTask()
        let app = UIApplication.shared
        var id: UIBackgroundTaskIdentifier = .invalid
        id = app.beginBackgroundTask(withName: "wake-alarm-run") {
            MainActor.assumeIsolated {
                if WakeAlarmRunner.shared.backgroundTask == id { WakeAlarmRunner.shared.backgroundTask = .invalid }
            }
            app.endBackgroundTask(id)
        }
        backgroundTask = id
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let id = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func strapLog(_ line: String) {
        AppModel.shared?.live.append(log: AppModel.stamped(line))
    }
}
#endif
