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
        /// The new password a server requires before the home screen (B-42).
        case requiredPasswordChange
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
        // A password sign-in held for a new password pushes the step; dropping
        // it (back, or a refused session) brings the sign-in step back.
        .onChange(of: auth.isPasswordChangeRequired) { _, required in
            if required {
                path.append(.requiredPasswordChange)
            } else if path.last == .requiredPasswordChange {
                path.removeLast()
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
        case .requiredPasswordChange: RequiredPasswordChangeScreen()
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

/// The change-password step a server requires after a password sign-in (B-42,
/// the official client's `ChangePasswordRoute` pushed by `onLogin`). It reuses
/// the Me hub's screen and view model. The system back button is replaced: the
/// only way out besides the change is an explicit return to the sign-in step,
/// which signs the held session out.
private struct RequiredPasswordChangeScreen: View {
    @Environment(AuthViewModel.self) private var auth
    @State private var vm = DependencyContainer.shared.makeChangePasswordViewModel()

    var body: some View {
        ChangePasswordView(
            vm: vm,
            onPasswordChanged: { auth.completeRequiredPasswordChange() },
            notice: Text("This server asks you to choose a new password before you continue.")
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await auth.abandonRequiredPasswordChange() }
                } label: {
                    Label("Back to Sign In", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("requiredPasswordChangeBackButton")
            }
        }
    }
}

/// The version of the running app, `v<CFBundleShortVersionString>`, shown next
/// to the "App Logs" entry of the onboarding like the official client's login
/// page (B-42). `nil` when the bundle carries no version.
enum OnboardingAppVersion {
    static func label(from info: [String: Any]?) -> String? {
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        return "v\(short)"
    }
}

/// The onboarding's trailing toolbar: the app version, then the "App Logs"
/// entry (L-28, B-42). One item, so the version stays next to the entry.
struct OnboardingLogsToolbar: ToolbarContent {
    let openLogs: () -> Void
    let logsIdentifier: String
    let versionIdentifier: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: PVSpacing.s8) {
                if let version = OnboardingAppVersion.label(from: Bundle.main.infoDictionary) {
                    Text(verbatim: version)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .fixedSize()
                        .accessibilityIdentifier(versionIdentifier)
                }
                Button(action: openLogs) {
                    Label("App Logs", systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier(logsIdentifier)
            }
        }
    }
}

// MARK: - Shared onboarding chrome

extension View {
    /// Pins a primary CTA to the bottom of an onboarding screen in a floating
    /// glass bar, inset from the screen edges (the floating-control `.bar`
    /// role, not a full-width strip). `.safeAreaInset` keeps the CTA reachable
    /// above the keyboard on iOS 17.
    func onboardingBottomBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // The button alone over the screen's own background: the floating bar
        // around it (made for controls over photos) read as a grey frame on
        // the light onboarding screens.
        safeAreaInset(edge: .bottom) {
            content()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, PVSpacing.s24)
                .padding(.top, PVSpacing.s8)
                .padding(.bottom, PVSpacing.s8)
                .background(Color.bgPrimary.ignoresSafeArea(edges: .bottom))
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
