import Foundation
import Security
import os

/// The credentials a widget needs to talk to the user's Immich server.
///
/// A widget runs in its own process, outside the app's `ImmichAPIClient`, so it
/// cannot read the app's in-memory session — it reads this small snapshot from
/// the keychain instead. The app is the only writer.
public struct WidgetSession: Codable, Equatable, Sendable {
    /// Server address, exactly as the app stores it (no trailing slash).
    public var baseURL: String
    /// Bearer token of the active account.
    public var token: String
    /// Display name, for the widget's greeting. Nil when the server did not
    /// return one.
    public var userName: String?
    public var userId: String?
    /// Hosts whose certificate the user explicitly accepted in the app. The
    /// widget cannot read the app's trust store (a different container), so the
    /// list travels with the session — see `WidgetTrustDelegate`.
    ///
    /// Optional on purpose: a session stored by an earlier build has no such key
    /// and must keep decoding.
    public var trustedHosts: [String]?

    /// The installation identifier the app uploads under (`DeviceIdentity`).
    /// It travels with the session because it lives in the *app's*
    /// `UserDefaults`, which a widget or a share extension cannot read: without
    /// it an asset shared from the sheet would appear under a second device in
    /// the web UI's per-device filter. Optional for the same reason as
    /// `trustedHosts` — an older stored session must keep decoding.
    public var deviceId: String?

    /// The custom HTTP headers (proxy password, `X-Access`…) of the active
    /// server, copied here by the app because the widget cannot read the app's
    /// in-memory registry. Optional for the same reason as `trustedHosts`: an
    /// older stored session has no such key and must keep decoding.
    public var customHeaders: [CustomHTTPHeader]?

    /// L-26: the local address of the server and the switch the user set in
    /// "Network". `baseURL` is the external address; a widget and the share
    /// extension pick between the two by `ServerAddressSelector`, as the app does
    /// (`WidgetEndpointResolver`). All optional: a session stored by an earlier
    /// build has no such key and must keep decoding (it then stays on `baseURL`).
    public var localURL: String?
    public var autoSwitch: Bool?
    /// `"major.minor.patch"` the local address must answer with when the
    /// external one is mute.
    public var lastKnownVersion: String?
    /// The address the user connected with: the key of the custom headers and
    /// of the client certificate, whichever address a request goes to.
    public var accountURL: String?

    public init(
        baseURL: String,
        token: String,
        userName: String? = nil,
        userId: String? = nil,
        trustedHosts: [String]? = nil,
        deviceId: String? = nil,
        customHeaders: [CustomHTTPHeader]? = nil,
        localURL: String? = nil,
        autoSwitch: Bool? = nil,
        lastKnownVersion: String? = nil,
        accountURL: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.userName = userName
        self.userId = userId
        self.trustedHosts = trustedHosts
        self.deviceId = deviceId
        self.customHeaders = customHeaders
        self.localURL = localURL
        self.autoSwitch = autoSwitch
        self.lastKnownVersion = lastKnownVersion
        self.accountURL = accountURL
    }

    public var trustedHostSet: Set<String> { Set(trustedHosts ?? []) }

    /// The settings the app published, in the shape `ServerAddressSelector` reads.
    public var addressSettings: ServerAddressSettings {
        ServerAddressSettings(
            localURL: localURL, externalURL: baseURL,
            autoSwitch: autoSwitch ?? false, lastKnownVersion: lastKnownVersion
        )
    }

    /// The key the client certificate of this server is saved under: the one of
    /// `accountURL` for the local and the external address alike (L-26), the key
    /// itself for any other server.
    public func canonicalKey(for key: ServerKey) -> ServerKey {
        func serverKey(_ text: String?) -> ServerKey? { text.flatMap { URL(string: $0) }.flatMap { ServerKey(url: $0) } }
        guard let owner = serverKey(accountURL ?? baseURL) else { return key }
        let aliases: [ServerKey?] = [serverKey(localURL), serverKey(baseURL)]
        return aliases.contains(key) ? owner : key
    }

