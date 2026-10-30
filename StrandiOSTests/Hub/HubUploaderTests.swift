// Fork-only (phone-hub): tests for the uploader's pure core — StrandiOS/Hub/Core/{HubBatchBuilder,
// HubPayload, HubWatermarks, HubClient, HubGzip, HubUploadEngine}.swift — with a fake store and a fake
// network. Everything here is synthetic (2030 dates); no real health data.
import XCTest

// MARK: - fakes

struct FakeReadError: Error {}

final class FakeHubSource: HubDataSource {
    var hr: [HubHRSampleInput] = []
    var ev: [HubEventInput] = []
    var bat: [HubBatteryInput] = []
    var daily: [HubDailyInput] = []
    var sleep: [HubSleepInput] = []
    var steps: [HubStepRow] = []
    var stepsStatus = "ok"
    var backfilling = false
    var historyPendingSync = false
    var lastBackfillingEndedAt: Int?
    /// nil = "loaded iff there are sessions", like the adapter.
    var sleepLoaded: Bool?
    /// Row reads (not fingerprints) throw this while set.
    var readError: Error?
    var failRowReads: Bool { get { readError != nil } set { readError = newValue ? FakeReadError() : nil } }
    var fingerprintCalls = 0
    var tz = TimeZone(identifier: "America/Los_Angeles")!

    func context(now: Int) async -> HubRunContext? {
        HubRunContext(device: HubDevice(appVersion: "12.0.0-hub.1", build: "1200", bandFw: "41.16.6.0",
                                        bandBattery: 81.5, embeddedExpiry: 1_896_379_200, tz: tz.identifier,
                                        stepsStatus: stepsStatus),
                      timeZone: tz, daily: daily, sleep: sleep, steps: steps,
                      sleepLoaded: sleepLoaded ?? !sleep.isEmpty,
                      backfilling: backfilling, historyPendingSync: historyPendingSync,
                      lastBackfillingEndedAt: lastBackfillingEndedAt)
    }
    func hrSamples(from: Int, to: Int) async throws -> [HubHRSampleInput] {
        if let e = readError { throw e }
        return hr.filter { $0.ts >= from && $0.ts <= to }
    }
    func events(from: Int, to: Int) async throws -> [HubEventInput] {
        if let e = readError { throw e }
        return ev.filter { $0.ts >= from && $0.ts <= to }
    }
    func battery(from: Int, to: Int) async throws -> [HubBatteryInput] {
        if let e = readError { throw e }
        return bat.filter { $0.ts >= from && $0.ts <= to }
    }
    func firstTs(_ s: HubStream, from: Int, to: Int) async throws -> Int? { tss(s).filter { $0 >= from && $0 <= to }.min() }
    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async throws -> [HubFingerprint] {
        fingerprintCalls += 1
        let all = tss(s)
        return ranges.map { r in
            let inR = all.filter { r.contains($0) }
            return HubFingerprint(count: inR.count, maxTs: inR.max() ?? 0)
        }
    }
    private func tss(_ s: HubStream) -> [Int] {
        switch s {
        case .hr_minute: return hr.filter { $0.bpm > 0 }.map(\.ts)
        case .events: return ev.filter { HubBatchBuilder.eventWhitelist.contains($0.kind) }.map(\.ts)
        case .battery: return bat.map(\.ts)
        }
    }
}

final class Counter { var n = 0 }

struct LeakyError: Error, CustomStringConvertible { let description: String }

final class FakeTransport: HubTransport {
    var requests: [URLRequest] = []
    var bodies: [[String: Any]] = []
    /// Given the decoded request JSON, return (status, response body) or throw.
    var respond: ([String: Any]) throws -> (Int, Data) = { FakeTransport.ackAll($0) }

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        let json = FakeTransport.decode(request.httpBody!)
        bodies.append(json)
        let (s, d) = try respond(json)
        return (s, d)
    }

    static func gunzip(_ gz: Data) -> Data {
        let bytes = [UInt8](gz)
        precondition(bytes[0] == 0x1f && bytes[1] == 0x8b && bytes[2] == 8)
        let raw = Data(bytes[10..<(bytes.count - 8)])
        return try! (raw as NSData).decompressed(using: .zlib) as Data
    }

    static func decode(_ gz: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: gunzip(gz)) as! [String: Any]
    }

    /// A well-behaved server: acks every table it received with that table's newest key.
    static func ackAll(_ j: [String: Any], locked: Bool = false, renewal: Int? = 1_896_000_000, alerts: Int = 0) -> (Int, Data) {
        var ack: [String: Any] = [:]
        for t in ["sleep", "hr_minute", "events", "battery"] {
            let key = t == "sleep" ? "start_ts" : "t"
            if let rows = j[t] as? [[String: Any]], let m = rows.compactMap({ $0[key] as? Int }).max() { ack[t] = m }
        }
        for t in ["daily", "steps"] {
            if let rows = j[t] as? [[String: Any]], let m = rows.compactMap({ $0["day"] as? String }).max() { ack[t] = m }
        }
        var o: [String: Any] = ["ack": ack, "locked": locked, "open_alerts": alerts, "server_time": 1_894_800_000]
        o["renewal_estimate"] = renewal.map { $0 as Any } ?? NSNull()
        return (200, try! JSONSerialization.data(withJSONObject: o))
    }
}

/// Runs an async closure to completion from a synchronous test (works under XCTest and the swiftc harness).
func blocking<T>(_ f: @escaping () async -> T) -> T {
    var out: T?
    let sem = DispatchSemaphore(value: 0)
    Task.detached { out = await f(); sem.signal() }
    sem.wait()
    return out!
}

final class HubUploaderTests: XCTestCase {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    /// 2030-01-15 00:00:00 in Los Angeles (UTC-8).
    let dayStart = 1_894_694_400
    let token = "tok_SYNTHETIC_abcdefghijklmnopqrstuvwxyz0123456789"

    var suite = ""
    var defaults: UserDefaults!
    var state: HubState!
    var marks: HubWatermarkStore!

