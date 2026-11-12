// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The phone wake alarm's whole decision logic, with no Bluetooth, no timers and no UI:
// (event, clock, config, state) -> actions. A port of the Health Analysis Mac loop
// (tools/wake_loop.py, `run_loop`), driven by events instead of a sleep loop: every heart-rate
// sample and every other app wake-up is one `step`, and every step re-reads the wall clock, so the
// 10-minute cap and the no-HR stop hold even when events stall. If events stop entirely, nothing
// buzzes (fails safe). A stopped run never re-arms.
import Foundation

/// The Mac loop's numbers (tools/wake_loop.py) as defaults.
struct WakeConfig: Equatable {
    /// bpm added to the resting HR (or the recent median) to get the "awake" threshold.
    var margin: Double = 15
    /// Threshold when there is neither a resting HR nor any recent HR.
    var fallbackThreshold: Double = 70
    /// Ceiling for a median-derived threshold (a median taken while already awake is unreachable + 15).
    var medianCap: Double = 90
    /// How far back the median fallback looks.
    var medianWindow: TimeInterval = 1200
    /// HR must stay at or above the threshold for this long to count as awake...
    var sustain: TimeInterval = 30
    /// ...with at least this many samples in the run.
    var minOverSamples: Int = 10
    /// A sample older than this is not "live".
    var fresh: TimeInterval = 35
    /// No new HR sample for longer than this pauses the buzzing (night 1: buzzing starved the HR stream).
    var buzzStall: TimeInterval = 20
    /// No live HR for this long stops the run.
    var noHRLimit: TimeInterval = 120
    /// Total run length.
    var cap: TimeInterval = 600
    /// Consecutive failed buzz writes that stop the run.
    var maxBuzzFailures: Int = 3
    /// At most one buzz decision (buzz or skip) per this many seconds.
    var buzzSpacing: TimeInterval = 2
    /// A step whose clock is more than this behind the newest clock seen in the run stops it (`clockMoved`):
    /// a clock set back mid-run would otherwise stretch the 10-minute cap in real time.
    var clockBackTolerance: TimeInterval = 5
}

struct WakeSample: Equatable {
    var ts: Date
    var bpm: Int
}

enum WakeThresholdSource: Equatable {
    case restingHR(Int)
    case median(bpm: Double, n: Int, capped: Bool)
    case fallback

    /// Shaped like the Mac loop's source text, for the strap log and the run record.
    var logDescription: String {
        switch self {
        case .restingHR(let r):
            return "resting_hr=\(r)"
        case .median(let bpm, let n, let capped):
            let minutes = Int(WakeConfig().medianWindow) / 60
            return "median_last_\(minutes)min=\(String(format: "%.0f", bpm))(n=\(n))\(capped ? " capped" : "")"
        case .fallback:
            return "fallback"
        }
    }
}

enum WakeStopReason: String, Codable, Equatable {
    case awake, timeout, noHR, buzzFailed, stopped, interrupted
    /// The wall clock went back before the run's start: every age and limit is then meaningless.
    case clockMoved
}

enum WakeEvent: Equatable {
    /// One heart-rate sample, stamped on arrival.
    case sample(WakeSample)
    /// Any other wake-up of the app (a non-HR Bluetooth frame, a UI action). Not a timer.
    case tick
    /// The outcome of the runner's last buzz write.
    case buzzResult(ok: Bool, detail: String)
}

enum WakeAction: Equatable {
    case buzz
    case skipBuzz(reason: String)
    case log(String)
    case stop(WakeStopReason)
}

/// One run's state. Value type: the runner owns the only copy.
struct WakeRunState: Equatable {
    var started: Date
    var threshold: Double
    /// Newest sample timestamp already walked (dedup mark).
    var lastSeenTs: Date
    /// First / newest sample of the current over-threshold run; nil when there is none.
    var overSince: Date?
    var overLast: Date?
    var overN: Int
    /// Wall clock of the last step that walked a not-yet-seen sample (the buzz gate reads it).
    var lastNewAt: Date
    /// Wall clock of the last step that saw a live sample (the no-HR stop reads it).
    var lastLiveAt: Date
    /// Wall clock of the last buzz decision, buzz OR skip, so neither happens more than once per spacing.
    var lastBuzzAt: Date
    /// The newest wall clock any step of this run has seen (the backwards-step check reads it).
    var newestNow: Date
    /// Buzzes requested (writes handed to the runner).
    var buzzCount: Int
    /// Buzzes the runner reported as written OK (`buzzResult(ok: true)`).
    var confirmedBuzzCount: Int
    var skippedCount: Int
    var consecutiveFailures: Int
    var maxBpm: Int?
    var stopReason: WakeStopReason?

    /// Start values as `run_loop`: samples from the `sustain + 1` s before the trigger can still be
    /// walked (the runner replays them from its ring), and `maxBpm` starts at the warm-up maximum.
    static func begin(started: Date, threshold: Double, warmup: [WakeSample], config: WakeConfig) -> WakeRunState {
        WakeRunState(started: started,
                     threshold: threshold,
                     lastSeenTs: started.addingTimeInterval(-config.sustain - 1),
                     overSince: nil, overLast: nil, overN: 0,
                     lastNewAt: started,
                     lastLiveAt: started,
                     lastBuzzAt: .distantPast,
                     newestNow: started,
                     buzzCount: 0, confirmedBuzzCount: 0, skippedCount: 0, consecutiveFailures: 0,
                     maxBpm: warmup.map(\.bpm).max(),
                     stopReason: nil)
    }
}

