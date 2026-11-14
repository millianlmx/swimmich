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
/// to learn whether the server responded. OAuth/SSO lives in `LoginScreen` and
/// `AuthViewModel.startOAuthFlow`; QR-code discovery in `ServerURLScreen` and
/// `QRScannerView`; self-signed certificate approval in the "Trust this server?"
/// alert of `ServerURLScreen` and `TrustEvaluatingURLSessionDelegate`.
struct OnboardingFlowView: View {
    @Environment(AuthViewModel.self) private var auth

    enum Step: Hashable {
        case welcome, serverURL, login
        /// The application log, reachable without a session (L-28).
        case logs
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
        case .serverURL: ServerURLScreen(continue: { path.append(.login) }, openLogs: { path.append(.logs) })
        case .login:     LoginScreen(openLogs: { path.append(.logs) })
        case .logs:      OnboardingAppLogScreen()
        }
    }
}

/// The application log on the onboarding stack. It is pushed on the flow's own
/// `NavigationStack` (no stack of its own: the bar would double), and its view
/// model is built once, on the process-wide log store — which the masking of
/// secrets already covers — so going back leaves the typed address untouched.
private struct OnboardingAppLogScreen: View {
    @State private var vm = DependencyContainer.shared.makeAppLogViewModel()

    var body: some View {
        AppLogView(vm: vm)
    }
}

// MARK: - Shared onboarding chrome

extension View {
    /// Pins a primary CTA to the bottom of an onboarding screen in a floating
    /// glass bar, inset from the screen edges (the floating-control `.bar`
    /// role, not a full-width strip). `.safeAreaInset` keeps the CTA reachable
    /// above the keyboard on iOS 17.
    func onboardingBottomBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom) {
            content()
                .padding(PVSpacing.s16)
                .frame(maxWidth: .infinity)
                .pvFloating(.bar)
                .padding(.horizontal, PVSpacing.s16)
                .padding(.bottom, PVSpacing.s8)
        }
    }

    /// `onboardingBottomBar`, only when `isPresented`: a screen whose CTA can
    /// disappear (the sign-in step of a server that refuses the password)
    /// carries no empty bar.
    @ViewBuilder
    func onboardingBottomBar<Content: View>(isPresented: Bool, @ViewBuilder content: () -> Content) -> some View {
        if isPresented {
            onboardingBottomBar(content: content)
        } else {
            self
        }
    }
}
