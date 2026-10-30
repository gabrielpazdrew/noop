// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// When to hold the band streams (HR, events, battery). NOOP persists live rows at "now" while a history
// offload is still landing older rows; sending the streams then would move their watermarks past history
// that hasn't arrived. NOOP's own "pending sync" signal is `backfilling || historyPendingSync`
// (PendingSyncDiagnostic). A 120 s quiet window after `backfilling` turns off covers the gap between two
// passes of a segmented offload for foreground and "Upload now" runs (the backfill trigger fires after the
// last pass, so it is exempt).
//
// The 2-hour cap exists because `historyPendingSync` has known latch traps; a hold must never silently stop
// uploads. So:
// - a hold "continues" only while runs keep seeing it at most 10 minutes apart; a longer gap (an offload
//   that ended by timeout or disconnect with no run to see it) starts a NEW hold, cap clock reset;
// - the cap applies to pending-sync / quiet holds, measured from the first run that saw the pending flag,
//   restarted when the flag was seen false since (by a run, or by the adapter's `historyPendingSync` sink);
//   gaps alone don't reset it, so a latched flag on sparse runs still reaches the cap;
// - a running offload (`backfilling`) is never capped: NOOP clears that flag on every exit and disconnect.
import Foundation

struct HubHoldMemory: Equatable {
    /// Start of the current hold (shown in Settings; kept after the cap). nil = not holding.
    var holdingSince: Int? = nil
    /// When a run last saw a hold.
    var lastSeen: Int? = nil
    /// When a run first saw `historyPendingSync` with no run since seeing it false.
    var pendingSince: Int? = nil
}

struct HubHoldDecision: Equatable {
    var hold: Bool
    var memory: HubHoldMemory
    var capped: Bool
    var holdingSince: Int? { memory.holdingSince }
}

enum HubHoldPolicy {
    static let quietWindow = 120
    static let cap = 2 * 3_600
    static let continuityGap = 10 * 60

    static func decide(trigger: HubTrigger, now: Int, backfilling: Bool, historyPendingSync: Bool,
                       lastBackfillingEndedAt: Int?, lastPendingSyncEndedAt: Int? = nil,
                       memory: HubHoldMemory) -> HubHoldDecision {
        let quiet = trigger != .backfill && lastBackfillingEndedAt.map { now - $0 < quietWindow } == true
        // The pending clock runs from the first sighting of this episode. When the flag was seen turning off
        // (in memory, like backfilling's end) after that sighting, this is a new episode: restart the clock.
        var pendingSince: Int? = nil
        if historyPendingSync {
            if let p = memory.pendingSince, lastPendingSyncEndedAt.map({ $0 < p }) ?? true { pendingSince = p } else { pendingSince = now }
        }
        guard backfilling || historyPendingSync || quiet else {
            return HubHoldDecision(hold: false, memory: HubHoldMemory(), capped: false)
        }
        let continuing = memory.holdingSince != nil && memory.lastSeen.map { now - $0 <= continuityGap } == true
        let since = continuing ? memory.holdingSince! : now
        let mem = HubHoldMemory(holdingSince: since, lastSeen: now, pendingSince: pendingSince)
        if backfilling { return HubHoldDecision(hold: true, memory: mem, capped: false) }
        let capped = now - since >= cap || pendingSince.map { now - $0 >= cap } == true
        return HubHoldDecision(hold: !capped, memory: mem, capped: capped)
    }
}
