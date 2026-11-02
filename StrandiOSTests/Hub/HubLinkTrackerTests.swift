// Fork-only (phone-hub): tests for StrandiOS/Hub/Core/HubLinkTracker.swift — when the band link counts as
// "good", and that a reconnect burst never moves the "lost since" time (PLAN-BAND-LINK T3).
import XCTest

final class HubLinkTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let minute: TimeInterval = 60

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * minute) }

    /// One observation: updates the tracker and the persisted memory in place.
    func observe(_ tracker: inout HubLinkTracker, _ memory: inout HubLinkMemory,
                 connected: Bool, sync: Date?, now: Date) {
        memory = tracker.observe(connected: connected, lastSyncedAt: sync, now: now, memory: memory)
    }

    func testNoGoodLinkEverRecordedMeansNothingIsLost() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory()
        observe(&tracker, &memory, connected: false, sync: nil, now: t0)
        XCTAssertNil(memory.lastGoodLinkAt)
        XCTAssertNil(tracker.lostSince(memory: memory))
        observe(&tracker, &memory, connected: true, sync: nil, now: at(1))
        observe(&tracker, &memory, connected: false, sync: nil, now: at(1.5))
        XCTAssertNil(tracker.lostSince(memory: memory))
    }

    func testSyncOnRecordAtLaunchIsTheStartingPoint() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory()
        let synced = at(-90)
        observe(&tracker, &memory, connected: false, sync: synced, now: t0)
        XCTAssertEqual(memory.lastGoodLinkAt, synced)
        XCTAssertEqual(memory.lastSyncSeen, synced)
        XCTAssertEqual(tracker.lostSince(memory: memory), synced)
    }

    func testSyncAdvanceDuringConnectionMakesTheLinkGood() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory()
        observe(&tracker, &memory, connected: false, sync: at(-60), now: t0)
        observe(&tracker, &memory, connected: true, sync: at(-60), now: at(1))
        XCTAssertEqual(tracker.lostSince(memory: memory), at(-60), "connected but not yet proven")
        observe(&tracker, &memory, connected: true, sync: at(1.5), now: at(1.5))
        XCTAssertTrue(tracker.goodNow)
        XCTAssertNil(tracker.lostSince(memory: memory))
        XCTAssertEqual(memory.lastGoodLinkAt, at(1.5))
        XCTAssertEqual(memory.lastSyncSeen, at(1.5))
    }

    func testConnectionLasting120SecondsMakesTheLinkGood() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory(lastGoodLinkAt: at(-60), lastSyncSeen: nil)
        observe(&tracker, &memory, connected: true, sync: nil, now: t0)
        observe(&tracker, &memory, connected: true, sync: nil, now: t0.addingTimeInterval(119))
        XCTAssertFalse(tracker.goodNow)
        observe(&tracker, &memory, connected: true, sync: nil, now: t0.addingTimeInterval(120))
        XCTAssertTrue(tracker.goodNow)
        XCTAssertEqual(memory.lastGoodLinkAt, t0.addingTimeInterval(120))
        XCTAssertNil(tracker.lostSince(memory: memory))
    }

    func testDropAfterAGoodLinkRecordsTheDropTime() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory(lastGoodLinkAt: at(-60), lastSyncSeen: nil)
        observe(&tracker, &memory, connected: true, sync: nil, now: t0)
        observe(&tracker, &memory, connected: true, sync: nil, now: at(5))
        observe(&tracker, &memory, connected: false, sync: nil, now: at(9))
        XCTAssertFalse(tracker.goodNow)
        XCTAssertEqual(memory.lastGoodLinkAt, at(9))
        XCTAssertEqual(tracker.lostSince(memory: memory), at(9))
    }

    func testReconnectBurstNeverMovesLostSince() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory(lastGoodLinkAt: at(-60), lastSyncSeen: at(-60))
        observe(&tracker, &memory, connected: false, sync: at(-60), now: t0)
        for i in 0..<10 {
            let start = at(Double(i))
            observe(&tracker, &memory, connected: true, sync: at(-60), now: start)
            observe(&tracker, &memory, connected: false, sync: at(-60), now: start.addingTimeInterval(20))
        }
        XCTAssertEqual(memory.lastGoodLinkAt, at(-60))
        XCTAssertEqual(tracker.lostSince(memory: memory), at(-60))
    }

    func testSyncAdvanceWhileDisconnectedIsEvidenceButNotAGoodLinkNow() {
        // A background relaunch can find a newer store sync than the one last seen: the link worked then.
        var tracker = HubLinkTracker(), memory = HubLinkMemory(lastGoodLinkAt: at(-60), lastSyncSeen: at(-60))
        observe(&tracker, &memory, connected: false, sync: at(-10), now: t0)
        XCTAssertFalse(tracker.goodNow)
        XCTAssertEqual(memory.lastGoodLinkAt, at(-10))
        XCTAssertEqual(tracker.lostSince(memory: memory), at(-10))
    }

    func testLastGoodLinkNeverMovesBackwards() {
        var tracker = HubLinkTracker(), memory = HubLinkMemory(lastGoodLinkAt: at(-5), lastSyncSeen: nil)
        observe(&tracker, &memory, connected: false, sync: at(-60), now: t0)
        XCTAssertEqual(memory.lastGoodLinkAt, at(-5))
    }

    func testRelaunchedTrackerStartsNotGoodAndKeepsPersistedTime() {
        var memory = HubLinkMemory(lastGoodLinkAt: at(-40), lastSyncSeen: at(-40))
        var tracker = HubLinkTracker()
        observe(&tracker, &memory, connected: true, sync: at(-40), now: t0)
        XCTAssertEqual(tracker.lostSince(memory: memory), at(-40))
    }
}
