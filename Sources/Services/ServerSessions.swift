import Foundation

/// Session delegate for every `URLSession` that talks to the Immich server
/// (outside `ImmichAPIClient`): TLS trust and same-host redirect behaviour.
///
/// - Challenges go to `TrustEvaluatingURLSessionDelegate` unchanged, so the
///   trust rule is the API client's (standard evaluation first, then anchoring
///   the presented chain only for a host in the trust store).
/// - On an HTTP redirect, `Authorization` is re-applied when the target is the
///   same host as the original request, and never otherwise.
///
/// It deliberately does not implement `urlSession(_:task:didReceive:)`.
final class ServerSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trust: TrustEvaluatingURLSessionDelegate

    init(trustStore: TrustedServerStore) {
        self.trust = TrustEvaluatingURLSessionDelegate(trustStore: trustStore)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var redirectedRequest = request
        if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
           request.url?.host == task.originalRequest?.url?.host {
            redirectedRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirectedRequest)
    }
}

/// The single place that builds `URLSession`s talking to the Immich server
/// (besides the API client's own). One instance per process, owned by
/// `DependencyContainer`: a session retains its delegate until invalidated, so
/// sessions are never built per call.
///
/// Three sessions, sharing the delegate logic but not the configuration:
/// - `images`: thumbnails and full-size images (disk cache, cache-first).
/// - `transfers`: offline copies and the download queue (one pool for both).
/// - `roadTrip`: road-trip asset pre-selection and image preloading, kept apart
///   from `transfers` so a large download never starves them of connections.
final class ServerSessions: ConnectionResetting, @unchecked Sendable {
    let images: URLSession
    let transfers: URLSession
    let roadTrip: URLSession

    init(
        trustStore: TrustedServerStore,
        imageCache: URLCache,
        transfersConfiguration: URLSessionConfiguration = .default,
        roadTripConfiguration: URLSessionConfiguration = .default
    ) {
        images = Self.makeSession(configuration: Self.imageConfiguration(cache: imageCache), trustStore: trustStore)
        transfers = Self.makeSession(configuration: transfersConfiguration, trustStore: trustStore)
        roadTrip = Self.makeSession(configuration: roadTripConfiguration, trustStore: trustStore)
    }

    /// The only constructor of server-facing sessions: any future session to
    /// the server goes through here.
    static func makeSession(configuration: URLSessionConfiguration, trustStore: TrustedServerStore) -> URLSession {
        URLSession(configuration: configuration, delegate: ServerSessionDelegate(trustStore: trustStore), delegateQueue: nil)
    }

    static func imageConfiguration(cache: URLCache) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return config
    }

    func makeDownloadTransport() -> URLSessionFileDownloadTransport {
        URLSessionFileDownloadTransport(session: transfers)
    }

    func resetConnections() async {
        await images.reset()
        await transfers.reset()
        await roadTrip.reset()
    }
}