    override func setUp() {
        suite = "hub.test.uploader.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        state = HubState(defaults: defaults)
        state.hubURLString = "https://hub.example.test"
        state.enabled = true
        marks = HubWatermarkStore(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func engine(_ src: FakeHubSource, _ tr: FakeTransport, token: String? = nil, attempts: Counter? = nil) -> HubUploadEngine {
        let tok = token ?? self.token
        return HubUploadEngine(source: src, client: HubClient(transport: tr, token: { tok }), state: state, marks: marks,
                               afterAttempt: { attempts?.n += 1 })
    }

    func run(_ e: HubUploadEngine, _ trig: HubTrigger = .manual, at now: Int, dataLandedAt: Int? = nil,
             shouldContinue: @escaping () -> Bool = { true }) -> HubRunOutcome {
        blocking { await e.run(trig, now: { Date(timeIntervalSince1970: TimeInterval(now)) }, dataLandedAt: dataLandedAt,
                               shouldContinue: shouldContinue) }
    }

    /// One sample every `step` seconds over [from, to), bpm = 60 + (ts / 60) % 40.
    func hrSeries(_ from: Int, _ to: Int, step: Int = 10) -> [HubHRSampleInput] {
        stride(from: from, to: to, by: step).map { HubHRSampleInput(ts: $0, bpm: 60 + ($0 / 60) % 40) }
    }

    func minutes(_ bodies: [[String: Any]]) -> [Int] {
        bodies.flatMap { ($0["hr_minute"] as? [[String: Any]] ?? []).map { $0["t"] as! Int } }
    }

    // MARK: minute aggregation

    func testMinuteAggregationIsExactOnPerSecondData() {
        let m0 = dayStart + 600   // a minute boundary
        var samples: [HubHRSampleInput] = []
        for i in 0..<60 { samples.append(HubHRSampleInput(ts: m0 + i, bpm: 50 + i)) }          // 50…109, mean 79.5
        for i in 0..<30 { samples.append(HubHRSampleInput(ts: m0 + 60 + i, bpm: i % 2 == 0 ? 70 : 73)) } // mean 71.5
        samples.append(HubHRSampleInput(ts: m0 + 61, bpm: 0))                                  // no contact: dropped
        samples.append(HubHRSampleInput(ts: m0 + 185, bpm: 64))                                // lone sample, minute 3
        let rows = HubBatchBuilder.minuteAggregates(samples.shuffled())
        XCTAssertEqual(rows, [
            HubHRMinute(t: m0, mean: 79.5, min: 50, max: 109, n: 60),
            HubHRMinute(t: m0 + 60, mean: 71.5, min: 70, max: 73, n: 30),
            HubHRMinute(t: m0 + 180, mean: 64, min: 64, max: 64, n: 1),
        ])
        XCTAssertEqual(HubBatchBuilder.minuteAggregates([HubHRSampleInput(ts: m0, bpm: 0)]), [])
    }

    func testEventWhitelistDropsEverythingElse() {
        let rows = HubBatchBuilder.events([
            HubEventInput(ts: 5, kind: "BLE_CONNECTION_UP"), HubEventInput(ts: 3, kind: "WRIST_OFF"),
            HubEventInput(ts: 4, kind: "CHARGING_ON"), HubEventInput(ts: 6, kind: "RTC_LOST"),
            HubEventInput(ts: 3, kind: "WRIST_OFF"), HubEventInput(ts: 7, kind: "WRIST_ON"),
            HubEventInput(ts: 8, kind: "CHARGING_OFF"),
        ])
        XCTAssertEqual(rows.map(\.kind), ["WRIST_OFF", "CHARGING_ON", "WRIST_ON", "CHARGING_OFF"])
    }

    func testNapRuleAndSleepTotals() {
        // NOOP stores efficiency as a 0–1 fraction (AnalyticsEngine); some imports carry a percentage.
        let night = HubSleepInput(startTs: dayStart - 3 * 3600, endTs: dayStart + 4 * 3600, efficiency: 0.9,
                                  restingHr: 55, avgHrv: 70, startTsAdjusted: nil, userEdited: false)
        let fragment = HubSleepInput(startTs: dayStart + 4 * 3600 + 30 * 60, endTs: dayStart + 6 * 3600,
                                     efficiency: nil, restingHr: nil, avgHrv: nil, startTsAdjusted: nil, userEdited: false)
        let nap = HubSleepInput(startTs: dayStart + 14 * 3600, endTs: dayStart + 14 * 3600 + 1800, efficiency: 80,
                                restingHr: 58, avgHrv: 60, startTsAdjusted: nil, userEdited: true)
        let rows = HubBatchBuilder.sleep([nap, fragment, night], timeZone: tz)
        XCTAssertEqual(rows.map(\.isNap), [0, 0, 1])
        XCTAssertEqual(rows[0].localDay, "2030-01-14")   // started the evening before
        XCTAssertEqual(rows[0].totalMin, 378)              // 7 h in bed × 0.9, not 3.78
        XCTAssertEqual(rows[0].efficiency, 0.9)
        XCTAssertNil(rows[1].totalMin)
        XCTAssertEqual(rows[2].totalMin, 24)               // a percentage (80) is read as 0.8
        XCTAssertEqual(rows[2].efficiency, 0.8)            // R22: the wire carries a fraction
        XCTAssertEqual(rows[2].userEdited, 1)
    }

    func testSleepTotalPrefersNOOPsDecodedAsleepMinutesAndMainNightFlag() {
        var s = HubSleepInput(startTs: dayStart, endTs: dayStart + 8 * 3600, efficiency: 0.95, restingHr: nil,
                              avgHrv: nil, startTsAdjusted: nil, userEdited: false)
        s.asleepMin = 401.5
        s.isMain = false              // NOOP's own grouping says nap, even though it is the day's longest
        let row = HubBatchBuilder.sleep([s], timeZone: tz)[0]
        XCTAssertEqual(row.totalMin, 401.5)
        XCTAssertEqual(row.isNap, 1)
    }

    func testEfficiencyIsAFractionOnTheWire() {
        XCTAssertEqual(HubBatchBuilder.efficiencyFraction(0.912), 0.912)
        XCTAssertEqual(HubBatchBuilder.efficiencyFraction(91.2)!, 0.912, accuracy: 1e-12)
        XCTAssertEqual(HubBatchBuilder.efficiencyFraction(1), 1)
        XCTAssertEqual(HubBatchBuilder.efficiencyFraction(150), 1)
        XCTAssertEqual(HubBatchBuilder.efficiencyFraction(-3), 0)
        XCTAssertNil(HubBatchBuilder.efficiencyFraction(nil))
        XCTAssertNil(HubBatchBuilder.efficiencyFraction(.nan))
        var d = HubDailyInput(day: "2030-01-15", recovery: nil, strain: nil, restingHr: nil, avgHrv: nil, avgSdnn: nil,
                              respRateBpm: nil, skinTempDevC: 0.3, totalSleepMin: nil, efficiency: 91.2,
                              disturbances: nil, exerciseCount: nil, steps: nil, activeKcalEst: nil)
        XCTAssertEqual(HubBatchBuilder.daily(d).efficiency!, 0.912, accuracy: 1e-12)
        XCTAssertEqual(HubBatchBuilder.daily(d).skinTempDevC, 0.3)
        d.skinTempDevC = 33.4        // an import's ABSOLUTE wrist °C in the deviation column: never sent as a deviation
        XCTAssertNil(HubBatchBuilder.daily(d).skinTempDevC)
    }

    // MARK: privacy + contract

    func fullPayload() -> HubPayload {
        var p = HubPayload(device: HubDevice(appVersion: "1", build: "1", bandFw: nil, bandBattery: nil,
                                             embeddedExpiry: nil, tz: "America/Los_Angeles", stepsStatus: "ok"))
        p.daily = [HubBatchBuilder.daily(HubDailyInput(day: "2030-01-15", recovery: 67, strain: 38.5, restingHr: 55,
                                                       avgHrv: 72.4, avgSdnn: nil, respRateBpm: 14.6, skinTempDevC: -0.1,
                                                       totalSleepMin: 441, efficiency: 91.2, disturbances: 9,
                                                       exerciseCount: 1, steps: 7912, activeKcalEst: 512.3))]
        p.sleep = HubBatchBuilder.sleep([HubSleepInput(startTs: dayStart, endTs: dayStart + 3600, efficiency: nil,
                                                       restingHr: 55, avgHrv: nil, startTsAdjusted: nil, userEdited: false)],
                                        timeZone: tz)
        p.hrMinute = HubBatchBuilder.minuteAggregates(hrSeries(dayStart, dayStart + 180))
        p.events = HubBatchBuilder.events([HubEventInput(ts: dayStart, kind: "WRIST_OFF")])
        p.battery = HubBatchBuilder.battery([HubBatteryInput(ts: dayStart, soc: 22, mv: 3620, charging: nil),
                                             HubBatteryInput(ts: dayStart + 60, soc: 23, mv: nil, charging: true)])
        p.steps = [HubStepRow(day: "2030-01-14", steps: 8423, distanceM: nil, flights: 7)]
        p.sleepWindow = HubBatchBuilder.sleepWindow(containing: dayStart, tz)
        return p
    }

    func allKeys(_ v: Any) -> [String] {
        if let d = v as? [String: Any] { return d.keys.map { $0 } + d.values.flatMap(allKeys) }
        if let a = v as? [Any] { return a.flatMap(allKeys) }
        return []
    }

    func testEncodedPayloadNeverCarriesSpO2StagesOrRR() {
        let json = try! JSONSerialization.jsonObject(with: try! HubWire.encode(fullPayload()))
        let keys = allKeys(json).map { $0.lowercased() }
        XCTAssertTrue(keys.count > 40)
        for k in keys {
            XCTAssertFalse(k.contains("spo2"), k)
            XCTAssertFalse(k.contains("stage"), k)
            XCTAssertFalse(k.hasPrefix("rr"), k)
        }
    }

    /// CONTRACT.md types: "i" integer, "n" number, "s" string; "?" = nullable.
    let contractTypes: [String: [String: String]] = [
        "device": ["app_version": "s", "build": "s", "band_fw": "s?", "band_battery": "n?", "embedded_expiry": "i?",
                   "tz": "s", "steps_status": "s"],
        "daily": ["day": "s", "recovery": "n?", "strain": "n?", "resting_hr": "i?", "avg_hrv": "n?", "avg_sdnn": "n?",
                  "resp_rate_bpm": "n?", "skin_temp_dev_c": "n?", "total_sleep_min": "n?", "efficiency": "n?",
                  "disturbances": "i?", "exercise_count": "i?", "steps": "i?", "active_kcal_est": "n?"],
        "sleep": ["start_ts": "i", "end_ts": "i", "local_day": "s", "total_min": "n?", "efficiency": "n?",
                  "resting_hr": "i?", "avg_hrv": "n?", "is_nap": "i", "start_ts_adjusted": "i?", "user_edited": "i"],
        "hr_minute": ["t": "i", "mean": "n", "min": "i", "max": "i", "n": "i"],
        "events": ["t": "i", "kind": "s"],
        "battery": ["t": "i", "soc": "n?", "mv": "i?", "charging": "i?"],
        "steps": ["day": "s", "steps": "i?", "distance_m": "n?", "flights": "i?"],
    ]

    func check(_ v: Any, _ type: String, _ where_: String) {
        if v is NSNull { XCTAssertTrue(type.hasSuffix("?"), "null in non-nullable \(where_)"); return }
        switch type.prefix(1) {
        case "s": XCTAssertTrue(v is String, "\(where_) not a string")
        case "i":
            let n = v as? NSNumber
            XCTAssertTrue(n != nil && !(v is String) && n!.doubleValue == n!.doubleValue.rounded(), "\(where_) not an integer")
        default: XCTAssertTrue(v is NSNumber && !(v is String), "\(where_) not a number")
        }
    }

    func testPayloadMatchesTheContractFixture() {
        let fixture = try! JSONSerialization.jsonObject(with: Data(HubContractFixture.phonePayloadV1.utf8)) as! [String: Any]
        let mine = try! JSONSerialization.jsonObject(with: try! HubWire.encode(fullPayload())) as! [String: Any]
        XCTAssertEqual(Set(mine.keys), Set(fixture.keys))
        XCTAssertEqual(mine["schema"] as? Int, 1)
        // R23: `sleep_window` is optional — present in the fixture, absent from a payload without a window.
        var bare = fullPayload(); bare.sleepWindow = nil
        let noWindow = try! JSONSerialization.jsonObject(with: try! HubWire.encode(bare)) as! [String: Any]
        XCTAssertEqual(Set(noWindow.keys), Set(fixture.keys).subtracting(["sleep_window"]))
        for (name, doc) in [("fixture", fixture), ("payload", mine)] {
            guard let w = doc["sleep_window"] as? [String: Any] else { XCTFail("\(name) has no sleep_window"); continue }
            XCTAssertEqual(Set(w.keys), ["from", "to"])
            check(w["from"] as Any, "i", "\(name).sleep_window.from")
            check(w["to"] as Any, "i", "\(name).sleep_window.to")
            let from = (w["from"] as? Int) ?? 0, to = (w["to"] as? Int) ?? 0
            XCTAssertTrue(from < to && to - from <= 691_200, "\(name).sleep_window span")
            for r in doc["sleep"] as! [[String: Any]] {
                let st = r["start_ts"] as! Int
                XCTAssertTrue(st >= from && st < to, "\(name).sleep row outside its window")
            }
        }
        // The fixture itself satisfies the type table (guards the table against drift).
        for (name, doc) in [("fixture", fixture), ("payload", mine)] {
            let dev = doc["device"] as! [String: Any]
            XCTAssertEqual(Set(dev.keys), Set(contractTypes["device"]!.keys), "\(name) device keys")
            for (k, t) in contractTypes["device"]! { check(dev[k] as Any, t, "\(name).device.\(k)") }
            for table in ["daily", "sleep", "hr_minute", "events", "battery", "steps"] {
                let rows = doc[table] as! [[String: Any]]
                XCTAssertTrue(!rows.isEmpty, "\(name).\(table) empty")
                let fixtureKeys = Set((fixture[table] as! [[String: Any]])[0].keys)
                for (i, row) in rows.enumerated() {
                    XCTAssertEqual(Set(row.keys), fixtureKeys, "\(name).\(table)[\(i)] keys")
                    XCTAssertEqual(Set(row.keys), Set(contractTypes[table]!.keys), "\(name).\(table)[\(i)] vs table")
                    for (k, t) in contractTypes[table]! { check(row[k] as Any, t, "\(name).\(table)[\(i)].\(k)") }
                    if let e = row["efficiency"] as? Double {   // R22: a 0–1 fraction
                        XCTAssertTrue(e >= 0 && e <= 1, "\(name).\(table)[\(i)].efficiency \(e) is not a 0–1 fraction (R22)")
                    }
                }
            }
        }
        let status = [HubStepsStatus.ok, .denied, .unavailable, .notDetermined, .error].map(\.rawValue)
        XCTAssertEqual(Set(status), ["ok", "denied", "unavailable", "not_determined", "error"])   // R10
    }

    // MARK: gzip + client

    func testGzipFramingAndCRC() {
        XCTAssertEqual(HubGzip.crc32(Data("123456789".utf8)), 0xCBF43926)
        let input = try! HubWire.encode(fullPayload())
        let gz = try! HubGzip.gzip(input)
        let b = [UInt8](gz)
        XCTAssertEqual(Array(b[0..<4]), [0x1f, 0x8b, 0x08, 0x00])
        let crc = UInt32(b[b.count - 8]) | UInt32(b[b.count - 7]) << 8 | UInt32(b[b.count - 6]) << 16 | UInt32(b[b.count - 5]) << 24
        let size = UInt32(b[b.count - 4]) | UInt32(b[b.count - 3]) << 8 | UInt32(b[b.count - 2]) << 16 | UInt32(b[b.count - 1]) << 24
        XCTAssertEqual(crc, HubGzip.crc32(input))
        XCTAssertEqual(Int(size), input.count)
        XCTAssertEqual(FakeTransport.gunzip(gz), input)
        XCTAssertTrue(gz.count < input.count)
    }

    func testRequestShapeAndAuth() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 600)
        _ = run(engine(src, tr), at: dayStart + 900)
        XCTAssertEqual(tr.requests.count, 1)
        let r = tr.requests[0]
        XCTAssertEqual(r.url?.absoluteString, "https://hub.example.test/ingest/phone")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual((tr.bodies[0]["device"] as! [String: Any])["steps_status"] as? String, "ok")
    }

