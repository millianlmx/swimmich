import SwiftUI

/// Onboarding — 3-step flow:
/// Bienvenue → Connexion au serveur → Identification.
///
/// Each step lives in its own file under `Onboarding/` (Apple convention:
/// one View per file). The flow orchestration stays here: a `NavigationStack`
/// driven by a `[Step]` path. There is no explicit success step — once
/// `auth.isAuthenticated` flips, the RootView gate swaps into the main TabView
/// and the app opening is the confirmation.
///
/// Server connectivity is validated inline on the connection screen (spinner →
/// reachable info card → Continue), so the user never leaves the input context
/// to learn whether the server responded. Future work — OAuth/SSO, QR-code
/// discovery and self-signed certificate validation — is tracked via the
/// `$PHASE_OAUTH` / `$PHASE_QR` / `$PHASE_CERT` markers inside each screen.
struct OnboardingFlowView: View {
    @Environment(AuthViewModel.self) private var auth

    enum Step: Hashable {
        case welcome, serverURL, login
    }

    @State private var path: [Step]

    /// `startsOnLogin` is set by the caller after a session expiry (SP-4 / BR-5):
    /// the flow opens directly on LoginScreen, whose badge shows the expiry copy.
    /// The caller passes it because `auth` comes from the environment, which is
    /// unreadable in an init.
    init(startsOnLogin: Bool = false) {
        _path = State(initialValue: Self.initialPath(startsOnLogin: startsOnLogin))
    }

    /// Chemin initial du flow (SP-4 / AC-7) : une expiration de session ouvre directement LoginScreen.
    static func initialPath(startsOnLogin: Bool) -> [Step] {
        startsOnLogin ? [.serverURL, .login] : []
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeScreen(continue: { path.append(.serverURL) })
                .navigationDestination(for: Step.self) { step in
                    destination(for: step)
                }
        }
    }

    @ViewBuilder
    private func destination(for step: Step) -> some View {
        switch step {
        case .welcome:   WelcomeScreen(continue: { path.append(.serverURL) })
        case .serverURL: ServerURLScreen(continue: { path.append(.login) })
        case .login:     LoginScreen()
        }
    }
}

// MARK: - Shared onboarding chrome

extension View {
    /// Pins a primary CTA to the bottom of an onboarding screen over a material
    /// bar that extends edge-to-edge (under the home indicator), the pattern
    /// Apple's setup/sign-in flows use. `.safeAreaInset` keeps the CTA reachable
    /// above the keyboard on iOS 17.
    func onboardingBottomBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom) {
            content()
                .padding(PVSpacing.s16)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
        }
    }
}
