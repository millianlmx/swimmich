import Foundation
import ImmichSharedKit
import Observation

/// Chooses, for the active account, between the local and the external address
/// of its server, and points every consumer at the one in use (L-26).
///
/// The identity of the account (`accountURL`: its connection address, which keys
/// the token, the offline copies and the caches) never changes. What changes is
/// the address the client, the socket and the image URLs use. The local address
/// is retained only when the switch is on and the address answered as THIS
/// server within `probeDeadline` (`ServerAddressSelector.choose`); every
/// automatic evaluation leaves the user signed in.
@MainActor @Observable
final class ServerEndpointSwitch: ServerEndpointSwitching {
    private(set) var accountID: String?
    private(set) var settings: ServerAddressSettings = .empty
    private(set) var activeURL: URL?
    private(set) var usesLocal = false
    private(set) var externalURL: URL?
    private(set) var localURL: URL?
    private(set) var localStatus: ServerAddressStatus = .notConfigured
    private(set) var externalStatus: ServerAddressStatus?
    private(set) var isEvaluating = false
    private(set) var lastOutcome: EvaluationOutcome?

    private let client: any ImmichClient
    private let realtime: RealtimeService
    private let store: any ServerAddressSettingsStoring
    private let probe: any ServerAddressProbing
    private let monitor: (any NetworkPathMonitoring)?
    private let addressBook: ServerAddressBook
    private let customHeaders: any CustomHeadersProviding
    private let appLog: any AppLogSink
    private let probeDeadline: Duration
    private let localNetworkDeniedOverride: Bool

    @ObservationIgnored private var accountURL: URL?
    @ObservationIgnored private var token: String?
    /// The address the socket was last connected to.
    @ObservationIgnored private var socketURL: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    @ObservationIgnored private var outcomeCounter = 0

    init(
        client: any ImmichClient, realtime: RealtimeService, store: any ServerAddressSettingsStoring,
        probe: any ServerAddressProbing, monitor: (any NetworkPathMonitoring)?,
        addressBook: ServerAddressBook, customHeaders: any CustomHeadersProviding, appLog: any AppLogSink,
        probeDeadline: Duration = .seconds(2), localNetworkDeniedOverride: Bool = false
    ) {
        self.client = client
        self.realtime = realtime
        self.store = store
        self.probe = probe
        self.monitor = monitor
        self.addressBook = addressBook
        self.customHeaders = customHeaders
        self.appLog = appLog
        self.probeDeadline = probeDeadline
        self.localNetworkDeniedOverride = localNetworkDeniedOverride
        monitor?.start { [weak self] in
            Task { @MainActor in await self?.evaluate(.networkChange) }
        }
    }

    // MARK: - Derived

    var publicURL: URL? { externalURL }

    var knownURLs: [URL] {
        var seen: [URL] = []
        for url in [accountURL, externalURL, localURL].compactMap({ $0 }) where !seen.contains(url) { seen.append(url) }
        return seen
    }

    // MARK: - Account lifecycle

    /// A new account or a new token: the only call that configures the client.
    /// The address in use starts as the external one; the local address is
    /// probed afterwards (never awaited) when the switch is on.
    func activate(accountID: String, accountURL: URL, token: String, connectRealtime: Bool) {
        generation += 1
        evaluationTask = nil
        self.accountID = accountID
        self.accountURL = accountURL
        self.token = token
        socketURL = nil
        isEvaluating = false
        externalStatus = nil
        loadSettings(accountID: accountID, accountURL: accountURL)
        activeURL = externalURL
        usesLocal = false
        client.configure(baseURL: externalURL, token: token)
        updateBook()
        learnServers()
        if connectRealtime { self.connectRealtime() }
        let probing = settings.autoSwitch && localURL != nil
        localStatus = localURL == nil ? .notConfigured : (probing ? .checking : .notConfigured)
        if probing { Task { await evaluate(.launch) } }
    }

