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

    public init(
        baseURL: String,
        token: String,
        userName: String? = nil,
        userId: String? = nil,
        trustedHosts: [String]? = nil,
        deviceId: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.userName = userName
        self.userId = userId
        self.trustedHosts = trustedHosts
        self.deviceId = deviceId
    }

    public var trustedHostSet: Set<String> { Set(trustedHosts ?? []) }
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
public final class WidgetTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let sessionStore: any WidgetSessionStoring

    public init(sessionStore: any WidgetSessionStoring = WidgetSessionStore()) {
        self.sessionStore = sessionStore
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
