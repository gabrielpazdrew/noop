// Fork-only (phone-hub, wake): tests for the wake runner's in-memory HR ring. Synthetic samples only.
import XCTest

final class WakeSampleRingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testKeepsOnlyTheWindow() {
        var r = WakeSampleRing()
        r.append(WakeSample(ts: at(0), bpm: 60))
        r.append(WakeSample(ts: at(600), bpm: 61))
        r.append(WakeSample(ts: at(1200), bpm: 62))
        XCTAssertEqual(r.samples.count, 3, "exactly 1200 s old is kept")
        r.append(WakeSample(ts: at(1201), bpm: 63))
        XCTAssertEqual(r.samples.map(\.bpm), [61, 62, 63])
    }

    func testCountCeiling() {
        var r = WakeSampleRing()
        r.maxCount = 5
        for i in 0..<8 { r.append(WakeSample(ts: at(Double(i)), bpm: 60 + i)) }
        XCTAssertEqual(r.samples.map(\.bpm), [63, 64, 65, 66, 67])
    }

    func testClockJumpForwardDropsOldSamples() {
        var r = WakeSampleRing()
        r.append(WakeSample(ts: at(0), bpm: 60))
        r.append(WakeSample(ts: at(86_400), bpm: 70))
        XCTAssertEqual(r.samples.map(\.bpm), [70])
    }

    func testSamplesAfterThrough() {
        var r = WakeSampleRing()
        for i in 0..<5 { r.append(WakeSample(ts: at(Double(i * 10)), bpm: 60 + i)) }
        XCTAssertEqual(r.samples(after: at(10), through: at(30)).map(\.bpm), [62, 63])
    }

    func testMergeRecentDedupsBySecondRingWins() {
        let ring = [WakeSample(ts: at(100.4), bpm: 80), WakeSample(ts: at(101), bpm: 81)]
        let stored = [WakeSample(ts: at(100), bpm: 50), WakeSample(ts: at(99), bpm: 52),
                      WakeSample(ts: at(-2000), bpm: 40), WakeSample(ts: at(500), bpm: 41)]
        let m = WakeSampleRing.mergeRecent(ring: ring, stored: stored, now: at(200), window: 1200)
        XCTAssertEqual(m.map(\.bpm), [52, 80, 81], "out-of-window and future samples dropped, ring wins the tie")
    }

    func testMergeRecentEmpty() {
        XCTAssertEqual(WakeSampleRing.mergeRecent(ring: [], stored: [], now: at(0), window: 1200).count, 0)
    }
}
