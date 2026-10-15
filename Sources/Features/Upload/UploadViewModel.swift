import Foundation
import Photos
import SwiftUI
import UIKit

/// How the album sets scope a backup. A single mode picked by the user — the
/// two sets below never both apply, which is what made the previous pair of
/// "Albums to back up" / "Albums to skip" links contradictory (selecting album
/// X and excluding album X is a run that backs up nothing, and nothing in the
/// UI said so).
enum BackupAlbumScope: String, CaseIterable, Sendable {
    /// Everything in the library.
    case all
    /// Only the albums in `selectedAlbumIDs`.
    case selected
    /// Everything except the albums in `excludedAlbumIDs`.
    case excluded
}

/// Persisted backup preferences, stored in an injectable UserDefaults suite
/// ("backupSettings" in production, per-test suites in unit tests).
@Observable
@MainActor
final class BackupSettingsStore {
    @ObservationIgnored let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    var onlyOnWiFi: Bool {
        didSet { defaults.set(onlyOnWiFi, forKey: Self.wifiKey) }
    }

    var onlyWhenCharging: Bool {
        didSet { defaults.set(onlyWhenCharging, forKey: Self.chargingKey) }
    }

    /// Under "Wi-Fi only", whether photos may still go up over cellular. The
    /// answer is per media kind because the cost is: a photo is a few MB, a
    /// video can be GBs. Without these the choice was all-or-nothing.
    var allowCellularForPhotos: Bool {
        didSet { defaults.set(allowCellularForPhotos, forKey: Self.cellularPhotosKey) }
    }

    var allowCellularForVideos: Bool {
        didSet { defaults.set(allowCellularForVideos, forKey: Self.cellularVideosKey) }
    }

    var autoDetectNewPhotos: Bool {
        didSet { defaults.set(autoDetectNewPhotos, forKey: Self.autoDetectNewPhotosKey) }
    }

    /// "Show backup status on thumbnails" (G6). Off by default: the badge is a
    /// statement about the server, and asking for it is a choice — the tiles
    /// stay bare until the user does.
    var showSyncBadge: Bool {
        didSet { defaults.set(showSyncBadge, forKey: Self.showSyncBadgeKey) }
    }

    /// Which album set applies. Only one is ever in force, so the two sets can
    /// no longer contradict each other.
    var albumScope: BackupAlbumScope {
        didSet { defaults.set(albumScope.rawValue, forKey: Self.albumScopeKey) }
    }

    /// Albums a `.selected` run is limited to. User albums are Photos
    /// `localIdentifier`s, smart albums are `BackupAlbum.SmartID` values.
    /// Kept even while another scope is active, so switching modes back and
    /// forth doesn't lose the picks.
    var selectedAlbumIDs: Set<String> {
        didSet { defaults.set(Array(selectedAlbumIDs), forKey: Self.albumsKey) }
    }

    /// Albums an `.excluded` run skips over.
    var excludedAlbumIDs: Set<String> {
        didSet { defaults.set(Array(excludedAlbumIDs), forKey: Self.excludedAlbumsKey) }
    }

    /// Albums mirrored one-way into server albums of the same name. Orthogonal
    /// to `albumScope`: the scope chooses what is backed up, this chooses where
    /// an uploaded photo is filed. Dedicated key, default empty — nobody's
    /// backup changes behavior by installing this version.
    var syncedAlbumIDs: Set<String> {
        didSet { defaults.set(Array(syncedAlbumIDs), forKey: Self.syncedAlbumsKey) }
    }

    static let enabledKey = "photoBackupEnabled"
    static let wifiKey = "photoBackupOnlyWiFi"
    static let chargingKey = "photoBackupOnlyCharging"
    static let cellularPhotosKey = "photoBackupCellularPhotos"
    static let cellularVideosKey = "photoBackupCellularVideos"
    static let albumScopeKey = "photoBackupAlbumScope"
    static let albumsKey = "photoBackupSelectedAlbums"
    static let excludedAlbumsKey = "photoBackupExcludedAlbums"
    static let autoDetectNewPhotosKey = "photoBackupAutoDetectNewPhotos"
    static let showSyncBadgeKey = "photoBackupShowSyncBadge"
    static let syncedAlbumsKey = "photoBackupSyncedAlbums"

    /// Legacy keys, read once for the one-shot migration and then deleted.
    /// The old screenshots toggle becomes the Screenshots smart album; the
    /// other two are dropped without an equivalent — the filename heuristics
    /// behind them were wrong on iOS (`!hasPrefix("IMG_")` excluded nearly the
    /// whole camera roll, `!contains("WhatsApp")` filtered nothing).
    static let legacyScreenshotsKey = "photoBackupExcludeScreenshots"
    static let legacyCameraRollKey = "photoBackupExcludeCameraRoll"
    static let legacyWhatsAppKey = "photoBackupExcludeWhatsApp"

