// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// When to hold the band streams (HR, events, battery). NOOP persists live rows at "now" while a history
// offload is still landing older rows; sending the streams then would move their watermarks past history
// that hasn't arrived. NOOP's own "pending sync" signal is `backfilling || historyPendingSync`
// (PendingSyncDiagnostic). A 120 s quiet window after `backfilling` turns off covers the gap between two
// passes of a segmented offload for foreground and "Upload now" runs (the backfill trigger fires after the
// last pass, so it is exempt). A continuous hold is capped at 2 h so a latched flag can never silently stop
// uploads: after that the streams go anyway (the 48 h late scan is the net) and the hold stays visible.
import Foundation

struct HubHoldDecision: Equatable {
    var hold: Bool
    /// The hold's start (kept after the cap, for the status line); nil = not holding.
    var holdingSince: Int?
    var capped: Bool
}

enum HubHoldPolicy {
    static let quietWindow = 120
    static let cap = 2 * 3_600

    static func decide(trigger: HubTrigger, now: Int, backfilling: Bool, historyPendingSync: Bool,
                       lastBackfillingEndedAt: Int?, holdingSince: Int?) -> HubHoldDecision {
        let quiet = trigger != .backfill && lastBackfillingEndedAt.map { now - $0 < quietWindow } == true
        guard backfilling || historyPendingSync || quiet else {
            return HubHoldDecision(hold: false, holdingSince: nil, capped: false)
        }
        let since = holdingSince ?? now
        if now - since >= cap { return HubHoldDecision(hold: false, holdingSince: since, capped: true) }
        return HubHoldDecision(hold: true, holdingSince: since, capped: false)
    }
}
