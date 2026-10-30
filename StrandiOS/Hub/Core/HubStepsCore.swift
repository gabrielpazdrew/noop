// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
// The pure half of the hub's phone step counts; the CoreMotion adapter is StrandiOS/Hub/HubSteps.swift.
import Foundation

/// Why there are (or aren't) step rows in a snapshot. T4.1 puts `rawValue` into the payload's
/// `device.steps_status`.
enum HubStepsStatus: String, Equatable {
    /// Motion access granted and at least one day was read.
    case ok
    /// The user denied Motion & Fitness, or it is restricted (Screen Time / MDM).
    case denied
    /// This device can't count steps.
    case unavailable
    /// Never asked yet. The reader does NOT ask (a query would raise the prompt at a surprising time);
    /// the prompt comes only from turning the hub on (`HubSteps.requestAuthorizationIfNeeded`).
    case notDetermined = "not_determined"
    /// Access granted but every day's query failed.
    case error
}

/// CoreMotion's authorization, mirrored so the logic stays Foundation-only.
enum HubStepsAuthorization: Equatable { case notDetermined, denied, restricted, authorized }

/// One local calendar day of phone totals. `date` is `YYYY-MM-DD` in the device's time zone (R3).
/// `distanceM` / `floorsAscended` are nil when the device doesn't report them — never a made-up zero.
struct HubStepDay: Equatable {
    let date: String
    let steps: Int
    let distanceM: Double?
    let floorsAscended: Int?
}

/// What T4.1's batch builder maps from: `status` → `device.steps_status`, `days` → the step rows.
/// Invariant: `days` is empty unless `status == .ok`.
struct HubStepsSnapshot: Equatable {
    let status: HubStepsStatus
    let days: [HubStepDay]
    /// IANA zone the day labels were cut in (same value as `device.tz`).
    let timeZone: String
}

/// One pedometer query's totals.
struct HubPedometerTotals: Equatable {
    let steps: Int
    let distanceM: Double?
    let floorsAscended: Int?
}

/// One local day's query window: `[start, end)`, with `end` = now for today.
struct HubStepWindow: Equatable {
    let date: String
    let start: Date
    let end: Date
}

/// The pedometer as the reader sees it (CMPedometer in the app, a fake in tests).
protocol HubPedometerSource {
    var isStepCountingAvailable: Bool { get }
    var authorization: HubStepsAuthorization { get }
    /// nil = the query failed. May call back on any thread.
    func query(from start: Date, to end: Date, completion: @escaping (HubPedometerTotals?) -> Void)
}

enum HubStepsCore {
    /// Days per snapshot: today plus the 6 before it.
    static let dayCount = 7
    /// CoreMotion keeps about 7 days of history. A day that starts further back than this would come
    /// back short and overwrite a good server value, so it is left out.
    static let historyLimit: TimeInterval = 7 * 24 * 3600

