// Fork-only (phone-hub): tests for HubStepsCore (local-day bucketing of phone step counts and the
// permission gate). Synthetic dates and totals only.
import XCTest

final class HubStepsTests: XCTestCase {

    private func cal(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func local(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func assertContiguous(_ ws: [HubStepWindow], file: StaticString = #file, line: UInt = #line) {
        for (a, b) in zip(ws, ws.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "gap or overlap between \(a.date) and \(b.date)", file: file, line: line)
        }
    }

    // MARK: bucketing (pure)

    func testSpringForwardDayIs23Hours() {
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 3, 10, 15)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.map(\.date), ["2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07",
                                        "2026-03-08", "2026-03-09", "2026-03-10"])
        assertContiguous(ws)
        let dst = ws.first { $0.date == "2026-03-08" }!
        XCTAssertEqual(dst.end.timeIntervalSince(dst.start), 23 * 3600)
        XCTAssertEqual(dst.start, local(c, 2026, 3, 8, 0))
        let normal = ws.first { $0.date == "2026-03-09" }!
        XCTAssertEqual(normal.end.timeIntervalSince(normal.start), 24 * 3600)
        XCTAssertEqual(ws.last!.end, now, "today runs up to now")
        XCTAssertEqual(ws.last!.start, local(c, 2026, 3, 10, 0))
    }

    func testFallBackDayIs25Hours() {
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 11, 3, 10)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.count, 7)
        XCTAssertEqual(ws.first!.date, "2026-10-28")
        assertContiguous(ws)
        let dst = ws.first { $0.date == "2026-11-01" }!
        XCTAssertEqual(dst.end.timeIntervalSince(dst.start), 25 * 3600)
        XCTAssertEqual(dst.end, local(c, 2026, 11, 2, 0))
    }

    func testDayOlderThanPedometerHistoryIsLeftOut() {
        // Late on the 7th day after a 25 h day, that day's midnight is more than 7×24 h back:
        // CoreMotion would return it short, so it must not be sent.
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 11, 7, 23, 30)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.map(\.date), ["2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05",
                                        "2026-11-06", "2026-11-07"])
        for w in ws { XCTAssertLessThanOrEqual(now.timeIntervalSince(w.start), HubStepsCore.historyLimit) }
        // Same clock time a week without DST keeps all 7 days.
        let plain = HubStepsCore.windows(now: local(c, 2026, 10, 24, 23, 30), calendar: c)
        XCTAssertEqual(plain.count, 7)
    }

    func testDayWhoseMidnightIsSkippedByDST() {
        // São Paulo, 2018-11-04: clocks jumped 00:00 → 01:00, so that day starts at 1:00 am.
        let c = cal("America/Sao_Paulo")
        let now = local(c, 2018, 11, 6, 12)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.count, 7)
        assertContiguous(ws)
        let dst = ws.first { $0.date == "2018-11-04" }!
        XCTAssertEqual(dst.end.timeIntervalSince(dst.start), 23 * 3600)
        XCTAssertEqual(ws.filter { $0.date == "2018-11-03" }.count, 1)
    }

    func testLabelsAreLocalDatesNotUTC() {
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 10, 29, 23, 30)   // 6:30 am Oct 30 in UTC
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.last!.date, "2026-10-29")
        XCTAssertEqual(ws.first!.date, "2026-10-23")
    }

    func testJustAfterMidnightTodayStillListed() {
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 10, 29, 0, 1)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        XCTAssertEqual(ws.count, 7)
        XCTAssertEqual(ws.last!.date, "2026-10-29")
        XCTAssertEqual(ws.last!.end.timeIntervalSince(ws.last!.start), 60)
    }

    // MARK: permission gate

    private final class FakePedometer: HubPedometerSource {
        var isStepCountingAvailable = true
        var authorization = HubStepsAuthorization.authorized
        var answers: [String: HubPedometerTotals] = [:]   // keyed by window start, epoch seconds
        var queries: [(Date, Date)] = []
        func query(from start: Date, to end: Date, completion: @escaping (HubPedometerTotals?) -> Void) {
            queries.append((start, end))
            completion(answers[String(Int(start.timeIntervalSince1970))])
        }
    }

    private func readSync(_ p: FakePedometer, now: Date, calendar: Calendar) -> HubStepsSnapshot? {
        var out: HubStepsSnapshot?
        HubStepsCore.read(source: p, now: now, calendar: calendar) { out = $0 }
        return out
    }

    func testDeniedPermissionSendsNothingAndReportsDenied() {
        let c = cal("America/Los_Angeles")
        for auth in [HubStepsAuthorization.denied, .restricted] {
            let p = FakePedometer()
            p.authorization = auth
            let snap = readSync(p, now: local(c, 2026, 10, 29, 12), calendar: c)
            XCTAssertEqual(snap?.status, .denied)
            XCTAssertEqual(snap?.status.rawValue, "denied")
            XCTAssertEqual(snap?.days, [])
            XCTAssertEqual(p.queries.count, 0, "a denied read must not touch the pedometer")
        }
    }

    func testNotDeterminedNeverQueriesSoNeverPrompts() {
        let c = cal("America/Los_Angeles")
        let p = FakePedometer()
        p.authorization = .notDetermined
        let snap = readSync(p, now: local(c, 2026, 10, 29, 12), calendar: c)
        XCTAssertEqual(snap?.status.rawValue, "not_determined")
        XCTAssertEqual(snap?.days, [])
        XCTAssertEqual(p.queries.count, 0)
    }

    func testUnavailablePedometerReportsUnavailable() {
        let c = cal("America/Los_Angeles")
        let p = FakePedometer()
        p.isStepCountingAvailable = false
        let snap = readSync(p, now: local(c, 2026, 10, 29, 12), calendar: c)
        XCTAssertEqual(snap?.status.rawValue, "unavailable")
        XCTAssertEqual(snap?.days, [])
        XCTAssertEqual(p.queries.count, 0)
    }

    func testAuthorizedReadsEachLocalDayAndDropsFailedDays() {
        let c = cal("America/Los_Angeles")
        let now = local(c, 2026, 11, 3, 10)
        let ws = HubStepsCore.windows(now: now, calendar: c)
        let p = FakePedometer()
        for (i, w) in ws.enumerated() where w.date != "2026-10-30" {
            p.answers[String(Int(w.start.timeIntervalSince1970))] =
                HubPedometerTotals(steps: 1000 * (i + 1), distanceM: i == 0 ? nil : 700.5 * Double(i),
                                   floorsAscended: i == 0 ? nil : i)
        }
        let snap = readSync(p, now: now, calendar: c)!
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.timeZone, "America/Los_Angeles")
        XCTAssertEqual(p.queries.count, 7)
        XCTAssertEqual(p.queries.map { $0.0 }, ws.map(\.start))
        XCTAssertEqual(p.queries.map { $0.1 }, ws.map(\.end))
        XCTAssertEqual(snap.days.map(\.date), ["2026-10-28", "2026-10-29", "2026-10-31",
                                               "2026-11-01", "2026-11-02", "2026-11-03"])
        XCTAssertEqual(snap.days[0], HubStepDay(date: "2026-10-28", steps: 1000, distanceM: nil, floorsAscended: nil))
        XCTAssertEqual(snap.days[1].distanceM, 700.5)
        XCTAssertEqual(snap.days[1].floorsAscended, 1)
    }

    func testEveryQueryFailingIsAnErrorWithNoRows() {
        let c = cal("America/Los_Angeles")
        let p = FakePedometer()   // no answers → every query fails
        let snap = readSync(p, now: local(c, 2026, 10, 29, 12), calendar: c)
        XCTAssertEqual(snap?.status.rawValue, "error")
        XCTAssertEqual(snap?.days, [])
    }

    func testStatusWireValues() {
        XCTAssertEqual([HubStepsStatus.ok, .denied, .unavailable, .notDetermined, .error].map(\.rawValue),
                       ["ok", "denied", "unavailable", "not_determined", "error"])
    }
}
