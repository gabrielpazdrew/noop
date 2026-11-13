// fork-only (phone-hub, link). Foundation-only: compiled into both app targets (it sits under Strand/) AND the
// NOOPiOSHubTests bundle (project.yml), so these rules are unit-tested on the fork's CI.
//
// The pure rules behind three small BLEManager changes:
//  A. A WHOOP 4.0's genuine bond never cleared the bond-loop pause (only the 5/MG CLIENT_HELLO ack did), so a
//     pause tripped earlier in the evening outlived hours of healthy link. It now clears once a bonded link has
//     stayed up `pauseClearAfterBond` seconds after its bond. A real bond-then-drop loop drops inside the
//     #617 detector's 8 s window, and a refusing strap never bonds, so neither can clear it.
//  B. Our own no-data watchdog bounce, while paused, used to fall under the 10-minute standing-connect floor
//     (meant for a strap that keeps refusing) and could leave NO reconnect request at all. A paused
//     disconnect that follows our own bounce within `watchdogBounceGrace` re-parks the connect at once.
//  C. The wake alarm's one link request at the start of a run (`BLEManager.wakeRequestLink`).
import Foundation

enum ForkLinkRecovery {
    /// A: seconds a bonded link must survive after its bond before the bond-loop pause clears.
    static let pauseClearAfterBond: TimeInterval = 20
    /// B: how long after our own watchdog cancel a disconnect still counts as that bounce.
    static let watchdogBounceGrace: TimeInterval = 30

    /// A: clear only on the same, still-up, bonded connection, and only while the pause is set.
    static func shouldClearPause(paused: Bool, connected: Bool, sameConnection: Bool, bonded: Bool) -> Bool {
        paused && connected && sameConnection && bonded
    }

    /// B: a paused disconnect right after our own watchdog bounce re-parks the connect without the floor.
    static func pausedDisconnectBypassesFloor(watchdogBounceAt: Date?, now: Date) -> Bool {
        guard let at = watchdogBounceAt else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age <= watchdogBounceGrace
    }

    /// C: what the wake alarm's link request does.
    enum WakeLinkRequest: String, Equatable {
        case requested, alreadyConnected, userDisconnected, bluetoothOff, otherDeviceActive, noTargetStrap

        var logLine: String {
            switch self {
            case .requested:
                return "Wake: link requested (system connect to the strap; the bond-loop pause is left as is)"
            case .alreadyConnected: return "Wake: link not requested (already connected, handshake in progress)"
            case .userDisconnected: return "Wake: link not requested (disconnected by hand)"
            case .bluetoothOff:     return "Wake: link not requested (Bluetooth is off)"
            case .otherDeviceActive: return "Wake: link not requested (a different device is active)"
            case .noTargetStrap:    return "Wake: link not requested (no selected or last-connected strap to target)"
            }
        }
    }

    /// C: request a link only when nothing is connected, the user didn't disconnect on purpose (a connect would
    /// clear that), Bluetooth is on, the active-device gate `connectFromSystem` applies would let it through
    /// (so the log never claims a request that silently didn't happen), and there is a strap to target: the
    /// selected one, or the last-connected one, which `connectCore` targets by identifier off-screen.
    static func wakeLinkRequest(connected: Bool, intentionalDisconnect: Bool, poweredOn: Bool,
                                hasTargetStrap: Bool, connectAllowed: Bool) -> WakeLinkRequest {
        if connected { return .alreadyConnected }
        if intentionalDisconnect { return .userDisconnected }
        if !poweredOn { return .bluetoothOff }
        if !connectAllowed { return .otherDeviceActive }
        if !hasTargetStrap { return .noTargetStrap }
        return .requested
    }
}
