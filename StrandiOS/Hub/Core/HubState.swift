// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
import Foundation

/// The hub's settings and status, shared by the Settings screen (reads, edits URL + switch) and the
/// uploader (T4.1: writes results, server estimate, lock/tripwire, alert count). Stored in
/// UserDefaults under `hub.*` keys. The token is NEVER stored here — it lives in HubKeychain.
/// Instants are stored as epoch seconds (Double).
final class HubState {
    static let shared = HubState(defaults: .standard)
    /// Posted (object: the HubState) after any write, so the Settings screen can refresh.
    static let didChange = Notification.Name("HubStateDidChange")
    static let maxReasonLength = 120

    enum Key {
        static let url = "hub.url"
        static let enabled = "hub.enabled"
        static let lastUploadAt = "hub.lastUploadAt"
        static let lastUploadOK = "hub.lastUploadOK"
        static let lastUploadResult = "hub.lastUploadResult"
        static let failingSince = "hub.failingSince"
        static let serverRenewalEstimate = "hub.serverRenewalEstimate"
        static let locked = "hub.locked"
        static let tripwire = "hub.tripwire"
        static let openAlerts = "hub.openAlerts"
        static let renewalArmedFor = "hub.notice.renewalArmedFor"
        static let failureArmedFor = "hub.notice.failureArmedFor"
        static let lockedAlerted = "hub.notice.lockedAlerted"
        static let tripwireAlerted = "hub.notice.tripwireAlerted"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    // MARK: settings

    /// Exactly what the user typed (trimmed). Use `hubURL` for the validated value.
    var hubURLString: String? {
        get { defaults.string(forKey: Key.url) }
        set { setOrRemove(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), Key.url) }
    }

    /// The hub's base URL, https only; nil when unset or invalid. Set at runtime in Settings —
    /// there is no built-in host.
    var hubURL: URL? { Self.validatedURL(hubURLString) }

    /// Default off: nothing is uploaded until the user turns it on.
    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled); changed() }
    }

    // MARK: status (written by the uploader)

    var lastUploadAt: Date? { date(Key.lastUploadAt) }
    /// nil = never attempted.
    var lastUploadOK: Bool? { defaults.object(forKey: Key.lastUploadOK) == nil ? nil : defaults.bool(forKey: Key.lastUploadOK) }
    /// Short human text: "OK" or the failure reason (e.g. "HTTP 503"). Never a body or token.
    var lastUploadResult: String? { defaults.string(forKey: Key.lastUploadResult) }
    /// Start of the current run of consecutive failures; nil after a success.
    var failingSince: Date? { date(Key.failingSince) }

    var serverRenewalEstimate: Date? {
        get { date(Key.serverRenewalEstimate) }
        set { setDate(newValue, Key.serverRenewalEstimate); changed() }
    }
    var locked: Bool {
        get { defaults.bool(forKey: Key.locked) }
        set { defaults.set(newValue, forKey: Key.locked); changed() }
    }
    var tripwire: Bool {
        get { defaults.bool(forKey: Key.tripwire) }
        set { defaults.set(newValue, forKey: Key.tripwire); changed() }
    }
    var openAlerts: Int {
        get { defaults.integer(forKey: Key.openAlerts) }
        set { defaults.set(newValue, forKey: Key.openAlerts); changed() }
    }

    func recordUploadSuccess(at time: Date) {
        setDate(time, Key.lastUploadAt)
        defaults.set(true, forKey: Key.lastUploadOK)
        defaults.set("OK", forKey: Key.lastUploadResult)
        setDate(nil, Key.failingSince)
        changed()
    }

    /// `reason` must be short and content-free ("HTTP 503", "timed out"); it is cut to 120 chars.
    func recordUploadFailure(at time: Date, reason: String) {
        setDate(time, Key.lastUploadAt)
        defaults.set(false, forKey: Key.lastUploadOK)
        defaults.set(String(reason.prefix(Self.maxReasonLength)), forKey: Key.lastUploadResult)
        if failingSince == nil { setDate(time, Key.failingSince) }
        changed()
    }

    // MARK: notification bookkeeping (HubNotifications)

    var noticeMemory: HubNoticeMemory {
        get {
            HubNoticeMemory(renewalArmedFor: date(Key.renewalArmedFor),
                            failureArmedFor: date(Key.failureArmedFor),
                            lockedAlerted: defaults.bool(forKey: Key.lockedAlerted),
                            tripwireAlerted: defaults.bool(forKey: Key.tripwireAlerted))
        }
        set {
            setDate(newValue.renewalArmedFor, Key.renewalArmedFor)
            setDate(newValue.failureArmedFor, Key.failureArmedFor)
            defaults.set(newValue.lockedAlerted, forKey: Key.lockedAlerted)
            defaults.set(newValue.tripwireAlerted, forKey: Key.tripwireAlerted)
        }
    }

    // MARK: helpers

    /// https with a host, no user/password, trailing slash dropped. Anything else is nil.
    static func validatedURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else { return nil }
        return c.url
    }

    private func date(_ key: String) -> Date? {
        defaults.object(forKey: key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: key))
    }
    private func setDate(_ d: Date?, _ key: String) {
        if let d { defaults.set(d.timeIntervalSince1970, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    private func setOrRemove(_ s: String?, _ key: String) {
        if let s, !s.isEmpty { defaults.set(s, forKey: key) } else { defaults.removeObject(forKey: key) }
        changed()
    }
    /// Always posted on the main thread, so observers (the Settings screen's SwiftUI state) never update
    /// off-main when the uploader writes from a background task (T4.3 review finding 3).
    private func changed() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
        }
    }
}

/// Hooks the Settings screen calls and the uploader (T4.1) installs at app start.
enum HubHooks {
    /// "Upload now". nil until the uploader is wired in; the button is disabled while nil.
    static var uploadNow: (() async -> Void)? = nil
}
