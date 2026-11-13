import SwiftUI

/// Step 4 — Connexion. Email + password grouped in one card.
///
/// No `Form`. A single `@FocusState` enum drives focus across email → password
/// so the keyboard's `.submitLabel(.next)` / `.submitLabel(.go)` chain matches
/// the natural flow. Both fields share one `PVInputGroup` card (Divider between
/// rows); `scrollDismissesKeyboard(.immediately)` keeps the CTA reachable. On
/// success there is no explicit next step: the RootView gate on
/// `auth.isAuthenticated` swaps straight into the main TabView — the app
/// opening is the confirmation.
struct LoginScreen: View {
    @PVReduceMotion private var reduceMotion
    @Environment(AuthViewModel.self) private var auth

    /// Opens the application log (L-28): usable without a session, whatever the
    /// state of the modes below.
    let openLogs: () -> Void

    enum Field: Hashable { case email, password }

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    /// The password form is shown once the modes are known and the server
    /// accepts a password.
    private var showsPasswordForm: Bool {
        !auth.loginOptionsPending && auth.loginPresentation.showsPassword
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s24) {
                header

                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    if auth.loginOptionsPending {
                        // The modes of this server are being read: no form
                        // before they arrive, so it never changes under a finger.
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 88)
                            .accessibilityIdentifier("loginOptionsLoading")
                    } else {
                        let presentation = auth.loginPresentation

                        if presentation.showsPassword {
                            PVInputGroup {
                                TextField("you@example.com", text: $email)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.emailAddress)
                                    .textContentType(.username)
                                    .submitLabel(.next)
                                    .focused($focus, equals: .email)
                                    .onSubmit { focus = .password }
                                    .font(.pvBody)
                                    .accessibilityLabel(Text("Email"))
                                    .accessibilityIdentifier("loginEmailField")
                                    .pvFieldSurface()

                                Divider()

                                SecureField("••••••••", text: $password)
                                    .textContentType(.password)
                                    .submitLabel(.go)
                                    .focused($focus, equals: .password)
                                    .onSubmit { signIn() }
                                    .font(.pvBody)
                                    .accessibilityLabel(Text("Password"))
                                    .accessibilityIdentifier("loginPasswordField")
                                    .pvFieldSurface()
                            }
                        }

                        // P5 oauth: SSO sign-in via ASWebAuthenticationSession when
                        // the server accepts OAuth. Password and SSO are two
                        // distinct paths — hence the separator, only when both show.
                        if presentation.showsPassword && presentation.showsSSO {
                            orDivider
                        }

                        if presentation.showsSSO {
                            Button(action: oauthSignIn) {
                                HStack(spacing: PVSpacing.s8) {
                                    if auth.isLoading {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "person.badge.key.fill")
                                    }
                                    Text(verbatim: presentation.ssoLabel)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("loginSSOLabel")
                                }
                                .font(.pvBody.weight(.medium))
                                .padding(.vertical, PVSpacing.s8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.textPrimaryPV)
                            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
                            .disabled(auth.isLoading)
                            .accessibilityIdentifier("loginSSOButton")
                        }

                        // Neither mode is accepted: say so, rather than show a
                        // form that cannot work.
                        if presentation.isLoginDisabled {
                            Text("Login is disabled on this server.")
                                .font(.pvSubhead)
                                .foregroundStyle(Color.textSecondaryPV)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("loginDisabledMessage")
                        }
                    }

                    // Auth errors render inline under the field card (PRD §5.10 Écran 4),
                    // never as a popup.
                    if let err = auth.errorMessage {
                        InlineErrorBadge(message: err)
                            .transition(.opacity)
                    }
                }

                Spacer(minLength: PVSpacing.s48)
            }
            .padding(PVSpacing.s24)
            .animation(PVMotion.movement(PVMotion.gentle, reduceMotion: reduceMotion), value: auth.errorMessage)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if showsPasswordForm { focus = .email } }
        .onChange(of: showsPasswordForm) { _, shown in
            if shown { focus = .email }
        }
        // The modes are read once the screen is up (the launch can open directly
        // on this step). A read that was cancelled leaves the state unknown and
        // asks again; that retry runs outside the view's task, which the state
        // change itself would otherwise cancel.
        .task { await auth.loadLoginOptionsIfNeeded() }
        .onChange(of: auth.loginOptionsState) { _, state in
            if state == .unknown { Task { await auth.loadLoginOptionsIfNeeded() } }
        }
        .appSensoryFeedback(.error, trigger: auth.errorMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openLogs) {
                    Label("App Logs", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("loginLogsButton")
            }
        }
        .onboardingBottomBar(isPresented: showsPasswordForm) {
            Button(action: signIn) {
                if auth.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 22)
                } else {
                    Text("Sign In")
                }
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
            .accessibilityIdentifier("loginSignInButton")
        }
    }

    /// Separates the password path from the SSO path.
    ///
    /// `Divider()` renders *vertical* inside an `HStack` (two upright bars
    /// flanking the label), so the rule is drawn explicitly.
    private var orDivider: some View {
        HStack(spacing: PVSpacing.s12) {
            orRule
            Text("OR")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
                .fixedSize()
            orRule
        }
        .accessibilityHidden(true)
    }

    private var orRule: some View {
        Rectangle()
            .fill(Color.separatorPV)
            .frame(height: 1)
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s8) {
            PVHeaderBadge(icon: "person.crop.circle.badge.checkmark")
            Text("Sign in to Immich")
                .font(.pvH2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("loginTitle")
            Text("Use your Immich account to access your photo library.")
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
        }
    }

    private func signIn() {
        Task {
            await auth.login(email: email, password: password)
        }
    }

    private func oauthSignIn() {
        Task {
            await auth.startOAuthFlow()
        }
    }
}
