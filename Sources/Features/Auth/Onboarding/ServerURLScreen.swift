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
    @PVReduceMotion private var reduceMotion
    @Environment(AuthViewModel.self) private var auth
    let `continue`: () -> Void

    @FocusState private var isFocused: Bool
    @State private var presentingQRScanner = false
    @State private var scanError: String?
    /// The server the open headers sheet edits (fixed when it opens).
    @State private var headersKey: HeadersSheetItem?
    /// Bumped when a list was saved, so the count beside the button re-reads.
    @State private var headersRevision = 0
    /// The client certificate sheet (import, replace, remove) for the typed server.
    @State private var presentingCertificate = false

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
                                .accessibilityIdentifier("serverURLField")
                                .pvFieldSurface()

                            Button {
                                presentingQRScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.pvBody)
                                    .foregroundStyle(Color.immichPrimary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Scan server QR code")
                            .accessibilityIdentifier("serverQRScanButton")
                        }
                    }

                    serverHeadersButton
                    serverClientCertificateButton

                    statusSection
                        .transition(.opacity)

                    // P5 qr-scan: a scanned config prefills the field and runs
                    // connectivity automatically.
                    if let error = scanError {
                        InlineErrorBadge(message: error)
                    }
                }

                // QR discovery: the `qrcode.viewfinder` button opens `QRScannerView`,
                // whose decoded payload goes through `handleScannedPayload`; it
                // pre-fills `auth.serverURLString` and starts the server check.
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
        .animation(PVMotion.movement(PVMotion.gentle, reduceMotion: reduceMotion), value: auth.serverStatus)
        .sheet(item: $headersKey) { item in
            ServerHeadersSheet(serverKey: item.key, onSaved: { auth.customHeadersDidChange(for: $0) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .immichCustomHeadersChanged)) { _ in
            headersRevision &+= 1
        }
        .sheet(isPresented: $presentingCertificate) {
            ClientCertificateSheet(
                serverURL: auth.baseURL,
                onChange: { await auth.clientCertificateDidChange() }
            )
        }
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
                case .clientCertificateRequired:
                    Text("Try Again")
                case .idle:
                    Text("Check connection")
                }
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(auth.serverURLString.isEmpty || auth.isLoading || auth.serverStatus == .checking)
            .accessibilityIdentifier("serverURLContinueButton")
        }
    }

    /// The server the field currently names, as its headers know it. `nil` while
    /// the address is not a usable URL.
    private var enteredServerKey: ServerKey? {
        auth.normalizedBaseURL(from: auth.serverURLString).flatMap { ServerKey(url: $0) }
    }

    /// "HTTP Headers" (B-1): before the address is checked, because a proxy that
    /// refuses the app makes the check itself fail.
    private var serverHeadersButton: some View {
        let key = enteredServerKey
        // Read for its side effect: a save bumps it, which re-reads the count.
        _ = headersRevision
        let count = key.map { DependencyContainer.shared.customHeaders.headers(for: $0).count } ?? 0
        return Button {
            if let key { headersKey = HeadersSheetItem(key: key) }
        } label: {
            HStack(spacing: PVSpacing.s8) {
                Label("HTTP Headers", systemImage: "list.bullet.rectangle")
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .accessibilityIdentifier("serverHeadersCount")
                }
            }
            .font(.pvBody)
            .foregroundStyle(Color.immichPrimary)
        }
        .buttonStyle(.plain)
        .disabled(key == nil || auth.serverStatus == .checking)
        .accessibilityIdentifier("serverHeadersButton")
    }

    /// "Client Certificate" (L-10): the TLS client certificate of the typed
    /// server. Disabled until the address is a usable URL, since the
    /// certificate belongs to one server (host + port).
    private var serverClientCertificateButton: some View {
        Button {
            presentingCertificate = true
        } label: {
            HStack(spacing: PVSpacing.s8) {
                PVAdaptiveStack(vAlignment: .leading, spacing: PVSpacing.s8) {
                    Label("Client Certificate", systemImage: "lock.shield")
                    Spacer(minLength: PVSpacing.s8)
                    Group {
                        if auth.serverHasClientCertificate {
                            Text("Installed")
                        } else {
                            Text("Not Installed")
                        }
                    }
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
                }
                Image(systemName: "chevron.right")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            .font(.pvBody)
            .foregroundStyle(Color.immichPrimary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(auth.baseURL == nil)
        .accessibilityIdentifier("serverClientCertificateButton")
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

        case .clientCertificateRequired:
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                InlineErrorBadge(
                    message: auth.errorMessage ?? UserFacingError.clientCertificateRequiredMessage,
                    retry: { connect() }
                )
                Button("Import Certificate") { presentingCertificate = true }
                    .buttonStyle(PVSubtleButtonStyle())
                    .accessibilityIdentifier("serverStatusImportCertificateButton")
            }
            .accessibilityIdentifier("serverStatusClientCertificateRequired")
        }
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s8) {
            PVHeaderBadge(icon: "link.badge.plus")
            Text("Connect your server")
                .font(.pvH2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("serverURLTitle")
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

/// Identifies the server a headers sheet was opened for (`ServerKey` itself is
/// the kit's, and a sheet item must be `Identifiable`).
private struct HeadersSheetItem: Identifiable {
    let key: ServerKey
    var id: String { key.rawValue }
}

/// The server step's headers editor in its own navigation stack (a sheet
/// inherits no bar): "Cancel" closes without saving, a successful "Save" closes
/// it. The view model is built once, with the key the sheet opened for.
private struct ServerHeadersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm: CustomHeadersViewModel

    init(serverKey: ServerKey, onSaved: @escaping @MainActor (ServerKey) -> Void) {
        _vm = State(initialValue: DependencyContainer.shared.makeCustomHeadersViewModel(
            serverKey: serverKey, onSaved: onSaved
        ))
    }

    var body: some View {
        NavigationStack {
            CustomHeadersView(vm: vm, onFinish: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("customHeadersCancelButton")
                    }
                }
        }
    }
}

/// The certificate screen of the server step, in its own navigation stack (a
/// sheet inherits no bar): "Done" closes it. The view model is built when the
/// sheet opens, for the server typed at that moment; any import or removal
/// re-checks the server (`onChange`).
private struct ClientCertificateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm: ClientCertificateViewModel

    init(serverURL: URL?, onChange: @escaping @MainActor () async -> Void) {
        _vm = State(initialValue: DependencyContainer.shared.makeClientCertificateViewModel(
            serverURL: serverURL, onChange: onChange
        ))
    }

    var body: some View {
        NavigationStack {
            ClientCertificateView(vm: vm)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("clientCertificateDoneButton")
                    }
                }
        }
        .presentationDetents([.medium, .large])
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PVAdaptiveStack {
            Text(label)
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
            Spacer()
            Text(value)
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .padding(.vertical, PVSpacing.s12)
    }
}
