import Foundation

/// One asset held in the offline cache.
///
/// The metadata travels with the payload so the offline screen can rebuild a
/// grid cell (thumbnail URL needs `thumbhash`, the cell needs the ratio and the
/// video flag) without asking the server — the server is exactly what isn't
/// available when this cache matters.
struct CachedAssetInfo: Codable, Equatable, Sendable {
    let id: String
    /// File name inside the cache folder (extension included). Derived from the
    /// asset id so a re-download always lands on the same path — the asset id
    /// is unique and filesystem-safe; the server's name is not.
    var fileName: String
    /// The server's own file name ("IMG_0421.HEIC"). Kept for display and
    /// search: `fileName` is an opaque id, which nobody can search for.
    var originalFileName: String?
    var cachedAt: Date
    var size: Int64
    var isVideo: Bool
    var ratio: Double
    var fileCreatedAt: String
    /// Milliseconds (the Immich unit, persisted verbatim) — render with
    /// `VideoDurationFormatter.string(milliseconds:)`.
    var duration: Int?
    var thumbhash: String?

    /// What the storage screen shows and searches.
    var displayName: String { originalFileName ?? fileName }

    /// Grid-rendering form, so `AssetThumbnailCell` can show a cached asset
    /// exactly like a timeline tile. Owner/visibility/favorite are not part of
    /// the cache's contract: an offline tile is not editable.
    var reactItem: AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "", ratio: ratio, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: !isVideo, thumbhash: thumbhash,
            createdAt: fileCreatedAt, fileCreatedAt: fileCreatedAt, localOffsetHours: 0,
            duration: duration, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }
}

enum OfflineStoreError: LocalizedError, Equatable {
    /// The asset's announced size alone blows the configured budget, so the
    /// download is refused *before* any byte is pulled.
    case exceedsCacheLimit(size: Int64, limit: Int64)
    case badStatus(Int)
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case let .exceedsCacheLimit(size, limit):
            return String(
                localized: "This file is \(Self.format(size)) — larger than the \(Self.format(limit)) offline budget."
            )
        case let .badStatus(code):
            return UserFacingError.from(code == 401 ? APIError.unauthorized : APIError.http(code))?.message
        case .emptyPayload:
            return String(localized: "The downloaded file was empty.")
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Everything `OfflineAssetStore` needs to know about who is signed in.
struct OfflineScope: Sendable, Equatable {
    /// `SavedAccount.id` of the active account; `nil` = none (nothing is served,
    /// every operation is refused).
    let accountID: String?
    /// Whether the registry holds an account other than the active one — decides
    /// where the legacy single-folder content goes.
    let otherAccountsRegistered: Bool
    /// Bumped each time `accountID` changes.
    let epoch: Int
}

/// What `OfflineAssetStore.listing()` saw, tagged with the scope it was read
/// under so a slow reader can be recognised as stale.
struct OfflineListing: Sendable, Equatable {
    let accountID: String?
    let scopeEpoch: Int
    /// Folder of the listed account; `nil` when no account was active.
    let folderURL: URL?
    /// Most recent first.
    let items: [CachedAssetInfo]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

/// Lock-protected scope, readable and writable synchronously from any thread.
private final class OfflineScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var scope = OfflineScope(accountID: nil, otherAccountsRegistered: false, epoch: 0)

    func snapshot() -> OfflineScope {
        lock.lock()
        defer { lock.unlock() }
        return scope
    }

