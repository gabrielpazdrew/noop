// Fork-only (phone-hub, wake): tests for the buzz/write-error attribution (at most one failure per buzz).
import XCTest

final class WakeBuzzLedgerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testErrorInsideWindowChargesOnce() {
        var l = WakeBuzzLedger()
        l.sent(at: at(0))
        XCTAssertTrue(l.writeError(at: at(0.5)))
        XCTAssertFalse(l.writeError(at: at(0.6)), "the buzz's second write error is not a second failure")
        XCTAssertEqual(l.expire(now: at(10)), 0, "a charged buzz never also counts as OK")
    }

    func testNoErrorInWindowIsOK() {
        var l = WakeBuzzLedger()
        l.sent(at: at(0))
        XCTAssertEqual(l.expire(now: at(3)), 0, "exactly 3 s is still inside the window")
        XCTAssertEqual(l.expire(now: at(3.1)), 1)
        XCTAssertEqual(l.pending.count, 0)
    }

    func testErrorAfterWindowIgnored() {
        var l = WakeBuzzLedger()
        l.sent(at: at(0))
        XCTAssertFalse(l.writeError(at: at(3.5)))
    }

    func testErrorBeforeAnyBuzzIgnored() {
        var l = WakeBuzzLedger()
        XCTAssertFalse(l.writeError(at: at(0)), "a sync ack error with no buzz pending is not a buzz failure")
        l.sent(at: at(5))
        XCTAssertFalse(l.writeError(at: at(4)), "an error stamped before the buzz is not its failure")
    }

    func testOverlappingBuzzesChargeOldestFirst() {
        var l = WakeBuzzLedger()
        l.sent(at: at(0))
        l.sent(at: at(2))
        XCTAssertTrue(l.writeError(at: at(2.5)))
        XCTAssertEqual(l.pending, [at(2)])
        XCTAssertTrue(l.writeError(at: at(2.6)))
        XCTAssertFalse(l.writeError(at: at(2.7)), "two buzzes, at most two failures")
    }

    func testFailuresNeverExceedBuzzes() {
        var l = WakeBuzzLedger()
        var charged = 0
        for i in 0..<5 {
            l.sent(at: at(Double(i * 2)))
            for k in 0..<4 where l.writeError(at: at(Double(i * 2) + 0.1 * Double(k + 1))) { charged += 1 }
        }
        XCTAssertEqual(charged, 5)
    }

    func testClockBackExpiresNothing() {
        var l = WakeBuzzLedger()
        l.sent(at: at(100))
        XCTAssertEqual(l.expire(now: at(0)), 0)
        XCTAssertEqual(l.pending.count, 1)
    }
}
