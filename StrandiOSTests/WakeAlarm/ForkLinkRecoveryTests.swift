// Fork-only (phone-hub, link): tests for the pure rules behind the bond-loop pause fixes and the wake
// alarm's link request. Synthetic values.
import XCTest

final class ForkLinkRecoveryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: A. clearing the pause after a healthy bond

    func testPauseClearsOnlyOnTheSameBondedConnectionStillUp() {
        XCTAssertTrue(ForkLinkRecovery.shouldClearPause(paused: true, connected: true, sameConnection: true, bonded: true))
        XCTAssertFalse(ForkLinkRecovery.shouldClearPause(paused: false, connected: true, sameConnection: true, bonded: true),
                       "nothing to clear")
        XCTAssertFalse(ForkLinkRecovery.shouldClearPause(paused: true, connected: false, sameConnection: true, bonded: true),
                       "a bond-then-drop loop never survives the window")
        XCTAssertFalse(ForkLinkRecovery.shouldClearPause(paused: true, connected: true, sameConnection: false, bonded: true),
                       "a later reconnect cycle can't satisfy an earlier connection's timer")
        XCTAssertFalse(ForkLinkRecovery.shouldClearPause(paused: true, connected: true, sameConnection: true, bonded: false),
                       "a refusing strap that stays connected unbonded keeps the pause")
    }

    func testSurvivalWindowOutlastsTheBondLoopDetectorWindow() {
        XCTAssertEqual(ForkLinkRecovery.pauseClearAfterBond, 20)
        // The #617 detector counts a drop within 8 s of the bond as a loop cycle: the clear must wait longer.
        XCTAssertGreaterThanOrEqual(ForkLinkRecovery.pauseClearAfterBond, 9)
    }

    // MARK: B. our own watchdog bounce always re-parks a connect

    func testAWatchdogBounceBypassesTheFloorOnlyWhenRecent() {
        XCTAssertTrue(ForkLinkRecovery.pausedDisconnectBypassesFloor(watchdogBounceAt: t0, now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(ForkLinkRecovery.pausedDisconnectBypassesFloor(watchdogBounceAt: t0, now: t0.addingTimeInterval(30)))
        XCTAssertFalse(ForkLinkRecovery.pausedDisconnectBypassesFloor(watchdogBounceAt: t0, now: t0.addingTimeInterval(30.5)),
                       "a stale mark never excuses a later, unrelated drop")
        XCTAssertFalse(ForkLinkRecovery.pausedDisconnectBypassesFloor(watchdogBounceAt: nil, now: t0))
        XCTAssertFalse(ForkLinkRecovery.pausedDisconnectBypassesFloor(watchdogBounceAt: t0.addingTimeInterval(5), now: t0),
                       "a mark from the future (clock moved) doesn't count")
    }

    // MARK: C. the wake alarm's link request

    func testWakeLinkRequestGate() {
        typealias R = ForkLinkRecovery.WakeLinkRequest
        func gate(_ c: Bool, _ i: Bool, _ p: Bool, _ target: Bool, allowed: Bool = true) -> R {
            ForkLinkRecovery.wakeLinkRequest(connected: c, intentionalDisconnect: i, poweredOn: p,
                                             hasTargetStrap: target, connectAllowed: allowed)
        }
        XCTAssertEqual(gate(false, false, true, true), .requested)
        XCTAssertEqual(gate(true, false, true, true), .alreadyConnected)
        XCTAssertEqual(gate(false, true, true, true), .userDisconnected, "never undoes a deliberate Disconnect")
        XCTAssertEqual(gate(false, false, false, true), .bluetoothOff)
        XCTAssertEqual(gate(false, false, true, false), .noTargetStrap)
        XCTAssertEqual(gate(false, false, true, true, allowed: false), .otherDeviceActive,
                       "never claims a request the active-device gate would drop")
        XCTAssertEqual(gate(true, true, false, false, allowed: false), .alreadyConnected)
    }

    func testWakeLinkRequestLogLines() {
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.requested.logLine,
                       "Wake: link requested (system connect to the strap; the bond-loop pause is left as is)")
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.userDisconnected.logLine,
                       "Wake: link not requested (disconnected by hand)")
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.bluetoothOff.logLine,
                       "Wake: link not requested (Bluetooth is off)")
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.noTargetStrap.logLine,
                       "Wake: link not requested (no selected or last-connected strap to target)")
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.otherDeviceActive.logLine,
                       "Wake: link not requested (a different device is active)")
        XCTAssertEqual(ForkLinkRecovery.WakeLinkRequest.alreadyConnected.logLine,
                       "Wake: link not requested (already connected, handshake in progress)")
    }
}