    func set(_ accountID: String?, otherAccountsRegistered: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = scope.accountID != accountID
        scope = OfflineScope(
            accountID: accountID,
            otherAccountsRegistered: otherAccountsRegistered,
            epoch: changed ? scope.epoch + 1 : scope.epoch
        )
        return changed
    }
}

/// Durable local cache of asset originals, one folder per account, backed by
/// files under **Application Support** (never `Caches`: the OS purges that
/// directory under disk pressure, and an asset advertised as available offline
/// must not vanish).
///
/// Layout (`OfflineAssets` carries `isExcludedFromBackup`, re-set whenever a
/// folder is created; everything below inherits it):
/// ```
/// Application Support/OfflineAssets/          # excluded from backup
/// ├── Accounts/<storageKey>/                  # storageKey = SavedAccount.storageKey(forID:)
/// │   ├── index.json                          # [CachedAssetInfo] — metadata, reconciled with disk
/// │   └── <assetId>.<ext>                     # the payload
/// └── Unassigned/                             # legacy content that fit no account: never read, wiped at logout
/// ```
///
/// The active account is set synchronously by `setActiveAccount`. Reads serve
/// that account only; `download`, `remove` and `clearAll` take the account they
/// were issued for and are refused (`CancellationError` / `false`) when it is
/// not the active one. `maxCacheSize` applies to each account's folder
/// separately. Content left by the single-folder layout is moved, never
/// deleted (a `.partial` apart), at the first load of an account: into its
/// folder when three guards hold (no other account registered, no
/// `Unassigned/`, nothing else under `Accounts/`; evaluated once per pass),
/// into `Unassigned/` (flagged excluded from backup) otherwise or on a name
/// collision (`<UUID>-<name>`). A move that fails falls back to `Unassigned/`,
/// then the item stays at the root, served to nobody. The root is never
/// reconciled (it would adopt `Accounts/` and `Unassigned/` as copies).
///
/// Downloads stream to disk (`URLSession.download(for:delegate:)` writes a temp
/// file; nothing is ever materialized as `Data` in memory) and land through an
/// atomic move, so a killed process leaves at most a `.partial` file that the
/// next load of that account deletes.
actor OfflineAssetStore {

    /// `UserDefaults` key holding the cache budget in bytes.
    static let maxCacheSizeKey = "offlineMaxSize"
    static let defaultMaxCacheSize: Int64 = 5 * 1024 * 1024 * 1024
    static let accountsFolderName = "Accounts"
    static let unassignedFolderName = "Unassigned"

    /// `OfflineAssets`. `nonisolated` so the UI-side index can resolve paths
    /// synchronously.
    nonisolated let rootURL: URL

    private let transport: any FileDownloadTransport
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private nonisolated let scope = OfflineScopeBox()

    /// Account whose index is in memory, with the epoch it was loaded under.
    private var loaded: (epoch: Int, accountID: String, folder: URL)?
    private var index: [String: CachedAssetInfo] = [:]
    private var didLoadIndex = false
    /// Bumped by `clearAll(accountID:)` and `clearEveryAccount()`. A download
    /// that captured an older value must not write anything: its payload
    /// belongs to a cache that no longer exists.
    private var generation = 0
    private var inFlight: [UUID: Task<DownloadedFile, Error>] = [:]

    /// The root every store writes to unless a test injects its own.
    static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("OfflineAssets", isDirectory: true)
    }

    init(
        rootURL: URL? = nil,
        transport: any FileDownloadTransport,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.transport = transport
        self.fileManager = fileManager
        self.defaults = defaults
    }

    // MARK: - Active account

    nonisolated func folderURL(forAccount accountID: String) -> URL {
        rootURL
            .appendingPathComponent(Self.accountsFolderName, isDirectory: true)
            .appendingPathComponent(SavedAccount.storageKey(forID: accountID), isDirectory: true)
    }

    nonisolated var unassignedURL: URL {
        rootURL.appendingPathComponent(Self.unassignedFolderName, isDirectory: true)
    }

    /// Synchronous (no `await`, no disk access). Returns `true` when the active
    /// account changed; otherwise only `otherAccountsRegistered` is refreshed.
    @discardableResult
    nonisolated func setActiveAccount(_ accountID: String?, otherAccountsRegistered: Bool) -> Bool {
        scope.set(accountID, otherAccountsRegistered: otherAccountsRegistered)
    }