    /// The same session, sent to `url` (the local address the resolver retained).
    public func retargeted(to url: URL) -> WidgetSession {
        var copy = self
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        copy.baseURL = text
        return copy
    }
}

/// Read/write seam for `WidgetSession`. The app writes on sign-in and clears on
/// sign-out; the widget only reads, and tests swap in a double.
public protocol WidgetSessionStoring: Sendable {
    func save(_ session: WidgetSession)
    func load() -> WidgetSession?
    func clear()
}

/// Keychain-backed store, shared by app and widget through the
/// `keychain-access-groups` entitlement both targets declare
/// (`Resources/ImmichSwiftUI.entitlements`, `Resources/ImmichWidgets.entitlements`,
/// plus the share extension's) — the group is `fr.millianlmx.swimmich`.
///
/// No `kSecAttrAccessGroup` is passed on purpose: the item lands in the process'
/// default group, and keychain services defines that as the FIRST entry of the
/// entitlement's array — the one all three binaries list — so the widget process
/// reads exactly what the app wrote without either side hardcoding a Team ID.
///
/// Accessibility is `afterFirstUnlock` (not the app's stricter `whenUnlocked`):
/// Lock Screen widgets refresh while the device is locked, and a
/// `whenUnlocked` item would silently fail every fetch there.
public struct WidgetSessionStore: WidgetSessionStoring {
    private static let account = "session"
    private let service: String
    private let logger = Logger(subsystem: "app.immich.swiftui", category: "widget-session")

    public init(service: String = "app.immich.swiftui.widget") {
        self.service = service
    }

    public func save(_ session: WidgetSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("widget session save failed: \(status, privacy: .public)")
        }
    }

    public func load() -> WidgetSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                // -34018 (missing entitlement) is what a widget sees when its
                // keychain group is not authorised: worth a loud line, because
                // every widget then shows the signed-out state.
                logger.error("widget session read failed: \(status, privacy: .public)")
            }
            return nil
        }
        guard let data = result as? Data,
              let session = try? JSONDecoder().decode(WidgetSession.self, from: data),
              !session.token.isEmpty
        else { return nil }
        return session
    }

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Certificate trust

/// Server-trust handling for the widget's own `URLSession`.
///
/// The app evaluates server trust through `TrustEvaluatingURLSessionDelegate`
/// and remembers the hosts the user accepted; a widget that fetches with
/// `URLSession.shared` has no delegate at all, so an Immich behind a
/// self-signed certificate — which works perfectly in the app — fails every
/// fetch and the widget shows nothing. Same policy as the app: default
/// evaluation first, and the server's own chain is anchored only for a host the
/// user explicitly trusted.
public final class WidgetTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let sessionStore: any WidgetSessionStoring
    private let clientCertificates: ClientCertificateResponder

    public init(
        sessionStore: any WidgetSessionStoring = WidgetSessionStore(),
        clientCertificates: ClientCertificateResponder = .live
    ) {
        self.sessionStore = sessionStore
        self.clientCertificates = clientCertificates
    }

    /// Same redirect rule as every other session (`ServerRedirectPolicy`): the
    /// token and the custom headers follow a redirect on the same host only.
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(ServerRedirectPolicy.redirectedRequest(request, original: task.originalRequest))
    }

    /// Whether `host` may be talked to despite a failed evaluation.
    func trustsCertificates(for host: String) -> Bool {
        sessionStore.load()?.trustedHostSet.contains(host) ?? false
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // The certificate of the account answers for its local address too (L-26).
        let responder = sessionStore.load().map { stored in
            clientCertificates.aliasing { stored.canonicalKey(for: $0) }
        } ?? clientCertificates
        if let (disposition, credential) = responder.answer(challenge) {
            completionHandler(disposition, credential)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        guard trustsCertificates(for: challenge.protectionSpace.host),
              let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certificates.isEmpty
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        SecTrustSetAnchorCertificates(serverTrust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
