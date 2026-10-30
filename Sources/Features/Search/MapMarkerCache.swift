import Foundation

/// File-backed cache of map markers so repeat map opens render instantly (no
/// network round-trip) while a silent, TTL-throttled background refresh in
/// `MapViewModel` keeps coordinates fresh.
///
/// Stored as JSON files in Caches/ (regenerable from the server, so
/// Caches is the correct domain — the OS may evict it under pressure), one
/// folder per account and one file per marker-filter variant. The
/// whole-catalogue payload can be large (10k+ markers); callers therefore run
/// `load`/`save` off the MainActor (`MapMarkerCache` is `Sendable`).
///
/// The persisted entry carries a `savedAt` timestamp so the ViewModel can
/// decide whether the cached set is fresh enough to skip the background
/// refresh entirely (see `age()`).
struct MapMarkerCache: Sendable {
    /// Persisted envelope: the markers plus when they were written.
    private struct Entry: Codable {
        let savedAt: Date
        let markers: [MapMarkerResponseDto]
    }

    private let fileURL: URL
    private let accountID: String

    /// Root the cache was opened on (Caches/ by default), kept so the same
    /// cache can be re-opened for another filter variant.
    private let root: URL

    /// Default location: Caches/MapMarkers/<storageKey(accountID)>/markers.json.
    ///
    /// Every file lives under the account's folder, so one account never reads
    /// another's positions (GPS coordinates). A file from a version without
    /// accounts (`MapMarkers/markers*.json`) is never read; `removeAll` wipes it.
    ///
    /// `variant` comes from `MapMarkerFilter.cacheVariant`: `nil` (the
    /// unconstrained filter) uses `markers.json`. A constrained filter gets its
    /// own `markers-<variant>.json`, because two filters must never overwrite
    /// each other's payload (a filtered response is not a valid answer for
    /// another filter).
    init(accountID: String, directory: URL? = nil, variant: String? = nil) {
        let root = directory ?? Self.defaultRoot
        self.accountID = accountID
        self.root = root
        let base = Self.markersFolder(in: root)
            .appendingPathComponent(SavedAccount.storageKey(forID: accountID), isDirectory: true)
        self.fileURL = variant.map { base.appendingPathComponent("markers-\($0).json") }
            ?? base.appendingPathComponent("markers.json")
    }

    /// Same account and location, another filter variant.
    func variant(_ variant: String?) -> MapMarkerCache {
        MapMarkerCache(accountID: accountID, directory: root, variant: variant)
    }

    /// Cached markers, or nil if the cache is empty/unreadable.
    func load() -> [MapMarkerResponseDto]? {
        loadEntry()?.markers
    }

    /// Seconds since the cache was written, or nil if there is no cache.
    /// Drives the ViewModel's refresh throttle (skip refetch while fresh).
    func age() -> TimeInterval? {
        guard let savedAt = loadEntry()?.savedAt else { return nil }
        return Date().timeIntervalSince(savedAt)
    }

    private func loadEntry() -> Entry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.immich.decode(Entry.self, from: data)
    }

    /// Writes the markers atomically, stamping the current time.
    func save(_ markers: [MapMarkerResponseDto]) {
        let entry = Entry(savedAt: Date(), markers: markers)
        guard let data = try? JSONEncoder.immich.encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes `<root>/MapMarkers` entirely: every account, every variant and
    /// any file left by a version that had no account notion. No-op when absent.
    static func removeAll(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: markersFolder(in: directory ?? defaultRoot))
    }

    private static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func markersFolder(in root: URL) -> URL {
        root.appendingPathComponent("MapMarkers", isDirectory: true)
    }
}