    nonisolated var scopeEpoch: Int { scope.snapshot().epoch }
    nonisolated var activeAccountID: String? { scope.snapshot().accountID }

    // MARK: - Configuration

    /// Configured budget in bytes. `0` means "unlimited" (explicit opt-out).
    var maxCacheSize: Int64 {
        let stored = defaults.object(forKey: Self.maxCacheSizeKey) as? Int
        guard let stored else { return Self.defaultMaxCacheSize }
        return stored == 0 ? 0 : Int64(stored)
    }

    /// Persists a new budget and immediately trims the active account's copies
    /// down to it. Other accounts are only trimmed when they next download or
    /// change the budget while active.
    func setMaxCacheSize(_ bytes: Int64) async {
        defaults.set(Int(max(0, bytes)), forKey: Self.maxCacheSizeKey)
        if let folder = activeFolder() { evictIfNeeded(folder) }
    }

    // MARK: - Download

    /// Downloads `url` (the asset's `/original`, built by the caller with
    /// `ImmichAssetURL.original`) into the cache.
    ///
    /// Bound to `accountID`: refused with `CancellationError` (no request, no
    /// disk access) when it isn't the active account, and dropped the same way
    /// — temp file deleted, nothing written — when it isn't any more when the
    /// transfer ends.
    ///
    /// - Parameters:
    ///   - announcedSize: the server's `fileSizeInByte` when known — the budget
    ///     is checked against it *before* the transfer starts.
    ///   - onProgress: `(received, expected)`; `expected` is 0 when the server
    ///     sends no `Content-Length` (the caller then shows an indeterminate bar).
    @discardableResult
    func download(
        accountID: String,
        assetID: String,
        url: URL,
        token: String?,
        fileName: String?,
        isVideo: Bool,
        ratio: Double,
        fileCreatedAt: String,
        duration: Int?,
        thumbhash: String?,
        announcedSize: Int64?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> CachedAssetInfo {
        // Refused before any disk access or request when `accountID` isn't the
        // active account (nor any account at all).
        let entry = scope.snapshot()
        guard entry.accountID == accountID, let folder = try prepare(entry) else {
            throw CancellationError()
        }
        try ensureFolderExists(folder)

        let limit = maxCacheSize
        if let announcedSize, limit > 0, announcedSize > limit {
            throw OfflineStoreError.exceedsCacheLimit(size: announcedSize, limit: limit)
        }

        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // The transport runs in a registered Task so `clearAll(accountID:)` /
        // `clearEveryAccount()` can cancel it. The actor is re-entrant across
        // this await: `generation` tells us after the fact whether a purge
        // happened meanwhile, even when the transport ignores the cancellation
        // and finishes anyway. A switch of account does NOT cancel the transfer;
        // it is dropped when it ends.
        let startGeneration = generation
        let transport = self.transport
        let transferID = UUID()
        let transfer = Task { try await transport.download(request, onProgress: onProgress) }
        inFlight[transferID] = transfer
        let downloaded: DownloadedFile
        do {
            downloaded = try await withTaskCancellationHandler {
                try await transfer.value
            } onCancel: {
                transfer.cancel()
            }
        } catch {
            inFlight[transferID] = nil
            if startGeneration != generation || scope.snapshot().accountID != accountID {
                throw CancellationError()
            }
            throw error
        }
        inFlight[transferID] = nil
        let now = scope.snapshot()
        guard startGeneration == generation, now.accountID == accountID,
              let target = try? prepare(now) else {
            try? fileManager.removeItem(at: downloaded.url)
            throw CancellationError()
        }
        if let status = downloaded.statusCode, !(200..<300).contains(status) {
            try? fileManager.removeItem(at: downloaded.url)
            throw OfflineStoreError.badStatus(status)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: downloaded.url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else {
            try? fileManager.removeItem(at: downloaded.url)
            throw OfflineStoreError.emptyPayload
        }

        // The server's own name wins (it carries the real extension); the
        // response Content-Type breaks the tie for a nameless asset.
        let ext = Self.fileExtension(fileName: fileName, contentType: downloaded.contentType, isVideo: isVideo)
        let storedName = "\(Self.sanitizedName(assetID)).\(ext)"

        // Replace in place: a re-download with a different extension must not
        // leave the previous payload behind.
        if let previous = index[assetID], previous.fileName != storedName {
            try? fileManager.removeItem(at: target.appendingPathComponent(previous.fileName))
        }
        let destination = target.appendingPathComponent(storedName)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: downloaded.url, to: destination)

        let info = CachedAssetInfo(
            id: assetID,
            fileName: storedName,
            originalFileName: fileName,
            cachedAt: Date(),
            size: bytes,
            isVideo: isVideo,
            ratio: ratio,
            fileCreatedAt: fileCreatedAt,
            duration: duration,
            thumbhash: thumbhash
        )
        index[assetID] = info
        saveIndex(target)
        evictIfNeeded(target, keeping: assetID)
        return info
    }

    // MARK: - Reads (active account)

    func cachedInfo(assetID: String) -> CachedAssetInfo? {
        guard let folder = activeFolder() else { return nil }
        guard let info = index[assetID] else { return nil }
        // A stale entry (file deleted behind our back, e.g. purge or a failed
        // write) must never be reported as cached.
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(info.fileName).path) else {
            index[assetID] = nil
            saveIndex(folder)
            return nil
        }
        return info
    }