    /// The windows for the last `dayCount` local days, oldest first, cut at LOCAL midnight in
    /// `calendar`'s time zone (Gregorian whatever the device calendar). Day lengths follow the calendar, so DST days are 23 h or 25 h.
    static func windows(now: Date, calendar deviceCalendar: Calendar) -> [HubStepWindow] {
        let calendar = gregorian(in: deviceCalendar.timeZone)
        var out: [HubStepWindow] = []
        var dayStart = calendar.startOfDay(for: now)
        var dayEnd = now
        for _ in 0..<dayCount {
            if now.timeIntervalSince(dayStart) > historyLimit { break }
            if dayStart < dayEnd {
                out.append(HubStepWindow(date: label(dayStart, calendar: calendar), start: dayStart, end: dayEnd))
            }
            // Noon of the previous day, then its midnight: safe even where midnight is skipped by DST.
            guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart),
                  let prevNoon = calendar.date(byAdding: .day, value: -1, to: noon) else { break }
            dayEnd = dayStart
            dayStart = calendar.startOfDay(for: prevNoon)
        }
        return out.reversed()
    }

    /// The Gregorian calendar in `timeZone`. Day labels must be Gregorian `YYYY-MM-DD` (R3) even when the
    /// phone is set to a Buddhist, Japanese or other calendar (which would give e.g. `2569-10-29`).
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Gregorian `YYYY-MM-DD` of `date` in `calendar`'s time zone (only the time zone is used).
    static func label(_ date: Date, calendar: Calendar) -> String {
        let c = gregorian(in: calendar.timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The status that stops the read before any query, or nil when the pedometer may be queried.
    static func blockingStatus(available: Bool, authorization: HubStepsAuthorization) -> HubStepsStatus? {
        guard available else { return .unavailable }
        switch authorization {
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        case .authorized: return nil
        }
    }

    /// Pairs each window with its query result. A failed day is left out (no fabricated zero);
    /// if every day failed the status is `.error` and there are no rows.
    static func assemble(windows: [HubStepWindow], results: [HubPedometerTotals?], timeZone: String) -> HubStepsSnapshot {
        let days: [HubStepDay] = zip(windows, results).compactMap { w, r in
            guard let r else { return nil }
            return HubStepDay(date: w.date, steps: max(0, r.steps),
                              distanceM: r.distanceM.map { max(0, $0) },
                              floorsAscended: r.floorsAscended.map { max(0, $0) })
        }
        if days.isEmpty && !windows.isEmpty { return HubStepsSnapshot(status: .error, days: [], timeZone: timeZone) }
        return HubStepsSnapshot(status: .ok, days: days, timeZone: timeZone)
    }

    /// How long `read` waits for CoreMotion before returning what it has. Whether CoreMotion answers
    /// promptly on a locked phone or in a Bluetooth-wake window is unproven (G5), and a missing answer
    /// must never stall the whole upload.
    static let defaultDeadline: TimeInterval = 5

    /// Runs a closure after a delay. Injected so tests can fire the deadline by hand.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    static let dispatchAfter: Scheduler = { delay, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Reads the snapshot. Never queries (so never prompts) unless access is already authorized.
    /// `completion` runs exactly once: when every day has answered, or at `deadline`, whichever is first.
    /// At the deadline the days that haven't answered are left out (never zero-filled); if none answered
    /// the status is `.error`. Answers arriving after completion are ignored. `completion` runs on
    /// whichever thread delivered the last answer or the timer (synchronously when the source answers
    /// synchronously or the read is blocked).
    static func read(source: HubPedometerSource, now: Date, calendar: Calendar,
                     deadline: TimeInterval = defaultDeadline, schedule: Scheduler = dispatchAfter,
                     completion: @escaping (HubStepsSnapshot) -> Void) {
        let tz = calendar.timeZone.identifier
        if let blocked = blockingStatus(available: source.isStepCountingAvailable, authorization: source.authorization) {
            completion(HubStepsSnapshot(status: blocked, days: [], timeZone: tz))
            return
        }
        let ws = windows(now: now, calendar: calendar)
        guard !ws.isEmpty else { completion(assemble(windows: [], results: [], timeZone: tz)); return }
        let lock = NSLock()
        var results = [HubPedometerTotals?](repeating: nil, count: ws.count)
        var remaining = ws.count
        var finished = false
        /// Under the lock: marks the read finished and returns a copy of the results, or nil if it
        /// already finished. The snapshot is built from that copy, so nothing touches it afterwards.
        func finishLocked() -> [HubPedometerTotals?]? {
            if finished { return nil }
            finished = true
            return results
        }
        for (i, w) in ws.enumerated() {
            source.query(from: w.start, to: w.end) { totals in
                lock.lock()
                var copy: [HubPedometerTotals?]?
                if !finished {
                    results[i] = totals
                    remaining -= 1
                    if remaining == 0 { copy = finishLocked() }
                }
                lock.unlock()
                if let copy { completion(assemble(windows: ws, results: copy, timeZone: tz)) }
            }
        }
        lock.lock()
        let alreadyDone = finished
        lock.unlock()
        guard !alreadyDone else { return }
        schedule(deadline) {
            lock.lock()
            let copy = finishLocked()
            lock.unlock()
            if let copy { completion(assemble(windows: ws, results: copy, timeZone: tz)) }
        }
    }
}
