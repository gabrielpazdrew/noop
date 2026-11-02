// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// Tracks when the phone last had a WORKING link to the band, for the "band lost" notice
// (PLAN-BAND-LINK T3). "Connected" alone is not enough: on Oct 31, 2026 the link reconnected and
// dropped in a burst for hours without moving any data. So a connection only counts as good once it
// proves itself — the strap sync time advances during it, or it stays up for `goodAfter` — and a
// connect/drop burst that never proves itself never moves "lost since".
import Foundation

/// The part that survives a relaunch (HubState `hub.link.*`).
struct HubLinkMemory: Equatable {
    /// The last instant the link was known good: updated while good, set to the drop time when a good
    /// link drops, and raised to any strap sync time seen (data landed, so the link worked then).
    /// nil = never seen a good link, so nothing can be "lost".
    var lastGoodLinkAt: Date? = nil
    /// The strap's last-sync time as of the previous observation, to tell when it advances.
    var lastSyncSeen: Date? = nil
}

/// The in-memory part: the current connection. A relaunched app starts "not yet good".
struct HubLinkTracker {
    static let goodAfter: TimeInterval = 120

    private(set) var connectedSince: Date? = nil
    private(set) var goodNow = false

    /// Feed the current link state; returns the memory to persist.
    mutating func observe(connected: Bool, lastSyncedAt: Date?, now: Date, memory: HubLinkMemory) -> HubLinkMemory {
        var m = memory
        let advanced: Bool
        if let s = lastSyncedAt {
            advanced = m.lastSyncSeen.map { s > $0 } ?? false
            // Any sync on record is evidence the link worked at that time (the first one seen is the
            // starting point after an install or a lost memory).
            if m.lastGoodLinkAt.map({ s > $0 }) ?? true { m.lastGoodLinkAt = s }
            m.lastSyncSeen = s
        } else {
            advanced = false
        }

        if connected {
            if connectedSince == nil { connectedSince = now; goodNow = false }
            if advanced { goodNow = true }
            if let since = connectedSince, now.timeIntervalSince(since) >= Self.goodAfter { goodNow = true }
            if goodNow { m.lastGoodLinkAt = max(m.lastGoodLinkAt ?? now, now) }
        } else if connectedSince != nil {
            // A drop. Only a link that had proven itself moves the clock; a burst leaves it alone.
            if goodNow { m.lastGoodLinkAt = max(m.lastGoodLinkAt ?? now, now) }
            connectedSince = nil
            goodNow = false
        }
        return m
    }

    /// When the band was lost: nil while the link is good (or no good link was ever seen).
    func lostSince(memory: HubLinkMemory) -> Date? { goodNow ? nil : memory.lastGoodLinkAt }
}
