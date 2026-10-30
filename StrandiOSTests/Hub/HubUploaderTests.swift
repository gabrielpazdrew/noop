// Fork-only (phone-hub): tests for the uploader's pure core — StrandiOS/Hub/Core/{HubBatchBuilder,
// HubPayload, HubWatermarks, HubClient, HubGzip, HubUploadEngine}.swift — with a fake store and a fake
// network. Everything here is synthetic (2030 dates); no real health data.
import XCTest

// MARK: - fakes

final class FakeHubSource: HubDataSource {
    var hr: [HubHRSampleInput] = []
    var ev: [HubEventInput] = []
    var bat: [HubBatteryInput] = []
    var daily: [HubDailyInput] = []
    var sleep: [HubSleepInput] = []
    var steps: [HubStepRow] = []
    var stepsStatus = "ok"
    var tz = TimeZone(identifier: "America/Los_Angeles")!

    func context(now: Int) async -> HubRunContext? {
        HubRunContext(device: HubDevice(appVersion: "12.0.0-hub.1", build: "1200", bandFw: "41.16.6.0",
                                        bandBattery: 81.5, embeddedExpiry: 1_896_379_200, tz: tz.identifier,
                                        stepsStatus: stepsStatus),
                      timeZone: tz, daily: daily, sleep: sleep, steps: steps)
    }
    func hrSamples(from: Int, to: Int) async -> [HubHRSampleInput] { hr.filter { $0.ts >= from && $0.ts <= to } }
    func events(from: Int, to: Int) async -> [HubEventInput] { ev.filter { $0.ts >= from && $0.ts <= to } }
    func battery(from: Int, to: Int) async -> [HubBatteryInput] { bat.filter { $0.ts >= from && $0.ts <= to } }
    func firstTs(_ s: HubStream, from: Int, to: Int) async -> Int? { tss(s).filter { $0 >= from && $0 <= to }.min() }
    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async -> [HubFingerprint] {
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

    func run(_ e: HubUploadEngine, _ trig: HubTrigger = .manual, at now: Int, shouldContinue: @escaping () -> Bool = { true }) -> HubRunOutcome {
        blocking { await e.run(trig, now: { Date(timeIntervalSince1970: TimeInterval(now)) }, shouldContinue: shouldContinue) }
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
        let night = HubSleepInput(startTs: dayStart - 3 * 3600, endTs: dayStart + 4 * 3600, efficiency: 90,
                                  restingHr: 55, avgHrv: 70, startTsAdjusted: nil, userEdited: false)
        let fragment = HubSleepInput(startTs: dayStart + 4 * 3600 + 30 * 60, endTs: dayStart + 6 * 3600,
                                     efficiency: nil, restingHr: nil, avgHrv: nil, startTsAdjusted: nil, userEdited: false)
        let nap = HubSleepInput(startTs: dayStart + 14 * 3600, endTs: dayStart + 14 * 3600 + 1800, efficiency: 80,
                                restingHr: 58, avgHrv: 60, startTsAdjusted: nil, userEdited: true)
        let rows = HubBatchBuilder.sleep([nap, fragment, night], timeZone: tz)
        XCTAssertEqual(rows.map(\.isNap), [0, 0, 1])
        XCTAssertEqual(rows[0].localDay, "2030-01-14")   // started the evening before
        XCTAssertEqual(rows[0].totalMin, 420 * 0.9)
        XCTAssertNil(rows[1].totalMin)
        XCTAssertEqual(rows[2].totalMin, 24)
        XCTAssertEqual(rows[2].userEdited, 1)
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
        XCTAssertEqual((tr.bodies[0]["sleep"] as! [Any]).count, 1)
        src.daily[2] = d("2030-01-15", 71)     // today's recovery scored
        tr.bodies.removeAll()
        _ = run(engine(src, tr), at: dayStart + 37_000)
        XCTAssertEqual((tr.bodies[0]["daily"] as! [[String: Any]]).map { $0["day"] as! String }, ["2030-01-15"])
        XCTAssertEqual((tr.bodies[0]["sleep"] as! [Any]).count, 0)
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
}