    /// On-disk URL of a cached asset, or nil when it isn't cached.
    func fileURL(assetID: String) -> URL? {
        guard let info = cachedInfo(assetID: assetID), let folder = loaded?.folder else { return nil }
        return folder.appendingPathComponent(info.fileName)
    }

    /// Every cached asset of the active account, most recent first.
    func allCached() -> [CachedAssetInfo] {
        guard activeFolder() != nil else { return [] }
        return index.values.sorted { $0.cachedAt > $1.cachedAt }
    }

    func isCached(assetID: String) -> Bool {
        cachedInfo(assetID: assetID) != nil
    }

    /// Total bytes the active account holds on disk.
    func totalBytes() -> Int64 {
        allCached().reduce(0) { $0 + $1.size }
    }

    /// Snapshot of the active account's copies, tagged with the scope it was
    /// read under so the UI mirror can drop it when the account changed since.
    func listing() -> OfflineListing {
        let s = scope.snapshot()
        guard let id = s.accountID else {
            _ = try? prepare(s)
            return OfflineListing(accountID: nil, scopeEpoch: s.epoch, folderURL: nil, items: [])
        }
        guard let folder = try? prepare(s) else {
            return OfflineListing(
                accountID: id, scopeEpoch: s.epoch, folderURL: folderURL(forAccount: id), items: []
            )
        }
        return OfflineListing(
            accountID: id,
            scopeEpoch: s.epoch,
            folderURL: folder,
            items: index.values.sorted { $0.cachedAt > $1.cachedAt }
        )
    }

    // MARK: - Removal

    /// Removes one copy of `accountID`; refused (`false`, nothing touched) when
    /// that account is not the active one.
    @discardableResult
    func remove(assetID: String, accountID: String) -> Bool {
        let s = scope.snapshot()
        guard s.accountID == accountID else { return false }
        guard let folder = try? prepare(s),
              let info = index.removeValue(forKey: assetID) else { return true }
        try? fileManager.removeItem(at: folder.appendingPathComponent(info.fileName))
        saveIndex(folder)
        return true
    }

    /// Wipes the copies of `accountID` (and only those) and aborts every
    /// transfer still in flight: each pending `download` throws a cancellation
    /// and writes nothing (see `generation`). Refused (`false`) when that
    /// account is not the active one.
    @discardableResult
    func clearAll(accountID: String) -> Bool {
        let s = scope.snapshot()
        guard s.accountID == accountID else { return false }
        generation += 1
        for task in inFlight.values { task.cancel() }
        _ = try? prepare(s)
        let folder = folderURL(forAccount: accountID)
        index.removeAll()
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
        saveIndex(folder)
        try? ensureFolderExists(folder)
        return true
    }

