// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
import Foundation

/// Reads when this install's signing runs out, from the provisioning profile SideStore embeds.
///
/// `embedded.mobileprovision` is a CMS-signed envelope around an XML plist. Only the plist is needed,
/// so the bytes from `<plist` to the first `</plist>` after it are cut out and handed to
/// PropertyListSerialization; the signature is never checked (the date is a reminder, not a trust
/// decision). Every failure — no file, no plist, a garbled one, no `ExpirationDate` — is `nil`.
enum SigningInfo {
    private static let open = Data("<plist".utf8)
    private static let close = Data("</plist>".utf8)

    /// The profile's `ExpirationDate`, or nil when it can't be read.
    static func expirationDate(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: open),
              let end = data.range(of: close, in: start.upperBound..<data.endIndex) else { return nil }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: slice, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    /// The running app's profile expiry. nil on the simulator, in tests, and on any read failure.
    static func embeddedExpirationDate(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expirationDate(fromProfile: data)
    }
}