    /// The session ended. The client and the socket are reset by the caller.
    func deactivate() {
        generation += 1
        evaluationTask = nil
        accountID = nil
        accountURL = nil
        token = nil
        socketURL = nil
        activeURL = nil
        externalURL = nil
        localURL = nil
        usesLocal = false
        isEvaluating = false
        localStatus = .notConfigured
        externalStatus = nil
        settings = .empty
        addressBook.clear()
    }

    func connectRealtime() {
        guard let activeURL, let token else { return }
        realtime.connect(baseURL: activeURL, token: token)
        socketURL = activeURL
    }

    func reconnectRealtime() { connectRealtime() }

    func forget(accountID: String) { store.remove(for: accountID) }

    func forgetAll() { store.removeAll() }

    // MARK: - Known version

    /// The last server version read for the active account, the reference the
    /// local address must match when the external one is mute.
    func recordVersion(_ version: String) {
        guard let accountID, settings.lastKnownVersion != version else { return }
        settings.lastKnownVersion = version
        store.save(settings, for: accountID)
    }

    /// Reads the version on the address in use (the external address, or a local
    /// one already retained: never an unverified address) and records it.
    func refreshKnownVersion() async {
        guard let id = accountID else { return }
        guard let version = try? await client.serverVersion() else { return }
        guard accountID == id else { return }
        recordVersion("\(version.major).\(version.minor).\(version.patch)")
    }

    // MARK: - Settings

    func save(_ new: ServerAddressSettings) async {
        // A change of settings makes the result of any evaluation already running
        // obsolete (it measured the old addresses): it must not write its state.
        generation += 1
        evaluationTask = nil
        isEvaluating = false
        guard let accountID, let accountURL else { return }
        let oldExternal = externalURL
        let before = activeURL
        var next = new
        if next.lastKnownVersion == nil { next.lastKnownVersion = settings.lastKnownVersion }
        store.save(next, for: accountID)
        loadSettings(accountID: accountID, accountURL: accountURL, settings: next)
        updateBook()
        learnServers()
        let hasLocal = localURL != nil
        if !(settings.autoSwitch && hasLocal) {
            applyExternal(reconnectSocket: true)
            finishOutcome(before: before)
            // The external address is probed once when it changed, and again when its last
            // state was "certificate not trusted" (the user has just approved it).
            var wasUntrusted = false
            if case .untrusted? = externalStatus { wasUntrusted = true }
            if !hasLocal, externalURL != oldExternal || wasUntrusted, let external = externalURL {
                let gen = generation
                isEvaluating = true
                externalStatus = .checking
                let result = await Self.bounded(probe, url: external, headers: customHeaders.headers(for: accountURL), deadline: probeDeadline)
                guard gen == generation else { return }
                externalStatus = ServerAddressSelector.status(external: result)
                if case .immich(let version) = result { recordVersion(version) }
                isEvaluating = false
            }
        }
        if hasLocal { await evaluate(.settingsChanged) }
    }

    // MARK: - Evaluation

