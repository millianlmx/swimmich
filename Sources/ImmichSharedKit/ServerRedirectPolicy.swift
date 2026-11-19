import Foundation

/// What a redirect keeps: the single rule shared by every session that talks to
/// the server (the app's sessions, the widgets', the extension's).
///
/// - **Same server**: every header of the original request the redirected one
///   lost comes back — `Authorization`, `x-immich-user-token` and the custom
///   headers. The same server is the same host on the same scheme and port, or
///   the `https` address an `http` one upgrades to (any port: `:80` → `:443`).
/// - **Anything else** — another host, another port of the same host (another
///   service of the machine), or `https` falling back to `http` (the secrets
///   would travel in clear): every header is removed except the few the app
///   itself sets (`preservedAcrossHosts`). A custom header — `User-Agent`
///   included — never leaves the server it was declared for.
public enum ServerRedirectPolicy {
    /// The headers the app sets itself. Invariant: a subset of
    /// `CustomHeaderValidation.reservedNames`, so every name allowed to cross
    /// hosts is a name the user cannot type. Adding one here means reserving it.
    public static let preservedAcrossHosts: Set<String> = [
        "accept", "content-type", "content-length", "cookie", "x-immich-checksum",
    ]

    public static func redirectedRequest(_ proposed: URLRequest, original: URLRequest?) -> URLRequest {
        guard let originalHost = original?.url?.host?.lowercased(), !originalHost.isEmpty else {
            return proposed
        }
        var request = proposed
        if isSameServer(proposed.url, as: original?.url) {
            for (name, value) in original?.allHTTPHeaderFields ?? [:]
            where !preservedAcrossHosts.contains(name.lowercased()) && request.value(forHTTPHeaderField: name) == nil {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } else {
            for name in (proposed.allHTTPHeaderFields ?? [:]).keys
            where !preservedAcrossHosts.contains(name.lowercased()) {
                request.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return request
    }

    /// Whether a redirect from `original` to `proposed` stays on the server the
    /// secrets were meant for (see the type's rule).
    static func isSameServer(_ proposed: URL?, as original: URL?) -> Bool {
        guard let proposed, let original,
              let host = original.host?.lowercased(), !host.isEmpty,
              proposed.host?.lowercased() == host,
              let from = original.scheme?.lowercased(), let to = proposed.scheme?.lowercased()
        else { return false }
        if from == to { return effectivePort(of: proposed) == effectivePort(of: original) }
        return from == "http" && to == "https"
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https", "wss": return 443
        case "http", "ws": return 80
        default: return nil
        }
    }
}

/// A per-task delegate that only applies `ServerRedirectPolicy`, for the sessions
/// that have no session delegate of their own (`URLSession.shared`, the client's
/// injected sessions). The two static gates are the ONLY way those paths send a
/// request, so the mechanism lives in one place.
///
/// Whether `URLSession.data(for:delegate:)` really delivers the redirect callback
/// to a task delegate is proven end to end by the `RedirectingURLProtocol` tests
/// (`ServerRedirectPolicyTests`, `ImmichAPIClientTests`, …), one per path.
public final class ServerRedirectTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = ServerRedirectTaskDelegate()

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(ServerRedirectPolicy.redirectedRequest(request, original: task.originalRequest))
    }

    public static func data(for request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: shared)
    }

    public static func upload(
        for request: URLRequest, fromFile fileURL: URL, on session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL, delegate: shared)
    }
}
