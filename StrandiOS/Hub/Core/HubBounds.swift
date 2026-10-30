// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// The server's value bounds, mirrored so one impossible value can never make the hub refuse (422) a whole
// request, and the attribution of a 422 the server still returns to the one thing it names.
//
// SOURCE OF TRUTH: hub/src/validate.ts at Health Analysis commit 5c29993 (DEVICE_SPEC, DAILY_SPEC,
// SLEEP_SPEC, HR_SPEC, EVENT_SPEC, BATTERY_SPEC, STEPS_SPEC, EPOCH_MIN/MAX, AHEAD_S, EXPIRY_AHEAD_S,
// maxDay, PRINTABLE). Keep this table in step with it; a drift only costs a quarantined row, never a wedge.
import Foundation

enum HubBounds {
    static let epochMin = 1_500_000_000
    static let epochMax = 4_000_000_000
    static let aheadS = 86_400
    static let expiryAheadS = 730 * 86_400

    // Optional (nullable) numbers: an out-of-range value is sent as null.
    static let bandBattery = 0.0...100.0
    static let recovery = 0.0...100.0, strain = 0.0...100.0
    static let restingHr = 20...250
    static let hrv = 0.0...500.0                       // avg_hrv, avg_sdnn
    static let respRate = 0.0...60.0
    static let skinTempDev = -10.0...10.0
    static let sleepMin = 0.0...1440.0                 // total_sleep_min, total_min
    static let efficiency = 0.0...1.0
    static let disturbances = 0...1000, exerciseCount = 0...100
    static let dailySteps = 0...200_000
    static let activeKcal = 0.0...20_000.0
    static let soc = 0.0...100.0
    static let mv = 0...10_000
    static let phoneSteps = 0...1_000_000
    static let distanceM = 0.0...1_000_000.0
    static let flights = 0...10_000
    // Required numbers: a row with one outside is dropped.
    static let hrValue = 0...255                       // hr_minute.mean/min/max
    static let hrN = 1...1000
    static let maxSleepSpan = 2 * 86_400               // sleep end_ts - start_ts

    static func epochOK(_ t: Int, now: Int, ahead: Int = aheadS) -> Bool { t >= epochMin && t <= epochMax && t <= now + ahead }

    /// The latest local day the server accepts: the UTC date of now + 1 day; days are 2000–2100.
    static func dayOK(_ day: String, now: Int) -> Bool {
        let parts = day.split(separator: "-")
        guard day.count == 10, parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (2000...2100).contains(y), (1...12).contains(m), d >= 1 else { return false }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let first = cal.date(from: DateComponents(year: y, month: m, day: 1)),
              let dim = cal.range(of: .day, in: .month, for: first)?.count, d <= dim else { return false }
        return day <= utcDay(now + aheadS)
    }

