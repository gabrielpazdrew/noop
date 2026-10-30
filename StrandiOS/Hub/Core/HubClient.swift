// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// POSTs one gzip JSON batch to `<hub URL>/ingest/phone` with the phone token and classifies the answer.
// Failure reasons are built from status codes and a fixed vocabulary only: never a response body, never
// the request, never the token (and `scrub` removes the token from anything that slips through anyway).
import Foundation

/// The server's answer to an accepted batch (PLAN T3.2).
struct HubServerResponse: Equatable {
    /// Per table (wire name), the newest key the server now holds: epoch seconds for `sleep`,
    /// `hr_minute`, `events`, `battery`; a `YYYY-MM-DD` day for `daily` and `steps`.
    var ack: [String: HubAckValue]
    var locked: Bool
    var renewalEstimate: Int?
    var openAlerts: Int
    var serverTime: Int?
    /// Not in the T3.2 response today; honoured if the server ever sends it.
    var tripwire: Bool?
}

enum HubAckValue: Equatable {
    case time(Int)
    case day(String)
}

enum HubFailure: Equatable {
    case notConfigured
    case unauthorized(Int)
    case tooLarge
    case rejected
    case rateLimited
    case serverLimit(String)
    case http(Int)
    case network(String)
    case badResponse
    case encoding

    /// Short, content-free text for HubState / the Settings screen.
    var reason: String {
        switch self {
        case .notConfigured: return "Hub URL or token missing"
        case .unauthorized(let c): return "Token refused (HTTP \(c))"
        case .tooLarge: return "Batch too large (HTTP 413)"
        case .rejected: return "Batch rejected (HTTP 422)"
        case .rateLimited: return "Rate limited (HTTP 429)"
        case .serverLimit(let code): return "Hub database unavailable (\(code))"
        case .http(let c): return "HTTP \(c)"
        case .network(let what): return what
        case .badResponse: return "Unreadable hub response"
        case .encoding: return "Could not build the batch"
        }
    }
}

enum HubSendResult: Equatable {
    case acked(HubServerResponse)
    case failed(HubFailure)
    /// The request was cancelled (background time ran out): not a hub failure, nothing advances.
    case cancelled
}

protocol HubTransport {
    func post(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// URLSession, ephemeral: no cookies, no cache, no credential storage.
struct URLSessionHubTransport: HubTransport {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    func post(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, resp) = try await Self.session.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

struct HubClient {
    static let path = "ingest/phone"
    var transport: HubTransport = URLSessionHubTransport()
    /// Read fresh for every request, so a token pasted or removed in Settings applies at once.
    var token: () -> String? = { HubKeychain.readToken() }

    static func endpoint(_ base: URL) -> URL { base.appendingPathComponent(path) }

    func request(base: URL, gzipBody: Data, token: String) -> URLRequest {
        var r = URLRequest(url: Self.endpoint(base))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.httpBody = gzipBody
        r.httpShouldHandleCookies = false
        return r
    }

    /// Encodes nothing itself: `json` is the already-encoded, size-checked payload.
    func send(json: Data, base: URL) async -> HubSendResult {
        guard let tok = token(), !tok.isEmpty else { return .failed(.notConfigured) }
        guard let body = try? HubGzip.gzip(json) else { return .failed(.encoding) }
        do {
            let (status, data) = try await transport.post(request(base: base, gzipBody: body, token: tok))
            return Self.classify(status: status, body: data)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                return .cancelled
            }
            return .failed(.network(Self.scrub(Self.networkReason(error), token: tok)))
        }
    }

    static func classify(status: Int, body: Data) -> HubSendResult {
        switch status {
        case 200..<300:
            guard let r = parse(body) else { return .failed(.badResponse) }
            return .acked(r)
        case 401, 403: return .failed(.unauthorized(status))
        case 413: return .failed(.tooLarge)
        case 422: return .failed(.rejected)
        case 429: return .failed(.rateLimited)
        case 503:
            // Only the two codes the contract names are echoed; anything else stays generic.
            let code = (try? JSONSerialization.jsonObject(with: body)) .flatMap { ($0 as? [String: Any])?["code"] as? String }
            return .failed(.serverLimit(code == "D1_LIMIT" || code == "D1_ERROR" ? code! : "HTTP 503"))
        default: return .failed(.http(status))
        }
    }

    static func parse(_ body: Data) -> HubServerResponse? {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let ackObj = o["ack"] as? [String: Any] else { return nil }
        var ack: [String: HubAckValue] = [:]
        for (k, v) in ackObj {
            if let s = v as? String { ack[k] = .day(s) }
            else if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { ack[k] = .time(n.intValue) }
        }
        func int(_ k: String) -> Int? {
            guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.intValue
        }
        return HubServerResponse(ack: ack,
                                 locked: (o["locked"] as? Bool) ?? false,
                                 renewalEstimate: int("renewal_estimate"),
                                 openAlerts: int("open_alerts") ?? 0,
                                 serverTime: int("server_time"),
                                 tripwire: o["tripwire"] as? Bool)
    }

    static func networkReason(_ error: Error) -> String {
        guard let u = error as? URLError else { return "Network error" }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "Offline"
        case .timedOut: return "Timed out"
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "Hub unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "TLS error"
        default: return "Network error \(u.code.rawValue)"
        }
    }

    /// Removes every occurrence of the token (and its Bearer form) from a string bound for a log or UI.
    static func scrub(_ s: String, token: String?) -> String {
        guard let t = token, !t.isEmpty else { return s }
        return s.replacingOccurrences(of: t, with: "[token]")
    }
}