    /// Wipes every account's copies, `Unassigned/` and any legacy leftover,
    /// whatever the active account, and aborts every transfer in flight. The
    /// root stays (and stays excluded from backup); no `index.json` is written.
    func clearEveryAccount() {
        generation += 1
        for task in inFlight.values { task.cancel() }
        index = [:]
        didLoadIndex = false
        loaded = nil
        for url in (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
        try? ensureFolderExists(rootURL)
    }

    // MARK: - Index

    /// Points the actor at the snapshot's account (reloading its index when the
    /// epoch moved) and returns that account's folder; `nil` when no account is
    /// active. Never evicts: activation does not trim (decision req #3).
    private func prepare(_ s: OfflineScope) throws -> URL? {
        guard let id = s.accountID else {
            index = [:]
            didLoadIndex = false
            loaded = nil
            return nil
        }
        if loaded?.epoch != s.epoch {
            index = [:]
            didLoadIndex = false
            loaded = (s.epoch, id, folderURL(forAccount: id))
        }
        let folder = folderURL(forAccount: id)
        try loadIndexIfNeeded(folder: folder, otherAccountsRegistered: s.otherAccountsRegistered)
        return folder
    }

    private func activeFolder() -> URL? {
        try? prepare(scope.snapshot())
    }

    /// Creates the root (flagged excluded from backup, every time: file
    /// operations can reset the flag) then `folder`. The flag sits on the root
    /// alone and is inherited by everything below; never on Application Support.
    private func ensureFolderExists(_ folder: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var root = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func loadIndexIfNeeded(folder: URL, otherAccountsRegistered: Bool) throws {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        try ensureFolderExists(folder)
        adoptLegacyContent(into: folder, otherAccountsRegistered: otherAccountsRegistered)
        // Drop half-written payloads from a previous run that a jetsam kill
        // (or an interrupted move) left behind.
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "partial" {
            try? fileManager.removeItem(at: url)
        }
        let data = try? Data(contentsOf: folder.appendingPathComponent("index.json"))
        if let data, let decoded = try? JSONDecoder.immich.decode([CachedAssetInfo].self, from: data) {
            index = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            index = [:]
        }
        reconcile(folder)
    }

    /// Moves what the single-folder layout left directly under the root: into
    /// `folder` or into `Unassigned/`. Three guards, evaluated once before the
    /// first move of the pass, send everything to the account folder only when
    /// no other account is registered (`otherAccountsRegistered == false`),
    /// `Unassigned/` does not exist, and `Accounts/` holds nothing but `folder`
    /// (so a leftover of an earlier pass is never handed to another account).
    /// A `.partial` is deleted, never moved. A name already taken at the
    /// destination goes to `Unassigned/<UUID>-<name>`. A move that fails falls
    /// back to `Unassigned/<UUID>-<name>` once; if that fails too the item stays
    /// at the root, served to no account, and is retried at the next first load.
    /// Nothing else is deleted or overwritten, and `Unassigned/` is flagged
    /// excluded from backup each time it is (re)created.
    private func adoptLegacyContent(into folder: URL, otherAccountsRegistered: Bool) {
        let reserved: Set<String> = [Self.accountsFolderName, Self.unassignedFolderName]
        let legacy = ((try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { !reserved.contains($0.lastPathComponent) }
        guard !legacy.isEmpty else { return }
        let toAccount = !otherAccountsRegistered
            && !fileManager.fileExists(atPath: unassignedURL.path)
            && accountsHoldOnly(folder)
        func setAside(_ name: String) -> URL {
            unassignedURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        }
        for item in legacy {
            if item.pathExtension == "partial" {
                try? fileManager.removeItem(at: item)
                continue
            }
            let name = item.lastPathComponent
            var target = (toAccount ? folder : unassignedURL).appendingPathComponent(name)
            var isPrefixed = false
            if fileManager.fileExists(atPath: target.path) {
                target = setAside(name)
                isPrefixed = true
            }
            if isPrefixed || !toAccount { ensureUnassignedExists() }
            do {
                try fileManager.moveItem(at: item, to: target)
            } catch where !isPrefixed {
                ensureUnassignedExists()
                try? fileManager.moveItem(at: item, to: setAside(name))
            } catch {
                // Already the last resort: the item stays at the root.
            }
        }
    }

    /// `true` when `Accounts/` is readable and every child (hidden ones
    /// included) is `folder`.
    private func accountsHoldOnly(_ folder: URL) -> Bool {
        let accounts = rootURL.appendingPathComponent(Self.accountsFolderName, isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil) else {
            return false
        }
        return children.allSatisfy { $0.lastPathComponent == folder.lastPathComponent }
    }

    /// Creates `Unassigned/` and flags it excluded from backup. Idempotent and
    /// redone before every move into it: the folder may have been deleted and
    /// recreated since. A failure is left to the move that follows.
    private func ensureUnassignedExists() {
        try? ensureFolderExists(unassignedURL)
        var unassigned = unassignedURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? unassigned.setResourceValues(values)
    }

    /// Confronts the index with the disk: entries whose file is gone are
    /// dropped, and files with no entry (an index lost to a crash) are adopted
    /// from their filesystem attributes rather than orphaned. Only ever run on
    /// an account folder, never on the root.
    private func reconcile(_ folder: URL) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        let payloads = contents.filter { $0.lastPathComponent != "index.json" }
        let onDisk = Set(payloads.map(\.lastPathComponent))

        var changed = false
        for (id, info) in index where !onDisk.contains(info.fileName) {
            index[id] = nil
            changed = true
        }
        let known = Set(index.values.map(\.fileName))
        for url in payloads where !known.contains(url.lastPathComponent) {
            let id = url.deletingPathExtension().lastPathComponent
            guard index[id] == nil else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            index[id] = CachedAssetInfo(
                id: id,
                fileName: url.lastPathComponent,
                originalFileName: nil,
                cachedAt: values?.contentModificationDate ?? Date(),
                size: Int64(values?.fileSize ?? 0),
                isVideo: Self.videoExtensions.contains(url.pathExtension.lowercased()),
                ratio: 1.0,
                fileCreatedAt: "",
                duration: nil,
                thumbhash: nil
            )
            changed = true
        }
        if changed { saveIndex(folder) }
    }

    private func saveIndex(_ folder: URL) {
        let encoder = JSONEncoder.immich
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index.values.sorted { $0.id < $1.id }) else { return }
        try? ensureFolderExists(folder)
        try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    /// Trims the oldest entries of the loaded account until it fits the budget.
    /// The asset that was just written is never the one evicted (`keeping:`).
    private func evictIfNeeded(_ folder: URL, keeping protectedID: String? = nil) {
        let limit = maxCacheSize
        guard limit > 0 else { return }
        var total = index.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        for candidate in index.values.sorted(by: { $0.cachedAt < $1.cachedAt }) {
            guard total > limit else { break }
            guard candidate.id != protectedID else { continue }
            index[candidate.id] = nil
            try? fileManager.removeItem(at: folder.appendingPathComponent(candidate.fileName))
            total -= candidate.size
        }
        saveIndex(folder)
    }

    // MARK: - Naming

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    private static func sanitizedName(_ assetID: String) -> String {
        assetID.replacingOccurrences(of: "/", with: "_")
    }

    private static func fileExtension(fileName: String?, contentType: String?, isVideo: Bool) -> String {
        if let fileName, !fileName.isEmpty {
            let ext = (fileName as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        if let contentType, !contentType.isEmpty {
            return AssetFileTransfer.fileExtension(forMime: contentType)
        }
        return isVideo ? "mp4" : "jpg"
    }
}