    static func utcDay(_ ts: Int) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// `^[\x20-\x7e]{1,32}$`
    static func printable(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.count <= 32 && s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e }
    }

    private static func keep<T: Comparable>(_ v: T?, _ r: ClosedRange<T>) -> T? { v.flatMap { r.contains($0) ? $0 : nil } }
    private static func keepD(_ v: Double?, _ r: ClosedRange<Double>) -> Double? { v.flatMap { $0.isFinite && r.contains($0) ? $0 : nil } }

    /// A dropped row: its table, its natural key, and the hash of its content (quarantined by the engine).
    struct Dropped: Equatable { var table: HubTable; var key: String; var hash: String }

    /// Nulls every impossible optional value and drops every row with an impossible required value.
    static func sanitize(_ p: HubPayload, now: Int) -> (HubPayload, [Dropped]) {
        var out = p
        var dropped: [Dropped] = []
        func clean(_ s: String) -> String {
            let t = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7e }).prefix(32))
            return t.isEmpty ? "unknown" : t
        }
        out.device.appVersion = clean(p.device.appVersion)
        out.device.build = clean(p.device.build)
        out.device.bandFw = p.device.bandFw.flatMap { printable($0) ? $0 : nil }
        out.device.bandBattery = keepD(p.device.bandBattery, bandBattery)
        out.device.embeddedExpiry = p.device.embeddedExpiry.flatMap { epochOK($0, now: now, ahead: expiryAheadS) ? $0 : nil }

        out.daily = p.daily.compactMap { r in
            guard dayOK(r.day, now: now) else {
                dropped.append(Dropped(table: .daily, key: r.day, hash: HubWire.rowHash(HubWire.daily(r)))); return nil
            }
            var c = r
            c.recovery = keepD(r.recovery, recovery); c.strain = keepD(r.strain, strain)
            c.restingHr = keep(r.restingHr, restingHr)
            c.avgHrv = keepD(r.avgHrv, hrv); c.avgSdnn = keepD(r.avgSdnn, hrv)
            c.respRateBpm = keepD(r.respRateBpm, respRate); c.skinTempDevC = keepD(r.skinTempDevC, skinTempDev)
            c.totalSleepMin = keepD(r.totalSleepMin, sleepMin); c.efficiency = keepD(r.efficiency, efficiency)
            c.disturbances = keep(r.disturbances, disturbances); c.exerciseCount = keep(r.exerciseCount, exerciseCount)
            c.steps = keep(r.steps, dailySteps); c.activeKcalEst = keepD(r.activeKcalEst, activeKcal)
            return c
        }
        out.sleep = p.sleep.compactMap { r in
            guard epochOK(r.startTs, now: now), epochOK(r.endTs, now: now), r.endTs >= r.startTs,
                  r.endTs - r.startTs <= maxSleepSpan, dayOK(r.localDay, now: now) else {
                dropped.append(Dropped(table: .sleep, key: String(r.startTs), hash: HubWire.rowHash(HubWire.sleep(r)))); return nil
            }
            var c = r
            c.totalMin = keepD(r.totalMin, sleepMin); c.efficiency = keepD(r.efficiency, efficiency)
            c.restingHr = keep(r.restingHr, restingHr); c.avgHrv = keepD(r.avgHrv, hrv)
            c.startTsAdjusted = r.startTsAdjusted.flatMap { epochOK($0, now: now) ? $0 : nil }
            return c
        }
        out.hrMinute = p.hrMinute.filter { r in
            let ok = epochOK(r.t, now: now) && r.t % 60 == 0 && hrValue.contains(r.min) && hrValue.contains(r.max)
                && r.mean.isFinite && r.mean >= 0 && r.mean <= 255 && hrN.contains(r.n)
                && Double(r.min) <= r.mean && r.mean <= Double(r.max)
            if !ok { dropped.append(Dropped(table: .hr_minute, key: String(r.t), hash: HubWire.rowHash(HubWire.hr(r)))) }
            return ok
        }
        out.events = p.events.filter { r in
            let ok = epochOK(r.t, now: now) && HubBatchBuilder.eventWhitelist.contains(r.kind)
            if !ok { dropped.append(Dropped(table: .events, key: "\(r.t)|\(r.kind)", hash: HubWire.rowHash(HubWire.event(r)))) }
            return ok
        }
        out.battery = p.battery.compactMap { r in
            guard epochOK(r.t, now: now) else {
                dropped.append(Dropped(table: .battery, key: String(r.t), hash: HubWire.rowHash(HubWire.battery(r)))); return nil
            }
            var c = r
            c.soc = keepD(r.soc, soc); c.mv = keep(r.mv, mv)
            c.charging = r.charging.flatMap { $0 == 0 || $0 == 1 ? $0 : nil }
            return c
        }
        out.steps = p.steps.compactMap { r in
            guard dayOK(r.day, now: now) else {
                dropped.append(Dropped(table: .steps, key: r.day, hash: HubWire.rowHash(HubWire.step(r)))); return nil
            }
            var c = r
            c.steps = keep(r.steps, phoneSteps); c.distanceM = keepD(r.distanceM, distanceM); c.flights = keep(r.flights, flights)
            return c
        }
        return (out, dropped)
    }

    /// Natural key of a row, as quarantine keys use it.
    static func key(_ t: HubTable, _ p: HubPayload, _ i: Int) -> (key: String, hash: String)? {
        switch t {
        case .daily: return p.daily.indices.contains(i) ? (p.daily[i].day, HubWire.rowHash(HubWire.daily(p.daily[i]))) : nil
        case .sleep: return p.sleep.indices.contains(i) ? (String(p.sleep[i].startTs), HubWire.rowHash(HubWire.sleep(p.sleep[i]))) : nil
        case .hr_minute: return p.hrMinute.indices.contains(i) ? (String(p.hrMinute[i].t), HubWire.rowHash(HubWire.hr(p.hrMinute[i]))) : nil
        case .events: return p.events.indices.contains(i)
            ? ("\(p.events[i].t)|\(p.events[i].kind)", HubWire.rowHash(HubWire.event(p.events[i]))) : nil
        case .battery: return p.battery.indices.contains(i) ? (String(p.battery[i].t), HubWire.rowHash(HubWire.battery(p.battery[i]))) : nil
        case .steps: return p.steps.indices.contains(i) ? (p.steps[i].day, HubWire.rowHash(HubWire.step(p.steps[i]))) : nil
        }
    }
}

/// What a 422's `error.field` (a schema path, never a value) points at.
enum HubRejectTarget: Equatable {
    case window
    case row(HubTable, Int)
    /// `$`, `$.schema`, `$.device…`, an unknown table, or a path that doesn't parse: nothing to skip.
    case unattributable

    /// Accepts only `^\$(\.[a-z_]+|\[\d{1,4}\])*$`.
    static func isSchemaPath(_ s: String) -> Bool {
        var cs = Array(s.unicodeScalars)
        guard cs.first == "$" else { return false }
        cs.removeFirst()
        var i = 0
        while i < cs.count {
            if cs[i] == "." {
                var j = i + 1
                while j < cs.count, (cs[j] >= "a" && cs[j] <= "z") || cs[j] == "_" { j += 1 }
                if j == i + 1 { return false }
                i = j
            } else if cs[i] == "[" {
                var j = i + 1
                while j < cs.count, cs[j] >= "0" && cs[j] <= "9" { j += 1 }
                if j == i + 1 || j - i - 1 > 4 || j >= cs.count || cs[j] != "]" { return false }
                i = j + 1
            } else { return false }
        }
        return true
    }

    static func parse(_ field: String) -> HubRejectTarget {
        guard isSchemaPath(field) else { return .unattributable }
        if field == "$.sleep_window" || field.hasPrefix("$.sleep_window.") { return .window }
        guard field.hasPrefix("$."), let open = field.firstIndex(of: "["), let close = field.firstIndex(of: "]"), open < close else {
            return .unattributable
        }
        let name = String(field[field.index(field.startIndex, offsetBy: 2)..<open])
        guard let table = HubTable(rawValue: name), let idx = Int(field[field.index(after: open)..<close]) else {
            return .unattributable
        }
        return .row(table, idx)
    }
}
