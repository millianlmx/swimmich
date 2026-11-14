import Foundation
import Network

// Local and external address of one Immich server (L-26). The types live in the
// kit because the app, the widgets and the share extension all choose an
// address by the same rule, and the widget processes cannot read the app's
// memory. Nothing here is a secret: addresses and the switch are plain settings.

// MARK: - Settings

/// What the user declared for one account: where the server answers on the local
/// network, where it answers from outside, and whether the app may switch.
public struct ServerAddressSettings: Codable, Equatable, Sendable {
    public var localURL: String?
    public var externalURL: String?
    public var autoSwitch: Bool
    /// `"major.minor.patch"` of the last server version the app read.
    public var lastKnownVersion: String?

    public static let empty = ServerAddressSettings()

    public init(
        localURL: String? = nil, externalURL: String? = nil,
        autoSwitch: Bool = false, lastKnownVersion: String? = nil
    ) {
        self.localURL = localURL
        self.externalURL = externalURL
        self.autoSwitch = autoSwitch
        self.lastKnownVersion = lastKnownVersion
    }

    /// Any absent key takes its default: a value written by an older build decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localURL = try container.decodeIfPresent(String.self, forKey: .localURL)
        externalURL = try container.decodeIfPresent(String.self, forKey: .externalURL)
        autoSwitch = try container.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? false
        lastKnownVersion = try container.decodeIfPresent(String.self, forKey: .lastKnownVersion)
    }
}

/// What the user typed in an address field.
public enum ServerAddressInput {
    public enum Result: Equatable, Sendable {
        case empty, invalid, valid(URL)
    }

    /// Same rule as the connection screen: spaces trimmed, `https://` when no
    /// scheme, trailing `/` dropped. Valid when it is an http(s) URL with a
    /// host, an optional port in 1...65535 and no credentials, query or
    /// fragment. A path is allowed (a proxy under a sub-path).
    public static func normalized(_ raw: String) -> Result {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url
        else { return .invalid }
        return .valid(url)
    }
}

// MARK: - Probe

public enum ServerAddressProbeResult: Equatable, Sendable {
    case immich(version: String)
    case notImmich
    case unreachable
    case untrustedCertificate(host: String)
    case localNetworkDenied
}

public protocol ServerAddressProbing: Sendable {
    func probe(_ base: URL, headers: [CustomHTTPHeader], deadline: Duration) async -> ServerAddressProbeResult
}

/// TLS failures that call for the explicit trust flow.
public enum ServerTrustFailure {
    public static func isTLSError(_ error: URLError) -> Bool {
        switch error.code {
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }
}

public enum ServerAddressProbeClassifier {
    /// A network failure received before the deadline.
    public static func classify(
        _ error: URLError, localNetworkDenied: Bool, host: String, trustRefused: Bool
    ) -> ServerAddressProbeResult {
        if ServerTrustFailure.isTLSError(error) || (error.code == .cancelled && trustRefused) {
            return .untrustedCertificate(host: host)
        }
        return localNetworkDenied ? .localNetworkDenied : .unreachable
    }
}

/// Whether the system refused this process the "local network" permission. No
/// API answers that directly (Apple TN3179): the check opens a TCP connection
/// and reads the path reason of its `.waiting` state.
public protocol LocalNetworkAccessChecking: Sendable {
    func isDenied(host: String, port: Int, within: Duration) async -> Bool
}

public struct NWConnectionLocalNetworkCheck: LocalNetworkAccessChecking {
    public init() {}

    /// `nil` while the connection has not decided yet.
    public static func verdict(
        state: NWConnection.State, unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> Bool? {
        switch state {
        case .waiting: return unsatisfiedReason == .localNetworkDenied
        case .ready, .failed, .cancelled: return false
        case .setup, .preparing: return nil
        @unknown default: return nil
        }
    }

    public func isDenied(host: String, port: Int, within: Duration) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "app.immich.local-network-check")
        let seconds = Double(within.components.seconds) + Double(within.components.attoseconds) / 1e18
        let denied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                if let verdict = Self.verdict(state: state, unsatisfiedReason: connection.currentPath?.unsatisfiedReason) {
                    once.resume(verdict)
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) { once.resume(false) }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return denied
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// `GET /api/server/ping` and `GET /api/server/version`, both public routes of
/// Immich v2.0.0 to v3.4.0. The probe never carries a session token or a cookie,
/// and never waits past `deadline`.
public struct URLSessionServerAddressProbe: ServerAddressProbing {
    private enum Reply {
        case response(status: Int, data: Data)
        case failure(URLError)
    }

    private let session: @Sendable () -> URLSession
    private let trustRefused: @Sendable (String) -> Bool
    private let localNetworkCheck: any LocalNetworkAccessChecking