    init(suiteName: String = "backupSettings") {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        onlyOnWiFi = defaults.bool(forKey: Self.wifiKey)
        onlyWhenCharging = defaults.bool(forKey: Self.chargingKey)
        allowCellularForPhotos = defaults.bool(forKey: Self.cellularPhotosKey)
        allowCellularForVideos = defaults.bool(forKey: Self.cellularVideosKey)
        autoDetectNewPhotos = defaults.bool(forKey: Self.autoDetectNewPhotosKey)
        showSyncBadge = defaults.bool(forKey: Self.showSyncBadgeKey)
        let selected = Set(defaults.stringArray(forKey: Self.albumsKey) ?? [])
        selectedAlbumIDs = selected
        let excluded: Set<String>
        if let stored = defaults.stringArray(forKey: Self.excludedAlbumsKey) {
            excluded = Set(stored)
        } else {
            // One-shot migration from the old "Exclude screenshots" toggle.
            excluded = defaults.bool(forKey: Self.legacyScreenshotsKey)
                ? [BackupAlbum.SmartID.screenshots]
                : []
        }
        excludedAlbumIDs = excluded
        syncedAlbumIDs = Set(defaults.stringArray(forKey: Self.syncedAlbumsKey) ?? [])
        if let raw = defaults.string(forKey: Self.albumScopeKey),
           let stored = BackupAlbumScope(rawValue: raw) {
            albumScope = stored
        } else {
            // Before the mode existed both sets applied at once, so an existing
            // install has to be resolved into one. An exclusion wins: it is the
            // one that made the run differ from "the whole library", and it is
            // what the old "Exclude screenshots" toggle migrated into.
            albumScope = !excluded.isEmpty ? .excluded : (selected.isEmpty ? .all : .selected)
        }
        defaults.removeObject(forKey: Self.legacyScreenshotsKey)
        defaults.removeObject(forKey: Self.legacyCameraRollKey)
        defaults.removeObject(forKey: Self.legacyWhatsAppKey)
    }

    /// The scope actually in force. "Only selected" with nothing picked cannot
    /// be expressed to the engine — an empty inclusion set means "the whole
    /// library" — so it degrades to `.all`, which the settings screen states
    /// outright rather than backing up something the user didn't ask for in
    /// silence.
    var effectiveAlbumScope: BackupAlbumScope {
        albumScope == .selected && selectedAlbumIDs.isEmpty ? .all : albumScope
    }

    /// Snapshot the current prefs; the engine runs against a frozen copy. Only
    /// the active scope's set is carried over, so the engine never has to
    /// arbitrate between an inclusion and an exclusion list — while the mirror
    /// set rides along untouched: it is not a scope, and a manual run must
    /// mirror exactly like an automatic one.
    func snapshot() -> BackupSettings {
        let inForce = effectiveAlbumScope
        return BackupSettings(
            isEnabled: isEnabled,
            autoDetectNewPhotos: autoDetectNewPhotos,
            onlyOnWiFi: onlyOnWiFi,
            onlyWhenCharging: onlyWhenCharging,
            allowCellularForPhotos: allowCellularForPhotos,
            allowCellularForVideos: allowCellularForVideos,
            excludedAlbumIDs: inForce == .excluded ? excludedAlbumIDs : [],
            selectedAlbumIDs: inForce == .selected ? selectedAlbumIDs : [],
            showSyncBadge: showSyncBadge,
            syncedAlbumIDs: syncedAlbumIDs
        )
    }
}

/// Holds a UIKit background assertion for the length of a backup run and
/// releases it exactly once — from the OS expiration handler or from the
/// caller. Without it, a run started in the foreground is suspended within a
/// second of the app being backgrounded: the engine freezes mid-asset and the
/// Live Activity stops moving in the Dynamic Island. When the grace window
/// runs out we only release the assertion — the engine keeps its state and the
/// island keeps showing where the run got to; it resumes on the next
/// activation or in the next BGTask window.
@MainActor
final class BackupBackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            release()
        }
    }

    func release() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
/// Record of a completed backup run for upload history display.
struct UploadHistoryEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date: Date
    let uploaded: Int
    let total: Int
    let failed: Int
    let success: Bool
}

/// Upload / backup view model — thin glue between the engine, the settings
/// store and the scheduler. The testable logic lives in `BackupEngine`.
@Observable
@MainActor
final class UploadViewModel {
    let client: any ImmichClient
    let photos: any PhotoLibraryService
    let engine: BackupEngine
    var settings: BackupSettingsStore
    let scheduler: any BackgroundBackupScheduling
    let activityService: any BackupLiveActivityServicing
    let notifications: any NotificationServicing
    /// Thumbnail badge mirror (G6). Optional: a VM built without an index has
    /// no badge to gate, and the setting simply writes itself to disk.
    @ObservationIgnored let cloudStatus: CloudBackupStatusIndex?
    /// Read-only mode (gap G17). A backup *writes*: while the mode is on the
    /// run is refused before it starts, so a whole pass reports one refusal
    /// instead of failing `uploadAsset` once per candidate. The client guard
    /// would refuse every one of those calls anyway — this is the gate that
    /// explains itself first.
    let readOnly: ReadOnlyModeStore

    var albums: [BackupAlbum] = []

    // Resume state
    var canResume: Bool {
        engine.phase == .done || engine.phase == .cancelled
    }

    // History
    var uploadHistory: [UploadHistoryEntry] = []
    var lastBackupResult: (uploaded: Int, total: Int, failed: Int)?
    /// Drives the "Reset backup tracking" confirmation dialog.
    var showResetTrackingConfirm: Bool = false

    /// Handle to the in-flight backup started by `resumeUpload` (which must
    /// return immediately for the UI). Lets callers/tests await it.
    @ObservationIgnored private(set) var currentBackupTask: Task<Void, Never>?

