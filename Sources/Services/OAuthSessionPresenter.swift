import Foundation
import AuthenticationServices
import os

/// Presents the Immich OAuth page in an `ASWebAuthenticationSession` and
/// resolves with the callback URL (nil when the user cancels).
///
/// The anchor is the first key-window scene — a fixed scene reference would
/// go stale across scene re-creation.
@MainActor
enum OAuthSessionPresenter {
    /// The scheme the server must redirect back through; must match the
    /// `CFBundleURLTypes` entry in project.yml.
    static let callbackScheme = "app.immich"

    private static let log = Logger(subsystem: "app.immich.swiftui", category: "oauth")

    /// `start()` returns while the sheet is still on screen, and an
    /// `ASWebAuthenticationSession` that is deallocated before it completes is
    /// cancelled without ever presenting — so the in-flight session (and its
    /// presentation anchor, which the session holds weakly) must stay alive.
    private static var activeSession: ASWebAuthenticationSession?
    private static var activeAnchor: AnchorProvider?

    static func present(_ url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            let anchor = AnchorProvider()
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                activeSession = nil
                activeAnchor = nil
                if let error {
                    log.warning("OAuth session ended with error: \(PublicLogText.describe(error), privacy: .public)")
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            activeAnchor = anchor
            activeSession = session
            if !session.start() {
                activeSession = nil
                activeAnchor = nil
                log.error("ASWebAuthenticationSession.start() returned false")
                continuation.resume(returning: nil)
            }
        }
    }
}

/// Minimal presentation-context provider anchored to the first key window.
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first ?? ASPresentationAnchor()
    }
}