    func evaluate(_ reason: EvaluationReason) async {
        guard accountID != nil, accountURL != nil else { return }
        let probing = settings.autoSwitch && localURL != nil
        if !probing && !(reason == .settingsChanged && localURL != nil) {
            // B-30.7: no probe. Whatever was in use, the external address is.
            if let external = externalURL, activeURL != external {
                let before = activeURL
                applyExternal(reconnectSocket: true)
                finishOutcome(before: before)
            }
            return
        }
        switch reason {
        case .launch, .foreground, .backgroundPass:
            if let running = evaluationTask {
                await running.value
                return
            }
        case .networkChange, .settingsChanged:
            break
        }
        generation += 1
        let gen = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runEvaluation(reason, generation: gen)
        }
        evaluationTask = task
        await task.value
    }

    private func runEvaluation(_ reason: EvaluationReason, generation gen: Int) async {
        guard let accountURL, let externalURL else { return }
        let before = reason == .launch ? externalURL : activeURL
        isEvaluating = true
        localStatus = .checking
        // (2) While the local address is measured, requests go to the external one.
        if settings.autoSwitch {
            client.retarget(baseURL: externalURL)
            activeURL = externalURL
            usesLocal = false
            updateBook()
        }
        // (3) Both addresses, in parallel, each bounded by the deadline.
        let headers = customHeaders.headers(for: accountURL)
        let probe = self.probe
        let deadline = probeDeadline
        let localURL = self.localURL
        let denied = localNetworkDeniedOverride
        async let localProbe = Self.localResult(probe, url: localURL, denied: denied, headers: headers, deadline: deadline)
        async let externalProbe = Self.bounded(probe, url: externalURL, headers: headers, deadline: deadline)
        let (localResult, externalResult) = await (localProbe, externalProbe)
        // (4) A newer evaluation, a new account or a sign-out owns the state now.
        guard gen == generation else { return }
        // (5)
        var externalVersion: String?
        if case .immich(let version) = externalResult {
            externalVersion = version
            recordVersion(version)
        }
        // (6)
        let choice = ServerAddressSelector.choose(
            settings: settings, accountURL: accountURL, local: localResult, externalVersion: externalVersion
        )
        if let localResult {
            localStatus = ServerAddressSelector.status(
                local: localResult, reference: externalVersion ?? settings.lastKnownVersion
            )
        } else {
            localStatus = .notConfigured
        }
        externalStatus = ServerAddressSelector.status(external: externalResult)
        // (7) With the switch off the address in use does not move.
        if settings.autoSwitch {
            client.retarget(baseURL: choice.url)
            activeURL = choice.url
            usesLocal = choice.usesLocal
            updateBook()
            if let socketURL, socketURL != choice.url { connectRealtime() }
        }
        // (8)
        finishOutcome(before: before)
        isEvaluating = false
        if gen == generation { evaluationTask = nil }
    }

    // MARK: - Helpers

    private func loadSettings(accountID: String, accountURL: URL, settings loaded: ServerAddressSettings? = nil) {
        let value = loaded ?? store.settings(for: accountID)
        settings = value
        externalURL = ServerAddressSelector.externalURL(settings: value, accountURL: accountURL)
        if let raw = value.localURL, case .valid(let url) = ServerAddressInput.normalized(raw) {
            localURL = url
        } else {
            localURL = nil
        }
        if localURL == nil { localStatus = .notConfigured }
    }

    /// Back on the external address (switch off, no local address, or the
    /// external address just changed).
    private func applyExternal(reconnectSocket: Bool) {
        guard let externalURL else { return }
        client.retarget(baseURL: externalURL)
        activeURL = externalURL
        usesLocal = false
        updateBook()
        if reconnectSocket, let socketURL, socketURL != externalURL { connectRealtime() }
    }

    private func finishOutcome(before: URL?) {
        outcomeCounter += 1
        lastOutcome = EvaluationOutcome(id: outcomeCounter, changedAddress: activeURL != before)
    }

    private func updateBook() {
        addressBook.update(accountURL: accountURL, addresses: [externalURL, localURL].compactMap { $0 }, activeURL: activeURL)
    }

    private func learnServers() {
        for url in [accountURL, externalURL, localURL].compactMap({ $0 }) { appLog.learnServer(url) }
    }

    /// The local probe, or nothing when no local address is declared, or the
    /// system refused the local network (test switch).
    private nonisolated static func localResult(
        _ probe: any ServerAddressProbing, url: URL?, denied: Bool, headers: [CustomHTTPHeader], deadline: Duration
    ) async -> ServerAddressProbeResult? {
        guard let url else { return nil }
        if denied { return .localNetworkDenied }
        return await bounded(probe, url: url, headers: headers, deadline: deadline)
    }

    /// The probe, raced against its own deadline (+ 0.1 s): an implementation
    /// that never answers cannot hold an evaluation.
    private nonisolated static func bounded(
        _ probe: any ServerAddressProbing, url: URL, headers: [CustomHTTPHeader], deadline: Duration
    ) async -> ServerAddressProbeResult {
        await withTaskGroup(of: ServerAddressProbeResult.self) { group in
            group.addTask { await probe.probe(url, headers: headers, deadline: deadline) }
            group.addTask {
                try? await Task.sleep(for: deadline + .milliseconds(100))
                return .unreachable
            }
            let first = await group.next() ?? .unreachable
            group.cancelAll()
            return first
        }
    }
}