    init(
        client: any ImmichClient,
        photos: any PhotoLibraryService,
        engine: BackupEngine? = nil,
        ledger: (any BackupLedgerStoring)? = nil,
        settings: BackupSettingsStore? = nil,
        scheduler: any BackgroundBackupScheduling = BGTaskBackupScheduler(),
        activityService: any BackupLiveActivityServicing = LiveActivityBackupService(),
        notifications: any NotificationServicing = NotificationService(),
        cloudStatus: CloudBackupStatusIndex? = nil,
        albumSync: (any AlbumSyncServicing)? = nil,
        // Defaulted rather than required: a caller that does not know the mode
        // (a test, a future preview) still gets a real store. `nil` because a
        // default argument is evaluated in the caller's context, which is not
        // the main actor — the store is built here instead.
        readOnly: ReadOnlyModeStore? = nil,
        userID: (@MainActor () -> String?)? = nil
    ) {
        self.client = client
        self.photos = photos
        self.engine = engine ?? BackupEngine(
            client: client,
            source: (photos as? BackupAssetSource) ?? PhotoLibraryServiceImpl(),
            ledger: ledger ?? BackupLedger.persistent(),
            albumSync: albumSync,
            userID: userID
        )
        self.settings = settings ?? BackupSettingsStore()
        self.scheduler = scheduler
        self.activityService = activityService
        self.notifications = notifications
        self.cloudStatus = cloudStatus
        self.readOnly = readOnly ?? ReadOnlyModeStore()
    }

    /// Pushes the "Show backup status on thumbnails" preference into the badge
    /// index — the badge's only gate. Called once at composition (so a
    /// relaunch restores the choice before the first tile is drawn) and on
    /// every toggle flip.
    func syncBadgeIndex() {
        cloudStatus?.setEnabled(settings.snapshot().showSyncBadge)
    }

    var running: Bool {
        engine.phase == .checking || engine.phase == .uploading
    }

    /// Requests Photos read access. Returns true once authorized/limited.
    /// Manual runs call this first — without it `fetchCandidates` silently
    /// returns nothing and the run "does nothing".
    private func ensurePhotoAccess() async -> Bool {
        let status = photos.authorizationStatus()
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                photos.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Photo access with a user-visible consequence: prompts when not
    /// determined; sends the user to the system settings when denied, so a
    /// silently-dead "Auto backup" toggle is impossible (the previous
    /// behavior: requestAuthorization resolves denied → no submit → the
    /// automatic chain never starts, no error shown anywhere).
    func requestPhotoAccessThenOpenDenied() {
        let status = photos.authorizationStatus()
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            photos.requestAuthorization { status in
                Task { @MainActor in
                    if status == .denied || status == .restricted {
                        self.openPhotoSettings()
                    }
                }
            }
        default:
            openPhotoSettings()
        }
    }

    private func openPhotoSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Runs the backup. `manual` (Run now / resume / retry) bypasses the
    /// automatic gates and first secures Photos access; the unattended BGTask
    /// path passes `manual: false`.
    ///
    /// `only` names the assets to run over — the two retry actions below.
    /// Everything else about the run (background assertion, Live Activity,
    /// completion notification, history entry) is the *same* code: a retry with
    /// its own envelope would be a run without an island and without a history
    /// entry, and the two would drift apart.
    func runBackup(
        overrideSettings: BackupSettings? = nil,
        manual: Bool = false,
        only assetIDs: [String] = []
    ) async {
        // Read-only mode: ONE refusal for the whole run — the manual CTA and
        // the automatic chain both come through this method — instead of a
        // failed `uploadAsset` per candidate.
        guard !readOnly.isEnabled else {
            engine.reportError(String(localized: "Read-only mode is on. Turn it off in Me to change your library."))
            return
        }
        if manual {
            guard await ensurePhotoAccess() else {
                engine.reportError("Photo library access is required to back up.")
                return
            }
        }
        // Fire-and-forget: the run must not wait for the user to answer the
        // prompt, and the result only matters when the run ends.
        Task { await notifications.requestAuthorization() }
        // Survive the app being backgrounded mid-run: the engine keeps
        // exporting/uploading (and the island keeps moving) for as long as the
        // OS grants us, instead of freezing the instant the user swipes away.
        let assertion = BackupBackgroundAssertion(name: "immich.backup")
        defer { assertion.release() }
        engine.onProgressUpdate = { [weak self] _, _ in
            guard let self else { return }
            self.activityService.update(self.makeActivitySnapshot())
        }
        activityService.start(makeActivitySnapshot())
        let started = await engine.run(
            settings: overrideSettings ?? settings.snapshot(),
            manual: manual,
            only: assetIDs
        )
        engine.onProgressUpdate = nil
        guard started else {
            // An automatic gate rejected the run (disabled / no Wi-Fi / not
            // charging) or another run already owns the engine. In the gate
            // case the activity we just requested has nothing to report: end
            // it now, or it lingers for hours at "Scanning… 0%" and the next
            // real run inherits a stale island. When the engine is still
            // running, that other run owns the island — leave it alone.
            if !running {
                activityService.end(success: false, snapshot: makeActivitySnapshot())
            }
            return
        }
        switch engine.phase {
        case .done:
            let success = engine.failedCount == 0
            activityService.end(success: success, snapshot: makeActivitySnapshot())
            await notifications.notifyBackupComplete(
                uploaded: engine.uploadedCount,
                total: engine.total,
                failed: engine.failedCount,
                success: success
            )
            // Keeps the automatic chain self-perpetuating while auto-backup
            // is on — including after a manual run, which heals a chain the
            // OS dropped (e.g. the process was killed mid-window).
            if settings.isEnabled {
                scheduler.submit()
            }
            // Record history
            uploadHistory.append(UploadHistoryEntry(
                date: Date(),
                uploaded: engine.uploadedCount,
                total: engine.total,
                failed: engine.failedCount,
                success: success
            ))
            lastBackupResult = (engine.uploadedCount, engine.total, engine.failedCount)
            // Keep last 10 entries
            if uploadHistory.count > 10 {
                uploadHistory = uploadHistory.suffix(10)
            }
        case .cancelled:
            activityService.end(success: false, snapshot: makeActivitySnapshot())
        default:
            break
        }
    }

