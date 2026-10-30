// Fork-only (phone-hub): tests for StrandiOS/Hub/Core/HubNoticePlanner.swift — which local
// notification fires when, and that re-planning never stacks duplicates.
import XCTest

/// Behaves like UNUserNotificationCenter for our purposes, but WORSE: `add` appends instead of
/// replacing a pending request with the same id. So any duplicate the applier lets through shows up.
final class FakeNoticeCenter: HubNoticeCenter {
    struct Pending: Equatable { let id: String; let title: String; let fireAt: Date }
    var pending: [Pending] = []
    var now: Date

    init(now: Date) { self.now = now }

    func removeNotices(ids: [String]) { pending.removeAll { ids.contains($0.id) } }
    func addNotice(id: String, title: String, body: String, after seconds: TimeInterval) {
        pending.append(Pending(id: id, title: title, fireAt: now.addingTimeInterval(seconds)))
    }
    func count(_ kind: HubNoticeKind) -> Int { pending.filter { $0.id == kind.identifier }.count }
    func fireAt(_ kind: HubNoticeKind) -> Date? { pending.first { $0.id == kind.identifier }?.fireAt }
}

final class HubNoticePlannerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86_400

    func inputs(now: Date, enabled: Bool = true, server: Date? = nil, embedded: Date? = nil,
                failingSince: Date? = nil, locked: Bool = false, tripwire: Bool = false) -> HubNoticeInputs {
        HubNoticeInputs(now: now, enabled: enabled, serverRenewalEstimate: server,
                        embeddedExpiry: embedded, failingSince: failingSince,
                        locked: locked, tripwire: tripwire)
    }

    /// Plan + apply one step, like HubNotifications.refresh does on the phone.
    @discardableResult
    func step(_ i: HubNoticeInputs, _ memory: inout HubNoticeMemory, _ center: FakeNoticeCenter) -> [HubNoticeAction] {
        center.now = i.now
        let (actions, next) = HubNoticePlanner.plan(i, memory: memory)
        HubNoticeApplier.apply(actions, now: i.now, to: center)
        memory = next
        return actions
    }

    // MARK: estimate

    func testEstimatePicksTheLaterDate() {
        let a = t0, b = t0.addingTimeInterval(2 * day)
        XCTAssertEqual(HubNoticePlanner.renewalEstimate(server: a, embedded: b), b)
        XCTAssertEqual(HubNoticePlanner.renewalEstimate(server: b, embedded: a), b)
        XCTAssertEqual(HubNoticePlanner.renewalEstimate(server: a, embedded: nil), a)
        XCTAssertEqual(HubNoticePlanner.renewalEstimate(server: nil, embedded: b), b)
        XCTAssertNil(HubNoticePlanner.renewalEstimate(server: nil, embedded: nil))
    }

    // MARK: renewal

    func testRenewalScheduledThreeDaysBeforeTheLaterEstimate() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        let server = t0.addingTimeInterval(5 * day), embedded = t0.addingTimeInterval(7 * day)
        step(inputs(now: t0, server: server, embedded: embedded), &memory, center)
        XCTAssertEqual(center.count(.renewal), 1)
        XCTAssertEqual(center.fireAt(.renewal), embedded.addingTimeInterval(-3 * day))
    }

    func testReschedulingNeverDuplicatesAndIdIsStable() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        let est1 = t0.addingTimeInterval(6 * day)
        for k in 0..<5 {
            step(inputs(now: t0.addingTimeInterval(Double(k) * hour), embedded: est1), &memory, center)
        }
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertEqual(center.pending.first?.id, "hub.notice.renewal")
        // A refresh moves the estimate: still exactly one, now at the new date.
        let est2 = t0.addingTimeInterval(13 * day)
        step(inputs(now: t0.addingTimeInterval(6 * hour), server: est2, embedded: est1), &memory, center)
        XCTAssertEqual(center.count(.renewal), 1)
        XCTAssertEqual(center.fireAt(.renewal), est2.addingTimeInterval(-3 * day))
    }

    func testRenewalInsideThreeDaysFiresOnceNotOnEveryUpload() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        let est = t0.addingTimeInterval(2 * day)
        let first = step(inputs(now: t0, embedded: est), &memory, center)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(center.fireAt(.renewal).map { $0 > t0 }, true) // "now", never in the past
        center.pending.removeAll() // delivered
        let second = step(inputs(now: t0.addingTimeInterval(hour), embedded: est), &memory, center)
        XCTAssertFalse(second.contains { if case .schedule = $0 { return true }; return false })
        XCTAssertEqual(center.count(.renewal), 0)
    }

    func testRenewalCancelledWhenNoEstimate() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0, embedded: t0.addingTimeInterval(6 * day)), &memory, center)
        step(inputs(now: t0, embedded: nil), &memory, center)
        XCTAssertEqual(center.count(.renewal), 0)
        XCTAssertNil(memory.renewalArmedFor)
    }

    func testRenewalStillPlannedWhenHubDisabled() {
        // The renewal reminder is about NOOP itself expiring, not the hub.
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0, enabled: false, embedded: t0.addingTimeInterval(6 * day)), &memory, center)
        XCTAssertEqual(center.count(.renewal), 1)
    }

    // MARK: uploads failing

    func testFailureNeverFiresBeforeSixHoursOfFailing() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        let since = t0
        for minutes in [0.0, 10, 60, 180, 359] {
            let now = since.addingTimeInterval(minutes * 60)
            step(inputs(now: now, failingSince: since), &memory, center)
            XCTAssertEqual(center.count(.uploadsFailing), 1)
            XCTAssertEqual(center.fireAt(.uploadsFailing), since.addingTimeInterval(6 * hour))
        }
    }

    func testSuccessInsideSixHoursCancelsTheFailureNotice() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0.addingTimeInterval(hour), failingSince: t0), &memory, center)
        step(inputs(now: t0.addingTimeInterval(5 * hour), failingSince: nil), &memory, center)
        XCTAssertEqual(center.count(.uploadsFailing), 0)
        XCTAssertNil(memory.failureArmedFor)
    }

    func testFailureFiresOnceAfterSixHoursThenStaysQuiet() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        // First failure seen only after the streak is already 7 h old (e.g. memory lost): fires now.
        let a = step(inputs(now: t0.addingTimeInterval(7 * hour), failingSince: t0), &memory, center)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(center.count(.uploadsFailing), 1)
        center.pending.removeAll() // delivered
        let b = step(inputs(now: t0.addingTimeInterval(8 * hour), failingSince: t0), &memory, center)
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(center.count(.uploadsFailing), 0)
    }

    func testNewStreakArmsAgain() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0.addingTimeInterval(7 * hour), failingSince: t0), &memory, center)
        step(inputs(now: t0.addingTimeInterval(8 * hour), failingSince: nil), &memory, center)
        let since2 = t0.addingTimeInterval(9 * hour)
        step(inputs(now: since2, failingSince: since2), &memory, center)
        XCTAssertEqual(center.count(.uploadsFailing), 1)
        XCTAssertEqual(center.fireAt(.uploadsFailing), since2.addingTimeInterval(6 * hour))
    }

    func testDisabledHubCancelsFailureLockedTripwire() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0, failingSince: t0, locked: true, tripwire: true), &memory, center)
        XCTAssertEqual(center.pending.count, 3)
        step(inputs(now: t0, enabled: false, failingSince: t0, locked: true, tripwire: true), &memory, center)
        XCTAssertEqual(center.pending.count, 0)
    }

    // MARK: locked / tripwire

    func testLockedFiresOncePerLockAndRearmsAfterUnlock() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0, locked: true), &memory, center)
        XCTAssertEqual(center.count(.hubLocked), 1)
        center.pending.removeAll()
        step(inputs(now: t0.addingTimeInterval(hour), locked: true), &memory, center)
        XCTAssertEqual(center.count(.hubLocked), 0)
        step(inputs(now: t0.addingTimeInterval(2 * hour), locked: false), &memory, center)
        step(inputs(now: t0.addingTimeInterval(3 * hour), locked: true), &memory, center)
        XCTAssertEqual(center.count(.hubLocked), 1)
    }

    func testTripwireFiresOnce() {
        var memory = HubNoticeMemory(), center = FakeNoticeCenter(now: t0)
        step(inputs(now: t0, tripwire: true), &memory, center)
        XCTAssertEqual(center.count(.tripwire), 1)
        center.pending.removeAll()   // delivered; a re-fire would show up as a new one
        let again = step(inputs(now: t0.addingTimeInterval(60), tripwire: true), &memory, center)
        XCTAssertEqual(center.count(.tripwire), 0)
        XCTAssertEqual(again, [])
        step(inputs(now: t0.addingTimeInterval(120), tripwire: false), &memory, center)
        step(inputs(now: t0.addingTimeInterval(180), tripwire: true), &memory, center)
        XCTAssertEqual(center.count(.tripwire), 1)
    }

    // MARK: permission (T4.3 review finding 1)

    func testNothingIsArmedWhileNotificationsCannotShow() {
        let center = FakeNoticeCenter(now: t0)
        let i = inputs(now: t0, server: t0.addingTimeInterval(day), failingSince: t0.addingTimeInterval(-7 * hour),
                       locked: true, tripwire: true)
        let held = HubNoticeRefresher.refresh(i, memory: HubNoticeMemory(), canNotify: false, center: center)
        XCTAssertEqual(held, HubNoticeMemory())
        XCTAssertEqual(center.pending.count, 0)
        // Permission granted: the same state now delivers every due notice.
        let sent = HubNoticeRefresher.refresh(i, memory: held, canNotify: true, center: center)
        XCTAssertEqual(center.count(.renewal), 1)
        XCTAssertEqual(center.count(.uploadsFailing), 1)
        XCTAssertEqual(center.count(.hubLocked), 1)
        XCTAssertEqual(center.count(.tripwire), 1)
        XCTAssertTrue(sent.lockedAlerted && sent.tripwireAlerted)
    }

    func testIdentifiersAreStableAndDistinct() {
        let ids = HubNoticeKind.allCases.map(\.identifier)
        XCTAssertEqual(ids, ["hub.notice.renewal", "hub.notice.uploadsFailing",
                             "hub.notice.hubLocked", "hub.notice.tripwire"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testNoticeTextCarriesNoNumbersButTheRenewalDate() {
        for kind in HubNoticeKind.allCases where kind != .renewal {
            let n = HubNoticePlanner.notice(kind, fireAt: t0, renewalEstimate: nil)
            XCTAssertNil((n.title + n.body).rangeOfCharacter(from: CharacterSet(charactersIn: "%")))
            XCTAssertFalse(n.title.isEmpty || n.body.isEmpty)
        }
    }
}
