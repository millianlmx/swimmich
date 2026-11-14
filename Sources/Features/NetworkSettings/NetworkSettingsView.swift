import SwiftUI
import UIKit

/// The "Network" setting pushed from the Me hub's "Advanced" section (L-26):
/// the local and the external address of the active account's server, the
/// automatic switch between them, the state of each address and the address in
/// use. No `NavigationStack` of its own: the hub already owns one.
struct NetworkSettingsView: View {
    @Bindable var vm: NetworkSettingsViewModel

    @Environment(\.openURL) private var openURL

    /// This app's page in Settings: the only place a refused "local network"
    /// permission can be turned back on.
    private var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    var body: some View {
        Form {
            Section {
                Toggle("Automatic switching", isOn: Binding(
                    get: { vm.autoSwitch },
                    set: { value in Task { await vm.setAutoSwitch(value) } }
                ))
                .accessibilityIdentifier("networkAutoSwitchToggle")
            } footer: {
                Text("Use the local address when it answers quickly as this server, and the external address otherwise. The app checks again whenever the network changes, and never signs you out.")
            }

            Section {
                TextField(text: $vm.localText, prompt: Text(verbatim: "http://192.168.1.10:2283")) {
                    Text("Local address")
                }
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("networkLocalAddressField")

                Button("Save") { Task { await vm.saveLocal() } }
                    .disabled(vm.isSaving)
                    .accessibilityIdentifier("networkLocalSaveButton")

                if let message = vm.localValidationMessage {
                    Text(message)
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                        .accessibilityIdentifier("networkLocalValidationMessage")
                }

                statusRow(vm.localStatus, prefix: "networkLocalStatus", openSettingsID: "networkOpenSettingsButton")
            } header: {
                Text("Local address")
            }

            Section {
                TextField(text: $vm.externalText, prompt: Text(verbatim: "https://photos.example.org")) {
                    Text("External address")
                }
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("networkExternalAddressField")

                Button("Save") { Task { await vm.saveExternal() } }
                    .disabled(vm.isSaving)
                    .accessibilityIdentifier("networkExternalSaveButton")

                if let message = vm.externalValidationMessage {
                    Text(message)
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                        .accessibilityIdentifier("networkExternalValidationMessage")
                }

                if let status = vm.externalStatus {
                    statusRow(status, prefix: "networkExternalStatus", openSettingsID: "networkExternalOpenSettingsButton")
                }
            } header: {
                Text("External address")
            }

            Section {
                LabeledContent {
                    Text(vm.activeAddressText)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("networkActiveAddress")
                } label: {
                    Text(vm.usesLocal ? LocalizedStringKey("Local") : LocalizedStringKey("External"))
                        .accessibilityIdentifier(vm.usesLocal ? "networkActiveAddressKind_local" : "networkActiveAddressKind_external")
                }
            } header: {
                Text("Address in use")
            }

            if vm.showsTestControls {
                Section {
                    Button { Task { await vm.simulateNetworkChange() } } label: {
                        Text(verbatim: "Simulate network change")
                    }
                    .accessibilityIdentifier("networkSimulateChangeButton")
                }
            }
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.refreshStatus() }
        .alert("Trust this server?", isPresented: Binding(
            get: { vm.pendingUntrustedHost != nil },
            set: { if !$0 { vm.pendingUntrustedHost = nil } }
        )) {
            Button("Trust", role: .destructive) { Task { await vm.trustPendingHost() } }
            Button("Cancel", role: .cancel) { vm.pendingUntrustedHost = nil }
        } message: {
            Text("The certificate of \(vm.pendingUntrustedHost ?? "this server") cannot be verified. Trust it anyway?")
        }
    }

    // MARK: - State rows

    /// One line for the state of an address; nothing for an address that is not set.
    @ViewBuilder
    private func statusRow(_ status: ServerAddressStatus, prefix: String, openSettingsID: String) -> some View {
        if let (name, label) = Self.presentation(of: status) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: Self.symbol(of: status))
                    .foregroundStyle(Self.tint(of: status))
            }
            .accessibilityIdentifier("\(prefix)_\(name)")
            if name == "denied", let settingsURL {
                Button {
                    openURL(settingsURL)
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .accessibilityIdentifier(openSettingsID)
            }
        }
    }

    /// The identifier suffix and the label of a state; nil when there is nothing to show.
    private static func presentation(of status: ServerAddressStatus) -> (String, LocalizedStringKey)? {
        switch status {
        case .notConfigured: return nil
        case .checking: return ("checking", LocalizedStringKey("Checking…"))
        case .reachable: return ("reachable", LocalizedStringKey("Reachable"))
        case .unreachable: return ("unreachable", LocalizedStringKey("Unreachable for now"))
        case .notThisServer: return ("notThisServer", LocalizedStringKey("Not responding as this server"))
        case .localNetworkDenied: return ("denied", LocalizedStringKey("Local network access denied"))
        case .untrusted: return ("untrusted", LocalizedStringKey("Certificate not trusted"))
        }
    }

    private static func symbol(of status: ServerAddressStatus) -> String {
        switch status {
        case .reachable: return "checkmark.circle.fill"
        case .checking, .notConfigured: return "ellipsis.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private static func tint(of status: ServerAddressStatus) -> Color {
        switch status {
        case .reachable: return Color.immichPrimary
        case .checking, .notConfigured: return Color.textSecondaryPV
        default: return Color.immichError
        }
    }
}

/// The screen pushed from the Me hub: builds its view model once, with the
/// account the hub showed when it was opened (`CustomHeadersScreen` pattern).
struct NetworkSettingsScreen: View {
    @State private var vm: NetworkSettingsViewModel

    init(accountURL: URL, onExternalChanged: @escaping () -> Void) {
        _vm = State(initialValue: DependencyContainer.shared.makeNetworkSettingsViewModel(
            accountURL: accountURL, onExternalChanged: onExternalChanged
        ))
    }

    var body: some View {
        NetworkSettingsView(vm: vm)
    }
}