    func cancelBackup() {
        engine.cancel()
    }

    /// Number of assets the last run couldn't finish — the badge the "Upload
    /// details" row carries. It counts the failure rows rather than
    /// `engine.failedCount`: a Live Photo whose still is on the server but whose
    /// link failed is listed too, and the badge must not promise fewer rows than
    /// the screen shows.
    var failedAssetCount: Int { engine.failures.count }

    /// Retries one asset: a run restricted to that Photos identifier, so a
    /// single failed photo no longer costs a whole-library scan. The asset is
    /// still hashed and dedup-checked like any other — the restriction is about
    /// which assets the run looks at, never about skipping the server's answer.
    func retryAsset(id: String) async {
        await runBackup(manual: true, only: [id])
    }

    /// Retries every asset the last run failed, in ONE restricted run.
    /// Nothing failed ⇒ no run at all: an empty `only` reads as "the whole
    /// library" to the engine, which is the opposite of a retry.
    func retryAllFailed() async {
        let ids = engine.failures.map(\.assetID)
        guard !ids.isEmpty else { return }
        await runBackup(manual: true, only: ids)
    }


    /// Foreground-triggered automatic pass — the "Auto-detect new photos"
    /// behavior: on every scene activation, run a (gated) scan when the
    /// user opted in. The run is NOT manual: Wi-Fi-only / charging-only
    /// still apply. When the toggle is off, only the OS background window
    /// triggers runs (the pending request is kept alive on activation).
    func kickOffAutoBackupIfConfigured() async {
        guard settings.autoDetectNewPhotos, !running else { return }
        guard await ensurePhotoAccess() else { return }
        currentBackupTask = Task { await runBackup(manual: false) }
    }

    /// Resume upload from where it left off (used when interrupted).
    func resumeUpload() {
        currentBackupTask = Task { await runBackup(manual: true) }
    }

    /// Awaits the in-flight backup task, if any (test/coordination helper).
    func awaitCurrentBackup() async {
        await currentBackupTask?.value
    }

    func loadAlbums() {
        albums = engine.source.fetchAlbums()
    }

    /// Assets the ledger currently tracks as already backed up.
    var trackedAssetCount: Int { engine.trackedAssetCount }

    /// Clears the backup ledger so the next run re-checks the whole library.
    /// Needed when the server library was wiped and the ledger is now stale.
    func resetBackupTracking() {
        engine.forgetAllBackedUp()
    }

    /// When the ledger was last confronted with the server (nil = never).
    var lastReconciliation: Date? { engine.lastReconciliation }

    /// Confronts the ledger with the server right now, ignoring the weekly
    /// throttle. Non-destructive: it only forgets entries the server no longer
    /// has, so those get re-uploaded instead of being skipped forever.
    func reconcileNow() async {
        await engine.reconcileNow()
    }

    // MARK: - Album mirror (device → server)

    /// What the mirror did, published by the engine (nil while it is off).
    var albumSyncOutcome: AlbumSyncOutcome? { engine.albumSyncOutcome }

    /// True while the catch-up pass runs. Its own lock on top of `running`, so
    /// two taps can't put two writers on the mirror's buffer.
    var isReorganizing = false

    /// Message of a failed catch-up, shown in an alert and cleared by its OK.
    var albumSyncError: String?

    /// "Reorganize into album" needs something to reorganize: a mirrored album
    /// to file into, and a ledger with assets that were backed up before the
    /// mirror existed.
    var canReorganize: Bool {
        !settings.syncedAlbumIDs.isEmpty && trackedAssetCount > 0
    }

    /// One line for the settings screen: what the mirror did, plus the first
    /// error when something failed. Nil while nothing has been mirrored.
    var albumSyncSummary: String? {
        guard let outcome = engine.albumSyncOutcome else { return nil }
        let counts = String(
            localized: "\(outcome.added) added · \(outcome.alreadyInAlbum) already there · \(outcome.failed) failed"
        )
        guard let error = outcome.lastError else { return counts }
        return "\(counts) — \(error)"
    }

    /// Sorts the assets an earlier run already uploaded into the mirrored
    /// albums. Reads the ledger and hands it to the engine — the view layer
    /// never speaks to the album API itself, so exactly one path writes into an
    /// album (the engine's mirror), and nothing is ever re-uploaded here.
    func reorganizeIntoAlbums() async {
        guard canReorganize, !running, !isReorganizing else { return }
        let entries = engine.entriesForReconciliation()
        guard !entries.isEmpty else { return }
        isReorganizing = true
        defer { isReorganizing = false }
        let outcome = await engine.reorganizeAlbums(
            entries: entries,
            syncedDeviceAlbumIDs: settings.syncedAlbumIDs
        )
        albumSyncError = outcome.failed > 0 ? outcome.lastError : nil
    }

