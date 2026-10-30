import Foundation

/// Wipes what the app keeps on disk and in memory *about the account*, when the
/// user signs out on purpose: backup ledger, offline copies, map markers,
/// thumbnail caches and the network connections of the API client and of the
/// server sessions (`ServerSessions`: images, transfers, road trip).
///
/// Transfers are stopped first — a backup or an offline download still running
/// would otherwise write into the stores right after they were emptied. The
/// order is the contract; see `purgeAll()`.
///
/// It also scopes the per-account offline copies: `activateAccount` is called
/// on every session change. At logout, step 2 deactivates the account first,
/// then calls `clearEveryAccount`, so nothing rewrites the store during the
/// rest of the purge.
///
/// Credentials, the registered-accounts list and the trusted-servers list are
/// not owned here: `AuthViewModel.logout()` clears them itself, the trusted
/// servers *before* calling this purge so the final connection reset leaves no
/// trusted connection behind.
@MainActor
final class LocalDataPurger {
    private let backupEngine: BackupEngine
    private let offlineStore: OfflineAssetStore
    private let offlineIndex: OfflineAssetIndex
    private let imageCache: ImageCache
    private let imageDiskCache: URLCache
    private let apiClient: ImmichAPIClient
    private let serverSessions: any ConnectionResetting
    private let mapCacheDirectory: URL?

    /// `mapCacheDirectory`: root of the map cache (`nil` = `Caches`, same default
    /// as `MapMarkerCache`); tests inject a temporary one.
    init(
        backupEngine: BackupEngine,
        offlineStore: OfflineAssetStore,
        offlineIndex: OfflineAssetIndex,
        imageCache: ImageCache,
        imageDiskCache: URLCache,
        apiClient: ImmichAPIClient,
        serverSessions: any ConnectionResetting,
        mapCacheDirectory: URL? = nil
    ) {
        self.backupEngine = backupEngine
        self.offlineStore = offlineStore
        self.offlineIndex = offlineIndex
        self.imageCache = imageCache
        self.imageDiskCache = imageDiskCache
        self.apiClient = apiClient
        self.serverSessions = serverSessions
        self.mapCacheDirectory = mapCacheDirectory
    }

    /// Scopes the offline copies to `accountID` (`nil` = no session). Called by
    /// `AuthViewModel` on every session change; synchronous, so the offline
    /// index is already empty of the previous account's copies on return.
    func activateAccount(_ accountID: String?, otherAccountsRegistered: Bool) {
        offlineIndex.activate(accountID, otherAccountsRegistered: otherAccountsRegistered, store: offlineStore)
    }

    func purgeAll() async {
        // 1. Stop the backup run and wait for it: no `markBackedUp` / `save()`
        //    may reach the ledger after step 4.
        await backupEngine.stopAndWait()
        // 2. Offline copies. No account is active first, so a download, removal
        //    or clear that reaches the store from here until `resetSession()` is
        //    refused and nothing rewrites `OfflineAssets/`; then every account's
        //    copies (and `Unassigned/`) go, in-flight transfers cancelled.
        activateAccount(nil, otherAccountsRegistered: false)
        await offlineStore.clearEveryAccount()
        offlineIndex.removeAll()
        // 3. Map markers (GPS positions of every account, legacy file included)
        //    and thumbnails: memory tier (its epoch drops loads in flight) +
        //    disk tier.
        MapMarkerCache.removeAll(directory: mapCacheDirectory)
        await imageCache.removeAll()
        imageDiskCache.removeAllCachedResponses()
        // 4. Backup ledger (also refreshes the cloud-status badges).
        backupEngine.forgetAllBackedUp()
        // 5. Fresh sockets on the API client and on every server session, so the
        //    next connection faces a new TLS challenge.
        await apiClient.resetConnections()
        await serverSessions.resetConnections()
    }
}
