// Fork-only (phone-hub): tests for StrandiOS/Hub/Core/SigningInfo.swift.
// The profile here is SYNTHETIC: a fake binary envelope around a hand-written plist. No real
// certificate, team id, or device id appears anywhere in this file.
import XCTest

final class SigningInfoTests: XCTestCase {

    /// A fake `embedded.mobileprovision`: binary junk (standing in for the CMS envelope), then the
    /// XML plist, then more binary junk (standing in for the signature).
    static func syntheticProfile(expiration: String?, extraKeys: String = "") -> Data {
        var data = Data([0x30, 0x82, 0x0F, 0xA1, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x00, 0xFF, 0x3C])
        let expiry = expiration.map { "<key>ExpirationDate</key><date>\($0)</date>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>AppIDName</key><string>Synthetic Test App</string>
        <key>CreationDate</key><date>2026-10-22T18:00:00Z</date>
        \(expiry)
        \(extraKeys)
        <key>Name</key><string>Synthetic Profile</string>
        </dict>
        </plist>
        """
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xA0, 0x82, 0x3C, 0x2F, 0x00, 0x31, 0x00]))
        return data
    }

    func testParsesExpirationFromSyntheticProfile() {
        let data = Self.syntheticProfile(expiration: "2026-10-29T18:00:00Z")
        let date = SigningInfo.expirationDate(fromProfile: data)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_793_296_800)) // 2026-10-29 18:00:00 UTC
    }

    func testMissingExpirationKeyIsNil() {
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: Self.syntheticProfile(expiration: nil)))
    }

    func testExpirationOfWrongTypeIsNil() {
        let data = Self.syntheticProfile(expiration: nil,
                                         extraKeys: "<key>ExpirationDate</key><string>soon</string>")
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: data))
    }

    func testEmptyAndGarbageAreNil() {
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: Data()))
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: Data([0x00, 0x01, 0x02, 0xFF])))
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: Data("<plist version=\"1.0\"><dict>".utf8)))
    }

    func testTruncatedProfileIsNil() {
        let full = Self.syntheticProfile(expiration: "2026-10-29T18:00:00Z")
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: full.prefix(full.count / 2)))
    }

    func testMalformedPlistSliceIsNil() {
        var data = Data([0x30, 0x82])
        data.append(Data("<plist version=\"1.0\"><dict><key>ExpirationDate</key><date>nope</plist>".utf8))
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: data))
    }

    func testBundleWithoutProfileIsNil() {
        // Neither a test bundle nor a simulator app carries embedded.mobileprovision.
        XCTAssertNil(SigningInfo.embeddedExpirationDate(bundle: Bundle(for: SigningInfoTests.self)))
    }
}
