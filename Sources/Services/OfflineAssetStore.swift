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

/// Durable local cache of asset originals, backed by files under
/// **Application Support** (never `Caches`: the OS purges that directory under
/// disk pressure, and an asset advertised as available offline must not vanish).
///
/// Layout:
/// ```
/// Application Support/OfflineAssets/
/// ├── index.json          # [CachedAssetInfo] — metadata, reconciled with disk
/// └── <assetId>.<ext>     # the payload
/// ```
///
/// Downloads stream to disk (`URLSession.download(for:delegate:)` writes a temp
/// file; nothing is ever materialized as `Data` in memory) and land through an
/// atomic move, so a killed process leaves at most a `.partial` file that the
/// next launch deletes.
actor OfflineAssetStore {

    /// `UserDefaults` key holding the cache budget in bytes.
    static let maxCacheSizeKey = "offlineMaxSize"
    static let defaultMaxCacheSize: Int64 = 5 * 1024 * 1024 * 1024

    /// Directory holding `index.json` and the payloads. `nonisolated` so the
    /// UI-side index can resolve a cached file's URL synchronously from a cell.
    nonisolated let folderURL: URL

    private let transport: any FileDownloadTransport
    private let fileManager: FileManager
    private let defaults: UserDefaults

    private var index: [String: CachedAssetInfo] = [:]
    private var didLoadIndex = false

    /// The folder every store writes to unless a test injects its own.
    static func defaultFolderURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("OfflineAssets", isDirectory: true)
    }

    init(
        folderURL: URL? = nil,
        transport: (any FileDownloadTransport)? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.folderURL = folderURL ?? Self.defaultFolderURL(fileManager: fileManager)
        self.transport = transport ?? URLSessionFileDownloadTransport()
        self.fileManager = fileManager
        self.defaults = defaults
    }

    // MARK: - Configuration

    /// Configured budget in bytes. `0` means "unlimited" (explicit opt-out).
    var maxCacheSize: Int64 {
        let stored = defaults.object(forKey: Self.maxCacheSizeKey) as? Int
        guard let stored else { return Self.defaultMaxCacheSize }
        return stored == 0 ? 0 : Int64(stored)
    }

    /// Persists a new budget and immediately trims the cache down to it.
    func setMaxCacheSize(_ bytes: Int64) async {
        defaults.set(Int(max(0, bytes)), forKey: Self.maxCacheSizeKey)
        evictIfNeeded()
    }

    // MARK: - Download

    /// Downloads `url` (the asset's `/original`, built by the caller with
    /// `ImmichAssetURL.original`) into the cache.
    ///
    /// - Parameters:
    ///   - announcedSize: the server's `fileSizeInByte` when known — the budget
    ///     is checked against it *before* the transfer starts.
    ///   - onProgress: `(received, expected)`; `expected` is 0 when the server
    ///     sends no `Content-Length` (the caller then shows an indeterminate bar).
    @discardableResult
    func download(
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
        try loadIndexIfNeeded()
        try ensureFolderExists()

        let limit = maxCacheSize
        if let announcedSize, limit > 0, announcedSize > limit {
            throw OfflineStoreError.exceedsCacheLimit(size: announcedSize, limit: limit)
        }

        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let downloaded = try await transport.download(request, onProgress: onProgress)
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
            try? fileManager.removeItem(at: folderURL.appendingPathComponent(previous.fileName))
        }
        let destination = folderURL.appendingPathComponent(storedName)
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
        saveIndex()
        evictIfNeeded(keeping: assetID)
        return info
    }

    // MARK: - Reads

    func cachedInfo(assetID: String) -> CachedAssetInfo? {
        try? loadIndexIfNeeded()
        guard let info = index[assetID] else { return nil }
        // A stale entry (file deleted behind our back, e.g. purge or a failed
        // write) must never be reported as cached.
        guard fileManager.fileExists(atPath: fileURL(for: info.fileName).path) else {
            index[assetID] = nil
            saveIndex()
            return nil
        }
        return info
    }

    /// On-disk URL of a cached asset, or nil when it isn't cached.
    func fileURL(assetID: String) -> URL? {
        cachedInfo(assetID: assetID).map { fileURL(for: $0.fileName) }
    }

    /// Every cached asset, most recent first.
    func allCached() -> [CachedAssetInfo] {
        try? loadIndexIfNeeded()
        return index.values.sorted { $0.cachedAt > $1.cachedAt }
    }

    func isCached(assetID: String) -> Bool {
        cachedInfo(assetID: assetID) != nil
    }

    /// Total bytes currently held on disk.
    func totalBytes() -> Int64 {
        allCached().reduce(0) { $0 + $1.size }
    }

    // MARK: - Removal

    func remove(assetID: String) {
        try? loadIndexIfNeeded()
        guard let info = index.removeValue(forKey: assetID) else { return }
        try? fileManager.removeItem(at: fileURL(for: info.fileName))
        saveIndex()
    }

    func clearAll() {
        try? loadIndexIfNeeded()
        index.removeAll()
        for url in (try? fileManager.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil
        )) ?? [] {
            try? fileManager.removeItem(at: url)
        }
        saveIndex()
    }

    // MARK: - Index

    private func fileURL(for fileName: String) -> URL {
        folderURL.appendingPathComponent(fileName)
    }

    private func ensureFolderExists() throws {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    private func loadIndexIfNeeded() throws {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        try ensureFolderExists()
        // Drop half-written payloads from a previous run that a jetsam kill
        // (or an interrupted move) left behind.
        for url in (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "partial" {
            try? fileManager.removeItem(at: url)
        }
        let data = try? Data(contentsOf: fileURL(for: "index.json"))
        if let data, let decoded = try? JSONDecoder.immich.decode([CachedAssetInfo].self, from: data) {
            index = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            index = [:]
        }
        reconcile()
    }

    /// Confronts the index with the disk: entries whose file is gone are
    /// dropped, and files with no entry (an index lost to a crash) are adopted
    /// from their filesystem attributes rather than orphaned.
    private func reconcile() {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folderURL,
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
        if changed { saveIndex() }
    }

    private func saveIndex() {
        let encoder = JSONEncoder.immich
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index.values.sorted { $0.id < $1.id }) else { return }
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: "index.json"), options: .atomic)
    }

    /// Trims the oldest entries until the cache fits the budget. The asset that
    /// was just written is never the one evicted (`keeping:`).
    private func evictIfNeeded(keeping protectedID: String? = nil) {
        let limit = maxCacheSize
        guard limit > 0 else { return }
        var total = index.values.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        for candidate in index.values.sorted(by: { $0.cachedAt < $1.cachedAt }) {
            guard total > limit else { break }
            guard candidate.id != protectedID else { continue }
            index[candidate.id] = nil
            try? fileManager.removeItem(at: fileURL(for: candidate.fileName))
            total -= candidate.size
        }
        saveIndex()
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
