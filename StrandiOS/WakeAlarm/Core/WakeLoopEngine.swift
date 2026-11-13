// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The phone wake alarm's whole decision logic, with no Bluetooth, no timers and no UI:
// (event, clock, config, state) -> actions. Driven by events, not a sleep loop: every heart-rate
// sample and every other app wake-up is one `step`, and every step re-reads the wall clock, so the
// watch window, the buzz budget and the no-HR stop hold even when events stall. If events stop
// entirely, nothing buzzes (fails safe).
//
// v2 (Nov 12, 2026): heart-rate LEVEL drives the run, not a one-shot "awake" stop. A run starts
// `.buzzing`; once the AVERAGE HR over the last `upSustain` is at or above the up line it goes `.quiet`
// (band stopped, run still watching); if the average over the last `asleepSustain` then drops to the
// back-asleep line it buzzes again. Each mode judges only samples walked since it began, and only
// after it has lasted its sustain. Averages, not every-sample runs: a short dip should not reset the
// "up" count, and a 5-min mean near resting HR separates dozing off from sitting awake far better than
// a short window. Only samples stamped at or after the start count. The run ends on the watch window, the
// buzz budget, no HR, buzz failures, a clock change or Stop. A stopped run never re-arms.
import Foundation

/// Every number the wake loop uses, in one place (the coordinator tunes them from real nights).
struct WakeConfig: Equatable {
    /// bpm added to the resting HR (or the recent median) to get the up line.
    var upMargin: Double = 15
    /// bpm added to the resting HR to get the back-asleep line (median/fallback: up line minus the gap).
    var asleepMargin: Double = 6
    /// A resting HR outside this range is treated as missing (a misread night, e.g. around a DST change, can report one far too high).
    var restingMin: Int = 35
    var restingMax: Int = 65
    /// Up line when there is neither a resting HR nor any recent HR.
    var fallbackThreshold: Double = 70
    /// Ceiling for a median-derived up line (a median taken while already awake is unreachable + 15).
    var medianCap: Double = 90
    /// How far back the median fallback looks.
    var medianWindow: TimeInterval = 1200
    /// Going quiet: the mean of the samples in the last this-many seconds (by sample time) is at or above
    /// the up line, and buzzing has lasted at least this long...
    var upSustain: TimeInterval = 120
    /// ...with at least this many samples in that window (half its seconds).
    var minOverSamples: Int = 60
    /// Buzzing again: the mean over the last this-many seconds is at or below the back-asleep line, and
    /// quiet has lasted at least this long...
    var asleepSustain: TimeInterval = 300
    /// ...with at least this many samples in that window.
    var minUnderSamples: Int = 150
    /// A sample older than this is not "live".
    var fresh: TimeInterval = 35
    /// A sample older than this on arrival is not walked at all (a late back-fill burst inside it still counts).
    var readWindow: TimeInterval = 65
    /// Ring samples from this long before the start seed `maxBpm` (they are never walked).
    var warmupWindow: TimeInterval = 31
    /// No new HR sample for longer than this pauses the buzzing (night 1: buzzing starved the HR stream).
    var buzzStall: TimeInterval = 20
    /// No live HR for this long stops the run, buzzing or quiet.
    var noHRLimit: TimeInterval = 120
    /// Total run length, from the start.
    var watchWindow: TimeInterval = 2700
    /// After going quiet, stop-haptics is sent once more on the first event at least this long after
    /// (the first one is an unconfirmed write: iOS may drop it, or it may overtake a queued buzz).
    var quietResendDelay: TimeInterval = 3
    /// Total time spent buzzing (all buzzing stretches added up) that ends the run.
    var buzzBudget: TimeInterval = 600
    /// At the start, with no fresh HR, how long (from the trigger) the intent waits for a live sample
    /// before ending the run as `.noLink`. Includes the runner's model wait; keeps the intent well
    /// under the Shortcuts time limit.
    var linkWait: TimeInterval = 22
    /// While the app is awake during a run, the runner feeds a `.tick` this often, so the watch window,
    /// buzz budget and no-HR limit fire even when no Bluetooth frames arrive.
    var tickInterval: TimeInterval = 5
    /// Consecutive failed buzz writes that stop the run.
    var maxBuzzFailures: Int = 3
    /// At most one buzz decision (buzz or skip) per this many seconds.
    var buzzSpacing: TimeInterval = 2
    /// A step whose clock is more than this behind the newest clock seen in the run stops it (`clockMoved`):
    /// a clock set back mid-run would otherwise stretch the watch window in real time.
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
    /// A resting HR failed the sanity range; `then` is what was used instead (median or fallback).
    indirect case rejected(restingHR: Int, then: WakeThresholdSource)

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
        case .rejected(let r, let then):
            return "\(then.logDescription) (resting_hr \(r) rejected)"
        }
    }
}