    /// Reduces the engine's observable state to one Live Activity frame:
    /// progress + outcome breakdown + phase + in-flight file + ETA.
    private func makeActivitySnapshot() -> BackupActivitySnapshot {
        let phase: BackupActivityAttributes.Phase = switch engine.phase {
        case .checking, .idle: .checking // idle at start(): a scan is imminent
        case .uploading: .uploading
        case .done: .done
        case .cancelled: .cancelled
        }
        return BackupActivitySnapshot(
            phase: phase,
            progress: engine.progressFraction,
            processed: engine.examinedCount,
            total: engine.total,
            uploaded: engine.uploadedCount,
            onServer: engine.rejectedCount,
            waiting: engine.deferredCount,
            failed: engine.failedCount,
            fileName: engine.currentFileName,
            estimatedDone: engine.estimatedSecondsRemaining.map {
                Date.now.addingTimeInterval(TimeInterval($0))
            }
        )
    }
}

/// Backup settings screen — the real backup UI (was a scaffold).
struct BackupSettingsView: View {
    @Environment(AuthViewModel.self) private var auth
    /// Read-only mode (gap G17): the run CTA is the one control that greys out
    /// instead of disappearing, explained by its own footer.
    @Environment(ReadOnlyModeStore.self) private var readOnly

    @State var vm: UploadViewModel
    /// The per-asset report of the same run — built from `vm`'s engine, not a
    /// second one (see `DependencyContainer.upload`).
    @State var detail: UploadDetailViewModel