enum WakeLoopEngine {

    // MARK: threshold

    /// Resting HR of the newest day that has one, today included; input order not assumed
    /// (Mac `resting_hr_from_health`). Days are `yyyy-MM-dd`, so string order is date order.
    static func newestRestingHR(_ rows: [(day: String, restingHr: Int?)]) -> Int? {
        var best: (day: String, hr: Int)?
        for row in rows {
            guard let hr = row.restingHr else { continue }
            if best == nil || row.day > best!.day { best = (row.day, hr) }
        }
        return best?.hr
    }

    /// Resting HR + margin (no cap); else median of recent HR + margin, capped; else the flat fallback.
    static func pickThreshold(restingHR: Int?, recent: [WakeSample],
                              config: WakeConfig) -> (Double, WakeThresholdSource) {
        if let r = restingHR {
            return (Double(r) + config.margin, .restingHR(r))
        }
        if !recent.isEmpty {
            let med = median(recent.map(\.bpm))
            let raw = med + config.margin
            let thr = min(raw, config.medianCap)
            return (thr, .median(bpm: med, n: recent.count, capped: thr < raw))
        }
        return (config.fallbackThreshold, .fallback)
    }

    /// Python's `statistics.median`: the mean of the two middle values when the count is even.
    static func median(_ values: [Int]) -> Double {
        let s = values.sorted()
        let n = s.count
        precondition(n > 0)
        if n % 2 == 1 { return Double(s[n / 2]) }
        return (Double(s[n / 2 - 1]) + Double(s[n / 2])) / 2
    }

    // MARK: the loop

    /// Ends the run from outside (Stop button, switch off). Returns [] if it already stopped.
    static func stop(_ state: inout WakeRunState, reason: WakeStopReason) -> [WakeAction] {
        guard state.stopReason == nil else { return [] }
        state.stopReason = reason
        return [.stop(reason)]
    }

    static func step(_ state: inout WakeRunState, _ event: WakeEvent, now: Date,
                     linkReady: Bool, config: WakeConfig) -> [WakeAction] {
        // 1. A stopped run stays stopped: no action of any kind, ever.
        guard state.stopReason == nil else { return [] }

        // 2. The clock first, on every event. A clock that went back before the start stops the run:
        //    otherwise the cap and every age would be measured from the wrong side.
        //    So does a step more than the tolerance behind the newest clock seen (set back mid-run).
        if now < state.started || state.newestNow.timeIntervalSince(now) > config.clockBackTolerance {
            return stop(&state, reason: .clockMoved)
        }
        if now > state.newestNow { state.newestNow = now }
        if now.timeIntervalSince(state.started) >= config.cap {
            return stop(&state, reason: .timeout)
        }
        if now.timeIntervalSince(state.lastLiveAt) >= config.noHRLimit {
            return stop(&state, reason: .noHR)
        }

        var actions: [WakeAction] = []

        switch event {
        case .buzzResult(let ok, let detail):
            // 5. Only the failure count; a result never itself leads to a buzz.
            if ok {
                state.confirmedBuzzCount += 1
                state.consecutiveFailures = 0
                return []
            }
            state.consecutiveFailures += 1
            actions.append(.log("buzz FAILED (\(state.consecutiveFailures)/\(config.maxBuzzFailures)): \(detail)"))
            if state.consecutiveFailures >= config.maxBuzzFailures {
                actions += stop(&state, reason: .buzzFailed)
            }
            return actions

        case .sample(let s):
            // 3. Walk the sample, then judge "awake" before any buzz decision.
            let age = now.timeIntervalSince(s.ts)
            let walk = s.ts <= now                         // never walk ahead of the clock
                && s.ts > state.lastSeenTs                 // dedup
                && age <= config.sustain + config.fresh    // the Mac's read window (65 s)
            if walk {
                if age <= config.fresh {
                    state.lastLiveAt = now
                    state.maxBpm = max(state.maxBpm ?? s.bpm, s.bpm)
                }
                state.lastSeenTs = s.ts
                state.lastNewAt = now
                if Double(s.bpm) >= state.threshold {
                    if state.overSince == nil { state.overSince = s.ts; state.overN = 0 }
                    state.overLast = s.ts
                    state.overN += 1
                } else {
                    state.overSince = nil; state.overLast = nil; state.overN = 0
                }
                if let since = state.overSince, let last = state.overLast,
                   last.timeIntervalSince(since) >= config.sustain,
                   state.overN >= config.minOverSamples {
                    return stop(&state, reason: .awake)
                }
            }

        case .tick:
            break
        }

        // 4. Buzz decision, at most one per spacing.
        guard now.timeIntervalSince(state.lastBuzzAt) >= config.buzzSpacing else { return actions }
        state.lastBuzzAt = now
        let sinceNew = now.timeIntervalSince(state.lastNewAt)
        if sinceNew > config.buzzStall {
            state.skippedCount += 1
            actions.append(.skipBuzz(reason: "no new HR sample for \(Int(sinceNew))s"))
        } else if !linkReady {
            // Not a failure: a cold-launched app must not burn its failures before the band connects.
            state.skippedCount += 1
            actions.append(.skipBuzz(reason: "link not ready"))
        } else {
            state.buzzCount += 1
            actions.append(.buzz)
        }
        return actions
    }
}