enum WakeStopReason: String, Codable, Equatable {
    /// v1 only (HR held high for 30 s ended the run); kept so old records still decode. v2 never ends on it.
    case awake
    /// The watch window ran out.
    case timeout
    case noHR, buzzFailed, stopped, interrupted
    /// The wall clock went back before the run's start: every age and limit is then meaningless.
    case clockMoved
    /// The run spent `buzzBudget` seconds buzzing in total.
    case buzzBudget
    /// The run started with no fresh HR and none arrived within `linkWait`: the band wasn't connected.
    case noLink
}

/// The start-of-run wait for a live HR sample (pure, so the decision is unit-tested; the runner polls).
enum WakeLinkWait: Equatable {
    case proceed, wait, noLink

    /// `proceed` once the newest sample is fresh (no older than `fresh`); `noLink` at the deadline.
    static func decide(newestSampleAt: Date?, now: Date, deadline: Date, config: WakeConfig) -> WakeLinkWait {
        if let ts = newestSampleAt, now.timeIntervalSince(ts) <= config.fresh, ts <= now { return .proceed }
        return now >= deadline ? .noLink : .wait
    }
}

/// Which half of the loop a live run is in.
enum WakeMode: String, Equatable {
    /// Buzzing (subject to spacing, stall and link checks). A run starts here.
    case buzzing
    /// HR showed he is up: the band is stopped and nothing buzzes until HR drops back to the asleep line.
    case quiet
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
    /// Stop the band's vibration now WITHOUT ending the run (going quiet).
    case stopHaptics
    case stop(WakeStopReason)
}

/// One run's state. Value type: the runner owns the only copy.
struct WakeRunState: Equatable {
    var started: Date
    /// At or above: counts toward "up" (going quiet).
    var upLine: Double
    /// At or below: counts toward "back asleep" (buzzing again).
    var asleepLine: Double
    var mode: WakeMode
    /// Newest sample timestamp already walked (dedup mark).
    var lastSeenTs: Date
    /// Wall clock the current mode began (run start, last quiet, last re-arm).
    var modeSince: Date
    /// Samples walked since the current mode began, oldest first, trimmed to that mode's sustain window
    /// (by sample time). Bounded: at most one sustain window of samples.
    var window: [WakeSample]
    /// Wall clock of the last step that walked a not-yet-seen sample (the buzz gate reads it).
    var lastNewAt: Date
    /// Wall clock of the last step that saw a live sample (the no-HR stop reads it).
    var lastLiveAt: Date
    /// Wall clock of the last buzz decision, buzz OR skip, so neither happens more than once per spacing.
    var lastBuzzAt: Date
    /// The newest wall clock any step of this run has seen (the backwards-step check reads it).
    var newestNow: Date
    /// Seconds spent buzzing in finished buzzing stretches.
    var buzzingDone: TimeInterval
    /// Wall clock the current buzzing stretch began; nil while quiet.
    var buzzingSince: Date?
    /// The one stop-haptics re-send after going quiet is still owed (cleared when sent or on re-arm).
    var quietResendPending: Bool
    /// Times the run went quiet (HR showed he was up) / went back to buzzing (HR showed he fell back asleep).
    var quietCount: Int
    var rearmCount: Int
    /// Buzzes requested (writes handed to the runner).
    var buzzCount: Int
    /// Buzzes the runner reported as written OK (`buzzResult(ok: true)`).
    var confirmedBuzzCount: Int
    var skippedCount: Int
    var consecutiveFailures: Int
    var maxBpm: Int?
    var stopReason: WakeStopReason?

