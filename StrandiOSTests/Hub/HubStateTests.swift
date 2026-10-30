// Fork-only (phone-hub): tests for HubState (UserDefaults-backed status) and the pure parts of
// HubKeychain. The Keychain itself is not exercised here: a host-less test bundle has no
// keychain entitlement on the simulator.
import XCTest
import Security

final class HubStateTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "hub.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsAreOffAndEmpty() {
        let s = HubState(defaults: defaults)
        XCTAssertFalse(s.enabled)
        XCTAssertNil(s.hubURL)
        XCTAssertNil(s.lastUploadAt)
        XCTAssertNil(s.failingSince)
        XCTAssertFalse(s.locked)
        XCTAssertEqual(s.openAlerts, 0)
        XCTAssertEqual(s.noticeMemory, HubNoticeMemory())
    }

    func testFailureStreakStartsOnceAndSuccessClearsIt() {
        let s = HubState(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        s.recordUploadFailure(at: t0, reason: "HTTP 503")
        s.recordUploadFailure(at: t0.addingTimeInterval(600), reason: "timed out")
        XCTAssertEqual(s.failingSince, t0)
        XCTAssertEqual(s.lastUploadOK, false)
        XCTAssertEqual(s.lastUploadResult, "timed out")
        s.recordUploadSuccess(at: t0.addingTimeInterval(1200))
        XCTAssertNil(s.failingSince)
        XCTAssertEqual(s.lastUploadOK, true)
        XCTAssertEqual(s.lastUploadAt, t0.addingTimeInterval(1200))
    }

    func testFailureReasonIsShortened() {
        let s = HubState(defaults: defaults)
        s.recordUploadFailure(at: Date(), reason: String(repeating: "x", count: 500))
        XCTAssertLessThanOrEqual(s.lastUploadResult?.count ?? 0, HubState.maxReasonLength)
    }

    func testValuesPersistAcrossInstances() {
        let a = HubState(defaults: defaults)
        a.hubURLString = "https://hub.example.test"
        a.enabled = true
        a.locked = true
        a.serverRenewalEstimate = Date(timeIntervalSince1970: 1_793_500_000)
        a.noticeMemory = HubNoticeMemory(renewalArmedFor: Date(timeIntervalSince1970: 5),
                                         failureArmedFor: nil, lockedAlerted: true, tripwireAlerted: false)
        let b = HubState(defaults: defaults)
        XCTAssertEqual(b.hubURL?.absoluteString, "https://hub.example.test")
        XCTAssertTrue(b.enabled)
        XCTAssertTrue(b.locked)
        XCTAssertEqual(b.serverRenewalEstimate, Date(timeIntervalSince1970: 1_793_500_000))
        XCTAssertEqual(b.noticeMemory, a.noticeMemory)
    }

    func testURLValidationIsHTTPSOnly() {
        XCTAssertEqual(HubState.validatedURL("  https://hub.example.test/ ")?.absoluteString,
                       "https://hub.example.test")
        XCTAssertNotNil(HubState.validatedURL("https://hub.example.test/base"))
        XCTAssertNil(HubState.validatedURL("http://hub.example.test"))
        XCTAssertNil(HubState.validatedURL("hub.example.test"))
        XCTAssertNil(HubState.validatedURL("https://"))
        XCTAssertNil(HubState.validatedURL(""))
        XCTAssertNil(HubState.validatedURL(nil))
        XCTAssertNil(HubState.validatedURL("https://user:pw@hub.example.test"))
    }

    func testStateDoesNotStoreAnythingTokenShaped() {
        let s = HubState(defaults: defaults)
        s.hubURLString = "https://hub.example.test"
        s.recordUploadSuccess(at: Date())
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("hub.") }
        XCTAssertFalse(keys.isEmpty)
        XCTAssertFalse(keys.contains { $0.lowercased().contains("token") })
    }

    func testUploadNowHookIsUnsetUntilTheUploaderInstallsIt() {
        XCTAssertNil(HubHooks.uploadNow)
    }

    // MARK: HubKeychain (pure parts)

    func testTokenNormalisation() {
        XCTAssertEqual(HubKeychain.normalizedToken("  abc.DEF-123_x \n"), "abc.DEF-123_x")
        XCTAssertNil(HubKeychain.normalizedToken(""))
        XCTAssertNil(HubKeychain.normalizedToken("   \n"))
        XCTAssertNil(HubKeychain.normalizedToken("two words"))
        XCTAssertNil(HubKeychain.normalizedToken(String(repeating: "a", count: 4097)))
    }

    func testKeychainItemIsThisDeviceOnlyAfterFirstUnlock() {
        let attrs = HubKeychain.addAttributes(for: Data("t".utf8))
        XCTAssertEqual(attrs[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attrs[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attrs[kSecAttrService as String] as? String, HubKeychain.service)
        XCTAssertEqual(attrs[kSecAttrSynchronizable as String] as? Bool, false)
    }
}
