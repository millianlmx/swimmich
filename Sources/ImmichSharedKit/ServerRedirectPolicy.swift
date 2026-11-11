import Foundation

/// What a redirect keeps: the single rule shared by every session that talks to
/// the server (the app's sessions, the widgets', the extension's).
///
/// - **Same host** (port ignored, as before L-09): every header of the original
///   request the redirected one lost comes back — `Authorization`,
///   `x-immich-user-token` and the custom headers.
/// - **Another host**: every header is removed except the few the app itself
///   sets (`preservedAcrossHosts`). A custom header — `User-Agent` included —
///   never leaves the server it was declared for.
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
        if proposed.url?.host?.lowercased() == originalHost {
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