    /// A run starts buzzing. Only samples stamped at or after `started` are walked; `maxBpm` starts at
    /// the warm-up maximum (ring samples from just before the start, never walked).
    static func begin(started: Date, upLine: Double, asleepLine: Double, warmup: [WakeSample],
                      config: WakeConfig) -> WakeRunState {
        WakeRunState(started: started,
                     upLine: upLine,
                     asleepLine: asleepLine,
                     mode: .buzzing,
                     lastSeenTs: .distantPast,
                     modeSince: started,
                     window: [],
                     lastNewAt: started,
                     lastLiveAt: started,
                     lastBuzzAt: .distantPast,
                     newestNow: started,
                     buzzingDone: 0,
                     buzzingSince: started,
                     quietResendPending: false,
                     quietCount: 0, rearmCount: 0,
                     buzzCount: 0, confirmedBuzzCount: 0, skippedCount: 0, consecutiveFailures: 0,
                     maxBpm: warmup.map(\.bpm).max(),
                     stopReason: nil)
    }

    /// Total seconds spent buzzing as of `now` (the current stretch included).
    func buzzingSeconds(at now: Date) -> TimeInterval {
        buzzingDone + (buzzingSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
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

    /// The up line: resting HR + `upMargin` (no cap); else median of recent HR + `upMargin`, capped;
    /// else the flat fallback.
    /// A resting HR outside `restingMin...restingMax` is rejected (treated as missing; the source says so).
    static func pickThreshold(restingHR: Int?, recent: [WakeSample],
                              config: WakeConfig) -> (Double, WakeThresholdSource) {
        if let r = acceptedRestingHR(restingHR, config: config) {
            return (Double(r) + config.upMargin, .restingHR(r))
        }
        let (line, source) = pickWithoutRestingHR(recent: recent, config: config)
        if let r = restingHR { return (line, .rejected(restingHR: r, then: source)) }
        return (line, source)
    }

    /// The resting HR if it passes the sanity range, else nil.
    static func acceptedRestingHR(_ restingHR: Int?, config: WakeConfig) -> Int? {
        guard let r = restingHR, r >= config.restingMin, r <= config.restingMax else { return nil }
        return r
    }

    private static func pickWithoutRestingHR(recent: [WakeSample],
                                             config: WakeConfig) -> (Double, WakeThresholdSource) {
        if !recent.isEmpty {
            let med = median(recent.map(\.bpm))
            let raw = med + config.upMargin
            let thr = min(raw, config.medianCap)
            return (thr, .median(bpm: med, n: recent.count, capped: thr < raw))
        }
        return (config.fallbackThreshold, .fallback)
    }

    /// The back-asleep line. Resting HR: resting + `asleepMargin`. Median / fallback: the up line minus the
    /// gap between the margins (the same gap, applied to whatever the up line came to, cap included).
    static func asleepLine(upLine: Double, source: WakeThresholdSource, config: WakeConfig) -> Double {
        switch source {
        case .restingHR(let r): return Double(r) + config.asleepMargin
        case .median, .fallback, .rejected: return upLine - (config.upMargin - config.asleepMargin)
        }
    }

    /// "2-min" for whole minutes, else "90-s" (log text built from config numbers).
    static func span(_ secs: TimeInterval) -> String {
        let n = Int(secs)
        return n % 60 == 0 ? "\(n / 60)-min" : "\(n)-s"
    }

    static func mean(_ samples: [WakeSample]) -> Double {
        Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
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
        //    otherwise the watch window and every age would be measured from the wrong side.
        //    So does a step more than the tolerance behind the newest clock seen (set back mid-run).
        if now < state.started || state.newestNow.timeIntervalSince(now) > config.clockBackTolerance {
            return stop(&state, reason: .clockMoved)
        }
        if now > state.newestNow { state.newestNow = now }
        if now.timeIntervalSince(state.started) >= config.watchWindow {
            return stop(&state, reason: .timeout)
        }
        if state.buzzingSeconds(at: now) >= config.buzzBudget {
            return stop(&state, reason: .buzzBudget)
        }
        // Either mode: a quiet run with no HR can't tell whether he fell back asleep.
        if now.timeIntervalSince(state.lastLiveAt) >= config.noHRLimit {
            return stop(&state, reason: .noHR)
        }

        var actions: [WakeAction] = []

        // The one stop-haptics re-send, on any event once the delay has passed. Unconfirmed, like the first.
        if state.mode == .quiet, state.quietResendPending,
           now.timeIntervalSince(state.modeSince) >= config.quietResendDelay {
            state.quietResendPending = false
            actions.append(.stopHaptics)
        }

        switch event {
        case .buzzResult(let ok, let detail):
            // 5. Only the failure count; a result never itself leads to a buzz.
            if state.mode == .quiet {
                // In-flight results of buzzes sent just before quiet: a late success still counts as
                // confirmed, a late failure is ignored (it must not end a quiet run as buzzFailed).
                if ok { state.confirmedBuzzCount += 1 }
                return actions
            }
            if ok {
                state.confirmedBuzzCount += 1
                state.consecutiveFailures = 0
                return actions
            }
            state.consecutiveFailures += 1
            actions.append(.log("buzz FAILED (\(state.consecutiveFailures)/\(config.maxBuzzFailures)): \(detail)"))
            if state.consecutiveFailures >= config.maxBuzzFailures {
                actions += stop(&state, reason: .buzzFailed)
            }
            return actions

        case .sample(let s):
            // 3. Walk the sample, then judge the mode change before any buzz decision.
            let age = now.timeIntervalSince(s.ts)
            let walk = s.ts >= state.started               // only this run's samples
                && s.ts <= now                             // never walk ahead of the clock
                && s.ts > state.lastSeenTs                 // dedup
                && age <= config.readWindow                // a late back-fill burst still counts
            if walk {
                if age <= config.fresh {
                    state.lastLiveAt = now
                    state.maxBpm = max(state.maxBpm ?? s.bpm, s.bpm)
                }
                state.lastSeenTs = s.ts
                state.lastNewAt = now
                // Each mode judges only samples walked since it began (a late sample stamped before
                // the mode change belongs to the old mode and is left out).
                if s.ts >= state.modeSince {
                    let sustain = state.mode == .buzzing ? config.upSustain : config.asleepSustain
                    state.window.append(s)
                    let oldest = s.ts.addingTimeInterval(-sustain)
                    if let keep = state.window.firstIndex(where: { $0.ts >= oldest }) {
                        state.window.removeFirst(keep)
                    }
                    if now.timeIntervalSince(state.modeSince) >= sustain {
                        let avg = mean(state.window)
                        switch state.mode {
                        case .buzzing:
                            if state.window.count >= config.minOverSamples, avg >= state.upLine {
                                goQuiet(&state, now: now, config: config, actions: &actions)
                                return actions
                            }
                        case .quiet:
                            if state.window.count >= config.minUnderSamples, avg <= state.asleepLine {
                                rearm(&state, now: now, config: config, actions: &actions)
                            }
                        }
                    }
                }
            }

        case .tick:
            break
        }

        // 4. Buzz decision, at most one per spacing, and never while quiet.
        guard state.mode == .buzzing else { return actions }
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

    /// Buzzing → quiet: the band is told to stop, the run keeps watching for a fall back asleep.
    private static func goQuiet(_ state: inout WakeRunState, now: Date, config: WakeConfig,
                                actions: inout [WakeAction]) {
        state.buzzingDone = state.buzzingSeconds(at: now)
        state.buzzingSince = nil
        state.modeSince = now
        state.window = []
        state.quietResendPending = true
        state.mode = .quiet
        state.quietCount += 1
        let secs = max(0, Int(now.timeIntervalSince(state.started)))
        actions.append(.stopHaptics)
        actions.append(.log("quiet (\(span(config.upSustain)) average ≥ \(String(format: "%.0f", state.upLine)) bpm) after \(secs)s, \(state.buzzCount) buzz(es)"))
    }

    /// Quiet → buzzing: HR held at or below the back-asleep line. The next eligible event buzzes.
    private static func rearm(_ state: inout WakeRunState, now: Date, config: WakeConfig,
                              actions: inout [WakeAction]) {
        state.mode = .buzzing
        state.buzzingSince = now
        state.modeSince = now
        state.window = []
        state.quietResendPending = false
        state.consecutiveFailures = 0
        state.rearmCount += 1
        actions.append(.log("back asleep? \(span(config.asleepSustain)) average ≤ \(String(format: "%.0f", state.asleepLine)) bpm — buzzing again"))
    }
}