    func testFailureReasonsNeverCarryTheToken() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 600)
        tr.respond = { _ in throw LeakyError(description: "failed for Bearer \(self.token)") }
        let out = run(engine(src, tr), at: dayStart + 900)
        if case .failed = out {} else { XCTFail("expected failure, got \(out)") }
        XCTAssertFalse((state.lastUploadResult ?? "").contains(token))
        XCTAssertFalse(HubClient.scrub("x \(token) y", token: token).contains(token))
        // A refused token is reported by status only.
        tr.respond = { _ in (401, Data("{\"error\":\"bad token \(self.token)\"}".utf8)) }
        _ = run(engine(src, tr), at: dayStart + 2000)
        XCTAssertEqual(state.lastUploadResult, "Token refused (HTTP 401)")
        tr.respond = { _ in (503, Data("{\"code\":\"D1_LIMIT\"}".utf8)) }
        _ = run(engine(src, tr), at: dayStart + 3000)
        XCTAssertEqual(state.lastUploadResult, "Hub database unavailable (D1_LIMIT)")
    }

    // MARK: watermarks

    func testWatermarksHoldOnFailureAndAdvanceOnAck() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 1800)
        src.ev = [HubEventInput(ts: dayStart + 100, kind: "WRIST_ON")]
        src.bat = [HubBatteryInput(ts: dayStart + 200, soc: 50, mv: 3900, charging: nil)]
        tr.respond = { _ in (503, Data("{\"code\":\"D1_ERROR\"}".utf8)) }
        let attempts = Counter()
        let e = engine(src, tr, attempts: attempts)
        let out = run(e, at: dayStart + 2000)
        XCTAssertEqual(out, .failed(.serverLimit("D1_ERROR")))
        XCTAssertEqual(marks.load().stream, [:])
        XCTAssertEqual(state.lastUploadOK, false)
        XCTAssertNotNil(state.failingSince)
        XCTAssertEqual(attempts.n, 1)

        // A short ack (the server claims less than was sent) moves nothing either.
        tr.respond = { j in
            var (_, d) = FakeTransport.ackAll(j)
            var o = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
            var ack = o["ack"] as! [String: Any]; ack["hr_minute"] = self.dayStart; o["ack"] = ack
            d = try! JSONSerialization.data(withJSONObject: o); return (200, d)
        }
        XCTAssertEqual(run(e, at: dayStart + 2100), .failed(.badResponse))
        XCTAssertEqual(marks.load().stream, [:])

        tr.respond = { FakeTransport.ackAll($0, locked: true, renewal: 1_895_000_000, alerts: 2) }
        let ok = run(e, at: dayStart + 2200)
        XCTAssertEqual(ok, .uploaded(requests: 1, more: false))
        let w = marks.load()
        XCTAssertEqual(w.streamMark(.hr_minute), dayStart + 1740)
        XCTAssertEqual(w.streamMark(.events), dayStart + 100)
        XCTAssertEqual(w.streamMark(.battery), dayStart + 200)
        XCTAssertEqual(state.lastUploadOK, true)
        XCTAssertNil(state.failingSince)
        XCTAssertTrue(state.locked)
        XCTAssertEqual(state.openAlerts, 2)
        XCTAssertEqual(state.serverRenewalEstimate, Date(timeIntervalSince1970: 1_895_000_000))
        // Each failed request resent the same rows: nothing was lost while the hub refused them.
        XCTAssertEqual(Set(minutes([tr.bodies[0]])), Set(minutes([tr.bodies[2]])))
    }

    func testCancelledRunAdvancesNothingAndMarksCatchUp() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 1800)
        tr.respond = { _ in throw CancellationError() }
        XCTAssertEqual(run(engine(src, tr), at: dayStart + 2000), .cancelled)
        XCTAssertEqual(marks.load().stream, [:])
        XCTAssertTrue(marks.load().catchUpPending)
        XCTAssertNil(state.lastUploadOK)   // background expiry is not a hub failure
        // Out of background time before the first request: nothing is sent at all.
        let tr2 = FakeTransport()
        XCTAssertEqual(run(engine(src, tr2), at: dayStart + 2100, shouldContinue: { false }), .cancelled)
        XCTAssertEqual(tr2.requests.count, 0)
    }

    func testChunksStayWithinOneLocalDayAndTwoThousandRows() {
        let src = FakeHubSource(), tr = FakeTransport()
        let start = dayStart - 2 * 86_400 + 5 * 3600
        let now = dayStart + 86_400 + 13 * 3600 + 17 * 60
        src.hr = hrSeries(start, now, step: 15)
        src.bat = stride(from: start, to: now, by: 480).map { HubBatteryInput(ts: $0, soc: 50, mv: nil, charging: nil) }
        let out = run(engine(src, tr), at: now)
        XCTAssertEqual(out, .uploaded(requests: 4, more: false))
        for body in tr.bodies {
            let ts = (body["hr_minute"] as! [[String: Any]]).map { $0["t"] as! Int }
                + (body["battery"] as! [[String: Any]]).map { $0["t"] as! Int }
            XCTAssertEqual(Set(ts.map { HubBatchBuilder.localDay($0, tz) }).count, 1)
            XCTAssertLessThanOrEqual((body["hr_minute"] as! [Any]).count, HubBatchBuilder.maxHRRowsPerRequest)
        }
        let expected = Set(HubBatchBuilder.minuteAggregates(src.hr).map(\.t))
        XCTAssertEqual(Set(minutes(tr.bodies)), expected)                       // nothing skipped
        XCTAssertEqual(marks.load().streamMark(.hr_minute), expected.max())
        // Device status rides every request.
        XCTAssertTrue(tr.bodies.allSatisfy { $0["device"] != nil })
    }

    func testCatchUpSendsDayChunksThenThrottles() {
        let src = FakeHubSource(), tr = FakeTransport()
        let now = dayStart + 12 * 3600
        // 13 days behind: one day-sized request per local day (14 requests incl. today), all in one run.
        src.hr = stride(from: now - 13 * 86_400, to: now, by: 3600).map { HubHRSampleInput(ts: $0, bpm: 70) }
        let out = run(engine(src, tr), .backfill, at: now)
        XCTAssertEqual(out, .uploaded(requests: 14, more: false))
        // A foreground trigger 2 minutes later is throttled (caught up); a manual one is not.
        XCTAssertEqual(run(engine(src, tr), .foreground, at: now + 120), .skipped("throttled"))
        if case .uploaded = run(engine(src, tr), .manual, at: now + 130) {} else { XCTFail("manual must run") }
        // After 10 minutes a foreground trigger runs again.
        if case .uploaded = run(engine(src, tr), .foreground, at: now + 130 + 600) {} else { XCTFail("10 min floor") }
        XCTAssertTrue(HubUploadEngine.shouldRun(trigger: .backfill, now: 100, lastAttemptAt: 90, catchUpPending: true))
        XCTAssertFalse(HubUploadEngine.shouldRun(trigger: .backfill, now: 100, lastAttemptAt: 90, catchUpPending: false))
    }

    func testLateBackfilledHourIsResent() {
        let src = FakeHubSource(), tr = FakeTransport()
        let now = dayStart + 18 * 3600
        // Live data 10 am–6 pm with a hole from 1 pm to 3 pm (the strap's history hadn't offloaded yet).
        src.hr = hrSeries(dayStart + 10 * 3600, dayStart + 13 * 3600) + hrSeries(dayStart + 15 * 3600, now)
        _ = run(engine(src, tr), at: now)
        let first = Set(minutes(tr.bodies))
        // The backfill lands the hole.
        let hole = hrSeries(dayStart + 13 * 3600, dayStart + 15 * 3600)
        src.hr += hole
        tr.bodies.removeAll()
        _ = run(engine(src, tr), .backfill, at: now + 700)
        let resent = Set(minutes(tr.bodies))
        let holeMinutes = Set(HubBatchBuilder.minuteAggregates(hole).map(\.t))
        XCTAssertTrue(holeMinutes.isSubset(of: resent))
        XCTAssertTrue(holeMinutes.isDisjoint(with: first))
        // Only the changed hours plus the still-open last hour went again, not the whole day.
        XCTAssertLessThanOrEqual(resent.count, 2 * 60 + 60)
        // A third run with no new data resends only the open hour.
        tr.bodies.removeAll()
        _ = run(engine(src, tr), .foreground, at: now + 1400)
        XCTAssertLessThanOrEqual(minutes(tr.bodies).count, 60)
    }

    func testChangedDailyAndSleepRowsAreResentOthersAreNot() {
        let src = FakeHubSource(), tr = FakeTransport()
        func d(_ day: String, _ rec: Double?) -> HubDailyInput {
            HubDailyInput(day: day, recovery: rec, strain: nil, restingHr: nil, avgHrv: nil, avgSdnn: nil,
                          respRateBpm: nil, skinTempDevC: nil, totalSleepMin: nil, efficiency: nil, disturbances: nil,
                          exerciseCount: nil, steps: nil, activeKcalEst: nil)
        }
        src.daily = [d("2030-01-13", 50), d("2030-01-14", 60), d("2030-01-15", nil)]
        src.sleep = [HubSleepInput(startTs: dayStart - 7200, endTs: dayStart + 21_600, efficiency: 90, restingHr: 55,
                                   avgHrv: 70, startTsAdjusted: nil, userEdited: false)]
        src.steps = [HubStepRow(day: "2030-01-15", steps: 100, distanceM: nil, flights: nil)]
        _ = run(engine(src, tr), at: dayStart + 36_000)
        XCTAssertEqual((tr.bodies[0]["daily"] as! [Any]).count, 3)
        XCTAssertEqual(tr.bodies.flatMap { $0["sleep"] as! [Any] }.count, 1)
        src.daily[2] = d("2030-01-15", 71)     // today's recovery scored
        tr.bodies.removeAll()
        _ = run(engine(src, tr), at: dayStart + 37_000)
        XCTAssertEqual(tr.bodies.count, 1)
        XCTAssertEqual((tr.bodies[0]["daily"] as! [[String: Any]]).map { $0["day"] as! String }, ["2030-01-15"])
        XCTAssertEqual((tr.bodies[0]["sleep"] as! [Any]).count, 0)
        XCTAssertNil(tr.bodies[0]["sleep_window"])                         // unchanged window: not resent
        XCTAssertEqual((tr.bodies[0]["steps"] as! [Any]).count, 1)     // steps go every upload
    }

    func testNonOkStepsCarryNoRows() {
        let snap = HubStepsSnapshot(status: .denied, days: [], timeZone: "America/Los_Angeles")
        XCTAssertEqual(HubBatchBuilder.steps(snap), [])
    }

    func testNothingRunsWhenOffOrUnconfigured() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 600)
        state.enabled = false
        XCTAssertEqual(run(engine(src, tr), at: dayStart + 900), .skipped("hub off"))
        state.enabled = true
        XCTAssertEqual(run(engine(src, tr, token: ""), at: dayStart + 900), .skipped("no token"))
        state.hubURLString = "http://insecure.example.test"
        XCTAssertEqual(run(engine(src, tr), at: dayStart + 900), .skipped("no hub URL"))
        XCTAssertEqual(tr.requests.count, 0)
        XCTAssertNil(state.lastUploadOK)
        XCTAssertNil(marks.load().lastAttemptAt)
    }

    func testWatermarksStoreNoHealthValuesAndRoundTrip() {
        var w = HubWatermarks()
        w.advance(.hr_minute, to: 120); w.advance(.hr_minute, to: 60)
        XCTAssertEqual(w.streamMark(.hr_minute), 120)   // never backwards
        w.setHourMark(.events, 3600, HubHourMark(clip: 7199, fp: HubFingerprint(count: 2, maxTs: 4000)))
        w.rows["daily"] = ["2030-01-15": "abc"]
        marks.save(w)
        XCTAssertEqual(marks.load(), w)
        w.prune(hoursBefore: 7200, keepRowKeys: [.daily: []])
        XCTAssertNil(w.hourMark(.events, 3600))
        XCTAssertEqual(w.rows["daily"], [:])
    }

    // MARK: fix round 1

    /// Review Important 3: the phone was away from the band for 3 days. On reconnect live rows land at
    /// "now" while the offload is still writing the 3 days. Streams are held during the offload, so the
    /// watermark can't jump past the backfill; afterwards every backfilled minute is sent.
    func testThreeDayGapBackfilledDuringLiveStreamIsSentInFull() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let t0 = dayStart - 3 * 86_400 + 8 * 3600       // last upload before the gap
        src.hr = hrSeries(t0 - 3600, t0)
        _ = run(e, at: t0 + 60)
        let before = marks.load().streamMark(.hr_minute)!
        let now = dayStart + 10 * 3600
        // Reconnect: live rows at now, offload still running with only the oldest day written so far.
        src.hr += hrSeries(now - 1200, now)
        src.hr += hrSeries(t0, t0 + 86_400)
        src.bat = [HubBatteryInput(ts: now - 60, soc: 40, mv: nil, charging: nil)]
        src.backfilling = true
        tr.bodies.removeAll()
        let held = run(e, .foreground, at: now)
        XCTAssertEqual(held, .uploaded(requests: 1, more: false))
        XCTAssertEqual(marks.load().streamMark(.hr_minute), before)        // not advanced past the backfill
        XCTAssertNil(marks.load().streamMark(.battery))
        XCTAssertEqual(minutes(tr.bodies), [])                            // streams not sent while held
        XCTAssertNotNil(tr.bodies[0]["device"])                           // status/steps still go
        // The offload finishes: the whole gap is in the store.
        src.hr += hrSeries(t0 + 86_400, now - 1200)
        src.backfilling = false; src.lastBackfillingEndedAt = now + 20
        tr.bodies.removeAll()
        _ = run(e, .backfill, at: now + 30, dataLandedAt: now + 25)
        let sent = Set(minutes(tr.bodies))
        let want = Set(HubBatchBuilder.minuteAggregates(src.hr.filter { $0.ts > before }).map(\.t))
        XCTAssertTrue(want.isSubset(of: sent), "\(want.subtracting(sent).count) backfilled minutes never sent")
    }

    /// Review Important 4: a failed store read fails the run; nothing is marked acked, nothing advances,
    /// and the failure counts toward the 6-hour notice.
    func testStoreReadFailureFailsTheRunAndLosesNothing() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let now = dayStart + 18 * 3600
        src.hr = hrSeries(dayStart + 10 * 3600, dayStart + 13 * 3600) + hrSeries(dayStart + 15 * 3600, now)
        _ = run(e, at: now)
        let w0 = marks.load()
        let hole = hrSeries(dayStart + 13 * 3600, dayStart + 15 * 3600)
        src.hr += hole
        src.failRowReads = true
        tr.bodies.removeAll()
        XCTAssertEqual(run(e, .backfill, at: now + 700, dataLandedAt: now + 690), .failed(.storeRead))
        XCTAssertEqual(tr.requests.count, 1)                // nothing new was posted
        XCTAssertEqual(marks.load().stream, w0.stream)
        // No segment holding rows got a new or changed mark (marks for segments seen EMPTY are harmless:
        // a row landing there later changes the fingerprint and is resent).
        let nonEmpty = { (w: HubWatermarks) in w.hours.mapValues { $0.filter { $0.value.fp.count > 0 } } }
        XCTAssertEqual(nonEmpty(marks.load()), nonEmpty(w0))
        XCTAssertEqual(state.lastUploadOK, false)
        XCTAssertNotNil(state.failingSince)
        src.failRowReads = false
        _ = run(e, .backfill, at: now + 1400, dataLandedAt: now + 1390)
        let holeMinutes = Set(HubBatchBuilder.minuteAggregates(hole).map(\.t))
        XCTAssertTrue(holeMinutes.isSubset(of: Set(minutes(tr.bodies))))
    }

    /// Review Minor 5: in a half-hour zone an hour straddles local midnight; both halves of a backfilled
    /// hole in that hour are resent, and every request stays within one local day.
    func testHalfHourZoneHoleAcrossMidnightIsResentInFull() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.tz = TimeZone(identifier: "Asia/Kolkata")!       // UTC+5:30
        let e = engine(src, tr)
        let midnight = 1_894_645_800                          // 2030-01-15 00:00 IST = 18:30 UTC
        let now = midnight + 6 * 3600
        let holeFrom = midnight - 1800, holeTo = midnight + 1800     // 11:30 pm → 12:30 am IST
        src.hr = hrSeries(midnight - 5 * 3600, holeFrom) + hrSeries(holeTo, now)
        _ = run(e, at: now)
        src.hr += hrSeries(holeFrom, holeTo)
        tr.bodies.removeAll()
        _ = run(e, .backfill, at: now + 700, dataLandedAt: now + 690)
        let want = Set(HubBatchBuilder.minuteAggregates(hrSeries(holeFrom, holeTo)).map(\.t))
        XCTAssertEqual(want.subtracting(Set(minutes(tr.bodies))).count, 0)
        for body in tr.bodies {
            let ts = (body["hr_minute"] as! [[String: Any]]).map { $0["t"] as! Int }
            XCTAssertTrue(Set(ts.map { HubBatchBuilder.localDay($0, src.tz) }).count <= 1)
        }
    }

    /// Review Minor 6: the 48 h late-backfill scan runs when new history can have landed (a backfill, or
    /// "Upload now"), not on every foreground.
    func testLateScanRunsOnBackfillAndManualOnly() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let now = dayStart + 18 * 3600
        src.hr = hrSeries(dayStart + 10 * 3600, now)
        _ = run(e, at: now)
        src.fingerprintCalls = 0
        _ = run(e, .foreground, at: now + 700)
        let foregroundCalls = src.fingerprintCalls
        src.fingerprintCalls = 0
        _ = run(e, .backfill, at: now + 1400, dataLandedAt: now + 1390)
        XCTAssertTrue(src.fingerprintCalls > foregroundCalls, "backfill \(src.fingerprintCalls) vs foreground \(foregroundCalls)")
        XCTAssertEqual(foregroundCalls, 1)     // only the marks for what is being sent (HR only here)
    }

    /// Review Minor 8: switching the hub off (or changing its URL) stops a catch-up already running.
    func testSwitchingOffStopsARunningCatchUp() {
        let src = FakeHubSource(), tr = FakeTransport()
        let now = dayStart + 12 * 3600
        src.hr = stride(from: now - 5 * 86_400, to: now, by: 3600).map { HubHRSampleInput(ts: $0, bpm: 70) }
        tr.respond = { j in self.state.enabled = false; return FakeTransport.ackAll(j) }
        let out = run(engine(src, tr), at: now)
        XCTAssertEqual(tr.requests.count, 1)
        XCTAssertEqual(out, .uploaded(requests: 1, more: true))
        state.enabled = true
        let tr2 = FakeTransport()
        tr2.respond = { j in self.state.hubURLString = "https://other.example.test"; return FakeTransport.ackAll(j) }
        _ = run(engine(src, tr2), at: now + 10)
        XCTAssertEqual(tr2.requests.count, 1)
    }

    /// Review Minor 10: the backfill a foreground kicks off is not held back by that foreground's run.
    func testBackfillAfterAForegroundRunIsNotThrottled() {
        XCTAssertTrue(HubUploadEngine.shouldRun(trigger: .backfill, now: 1_120, lastAttemptAt: 1_000,
                                                catchUpPending: false, dataLandedAt: 1_100))
        XCTAssertFalse(HubUploadEngine.shouldRun(trigger: .backfill, now: 1_120, lastAttemptAt: 1_000,
                                                 catchUpPending: false, dataLandedAt: 990))
        XCTAssertFalse(HubUploadEngine.shouldRun(trigger: .foreground, now: 1_120, lastAttemptAt: 1_000,
                                                 catchUpPending: false, dataLandedAt: 1_100))
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 600)
        let e = engine(src, tr)
        _ = run(e, .foreground, at: dayStart + 700)
        if case .uploaded = run(e, .backfill, at: dayStart + 820, dataLandedAt: dayStart + 815) {} else { XCTFail("backfill throttled") }
    }

    /// Review Minor 9: a redirect is never followed (it would carry the bearer token elsewhere).
    func testRedirectsAreRefused() {
        let blocker = HubRedirectBlocker()
        var followed: URLRequest? = URLRequest(url: URL(string: "https://example.test")!)
        blocker.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: URL(string: "https://hub.example.test")!),
                           willPerformHTTPRedirection: HTTPURLResponse(), newRequest: URLRequest(url: URL(string: "https://login.example.test")!)) {
            followed = $0
        }
        XCTAssertNil(followed)
        XCTAssertEqual(HubClient.classify(status: 302, body: Data()), .failed(.http(302)))
    }

    // MARK: fix round 2 — R23 sleep windows

    func night(_ start: Int, hours: Int = 7) -> HubSleepInput {
        HubSleepInput(startTs: start, endTs: start + hours * 3600, efficiency: 0.9, restingHr: 55, avgHrv: 70,
                      startTsAdjusted: nil, userEdited: false)
    }

    func windows(_ bodies: [[String: Any]]) -> [(from: Int, to: Int, starts: [Int])] {
        bodies.compactMap { b in
            guard let w = b["sleep_window"] as? [String: Any] else { return nil }
            return (w["from"] as! Int, w["to"] as! Int, (b["sleep"] as! [[String: Any]]).map { $0["start_ts"] as! Int })
        }
    }

    func testReKeyedSessionReplacesItsDayWindow() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let s1 = dayStart - 5 * 3600                     // 7 pm the evening before (local day 2030-01-14)
        src.sleep = [night(s1)]
        _ = run(e, at: dayStart + 10 * 3600)
        tr.bodies.removeAll()
        src.sleep = [night(s1 + 1200)]                   // NOOP re-detected the onset 20 min later
        _ = run(e, at: dayStart + 11 * 3600)
        let ws = windows(tr.bodies)
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws.first?.starts, [s1 + 1200])    // only the new key: the server supersedes the old one
        XCTAssertEqual(ws.first?.from, HubBatchBuilder.startOfLocalDay(s1, tz))
    }

    func testDeletedSessionSendsAnEmptyWindow() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let s1 = dayStart - 5 * 3600, s2 = dayStart + 13 * 3600
        src.sleep = [night(s1), night(s2, hours: 1)]
        _ = run(e, at: dayStart + 16 * 3600)
        tr.bodies.removeAll()
        src.sleep = [night(s1)]                           // the nap was deleted in NOOP
        let out = run(e, at: dayStart + 17 * 3600)
        if case .uploaded = out {} else { XCTFail("\(out)") }
        let ws = windows(tr.bodies)
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws.first?.from, dayStart)
        XCTAssertEqual(ws.first?.starts, [])
        // Confirmed by the ack: an unchanged state sends nothing more.
        tr.bodies.removeAll()
        _ = run(e, at: dayStart + 18 * 3600)
        XCTAssertEqual(windows(tr.bodies).count, 0)
    }

    func testStartMovedAcrossMidnightSendsBothWindows() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let s1 = dayStart - 600                           // 11:50 pm on the 14th
        let older = night(dayStart - 3 * 86_400)          // NOOP's loaded list reaches further back
        src.sleep = [older, night(s1)]
        _ = run(e, at: dayStart + 10 * 3600)
        tr.bodies.removeAll()
        src.sleep = [older, night(dayStart + 600)]        // corrected to 12:10 am on the 15th
        _ = run(e, at: dayStart + 11 * 3600)
        let ws = windows(tr.bodies).sorted { $0.from < $1.from }
        XCTAssertEqual(ws.map(\.from), [HubBatchBuilder.startOfLocalDay(s1, tz), dayStart])
        XCTAssertEqual(ws.map(\.starts), [[], [dayStart + 600]])
    }

    func testWindowNotConfirmedWithoutAnAck() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        src.sleep = [night(dayStart - 5 * 3600)]
        tr.respond = { _ in (503, Data("{\"code\":\"D1_ERROR\"}".utf8)) }
        _ = run(e, at: dayStart + 10 * 3600)
        tr.respond = { FakeTransport.ackAll($0) }
        tr.bodies.removeAll()
        _ = run(e, at: dayStart + 11 * 3600)
        XCTAssertTrue(windows(tr.bodies).contains { $0.starts == [dayStart - 5 * 3600] })
    }

    func testRowsOutsideTheWindowAreRefusedLocally() {
        var p = fullPayload()
        p.sleepWindow = HubSleepWindow(from: dayStart + 86_400, to: dayStart + 2 * 86_400)   // row starts the day before
        XCTAssertNil(try? HubWire.encode(p))
        p.sleepWindow = HubSleepWindow(from: dayStart, to: dayStart)                         // from == to
        p.sleep = []
        XCTAssertNil(try? HubWire.encode(p))
        p.sleepWindow = HubSleepWindow(from: dayStart, to: dayStart + 691_201)               // > 8 days
        XCTAssertNil(try? HubWire.encode(p))
        p.sleepWindow = HubSleepWindow(from: dayStart, to: dayStart + 86_400)
        XCTAssertNotNil(try? HubWire.encode(p))
    }

    func testNoWindowsUnlessNOOPsSleepListIsLoaded() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.sleep = [night(dayStart - 5 * 3600)]
        src.sleepLoaded = false
        src.hr = hrSeries(dayStart, dayStart + 600)
        _ = run(engine(src, tr), at: dayStart + 36_000)
        XCTAssertTrue(tr.bodies.allSatisfy { $0["sleep_window"] == nil })
        XCTAssertTrue(tr.bodies.allSatisfy { ($0["sleep"] as! [Any]).isEmpty })
        // Loaded but empty (a cold background launch): also nothing.
        let src2 = FakeHubSource(), tr2 = FakeTransport()
        src2.hr = hrSeries(dayStart, dayStart + 600)
        _ = run(engine(src2, tr2), at: dayStart + 36_000)
        XCTAssertTrue(tr2.bodies.allSatisfy { $0["sleep_window"] == nil })
    }

    func testWindowsOnlyForTheLast14DaysAndNotBeforeTheOldestLoadedSession() {
        let src = FakeHubSource(), tr = FakeTransport()
        let now = dayStart + 10 * 3600
        src.sleep = [night(dayStart - 30 * 86_400), night(dayStart - 5 * 86_400 - 5 * 3600)]
        _ = run(engine(src, tr), at: now)
        let froms = windows(tr.bodies).map(\.from)
        XCTAssertFalse(froms.isEmpty)
        XCTAssertTrue(froms.allSatisfy { $0 >= now - 13 * 86_400 })        // R26 addendum
        XCTAssertEqual(froms.count, 13)                                   // 10 am: 13 days back is mid-day, so 13 windows
        XCTAssertTrue(tr.bodies.allSatisfy { windows([$0]).count <= 1 })      // one window per request
        let src2 = FakeHubSource(), tr2 = FakeTransport()
        src2.sleep = [night(dayStart - 2 * 86_400 - 5 * 3600)]                  // oldest loaded: 3 days back
        _ = run(engine(src2, tr2), at: now)
        XCTAssertEqual(windows(tr2.bodies).map(\.from).min(), HubBatchBuilder.startOfLocalDay(dayStart - 2 * 86_400 - 5 * 3600, tz))
    }

    func testDSTDayWindowsAre23And25Hours() {
        let spring = dayStart + 54 * 86_400           // 2030-03-10 00:00 PST (spring forward)
        let fall = dayStart + 292 * 86_400 - 3600     // 2030-11-03 00:00 PDT (fall back)
        let w1 = HubBatchBuilder.sleepWindow(containing: spring + 3600, tz)
        let w2 = HubBatchBuilder.sleepWindow(containing: fall + 3600, tz)
        XCTAssertEqual(HubBatchBuilder.localDay(w1.from, tz), "2030-03-10")
        XCTAssertEqual(w1.to - w1.from, 23 * 3600)
        XCTAssertEqual(HubBatchBuilder.localDay(w2.from, tz), "2030-11-03")
        XCTAssertEqual(w2.to - w2.from, 25 * 3600)
    }

    // MARK: fix round 2 — hold policy (re-review Q1) and Minors

    func testHoldPolicy() {
        let now = 100_000
        func d(_ t: HubTrigger, bf: Bool = false, pend: Bool = false, ended: Int? = nil, since: Int? = nil) -> HubHoldDecision {
            HubHoldPolicy.decide(trigger: t, now: now, backfilling: bf, historyPendingSync: pend,
                                 lastBackfillingEndedAt: ended, holdingSince: since)
        }
        XCTAssertEqual(d(.foreground), HubHoldDecision(hold: false, holdingSince: nil, capped: false))
        XCTAssertEqual(d(.foreground, bf: true), HubHoldDecision(hold: true, holdingSince: now, capped: false))
        XCTAssertEqual(d(.backfill, pend: true), HubHoldDecision(hold: true, holdingSince: now, capped: false))
        // 120 s quiet window after an offload ends: foreground and manual wait, the backfill trigger doesn't.
        XCTAssertTrue(d(.foreground, ended: now - 119).hold)
        XCTAssertTrue(d(.manual, ended: now - 60).hold)
        XCTAssertFalse(d(.backfill, ended: now - 60).hold)
        XCTAssertFalse(d(.foreground, ended: now - 121).hold)
        // A continuous hold is capped at 2 h: then it sends anyway, keeping the start so Settings can show it.
        XCTAssertEqual(d(.foreground, bf: true, since: now - 7_199), HubHoldDecision(hold: true, holdingSince: now - 7_199, capped: false))
        XCTAssertEqual(d(.foreground, bf: true, since: now - 7_200), HubHoldDecision(hold: false, holdingSince: now - 7_200, capped: true))
    }

    func testHoldStatusIsVisibleAndCleared() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        src.hr = hrSeries(dayStart, dayStart + 600)
        src.historyPendingSync = true
        _ = run(e, at: dayStart + 1000)
        XCTAssertEqual(state.holdingSince, Date(timeIntervalSince1970: TimeInterval(dayStart + 1000)))
        XCTAssertEqual(minutes(tr.bodies), [])
        // Still pending 2 h later (a latched flag): the cap sends anyway and the status stays visible.
        tr.bodies.removeAll()
        _ = run(e, at: dayStart + 1000 + 7_200)
        XCTAssertFalse(minutes(tr.bodies).isEmpty)
        XCTAssertNotNil(state.holdingSince)
        src.historyPendingSync = false
        _ = run(e, .manual, at: dayStart + 1000 + 7_300)
        XCTAssertNil(state.holdingSince)
    }

    /// Re-review Minor a: a deep offload drains in ~60 s passes, each firing the backfill hook. While held,
    /// those runs keep the 10-minute floor instead of posting ~24 near-empty requests.
    func testHeldBackfillRunsKeepTheTenMinuteFloor() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        src.hr = hrSeries(dayStart, dayStart + 600)
        _ = run(e, at: dayStart + 700)
        src.backfilling = true
        tr.requests.removeAll()
        for pass in 1...24 {
            let t = dayStart + 700 + 60 * pass
            _ = run(e, .backfill, at: t, dataLandedAt: t - 2)
        }
        XCTAssertLessThanOrEqual(tr.requests.count, 3)       // 24 passes over 24 min → at most one per 10 min
        src.backfilling = false
        let t = dayStart + 700 + 60 * 25
        if case .uploaded = run(e, .backfill, at: t, dataLandedAt: t - 2) {} else { XCTFail("final backfill must send") }
    }

    /// Re-review Minor b: a cancellation thrown by a store read (background expiry) is not an upload failure.
    func testCancellationDuringAStoreReadIsNotAFailure() {
        let src = FakeHubSource(), tr = FakeTransport()
        src.hr = hrSeries(dayStart, dayStart + 600)
        src.readError = CancellationError()
        XCTAssertEqual(run(engine(src, tr), at: dayStart + 700), .cancelled)
        XCTAssertNil(state.lastUploadOK)
        XCTAssertNil(state.failingSince)
        XCTAssertTrue(marks.load().catchUpPending)
    }

    /// Re-review Minor c: the real transport passes the redirect blocker to URLSession.
    func testTransportPassesTheRedirectBlocker() {
        var seen: URLSessionTaskDelegate?
        let t = URLSessionHubTransport(perform: { req, delegate in
            seen = delegate
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!)
        })
        let r = blocking { try? await t.post(URLRequest(url: URL(string: "https://hub.example.test/ingest/phone")!)) }
        XCTAssertTrue(seen is HubRedirectBlocker)
        XCTAssertEqual(r?.status, 302)
    }

    // MARK: fix round 3 — R26

    /// R26 addendum: windows only for local days whose start is >= now − 13 days, exactly at the edge and
    /// across the spring-forward change (2030-03-10, a 23-hour day).
    func testWindowsStopAtThirteenDaysAcrossDST() {
        let mar7 = dayStart + 51 * 86_400                 // 2030-03-07 00:00 PST
        let edge = mar7 + 13 * 86_400                     // 2030-03-20 01:00 PDT: Mar 7 is exactly 13 days back
        for (now, oldestDay, count) in [(edge, "2030-03-07", 14), (edge + 1, "2030-03-08", 13)] {
            setUp()
            let src = FakeHubSource(), tr = FakeTransport()
            src.sleep = [night(mar7 - 10 * 86_400), night(edge - 6 * 3600)]
            _ = run(engine(src, tr), at: now)
            let froms = windows(tr.bodies).map(\.from)
            XCTAssertEqual(froms.count, count)
            XCTAssertTrue(froms.allSatisfy { $0 >= now - 13 * 86_400 }, "a window older than now − 13 days")
            XCTAssertEqual(froms.min().map { HubBatchBuilder.localDay($0, tz) }, oldestDay)
            tearDown()
        }
    }

    /// R26: if the server 422s a request carrying a window, that window is dropped (recorded, not retried)
    /// so it can never block HR or daily uploads.
    func testRejectedWindowDoesNotWedgeTheQueue() {
        let src = FakeHubSource(), tr = FakeTransport()
        let e = engine(src, tr)
        let now = dayStart + 18 * 3600
        src.sleep = [night(dayStart - 5 * 3600)]
        src.sleepLoaded = true
        src.hr = hrSeries(dayStart + 17 * 3600, now)
        let badFrom = HubBatchBuilder.startOfLocalDay(dayStart - 5 * 3600, tz)
        tr.respond = { j in
            if let w = j["sleep_window"] as? [String: Any], w["from"] as? Int == badFrom {
                return (422, Data("{\"error\":\"invalid\"}".utf8))
            }
            return FakeTransport.ackAll(j)
        }
        let first = run(e, at: now)
        XCTAssertEqual(first, .failed(.rejected))
        XCTAssertEqual(state.lastUploadResult, "Sleep window rejected (HTTP 422); dropped")
        XCTAssertNotNil(marks.load().rejectedWindows[String(badFrom)])
        tr.bodies.removeAll()
        let second = run(e, .manual, at: now + 60)
        if case .uploaded = second {} else { XCTFail("queue wedged: \(second)") }
        XCTAssertFalse(windows(tr.bodies).contains { $0.from == badFrom })
        XCTAssertFalse(minutes(tr.bodies).isEmpty)                     // HR goes through
        XCTAssertEqual(state.lastUploadOK, true)
        tr.bodies.removeAll()
        _ = run(e, .manual, at: now + 120)
        XCTAssertFalse(windows(tr.bodies).contains { $0.from == badFrom })   // not retried
        // New content in that window is a new window: it gets one fresh try.
        src.sleep.append(night(dayStart - 2 * 3600, hours: 1))
        tr.bodies.removeAll()
        _ = run(e, .manual, at: now + 180)
        XCTAssertTrue(windows(tr.bodies).contains { $0.from == badFrom })
    }
}
