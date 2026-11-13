// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The wake runner's in-memory heart-rate ring: the last 20 minutes of readable HR samples, stamped on
// arrival. It feeds the up line's median fallback and the run's max-HR warm-up (v2: never replayed into a run).
// Never persisted.
import Foundation

struct WakeSampleRing {
    /// How far back the ring keeps samples (the engine's median window).
    var window: TimeInterval = WakeConfig().medianWindow
    /// Hard ceiling on the count, whatever the clock does (about 1 sample/s for 20 min, with room).
    var maxCount = 3000

    private(set) var samples: [WakeSample] = []

    /// Appends one sample and drops everything older than `window` before it, plus anything over `maxCount`.
    mutating func append(_ s: WakeSample) {
        samples.append(s)
        let floor = s.ts.addingTimeInterval(-window)
        if let first = samples.first, first.ts < floor {
            samples.removeAll { $0.ts < floor }
        }
        if samples.count > maxCount { samples.removeFirst(samples.count - maxCount) }
    }

    /// Samples with `from < ts <= to`, in arrival order.
    func samples(after from: Date, through to: Date) -> [WakeSample] {
        samples.filter { $0.ts > from && $0.ts <= to }
    }

    /// The ring's samples in `(now - window, now]` merged with stored ones in the same span, one per
    /// whole second (the ring wins a tie), sorted by time. For the median fallback.
    static func mergeRecent(ring: [WakeSample], stored: [WakeSample], now: Date,
                            window: TimeInterval) -> [WakeSample] {
        let from = now.addingTimeInterval(-window)
        var bySecond: [Int: WakeSample] = [:]
        for s in stored where s.ts > from && s.ts <= now { bySecond[Int(s.ts.timeIntervalSince1970)] = s }
        for s in ring where s.ts > from && s.ts <= now { bySecond[Int(s.ts.timeIntervalSince1970)] = s }
        return bySecond.values.sorted { $0.ts < $1.ts }
    }
}
