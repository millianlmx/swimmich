import Foundation

/// Session delegate for every `URLSession` that talks to the Immich server
/// (outside `ImmichAPIClient`): TLS trust and same-host redirect behaviour.
///
/// - Challenges go to `TrustEvaluatingURLSessionDelegate` unchanged, so the
///   trust rule is the API client's (standard evaluation first, then anchoring
///   the presented chain only for a host in the trust store).
/// - On an HTTP redirect, `ServerRedirectPolicy` applies: the token and the
///   custom headers are re-applied on the same host and dropped for any other.
///
/// It deliberately does not implement `urlSession(_:task:didReceive:)`.
final class ServerSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trust: TrustEvaluatingURLSessionDelegate

    init(trustStore: TrustedServerStore, clientCertificates: ClientCertificateResponder = .live) {
        self.trust = TrustEvaluatingURLSessionDelegate(trustStore: trustStore, clientCertificates: clientCertificates)
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
        completionHandler(ServerRedirectPolicy.redirectedRequest(request, original: task.originalRequest))
    }
}

/// The single place that builds `URLSession`s talking to the Immich server
/// (besides the API client's own). One instance per process, owned by
/// `DependencyContainer`.
///
/// Six sessions, sharing the delegate logic but not the configuration:
/// - `images`: thumbnails and full-size images (disk cache, cache-first).
/// - `transfers`: offline copies and the download queue (one pool for both).
/// - `roadTrip`: road-trip asset pre-selection and image preloading, kept apart
///   from `transfers` so a large download never starves them of connections.
/// - `video`: the byte ranges AVFoundation asks for when a client certificate
///   is attached to the server (`AppTransportVideoLoader`).
/// - `realtime`: the Socket.IO WebSocket (`URLSessionSocketEngine`).
/// - `probe`: the 2 s address probes of L-26 (`URLSessionServerAddressProbe`),
///   with no cache, no cookie and no waiting for connectivity.
///
/// The sessions are replaceable (`renewSessions()`): they are computed
/// properties, and every consumer reads the current one when it creates a task.
final class ServerSessions: ConnectionResetting, SessionRenewing, @unchecked Sendable {
    private enum Kind: CaseIterable { case images, transfers, roadTrip, video, realtime, probe }

    private let trustStore: TrustedServerStore
    private let clientCertificates: ClientCertificateResponder
    private let configurations: [Kind: URLSessionConfiguration]
    private let lock = NSLock()
    private var current: [Kind: URLSession] = [:]

    var images: URLSession { session(.images) }
    var transfers: URLSession { session(.transfers) }
    var roadTrip: URLSession { session(.roadTrip) }
    var video: URLSession { session(.video) }
    var realtime: URLSession { session(.realtime) }
    var probe: URLSession { session(.probe) }

    init(
        trustStore: TrustedServerStore,
        clientCertificates: ClientCertificateResponder = .live,
        imageCache: URLCache,
        transfersConfiguration: URLSessionConfiguration = .default,
        roadTripConfiguration: URLSessionConfiguration = .default
    ) {
        self.trustStore = trustStore
        self.clientCertificates = clientCertificates
        configurations = [
            .images: Self.imageConfiguration(cache: imageCache),
            .transfers: transfersConfiguration,
            .roadTrip: roadTripConfiguration,
            .video: .default,
            .realtime: .default,
            .probe: Self.probeConfiguration(),
        ]
        for kind in Kind.allCases {
            current[kind] = Self.makeSession(
                configuration: configurations[kind] ?? .default,
                trustStore: trustStore,
                clientCertificates: clientCertificates
            )
        }
    }

    private func session(_ kind: Kind) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        // `current` is filled for every kind by `init` and never loses a key.
        return current[kind]!
    }

    /// The only constructor of server-facing sessions: any future session to
    /// the server goes through here.
    static func makeSession(
        configuration: URLSessionConfiguration,
        trustStore: TrustedServerStore,
        clientCertificates: ClientCertificateResponder = .live
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: ServerSessionDelegate(trustStore: trustStore, clientCertificates: clientCertificates),
            delegateQueue: nil
        )
    }

    /// One probe answers within 2 s or not at all: nothing waits, nothing is
    /// cached and no cookie is read or stored (a probe never carries a session).
    static func probeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return config
    }

    static func imageConfiguration(cache: URLCache) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return config
    }

    func makeDownloadTransport() -> URLSessionFileDownloadTransport {
        URLSessionFileDownloadTransport(session: { [self] in self.transfers })
    }

    /// Voluntary-logout purge: empties the current sessions.
    func resetConnections() async {
        for kind in Kind.allCases { await session(kind).reset() }
    }

    /// Certificate change: fresh sessions (fresh delegates, same configurations
    /// — the image `URLCache` object is shared, so the disk cache survives),
    /// swapped in under the lock, then the old ones invalidated.
    func renewSessions() {
        var replaced: [URLSession] = []
        for kind in Kind.allCases {
            let fresh = Self.makeSession(
                configuration: configurations[kind] ?? .default,
                trustStore: trustStore,
                clientCertificates: clientCertificates
            )
            lock.lock()
            if let old = current[kind] { replaced.append(old) }
            current[kind] = fresh
            lock.unlock()
        }
        for old in replaced { old.invalidateAndCancel() }
    }
}