    public init(
        session: @escaping @Sendable () -> URLSession,
        trustRefused: @escaping @Sendable (String) -> Bool = { _ in false },
        localNetworkCheck: any LocalNetworkAccessChecking = NWConnectionLocalNetworkCheck()
    ) {
        self.session = session
        self.trustRefused = trustRefused
        self.localNetworkCheck = localNetworkCheck
    }

    public func probe(_ base: URL, headers: [CustomHTTPHeader], deadline: Duration) async -> ServerAddressProbeResult {
        let session = session()
        let replies = await withTaskGroup(of: [Reply]?.self, returning: [Reply]?.self) { group in
            group.addTask {
                async let ping = Self.fetch(session, base, "api/server/ping", headers)
                async let version = Self.fetch(session, base, "api/server/version", headers)
                return await [ping, version]
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let replies else { return .unreachable }

        let host = base.host ?? ""
        var failed = false
        var denial: Bool?
        for case .failure(let error) in replies {
            failed = true
            let refused = error.code == .cancelled && trustRefused(host)
            var denied = false
            if !ServerTrustFailure.isTLSError(error) && !refused {
                if denial == nil {
                    let port = base.port ?? (base.scheme?.lowercased() == "https" ? 443 : 80)
                    denial = await localNetworkCheck.isDenied(host: host, port: port, within: .milliseconds(300))
                }
                denied = denial ?? false
            }
            let result = ServerAddressProbeClassifier.classify(
                error, localNetworkDenied: denied, host: host, trustRefused: refused
            )
            if result != .unreachable { return result }
        }
        if failed { return .unreachable }
        return Self.identify(replies)
    }

    private static func fetch(_ session: URLSession, _ base: URL, _ path: String, _ headers: [CustomHTTPHeader]) async -> Reply {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        ServerRequestAuthorization.apply(token: nil, custom: headers, to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            return .response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch let error as URLError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(URLError(.cancelled))
        } catch {
            return .failure(URLError(.unknown))
        }
    }

    private static func identify(_ replies: [Reply]) -> ServerAddressProbeResult {
        struct Ping: Decodable { let res: String }
        struct Version: Decodable { let major: Int; let minor: Int; let patch: Int }
        guard case .response(200, let pingData) = replies[0], case .response(200, let versionData) = replies[1],
              (try? JSONDecoder().decode(Ping.self, from: pingData))?.res == "pong",
              let version = try? JSONDecoder().decode(Version.self, from: versionData)
        else { return .notImmich }
        return .immich(version: "\(version.major).\(version.minor).\(version.patch)")
    }
}

// MARK: - Choice

public enum ServerAddressStatus: Equatable, Sendable {
    case notConfigured, checking, reachable, unreachable, notThisServer
    case localNetworkDenied
    case untrusted(host: String)
}

/// The rule that picks the address in use, shared by the app, the widgets and
/// the share extension.
public enum ServerAddressSelector {
    /// The external address: the declared one when valid, else the one the user
    /// connected with.
    public static func externalURL(settings: ServerAddressSettings, accountURL: URL) -> URL {
        if let raw = settings.externalURL, case .valid(let url) = ServerAddressInput.normalized(raw) { return url }
        return accountURL
    }

    /// The local address wins only when the switch is on, the address is valid
    /// and it answered as this very server: same version as the external
    /// address, or as the last known one when the external address is mute.
    public static func choose(
        settings: ServerAddressSettings, accountURL: URL,
        local: ServerAddressProbeResult?, externalVersion: String?
    ) -> (url: URL, usesLocal: Bool) {
        if settings.autoSwitch,
           let raw = settings.localURL, case .valid(let localURL) = ServerAddressInput.normalized(raw),
           case .immich(let version)? = local,
           let reference = externalVersion ?? settings.lastKnownVersion, version == reference {
            return (localURL, true)
        }
        return (externalURL(settings: settings, accountURL: accountURL), false)
    }

    /// State of the local address. A server that answers as Immich with another
    /// version, or not as Immich, is not this server.
    public static func status(local: ServerAddressProbeResult, reference: String?) -> ServerAddressStatus {
        if case .immich(let version) = local, version == reference { return .reachable }
        return status(other: local)
    }

    /// State of the external address: it is the reference, so its version is not compared.
    public static func status(external: ServerAddressProbeResult) -> ServerAddressStatus {
        if case .immich = external { return .reachable }
        return status(other: external)
    }

    private static func status(other result: ServerAddressProbeResult) -> ServerAddressStatus {
        switch result {
        case .immich, .notImmich: return .notThisServer
        case .unreachable: return .unreachable
        case .localNetworkDenied: return .localNetworkDenied
        case .untrustedCertificate(let host): return .untrusted(host: host)
        }
    }
}
