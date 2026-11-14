import Foundation
import ImmichSharedKit
import WidgetKit

/// App-wide composition root. Provides pre-built service graph + view models.
@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    /// The transport's own log (gap G24). Declared before `client` on purpose:
    /// the transport takes its sink at construction, so a client built first
    /// could not be given one afterwards. One store per process — a second
    /// instance would show a log the client never wrote to.
    let appLog = AppLogStore()
    /// Thumbnail and preview caches (memory and disk) the "Advanced" section
    /// measures and empties; not the offline copies, the map or the widgets.
    let imageCache: any ImageCacheManaging = ImageCacheService()

    let client: ImmichAPIClient
    let keychain: KeychainStore
    let photos: PhotoLibraryService
    /// The destructive half of the Photos surface (gap G1). Same object as
    /// `photos` — see `photoLibrary`.
    let cleanupSource: any LocalCleanupSource
    /// The one PhotosKit service behind `photos` and `cleanupSource`. Stored
    /// concretely because the album list Free Up Space offers is only reachable
    /// through `BackupAssetSource`: a second `PhotoLibraryServiceImpl` would
    /// rebuild its own iCloud-shared-album set, and the screen that offers a
    /// deletion would disagree with the one performing it.
    private let photoLibrary: PhotoLibraryServiceImpl
    let appLock: AppLockViewModel
    let trustedServers: TrustedServerStore
    /// One per process: the trust-aware sessions for images, transfers and road
    /// trip. Built on the API client's own trust store and reset by the
    /// logout purge (`LocalDataPurger`).
    nonisolated let serverSessions: ServerSessions
    let realtime: RealtimeService
    /// The TLS client certificate of each server (L-10): the keychain-backed
    /// store the TLS delegates, the widgets and the share extension all read,
    /// and the service that imports, replaces and removes one.
    nonisolated let clientIdentities: any ClientIdentityStoring
    nonisolated let clientCertificateResponder: ClientCertificateResponder
    let clientCertificates: ClientCertificateService
    /// Process-wide single instance so the BG handler, the settings toggle
    /// and `UploadViewModel` all submit through the same request slot —
    /// `submit()` cancels then re-submits, so concurrent independent
    /// instances can't step on each other.
    let backupScheduler: any BackgroundBackupScheduling
    /// Process-wide ledger so the BG handler, the foreground kick and the
    /// backup screen all share one loaded copy of the already-backed-up set.
    let backupLedger: any BackupLedgerStoring
    /// The edited versions already backed up, beside `backupLedger`. The same
    /// persistent instance for the engine, the thumbnail badge index and Free
    /// Up Space — an in-memory one would forget every edit at each launch.
    let backupEditLedger: any BackupEditLedgerStoring
    /// Process-wide Live Activity driver: the BG handler, the scene-phase
    /// kick and the backup screen must all drive ONE activity — separate
    /// instances each `Activity.request` their own, pile up concurrent
    /// same-app activities, and the island renders them unreliably (the
    /// "no island while the app is open" symptom).
    let backupLiveActivity: any BackupLiveActivityServicing
    /// Process-wide backup view model — and therefore ONE `BackupEngine`.
    /// Separate instances have separate engines, so their `!running` guards
    /// can't see each other: the scene-phase kick, the BG handler, the
    /// AppIntent and the backup screen would run concurrent passes over the
    /// same library (double iCloud downloads) while fighting over the single
    /// Live Activity — the first one to finish dismisses the island out from
    /// under the other. One VM, one run, one island.
    let upload: UploadViewModel
    /// Watches Photos for inserted assets while the app is in the foreground,
    /// so "Back up new photos automatically" reacts to a photo taken now rather
    /// than only at the next scene activation.
    let libraryMonitor: any PhotoLibraryChangeMonitoring

    /// Persisted device album → server album map, one per process for the same
    /// reason as `upload`: a second store could disagree about which album a
    /// mirrored album already has.
    let albumSyncStore: AlbumSyncStore
    /// The one album mirror this process owns. Two services would each hold
    /// their own buffer, and the second would lose half a run's assets.
    let albumSyncService: AlbumSyncService

    /// Offline cache (issue #18). One store per process: the timeline badge,
    /// the viewer and the storage screen must all read the same on-disk index,
    /// and two stores would each hold their own copy of it.
    let offlineStore: OfflineAssetStore
    /// UI mirror of `offlineStore`'s index, injected into the environment so
    /// every grid cell can answer "is this cached?" without a parameter.
    let offlineIndex: OfflineAssetIndex

    /// Process-wide external-screen state (gap G9). One instance for the whole
    /// app for the same reason as `upload`: the route detector and its
    /// notifications are system resources, the viewer can be opened from eight
    /// surfaces, and a per-viewer service would leave the badge wrong the first
    /// time the viewer opens.
    let castService: any CastService = AirPlayCastService()

    /// Backup-state mirror (G6), same shape and same reason as `offlineIndex`:
    /// one instance per process, rebuilt from the ledger on every ledger write
    /// and read by every thumbnail cell through the environment.
    let cloudStatus: CloudBackupStatusIndex

    /// Process-wide language choice (issue #21). `RootView` injects its locale
    /// into the view tree and every `String(localized:)` call resolves through
    /// `AppleLanguages` at launch, so the store must be the single writer of
    /// both — a second instance would disagree with the one on screen.
    let language: AppLanguageStore

    /// Process-wide app preferences (gap G22). Same shape of reasoning as
    /// `language`: `RootView` projects the theme and the accent onto the whole
    /// tree, and five screens read these switches, so the store must be the
    /// single writer of all fourteen keys — a second instance would keep a
    /// second mirror and the next launch would disagree with the screen.
    let appSettings: AppSettingsStore

    /// Process-wide map settings (gap G14b). Same shape of reasoning as
    /// `language`: the map, its settings sheet, its filter badge and the photo
    /// sheet's banner must all project ONE filter, and the choice has to
    /// outlive the segment view that presents the sheet.
    let mapSettings: MapSettingsStore

    /// The device position (L-25, B-29.2): one provider for the map's "My
    /// Location" and the adjust-location sheet's. The launch arguments of the UI
    /// tests swap in a scripted one; production always gets CoreLocation.
    let deviceLocation: any DeviceLocationProviding

    /// Process-wide download queue (gap G10). Same reasoning as `upload`: the
    /// floating panel, the viewer's "Download to Files" and the timeline's
    /// mass action must all drive ONE queue — and it has to outlive the screen
    /// that started the download, where a queue built per presentation dies
    /// with the sheet (exactly the defect this feature fixes).
    let downloadQueue: DownloadQueueViewModel

    /// Keychain slot for the locked folder's remembered PIN (gap G12). One
    /// store per process so the folder's ViewModel and any future Face ID
    /// shortcut read the same entry; never the session token slot.
    let lockedFolderPINs: any LockedFolderPINStoring

    /// Read-only mode (gap G17). One store per process: the Me hub's switch,
    /// the avatar's long press and the guard below are three readers of ONE
    /// boolean, and a second store could publish a state the guard disagrees
    /// with.
    let readOnly: ReadOnlyModeStore

    /// The library client every view model and every view writes through. The
    /// raw `client` above stays the transport (session, trust store, low-level
    /// container calls); this one refuses the writes while the mode is on, so
    /// no screen can bypass the guard by holding the transport instead.
    ///
    /// `nonisolated` on purpose: the photo viewer takes it as a **default
    /// argument**, and default arguments are evaluated in the caller's context
    /// — its eight presenters must not each have to thread a client through.
    nonisolated let libraryClient: any ImmichClient
    /// Every server's custom HTTP headers (L-09): the one registry the API
    /// client, the realtime socket, the offline store and the editor read.
    nonisolated let customHeaders: CustomHeadersRegistry = .shared
    /// "What's New" seen-state (gap G23). One store per process: the automatic
    /// sheet, the About row that reopens it and `AuthViewModel`'s
    /// add-an-account write must all agree on which batch has been presented.
    let whatsNewStore = WhatsNewStore(defaults: .standard)

    init() {
        self.keychain = KeychainStoreImpl()
        let identities = KeychainClientIdentityStore()
        self.clientIdentities = identities
        // Test only (`-uiTestResetClientCertificates YES`): every UI scenario
        // starts without a certificate, whatever the previous one left in the
        // keychain of the simulator.
        if UserDefaults.standard.bool(forKey: "uiTestResetClientCertificates") {
            try? identities.removeAll()
        }
        // Test only (`-uiTestResetWhatsNewSeen YES`): "What's New" has not been
        // seen at this launch. Written to the persistent domain, which the
        // argument domain does not do, so a later launch finds it unseen too.
        if UserDefaults.standard.bool(forKey: "uiTestResetWhatsNewSeen") {
            UserDefaults.standard.removeObject(forKey: WhatsNewStore.seenReleaseKey)
        }
        #if DEBUG
        // Test only (`-uiTestEditAssetNamed <file name>`): edits that Photos
        // asset in place so a scenario holds a really edited photo.
        UITestPhotoEditHook.runIfRequested()
        #endif
        let responder = ClientCertificateResponder(store: identities, log: .shared)
        self.clientCertificateResponder = responder
        let trustStore = TrustedServerStoreImpl()
        self.trustedServers = trustStore
        let serverSessions = ServerSessions(
            trustStore: trustStore, clientCertificates: responder, imageCache: AuthenticatedAsyncImage.imageDiskCache
        )
        self.serverSessions = serverSessions
        self.client = ImmichAPIClient(
            trustStore: trustStore, log: appLog, customHeaders: customHeaders, clientCertificates: responder
        )
        // Read-only mode: the store persists into `.standard` and the guard
        // reads the very same defaults at call time (never a captured value),
        // so the mode can be flipped without a relaunch and the next write
        // already sees it. Built before `upload`, whose engine holds this
        // client.
        self.readOnly = ReadOnlyModeStore()
        self.libraryClient = ReadOnlyGuardClient(inner: client as any ImmichClient, isEnabled: { ReadOnlyModeStore.isEnabledIn(.standard) })
        // One PhotosKit service for the whole app: the album list, the export
        // path and the deletion path all have to describe the same library.
        let photoLibrary = PhotoLibraryServiceImpl()
        self.photoLibrary = photoLibrary
        self.photos = photoLibrary
        self.cleanupSource = photoLibrary
        self.appLock = AppLockViewModel()
        self.lockedFolderPINs = KeychainLockedFolderPINStore(keychain: keychain)
        let realtime = RealtimeService(
            transport: SocketIORealtimeTransport(session: { [serverSessions] in serverSessions.realtime }),
            customHeaders: customHeaders
        )
        self.realtime = realtime
        self.clientCertificates = ClientCertificateService(
            store: identities,
            log: .shared,
            sessions: [client, serverSessions],
            reconnectRealtime: { [realtime] in realtime.reconnectIfConnected() },
            reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
            appLog: appLog
        )
        self.backupScheduler = BGTaskBackupScheduler()
        self.backupLedger = BackupLedger.persistent()
        self.backupEditLedger = BackupEditLedger.persistent()
        self.backupLiveActivity = LiveActivityBackupService()
        self.libraryMonitor = PhotoLibraryChangeMonitor()
        self.offlineStore = OfflineAssetStore(transport: serverSessions.makeDownloadTransport(), customHeaders: customHeaders)
        self.offlineIndex = OfflineAssetIndex()
        self.language = AppLanguageStore()
        // The shared instance, not a fresh one: view models built with the
        // defaulted initializer (the video player page) read `AppSettingsStore.shared`,
        // and the two must be the same object.
        self.appSettings = AppSettingsStore.shared
        self.mapSettings = MapSettingsStore()
        let scriptedLocation: (any DeviceLocationProviding)? = ScriptedDeviceLocationService.fromLaunchArguments()
        self.deviceLocation = scriptedLocation ?? SystemDeviceLocationService()
        let cloudStatus = CloudBackupStatusIndex()
        self.cloudStatus = cloudStatus
        self.albumSyncStore = AlbumSyncStore()
        self.albumSyncService = AlbumSyncService(
            mapping: albumSyncStore,
            // Same chunk size as the dedup check and the ledger reconciliation:
            // the mirror receives it instead of hard-coding a second copy.
            batchSize: BackupEngine.checkChunkSize
        )
        self.upload = UploadViewModel(
            client: libraryClient, photos: photos,
            ledger: backupLedger, editLedger: backupEditLedger,
            scheduler: backupScheduler,
            activityService: backupLiveActivity,
            cloudStatus: cloudStatus,
            albumSync: albumSyncService,
            readOnly: readOnly,
            // Read per run, not captured: a login that happens after this
            // composition root was built must still mirror, and the mapping is
            // keyed by the account that owns the albums.
            userID: { UserDefaults.standard.string(forKey: AuthViewModel.userIdDefaultsKey) }
        )
        // Seed the badge index before anything can draw a tile, then re-read it
        // on every ledger write — the engine's runs are the only thing that adds
        // or removes a "proven on the server" fact.
        let ledger = backupLedger
        let editLedger = backupEditLedger
        cloudStatus.refresh(ledger: ledger, editLedger: editLedger)
        upload.engine.onLedgerChange = { cloudStatus.refresh(ledger: ledger, editLedger: editLedger) }
        upload.syncBadgeIndex()
        // Foreground-only by construction: the transport streams through
        // `ServerSessions.transfers`, a default (non-background) session, so a
        // transfer pauses when iOS suspends the app. A
        // background `URLSession` would need its own identifier, an app-delegate
        // hand-off and a reconciliation pass at launch — none of which this
        // card asks for; the panel is what keeps the run visible, not a
        // background session. The transport is the same type, on the same
        // session, as the offline cache uses.
        self.downloadQueue = DownloadQueueViewModel(client: libraryClient, transport: serverSessions.makeDownloadTransport())
        self.libraryMonitor.onAssetsInserted = { [weak self] in
            self?.kickOffAutoBackup()
        }
        // Gap G9: the route is watched for the whole process, with the
        // container's interest as the permanent one — a cast sheet opening and
        // closing only adds and releases its own.
        castService.startObserving()
    }

    func makeAuthViewModel() -> AuthViewModel {
        AuthViewModel(
            client: libraryClient,
            keychain: keychain,
            // The very store the API client's TLS delegate reads, so the logout
            // purge and the next handshake agree on what is trusted.
            trustStore: trustedServers,
            realtime: realtime,
            // Widgets read the session from the shared keychain group, not from
            // this process (issue #19).
            widgetSession: WidgetSessionStore(),
            localData: LocalDataPurger(
                backupEngine: upload.engine,
                offlineStore: offlineStore,
                offlineIndex: offlineIndex,
                imageCache: .shared,
                imageDiskCache: AuthenticatedAsyncImage.imageDiskCache,
                apiClient: client,
                serverSessions: serverSessions
            ),
            customHeaders: customHeaders,
            identities: clientIdentities
        )
    }

    /// Client certificate screen of one server (L-10). `onChange` runs after an
    /// import or a removal succeeded: the server step uses it to check the
    /// server again.
    func makeClientCertificateViewModel(
        serverURL: URL?,
        onChange: @escaping @MainActor () async -> Void = {}
    ) -> ClientCertificateViewModel {
        ClientCertificateViewModel(serverURL: serverURL, manager: clientCertificates, onChange: onChange)
    }

    /// How the video player reaches a server that has a client certificate:
    /// the app's `video` session (read per request) and the identity store.
    /// `nonisolated` on purpose: `VideoPlaybackViewModel` takes it as a default
    /// argument, which is evaluated in the caller's (nonisolated) context.
    nonisolated var videoTransport: VideoAppTransport {
        VideoAppTransport(session: { [serverSessions] in serverSessions.video }, identities: clientIdentities)
    }

    func makeTimelineViewModel() -> TimelineViewModel {
        TimelineViewModel(client: libraryClient)
    }

    /// Change-password screen (gap G18). Only lends the shared `ImmichClient`:
    /// the ViewModel is an instance per screen, so the form's fields and its
    /// in-flight state never reach the global auth tree.
    func makeChangePasswordViewModel() -> ChangePasswordViewModel {
        ChangePasswordViewModel(client: libraryClient)
    }

    /// One view model per "recent" sort axis (gap G13). Two instances, not one:
    /// the two screens keep their own bucket list and their own scroll, so
    /// nothing but the mode parameter is shared.
    func makeRecentAssetsViewModel(mode: RecentAssetsMode) -> RecentAssetsViewModel {
        RecentAssetsViewModel(client: libraryClient, mode: mode)
    }

    func makeTrashViewModel() -> TrashViewModel {
        TrashViewModel(client: libraryClient)
    }

    func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(client: libraryClient)
    }

    func makeMapViewModel(accountID: String) -> MapViewModel {
        MapViewModel(
            client: libraryClient,
            cache: MapMarkerCache(accountID: accountID),
            settings: mapSettings,
            location: deviceLocation
        )
    }

    func makeAlbumsViewModel() -> AlbumsViewModel {
        AlbumsViewModel(client: libraryClient)
    }

    func makeAlbumDetailViewModel(albumId: String) -> AlbumDetailViewModel {
        AlbumDetailViewModel(client: libraryClient, albumId: albumId)
    }

    func makeSharedLinksViewModel() -> SharedLinksViewModel {
        SharedLinksViewModel(client: libraryClient)
    }

    /// The album mirror, for callers that need it explicitly. Always the single
    /// process-wide instance — same reasoning as `container.upload`: a second
    /// service would hold a second buffer, and half a run's assets would wait in
    /// a buffer nobody flushes.
    func makeAlbumSyncService() -> AlbumSyncService { albumSyncService }

    /// Public shared-link viewer (issue #22). Takes the connected server as an
    /// argument: the host check and the public-URL builder both need it, and it
    /// is only known once the app is authenticated.
    func makeSharedLinkViewerViewModel(baseURL: URL, externalDomain: String) -> SharedLinkViewerViewModel {
        SharedLinkViewerViewModel(
            client: libraryClient,
            baseURL: baseURL,
            externalDomain: externalDomain
        )
    }

    func makeStorageStatsViewModel() -> StorageStatsViewModel {
        StorageStatsViewModel(client: libraryClient)
    }

    /// App Logs screen (gap G24). Shares the process-wide store the transport
    /// writes into — a fresh store would show an empty log.
    func makeAppLogViewModel() -> AppLogViewModel {
        AppLogViewModel(store: appLog)
    }

    /// "Advanced" section of the Me hub: log level and image cache. Shares the
    /// process-wide log store and image cache.
    func makeAdvancedSettingsViewModel() -> AdvancedSettingsViewModel {
        AdvancedSettingsViewModel(log: appLog, imageCache: imageCache)
    }

    /// Viewer share (B-31): downloads the photo in the chosen quality to a file
    /// and hands it to the iOS share sheet. One instance per viewer.
    func makeViewerShareViewModel(baseURL: URL, token: String?) -> ViewerShareViewModel {
        ViewerShareViewModel(
            client: libraryClient, baseURL: baseURL, token: token,
            transport: serverSessions.makeDownloadTransport(), customHeaders: customHeaders
        )
    }

    /// Inventory of the offline cache (gap G24). Takes the caller's offline
    /// view model rather than choosing one, like `makeSyncStatusViewModel`: the
    /// container must not decide which instance of the process is observed.
    func makeDownloadInfoViewModel(offline: OfflineDownloadViewModel) -> DownloadInfoViewModel {
        DownloadInfoViewModel(offline: offline)
    }

    /// Media stats (gap G24): the storage card's call, plus the ledger and the
    /// offline cache the device already holds.
    func makeMediaStatsViewModel(offline: OfflineDownloadViewModel) -> MediaStatsViewModel {
        MediaStatsViewModel(client: libraryClient, ledger: backupLedger, offline: offline)
    }

    /// Asset troubleshoot (gap G24). Reads the same ledger the backup engine
    /// writes and the same offline mirror every grid cell reads, so the page
    /// cannot contradict the screen the user came from.
    func makeAssetTroubleshootViewModel() -> AssetTroubleshootViewModel {
        AssetTroubleshootViewModel(
            client: libraryClient,
            ledger: backupLedger,
            offlineIndex: offlineIndex
        )
    }
    /// Reads the persisted auto-backup toggle directly — no live VM needed
    /// (the scene-phase code runs outside the tab tree's VMs).
    func isAutoBackupEnabled() -> Bool {
        BackupSettingsStore().isEnabled
    }

    /// Kicks the gated backup engine when auto-backup is configured and
    /// nothing is running (foreground "upload at launch / on return").
    func kickOffAutoBackup() {
        Task { await upload.kickOffAutoBackupIfConfigured() }
    }

    /// Starts a manual backup pass (the "Back up now" widget link): see
    /// `UploadViewModel.startManualBackup()`.
    func startManualBackup() {
        upload.startManualBackup()
    }

    /// Aligns the Photos observer with the current settings: observing only
    /// makes sense when both auto-backup and new-photo detection are on, and it
    /// must never be left running otherwise.
    func syncLibraryMonitor() {
        if BackupSettingsStore().snapshot().shouldObserveLibraryChanges {
            libraryMonitor.start()
        } else {
            libraryMonitor.stop()
        }
    }

    func makePeopleViewModel() -> PeopleViewModel {
        PeopleViewModel(client: libraryClient)
    }

    func makeTagsViewModel() -> TagsViewModel {
        TagsViewModel(client: libraryClient)
    }

    func makeTagAssetsViewModel(tagId: String, tagName: String) -> TagAssetsViewModel {
        TagAssetsViewModel(client: libraryClient, tagId: tagId, tagName: tagName)
    }

    func makeStacksViewModel() -> StacksViewModel {
        StacksViewModel(client: libraryClient)
    }

    func makePartnersViewModel() -> PartnersViewModel {
        PartnersViewModel(client: libraryClient)
    }

    /// One partner's library (L-08). Each push gets its own instance.
    func makePartnerLibraryViewModel(partnerId: String, partnerName: String) -> PartnerLibraryViewModel {
        PartnerLibraryViewModel(client: libraryClient, partnerId: partnerId, partnerName: partnerName)
    }

    /// Notification permission screen (issue #16). Holds no cache — it reads
    /// the system's answer on appear.
    func makeNotificationsViewModel() -> NotificationsViewModel {
        NotificationsViewModel()
    }

    func makeAdminViewModel() -> AdminViewModel {
        AdminViewModel(client: libraryClient)
    }

    /// Gap G20: the current account's own API keys. A dedicated VM, not
    /// `AdminViewModel` — that one's `load()` also fetches users, jobs and
    /// libraries, and this screen is open to non-admin accounts.
    func makeUserApiKeysViewModel() -> UserApiKeysViewModel {
        UserApiKeysViewModel(client: libraryClient)
    }

    /// L-09: the editor of one server's custom HTTP headers. `onSaved` is what
    /// nudges the session (`AuthViewModel.customHeadersDidChange`).
    func makeCustomHeadersViewModel(
        serverKey: ServerKey,
        onSaved: @escaping @MainActor (ServerKey) -> Void
    ) -> CustomHeadersViewModel {
        CustomHeadersViewModel(serverKey: serverKey, registry: customHeaders, onSaved: onSaved)
    }

    func makeMemoriesViewModel() -> MemoriesViewModel {
        MemoriesViewModel(client: libraryClient)
    }

    func makeRoadTripViewModel(
        albumId: String,
        selectedAssetIds: Set<String>?,
        albumTitle: String,
        baseURL: URL,
        token: String?
    ) -> RoadTripViewModel {
        RoadTripViewModel(
            client: libraryClient,
            albumId: albumId,
            selectedAssetIds: selectedAssetIds,
            albumTitle: albumTitle,
            baseURL: baseURL,
            token: token,
            photos: photos,
            session: { [serverSessions] in serverSessions.roadTrip }
        )
    }

    func makeDuplicatesViewModel() -> DuplicatesViewModel {
        DuplicatesViewModel(client: libraryClient)
    }

    /// Folder view (gap G11). Read-only and stateless outside the VM: the tree
    /// and the per-folder asset cache live in the instance and nothing is
    /// persisted, so there is no store to share here — one VM per screen tree.
    func makeFolderViewModel() -> FolderViewModel {
        FolderViewModel(client: libraryClient)
    }

    /// Offline storage screen (issue #18). Shares the process-wide store and
    /// mirror so a download made in the viewer shows up on the timeline badge
    /// and on this screen without a relaunch. The view model is bound to
    /// `accountID` (the account of the screen tree that builds it): once another
    /// account is active, the store refuses everything it asks for.
    func makeOfflineDownloadViewModel(accountID: String) -> OfflineDownloadViewModel {
        OfflineDownloadViewModel(
            store: offlineStore,
            client: libraryClient,
            index: offlineIndex,
            accountID: accountID
        )
    }

    /// The one download queue of the process — the same instance the floating
    /// panel projects, the viewer enqueues into and the timeline's mass action
    /// hands its selection to. Never a fresh instance: a second queue would
    /// show its own rows and cancel tasks the panel is following.
    func makeDownloadQueueViewModel() -> DownloadQueueViewModel { downloadQueue }
    /// Cast sheet of the viewer (gap G9). Projection only — the ViewModel stores
    /// no state, so a fresh instance per presentation is free and always current
    /// with the process-wide `castService` it projects.
    func makeCastViewModel() -> CastViewModel {
        CastViewModel(service: castService)
    }

    /// Sync status screen (AC-5030–5039). Takes both view models explicitly:
    /// the container must not pick which engine of the process is observed, and
    /// `RootView` already holds the process-wide `upload`.
    func makeSyncStatusViewModel(
        upload: UploadViewModel,
        offline: OfflineDownloadViewModel
    ) -> SyncStatusViewModel {
        SyncStatusViewModel(upload: upload, offline: offline)
    }

    /// Interface-language picker (issue #21). Shares the process-wide store, so
    /// the choice made here is the one `RootView`'s locale and the next launch
    /// read.
    func makeLanguageSettingsViewModel() -> LanguageSettingsViewModel {
        LanguageSettingsViewModel(store: language)
    }

    func makeDeviceSessionsViewModel() -> DeviceSessionsViewModel {
        DeviceSessionsViewModel(client: libraryClient)
    }

    /// Preferences screen (gap G22). Built here, not in the view: the store is
    /// process-wide and a second one would diverge from the instance the
    /// timeline and the viewer read.
    func makeAppSettingsViewModel() -> PreferencesViewModel {
        PreferencesViewModel(store: appSettings)
    }

    /// "What's New" (gap G23). Built on the container's store, so the automatic
    /// sheet, the About row that reopens the same cards and `AuthViewModel`'s
    /// write at add-account time read one seen-release.
    func makeWhatsNewViewModel() -> WhatsNewViewModel {
        WhatsNewViewModel(store: whatsNewStore)
    }

    /// Profile picture screen (gap G16). Takes the session as an argument for
    /// the same reason as `makeSharedLinkViewerViewModel`: the container knows
    /// the client, but the connected server and its bearer token only exist
    /// once the app is authenticated.
    func makeProfilePictureViewModel(baseURL: URL?, token: String?) -> ProfilePictureViewModel {
        ProfilePictureViewModel(client: libraryClient, baseURL: baseURL, token: token)
    }

    /// Per-asset upload report (upload-detail). Takes the caller's
    /// `UploadViewModel` rather than choosing one: the screen must project the
    /// engine the process is actually running, and there is only one
    /// (`self.upload`, "One VM, one run, one island").
    func makeUploadDetailViewModel(upload: UploadViewModel) -> UploadDetailViewModel {
        UploadDetailViewModel(upload: upload)
    }

    /// "Remaining to back up": what a complete pass would still send. Takes the
    /// caller's `UploadViewModel` for the same reason as the upload report
    /// above: the engine it projects is the one the process runs, and its
    /// settings and ledger are the ones the Backup screen edits.
    func makeBackupRemainderViewModel(upload: UploadViewModel) -> BackupRemainderViewModel {
        BackupRemainderViewModel(upload: upload)
    }

    /// "On this device" (local library). Reads the same Photos instance the
    /// backup engine reads (`PhotoLibraryServiceImpl` is both the library
    /// service and the backup asset source) and the same client for the remote
    /// aggregate, so the screen and a backup run can never disagree about what
    /// the device holds. Its Upload is a run of `self.upload` — the one engine
    /// and the one ledger — never a second pipeline.
    func makeLocalLibraryViewModel() -> LocalLibraryViewModel {
        LocalLibraryViewModel(
            photoLibrary: photos,
            albumSource: (photos as? BackupAssetSource) ?? PhotoLibraryServiceImpl(),
            client: libraryClient,
            backup: upload
        )
    }

    /// Free Up Space (gap G1). The ledger passed here is the SAME instance the
    /// backup engine writes: it is the only record of which checksums the server
    /// was told about, and a fresh ledger would make the scan find nothing.
    func makeFreeUpSpaceViewModel() -> FreeUpSpaceViewModel {
        FreeUpSpaceViewModel(
            client: libraryClient,
            source: cleanupSource,
            albumSource: photoLibrary,
            ledger: backupLedger,
            editLedger: backupEditLedger,
            includesEdits: { [upload] in upload.settings.backUpEdits },
            settings: CleanupSettingsStore()
        )
    }

    /// AC-615: photo editor VM factory. The editor downloads the original with URLSession +
    /// ImmichAssetURL, saves its edited copy through `libraryClient` (the read-only guard) and
    /// writes "Save to Photos" to the device library through `photos`.
    /// V1.5 polish (AC-718): wire 0.033s render debounce (≈30fps cap) for production.
    func makePhotoEditorViewModel(asset: AssetReactItem) -> PhotoEditorViewModel {
        let vm = PhotoEditorViewModel(
            assetId: asset.id, client: libraryClient, appLog: appLog, photos: photos,
            urlSession: { [serverSessions] in serverSessions.transfers }, customHeaders: customHeaders
        )
        vm.renderDebounceInterval = 0.033
        return vm
    }

    /// Locked folder (gap G12). Takes the active account because the remembered
    /// PIN is stored per account — two servers must never share one code.
    func makeLockedFolderViewModel(accountID: String) -> LockedFolderViewModel {
        LockedFolderViewModel(
            client: libraryClient,
            pins: lockedFolderPINs,
            accountID: accountID
        )
    }
}
