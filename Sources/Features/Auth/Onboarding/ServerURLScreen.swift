import SwiftUI

/// Step 2 — Connexion au serveur. Input + live validation, one screen.
///
/// No `Form`. The field lives in a card-styled capsule with `@FocusState`
/// auto-focus on appear and `.submitLabel(.continue)` so the keyboard's return
/// key matches the primary action. Connectivity is validated in place — the
/// status section under the field reflects `auth.serverStatus` (checking →
/// reachable info card → unreachable error with retry) so the user never leaves
/// this screen to learn the result. On `.reachable` the CTA becomes
/// "Continuer", pushing the sign-in step. The CTA is pinned to the bottom over
/// a material bar — `.safeAreaInset` rides above the keyboard on iOS 17.
struct ServerURLScreen: View {
    @Environment(AuthViewModel.self) private var auth
    let `continue`: () -> Void

    @FocusState private var isFocused: Bool
    @State private var presentingQRScanner = false
    @State private var scanError: String?

    var body: some View {
        @Bindable var auth = auth

        ScrollView {
            VStack(spacing: PVSpacing.s24) {
                header

                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    Text("SERVER ADDRESS")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .tracking(1)

                    PVInputGroup {
                        HStack(spacing: PVSpacing.s8) {
                            TextField("https://photos.example.com", text: $auth.serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .submitLabel(.continue)
                                .focused($isFocused)
                                .onSubmit(primaryAction)
                                .font(.pvBody)
                                .pvFieldSurface()

                            Button {
                                presentingQRScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.pvBody)
                                    .foregroundStyle(Color.immichPrimary)
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Scan server QR code")
                        }
                    }

                    statusSection
                        .transition(.opacity)

                    // P5 qr-scan: a scanned config prefills the field and runs
                    // connectivity automatically.
                    if let error = scanError {
                        InlineErrorBadge(message: error)
                    }
                }

                // TODO: $PHASE_QR — scan a server QR code (AVFoundation/VisionKit)
                // and pre-fill `auth.serverURLString` from the decoded payload.
                // Certificates: HTTPS servers go through the standard trust
                // evaluation (TrustEvaluatingURLSessionDelegate). A self-signed
                // server is accepted only after the "Trust this server?" alert
                // below, which pins its certificate chain. NSAllowsArbitraryLoads
                // only relaxes App Transport Security (plain-HTTP self-hosted
                // servers); it does not skip certificate validation.

                Spacer(minLength: PVSpacing.s48)
            }
            .padding(PVSpacing.s24)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Server URL")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
        .onChange(of: auth.serverURLString) { _, _ in
            auth.serverStatus = .idle
        }
        .animation(PVMotion.gentle, value: auth.serverStatus)
        .sheet(isPresented: $presentingQRScanner) {
            NavigationStack {
                QRScannerView { payload in
                    handleScannedPayload(payload)
                    presentingQRScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("Scan QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { presentingQRScanner = false }
                    }
                }
            }
            .presentationDetents([.fraction(0.7)])
        }
        .alert("Trust this server?", isPresented: Binding(
            get: { auth.pendingUntrustedHost != nil },
            set: { if !$0 { auth.pendingUntrustedHost = nil } }
        )) {
            Button("Trust", role: .destructive) {
                Task { await auth.trustPendingServer() }
            }
            Button("Cancel", role: .cancel) { auth.pendingUntrustedHost = nil }
        } message: {
            Text("The certificate of \(auth.pendingUntrustedHost ?? "this server") cannot be verified. Trust it anyway?")
        }
        .onboardingBottomBar {
            Button(action: primaryAction) {
                switch auth.serverStatus {
                case .checking:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 22)
                case .reachable:
                    Text("Continue")
                case .unreachable:
                    Text("Try Again")
                case .idle:
                    Text("Check connection")
                }
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(auth.serverURLString.isEmpty || auth.isLoading || auth.serverStatus == .checking)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch auth.serverStatus {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: PVSpacing.s8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking server…")
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            .padding(PVSpacing.s8)

        case .reachable(let version):
            VStack(alignment: .leading, spacing: PVSpacing.s12) {
                Label("Server connected", systemImage: "checkmark.circle.fill")
                    .font(.pvBodyLarge)
                    .foregroundStyle(Color.immichSuccess)

                ServerInfoCard(
                    version: version.map { "\($0.major).\($0.minor).\($0.patch)" },
                    externalDomain: auth.serverConfig?.externalDomain,
                    isInitialized: auth.serverConfig?.isInitialized
                )
            }

        case .unreachable:
            InlineErrorBadge(
                message: auth.errorMessage ?? String(localized: "Server unreachable"),
                retry: { connect() }
            )
        }
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s8) {
            PVHeaderBadge(icon: "link.badge.plus")
            Text("Connect your server")
                .font(.pvH2)
                .multilineTextAlignment(.center)
            Text("Enter the URL of your Immich instance.")
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
        }
        .padding(.top, PVSpacing.s8)
    }

    private func primaryAction() {
        switch auth.serverStatus {
        case .reachable: `continue`()
        default: connect()
        }
    }

    private func connect() {
        Task {
            await auth.connectServer()
        }
    }

    /// Applies a scanned QR payload to the server field and validates it.
    private func handleScannedPayload(_ payload: String) {
        guard let url = QRServerConfigParser.parse(payload) else {
            scanError = String(localized: "Invalid QR code: no server URL found.")
            return
        }
        scanError = nil
        auth.serverURLString = url.absoluteString
        connect()
    }
}

/// Server info display card (no Form `Section`).
private struct ServerInfoCard: View {
    let version: String?
    let externalDomain: String?
    let isInitialized: Bool?

    var body: some View {
        VStack(spacing: PVSpacing.s0) {
            if let version {
                InfoRow(label: "Version", value: version)
                Divider()
            }
            if let externalDomain {
                InfoRow(label: "Domain", value: externalDomain)
                Divider()
            }
            if let isInitialized {
                InfoRow(label: "Initialized", value: isInitialized ? String(localized: "Yes") : String(localized: "No"))
            }
        }
        .padding(.horizontal, PVSpacing.s16)
        .background(Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
    }
}

private struct InfoRow: View {
    /// `LocalizedStringKey`, not `String`: the row takes a literal and must
    /// resolve it through the environment locale like `Text` does. A `String`
    /// property is never extracted by the compiler and never translated.
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
            Spacer()
            Text(value)
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, PVSpacing.s12)
    }
}
