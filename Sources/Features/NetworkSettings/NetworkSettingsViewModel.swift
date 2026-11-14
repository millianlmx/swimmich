import Foundation
import ImmichSharedKit
import Observation

/// The "Network" setting of the active account (L-26): the local and the
/// external address of its server, the automatic switch between them, the state
/// of each address and the address in use.
///
/// It edits nothing itself: every change goes through `ServerEndpointSwitching.save`,
/// which stores it, applies it and measures the addresses.
@Observable @MainActor
final class NetworkSettingsViewModel {
    private let endpoints: any ServerEndpointSwitching
    private let trustStore: TrustedServerStore
    private let accountURL: URL
    private let onExternalChanged: () -> Void

    /// Shows the "Simulate network change" control (UI tests only).
    let showsTestControls: Bool

    var localText: String
    var externalText: String
    private(set) var autoSwitch: Bool
    private(set) var localValidationMessage: String?
    private(set) var externalValidationMessage: String?
    /// The host whose certificate cannot be verified, until the user answers.
    var pendingUntrustedHost: String?
    private(set) var isSaving = false

    init(
        endpoints: any ServerEndpointSwitching, trustStore: TrustedServerStore, accountURL: URL,
        showsTestControls: Bool, onExternalChanged: @escaping () -> Void
    ) {
        self.endpoints = endpoints
        self.trustStore = trustStore
        self.accountURL = accountURL
        self.showsTestControls = showsTestControls
        self.onExternalChanged = onExternalChanged
        localText = endpoints.settings.localURL ?? ""
        externalText = (endpoints.externalURL ?? accountURL).absoluteString
        autoSwitch = endpoints.settings.autoSwitch
    }

    // MARK: - Read from the service

    var localStatus: ServerAddressStatus { endpoints.localStatus }
    var externalStatus: ServerAddressStatus? { endpoints.externalStatus }
    var activeAddressText: String { (endpoints.activeURL ?? accountURL).absoluteString }
    var usesLocal: Bool { endpoints.usesLocal }

    // MARK: - Edits

    func saveLocal() async {
        localValidationMessage = nil
        var settings = endpoints.settings
        switch ServerAddressInput.normalized(localText) {
        case .invalid:
            localValidationMessage = String(localized: "Enter a valid server URL.")
            return
        case .empty:
            settings.localURL = nil
        case .valid(let url):
            settings.localURL = url.absoluteString
            localText = url.absoluteString
        }
        await persist(settings)
        if case .untrusted(let host) = localStatus { pendingUntrustedHost = host }
    }

    func saveExternal() async {
        externalValidationMessage = nil
        var settings = endpoints.settings
        switch ServerAddressInput.normalized(externalText) {
        case .invalid:
            externalValidationMessage = String(localized: "Enter a valid server URL.")
            return
        case .empty:
            settings.externalURL = nil
            externalText = accountURL.absoluteString
        case .valid(let url):
            // The connection address is the default: typing it back clears the override.
            settings.externalURL = url.absoluteString == accountURL.absoluteString ? nil : url.absoluteString
            externalText = url.absoluteString
        }
        await persist(settings)
        onExternalChanged()
        if case .untrusted(let host)? = externalStatus { pendingUntrustedHost = host }
    }

    func setAutoSwitch(_ value: Bool) async {
        autoSwitch = value
        var settings = endpoints.settings
        settings.autoSwitch = value
        await persist(settings)
    }

    /// The user accepted the certificate of `pendingUntrustedHost`: remember it
    /// and measure the addresses again.
    func trustPendingHost() async {
        guard let host = pendingUntrustedHost else { return }
        trustStore.add(host)
        pendingUntrustedHost = nil
        await persist(endpoints.settings)
    }

    /// Re-measures the addresses when the screen opens. A gesture of the user,
    /// so it may probe even with the switch off; nothing is changed.
    func refreshStatus() async {
        guard endpoints.settings.localURL != nil else { return }
        await endpoints.evaluate(.settingsChanged)
    }

    /// Test only: behaves as if the device had changed network.
    func simulateNetworkChange() async {
        guard showsTestControls else { return }
        await endpoints.evaluate(.networkChange)
    }

    private func persist(_ settings: ServerAddressSettings) async {
        isSaving = true
        await endpoints.save(settings)
        isSaving = false
    }
}