    var body: some View {
        @Bindable var vm = vm
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: auth.serverURLString)
                    LabeledContent("User", value: auth.userEmail ?? "—")
                }
                backupSection
                albumSection
                reorganizeSection
                progressSection
                trackingSection
                serverCheckSection
                resetTrackingSection
            }
            .navigationTitle(Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ImmichAppBar(title: "Backup")
                }
            }
            .task {
                vm.loadAlbums()
            }
            .confirmationDialog(
                "Reset backup tracking?",
                isPresented: $vm.showResetTrackingConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset tracking", role: .destructive) {
                    vm.resetBackupTracking()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The next backup will re-check every photo against the server. Nothing is deleted — already-uploaded photos are simply skipped again.")
            }
            .alert(
                "Reorganization failed",
                isPresented: Binding(
                    get: { vm.albumSyncError != nil },
                    set: { if !$0 { vm.albumSyncError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { vm.albumSyncError = nil }
            } message: {
                Text(vm.albumSyncError ?? "")
            }
        }
    }

    /// What Immich has recorded as backed up. Read-only: the two actions that
    /// change it live in their own sections, each with its own explanation.
    @ViewBuilder
    private var trackingSection: some View {
        Section {
            LabeledContent("Tracked photos", value: "\(vm.trackedAssetCount)")
        } header: {
            Text("Backup tracking")
        } footer: {
            Text("Immich remembers which photos are already backed up so it never re-reads your whole iCloud library on every run. A photo stays on this list until the server is found to no longer have it.")
        }
    }

    /// The non-destructive half of tracking maintenance: compare the local list
    /// with the server and forget what the server lost.
    @ViewBuilder
    private var serverCheckSection: some View {
        Section {
            LabeledContent("Last server check", value: lastServerCheckText)
            Button {
                Task { await vm.reconcileNow() }
            } label: {
                Label("Check server now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(vm.running)
            .accessibilityIdentifier("reconcileNowButton")
        } header: {
            Text("Server check")
        } footer: {
            Text("Asks the server which of your tracked photos it still has. Nothing is uploaded or downloaded — it is a list comparison, so it is quick even on a large library. Photos you deleted on the server are forgotten here, so the next backup uploads them again. Immich does this automatically about once a week; run it by hand after deleting photos on the server, so they come back without waiting for the next backup.")
        }
    }

    /// The catch-up action for assets uploaded before the mirror was turned on:
    /// one section, one button — modelled on `serverCheckSection`, the
    /// non-destructive maintenance action already in this Form.
    ///
    /// No `NavigationStack` here: `BackupSettingsView` wraps its own `Form` in
    /// one, and a second would draw a second bar.
    @ViewBuilder
    private var reorganizeSection: some View {
        Section {
            if let summary = vm.albumSyncSummary {
                LabeledContent("In albums", value: summary)
            }
            Button {
                Task { await vm.reorganizeIntoAlbums() }
            } label: {
                Label("Reorganize into album", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(!vm.canReorganize || vm.running || vm.isReorganizing)
            .accessibilityIdentifier("backupReorganizeButton")
        } header: {
            Text("Album mirror")
        } footer: {
            Text("Files the photos you backed up before turning the mirror on into their albums. It reads your backup list and asks the server which photos it already has — nothing is uploaded again, and nothing is deleted.")
        }
    }

    /// The destructive half: drop the whole list.
    @ViewBuilder
    private var resetTrackingSection: some View {
        Section {
            Button(role: .destructive) {
                vm.showResetTrackingConfirm = true
            } label: {
                Label("Reset backup tracking", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(Color.immichError)
            }
            .accessibilityIdentifier("resetTrackingButton")
        } footer: {
            Text("Forgets every photo Immich has recorded as backed up — the tracked count goes to zero. The next backup then re-checks the whole library against the server. Nothing is deleted from Immich or from Photos, and already-uploaded photos are skipped again, but on an iCloud-optimized library the re-check reads a lot of metadata and can take a long time. Prefer \"Check server now\" when only a few photos are missing.")
        }
    }

    private var lastServerCheckText: String {
        guard let date = vm.lastReconciliation else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var backupSection: some View {
        @Bindable var vm = vm
        Section {
            Toggle("Auto backup", isOn: $vm.settings.isEnabled)
                .onChange(of: vm.settings.isEnabled) { _, newValue in
                    if newValue {
                        // Ask for Photos access (prompt when .notDetermined,
                        // bounce to Settings when denied) AND start the
                        // self-perpetuating background chain — the chain
                        // does not depend on the prompt outcome: while
                        // access is denied the fetches come back empty and
                        // each window is a cheap no-op that re-arms itself.
                        vm.requestPhotoAccessThenOpenDenied()
                        vm.scheduler.submit()
                    }
                }
                .accessibilityIdentifier("autoBackupToggle")
            Toggle("Wi-Fi only", isOn: $vm.settings.onlyOnWiFi)
            if vm.settings.onlyOnWiFi {
                Toggle("Use cellular for photos", isOn: $vm.settings.allowCellularForPhotos)
                    .padding(.leading, PVSpacing.s16)
                Toggle("Use cellular for videos", isOn: $vm.settings.allowCellularForVideos)
                    .padding(.leading, PVSpacing.s16)
            }
            Toggle("Charging only", isOn: $vm.settings.onlyWhenCharging)
            Toggle("Back up new photos automatically", isOn: $vm.settings.autoDetectNewPhotos)
                .onChange(of: vm.settings.autoDetectNewPhotos) { _, _ in
                    DependencyContainer.shared.syncLibraryMonitor()
                }
            Toggle("Show backup status on thumbnails", isOn: $vm.settings.showSyncBadge)
                .onChange(of: vm.settings.showSyncBadge) { _, _ in
                    vm.syncBadgeIndex()
                }
                .accessibilityIdentifier("syncBadgeToggle")
            // What the last run did, asset by asset. A pushed page, not a sheet:
            // a sheet is handed a copy of the failures array and cannot follow
            // assets still in flight, and the list needs a stable destination on
            // a run of several thousand assets.
            NavigationLink {
                UploadDetailView(vm: detail)
            } label: {
                LabeledContent {
                    if vm.failedAssetCount > 0 {
                        Text("\(vm.failedAssetCount)")
                            .font(.pvNumeric)
                            .foregroundStyle(Color.immichError)
                            .contentTransition(.numericText())
                    }
                } label: {
                    Label("Upload details", systemImage: "list.bullet.rectangle")
                }
            }
            .accessibilityIdentifier("uploadDetailRow")
        } header: {
            Text("Auto backup")
        } footer: {
            Text("While Immich is open, new photos start backing up within a few seconds. When it's closed, iOS decides when to run — usually while charging on Wi-Fi.")
        }
    }

    /// What gets backed up. One mode, one list: the previous version offered
    /// "Albums to back up" and "Albums to skip" side by side, which let you
    /// include and exclude the same album at once — a run that silently backs
    /// up nothing.
    @ViewBuilder
    private var albumSection: some View {
        @Bindable var vm = vm
        Section {
            Picker("Back up", selection: $vm.settings.albumScope) {
                Text("All albums").tag(BackupAlbumScope.all)
                Text("Only selected albums").tag(BackupAlbumScope.selected)
                Text("All but selected albums").tag(BackupAlbumScope.excluded)
            }
            switch vm.settings.albumScope {
            case .all:
                EmptyView()
            case .selected:
                NavigationLink {
                    AlbumPickerView(
                        title: "Albums to back up",
                        albums: vm.albums,
                        selection: $vm.settings.selectedAlbumIDs
                    )
                } label: {
                    LabeledContent("Albums to back up",
                                   value: albumCount(vm.settings.selectedAlbumIDs, "selected"))
                }
            case .excluded:
                NavigationLink {
                    AlbumPickerView(
                        title: String(localized: "Albums to skip"),
                        albums: vm.albums,
                        selection: $vm.settings.excludedAlbumIDs
                    )
                } label: {
                    LabeledContent("Albums to skip",
                                   value: albumCount(vm.settings.excludedAlbumIDs, "excluded"))
                }
            }
            // The mirror is not part of the scope above: it is the same
            // question ("which albums?") for a different job — filing what was
            // uploaded. Smart albums are left out at the call site: the
            // resolution ignores them, so offering them would be a setting with
            // no effect.
            NavigationLink {
                AlbumPickerView(
                    title: String(localized: "Albums to mirror"),
                    albums: vm.albums.filter { !$0.isSmart },
                    selection: $vm.settings.syncedAlbumIDs
                )
            } label: {
                LabeledContent("Mirror into albums",
                               value: albumCount(vm.settings.syncedAlbumIDs, "mirrored"))
            }
            .accessibilityIdentifier("backupMirrorAlbumsRow")
        } header: {
            Text("Albums")
        } footer: {
            Text(albumSectionFooter)
        }
    }

    private func albumCount(_ ids: Set<String>, _ verb: String) -> String {
        ids.isEmpty ? "None" : "\(ids.count) \(verb)"
    }

    private var albumSectionFooter: String {
        let scope: String = switch vm.settings.albumScope {
        case .all:
            "Every photo and video in your library is backed up."
        case .selected:
            vm.settings.selectedAlbumIDs.isEmpty
                // The engine reads an empty inclusion list as "the whole
                // library", so say so instead of quietly widening the run.
                ? "No album picked yet, so every album is backed up. Pick at least one to limit the backup to those albums."
                : "Only photos in the albums you picked are backed up. Nothing is ever deleted from Immich or from Photos."
        case .excluded:
            vm.settings.excludedAlbumIDs.isEmpty
                ? "No album skipped yet, so every album is backed up. Pick an album to leave it out."
                : "Photos in the albums you picked are left out of every backup. Nothing is ever deleted from Immich or from Photos."
        }
        // The mirror is one-way and frozen at creation; saying it once, here,
        // is cheaper than a user discovering it — and the alternative reading
        // (a two-way sync) is the one people assume. This one sentence goes
        // through `String(localized:)` because the scope sentences above are
        // built as plain strings and never reach the catalogue.
        return scope + " " + String(
            localized: "Photos in a mirrored album also join a server album of the same name. That server album is created at the first backup and reused as it is: moving a photo between albums in Photos never moves it on the server, and nothing is ever deleted or renamed here."
        )
    }

    @ViewBuilder
    private var progressSection: some View {
        Section {
            switch vm.engine.phase {
            case .checking, .uploading:
                activeProgress
            case .done:
                completionSummary
            case .cancelled:
                cancelledSummary
            case .idle:
                EmptyView()
            }
            if vm.running {
                Button(vm.engine.isCancelling ? "Cancelling…" : "Cancel", role: .destructive) {
                    vm.cancelBackup()
                }
                .disabled(vm.engine.isCancelling)
                .accessibilityIdentifier("cancelBackupButton")
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            } else {
                Button {
                    Task { await vm.runBackup(manual: true) }
                } label: {
                    Label("Run now", systemImage: "arrow.up.circle")
                }
                // The one control this feature greys out instead of removing:
                // a backup row is a place, not a destructive affordance, and
                // the footer below says why it does not answer.
                .disabled(readOnly.isEnabled)
                .accessibilityIdentifier("runBackupButton")
                if vm.canResume {
                    Button {
                        vm.resumeUpload()
                    } label: {
                        Label("Resume last backup", systemImage: "arrow.clockwise.circle.fill")
                    }
                    .accessibilityIdentifier("resumeBackupButton")
                }
            }
        } header: {
            Text("Progress")
        } footer: {
            // One view only (see the hub's Security footer): a sibling `Text` is
            // silently dropped by the List footer.
            VStack(alignment: .leading, spacing: 4) {
                Text("Photos kept only in iCloud are downloaded before they can be uploaded. A slow or not-yet-ready download retries automatically, and anything still pending is picked up on the next backup.")
                if readOnly.isEnabled {
                    Text("Read-only mode is on. Turn it off in Me to change your library.")
                }
            }
        }
    }

    // MARK: Progress subviews

    /// Live progress while the engine is checking or uploading.
    @ViewBuilder
    private var activeProgress: some View {
        let engine = vm.engine
        let scanning = engine.phase == .checking && engine.total == 0
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                Image(systemName: engine.phase == .checking ? "magnifyingglass" : "icloud.and.arrow.up")
                    .foregroundStyle(Color.immichPrimary)
                Text(scanning ? "Scanning your library…"
                     : engine.phase == .checking ? "Preparing \(engine.total) photos" : "Backing up")
                    .font(.pvSubhead.weight(.semibold))
                Spacer()
                if !scanning {
                    Text("\(engine.progressPercent)%")
                        .font(.pvSubhead.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            if scanning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.immichPrimary)
            } else {
                ProgressView(value: engine.progressFraction)
                    .tint(Color.immichPrimary)
                    .animation(PVMotion.snappy, value: engine.progressFraction)
            }
            if !scanning {
                HStack(spacing: PVSpacing.s4) {
                    Text("\(engine.examinedCount) of \(engine.total)")
                        .contentTransition(.numericText())
                    if let eta = etaText { Text("· \(eta)") }
                    Spacer()
                }
                .font(.pvCaption)
                .foregroundStyle(.secondary)
            }
            currentItemRow
            segmentBar
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activeAccessibilityLabel)
    }

    /// Thumbnail + name of the asset in flight, plus any iCloud status note.
    @ViewBuilder
    private var currentItemRow: some View {
        let engine = vm.engine
        if let name = engine.currentFileName {
            HStack(spacing: PVSpacing.s8) {
                BackupThumbnailView(localIdentifier: engine.currentAssetID)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    Text(name)
                        .font(.pvCaption)
                        .lineLimit(1)
                    if let status = engine.statusMessage {
                        Text(status)
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichPrimary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
        } else if let status = engine.statusMessage {
            Label(status, systemImage: "icloud.and.arrow.down")
                .font(.pvCaption)
                .foregroundStyle(Color.immichPrimary)
        }
    }

    /// Stacked uploaded / already-on-server / failed breakdown + legend.
    @ViewBuilder
    private var segmentBar: some View {
        let engine = vm.engine
        let denom = CGFloat(max(1, engine.total))
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    Color.immichSuccess
                        .frame(width: w * CGFloat(engine.uploadedCount) / denom)
                    Color.secondary
                        .frame(width: w * CGFloat(engine.rejectedCount) / denom)
                    Color.immichError
                        .frame(width: w * CGFloat(engine.failedCount) / denom)
                    Color.immichWarning
                        .frame(width: w * CGFloat(engine.deferredCount) / denom)
                    Color.clear
                }
            }
            .frame(height: 6)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
            HStack(spacing: PVSpacing.s12) {
                legendDot(Color.immichSuccess, "Uploaded \(engine.uploadedCount)")
                legendDot(Color.secondary, "On server \(engine.rejectedCount)")
                if engine.failedCount > 0 {
                    legendDot(Color.immichError, "Failed \(engine.failedCount)")
                }
                if engine.deferredCount > 0 {
                    legendDot(Color.immichWarning, "\(waitingLabel) \(engine.deferredCount)")
                }
            }
            .font(.pvCaption)
            .foregroundStyle(.secondary)
        }
    }

    /// Names what the deferred assets are waiting for. Both cases are
    /// non-failures, but "waiting for Wi-Fi" and "waiting for iCloud" are
    /// different stories for the user — an unlabeled counter reads as a stall.
    private var waitingLabel: String {
        let reason = vm.engine.deferralReason
        let wifi = reason.contains(.waitingForWiFi)
        let icloud = reason.contains(.waitingForICloud)
        return switch (wifi, icloud) {
        case (true, true): "Waiting for"
        case (true, false): "Waiting for Wi-Fi"
        default: "Waiting for iCloud"
        }
    }

    /// Footer line for the deferred bucket, matching `waitingLabel`.
    private var waitingFooter: String {
        let reason = vm.engine.deferralReason
        let wifi = reason.contains(.waitingForWiFi)
        let icloud = reason.contains(.waitingForICloud)
        return switch (wifi, icloud) {
        case (true, true):
            "Some photos are waiting for Wi-Fi, others for iCloud — the next backup finishes them"
        case (true, false):
            "Waiting for Wi-Fi — the next backup on Wi-Fi finishes them"
        default:
            "Waiting for iCloud — finishes on the next backup"
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: PVSpacing.s4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    /// Success / partial-failure card shown when the run finished.
    @ViewBuilder
    private var completionSummary: some View {
        let engine = vm.engine
        let ok = engine.failedCount == 0
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.immichSuccess : Color.immichError)
                Text(ok ? "Backup complete" : "Finished with errors")
                    .font(.pvSubhead.weight(.semibold))
            }
            Text("\(engine.uploadedCount) uploaded · \(engine.rejectedCount) already on server")
                .font(.pvCaption)
                .foregroundStyle(.secondary)
            segmentBar
            if engine.deferredCount > 0 {
                Label(waitingFooter, systemImage: engine.deferralReason.contains(.waitingForWiFi)
                      ? "wifi.slash" : "icloud.and.arrow.down")
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichWarning)
            }
            if engine.failedCount > 0 {
                NavigationLink {
                    UploadDetailView(vm: detail)
                } label: {
                    HStack {
                        Text("\(engine.failedCount) couldn't be backed up")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichError)
                }
                .accessibilityIdentifier("failuresButton")
                Button {
                    Task { await vm.retryAllFailed() }
                } label: {
                    Label("Retry failed", systemImage: "arrow.clockwise")
                        .foregroundStyle(Color.immichPrimary)
                }
                .accessibilityIdentifier("retryFailedButton")
            }
        }
    }

    @ViewBuilder
    private var cancelledSummary: some View {
        let engine = vm.engine
        HStack(spacing: PVSpacing.s8) {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
            Text("Cancelled — \(engine.processedCount) of \(engine.total) done")
                .font(.pvSubhead.weight(.semibold))
        }
    }

    /// Human ETA string, e.g. "about 3 min left".
    private var etaText: String? {
        guard let secs = vm.engine.estimatedSecondsRemaining, secs > 0 else { return nil }
        if secs < 60 { return "about \(secs)s left" }
        let mins = Int((Double(secs) / 60).rounded())
        return "about \(mins) min left"
    }

    private var activeAccessibilityLabel: String {
        let engine = vm.engine
        if engine.phase == .checking && engine.total == 0 { return "Scanning your library" }
        var parts = ["Backing up", "\(engine.examinedCount) of \(engine.total)", "\(engine.progressPercent) percent"]
        if let status = engine.statusMessage { parts.append(status) }
        return parts.joined(separator: ", ")
    }
}

/// Album selection list — a generic checkmark picker bound to whichever
/// identifier set the caller owns (backup scope or exclusion scope), so the
/// two screens share one implementation.
struct AlbumPickerView: View {
    let title: String
    let albums: [BackupAlbum]
    @Binding var selection: Set<String>

    private var userAlbums: [BackupAlbum] { albums.filter { !$0.isSmart } }
    private var smartAlbums: [BackupAlbum] { albums.filter(\.isSmart) }

    var body: some View {
        Group {
            if albums.isEmpty {
                // A `List` with no row in it is a blank screen: "your library
                // has no album" and "this screen failed to load" look exactly
                // alike. The empty state is the screen's only content in that
                // case, so it says which of the two it is.
                ContentUnavailableView("No albums yet", systemImage: "rectangle.stack")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("albumPickerEmptyState")
            } else {
                List {
                    section("Albums", userAlbums)
                    section("Smart albums", smartAlbums)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ header: String, _ items: [BackupAlbum]) -> some View {
        if !items.isEmpty {
            Section(header) {
                ForEach(items) { album in
                    Button {
                        if selection.contains(album.id) {
                            selection.remove(album.id)
                        } else {
                            selection.insert(album.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                                Text(album.name)
                                    .foregroundStyle(Color.textPrimaryPV)
                                Text("\(album.count) photos")
                                    .font(.pvCaption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection.contains(album.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.immichPrimary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Small thumbnail for the asset currently being backed up. Loads a low-res
/// PhotosKit image by local identifier (no network — iCloud-only assets fall
/// back to a placeholder) so the progress row shows *what* is uploading.
struct BackupThumbnailView: View {
    let localIdentifier: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: localIdentifier) {
            image = nil
            guard let localIdentifier else { return }
            let loaded = await Self.thumbnail(for: localIdentifier)
            if !Task.isCancelled { image = loaded }
        }
    }

    private static func thumbnail(for id: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = fetched.firstObject else {
                continuation.resume(returning: nil)
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

