import Foundation
import Photos
import UIKit
import os

/// PHPhotoLibrary-backed implementation of PhotoLibraryService.
final class PhotoLibraryServiceImpl: PhotoLibraryService, @unchecked Sendable {

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { handler($0) }
    }

    func fetchAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    func fetchAssets(inAlbumID albumID: String) -> [PHAsset] {
        guard let collection = Self.collection(forAlbumID: albumID) else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Property hint, same as `fetchAssets()`: the predicate filters nothing,
        // it only forces Photos to pre-fetch what the caller will read.
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")
        let result = PHAsset.fetchAssets(in: collection, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Stall window of the export watchdog in `writeResource`: how long one
    /// resource request may go without a progress tick or completion before it
    /// counts as hung (`BackupExportError.cloudDownloadPending`, retried on the
    /// next run). Bounds "Checking library…" to at worst library × interval
    /// instead of potentially infinite.
    private static let loadTimeoutSeconds: TimeInterval = 90

    /// iCloud-optimized originals can transiently report
    /// `CloudPhotoLibraryErrorDomain` 1005 ("asset not local and not
    /// preparing") when the download hasn't been scheduled yet — distinct from
    /// a genuinely missing/corrupt asset. Re-issuing the resource request nudges
    /// iCloud to start the download; deferring quickly after a single retry lets
    /// the run reach already-local assets fast, while iCloud-only ones are
    /// picked up on the next run once their download has landed.
    private static let cloudRetryAttempts = 2
    private static let cloudRetryDelayNanos: UInt64 = 2 * 1_000_000_000

    /// True when `error` is the retryable iCloud "not local and not preparing"
    /// condition (code 1005), directly or wrapped as an underlying error.
    static func isCloudNotReady(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "CloudPhotoLibraryErrorDomain" && ns.code == 1005 { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == "CloudPhotoLibraryErrorDomain" && underlying.code == 1005 {
            return true
        }
        return false
    }

    func loadThumbnail(for asset: PHAsset, targetSize: CGSize, scale: CGFloat) async -> UIImage? {
        // The process-wide image manager, reused rather than rebuilt per tile:
        // Photos coalesces identical in-flight requests and keeps its own
        // decoded-image cache behind this one instance.
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        // The screen inventories the *device*: an iCloud-evicted original stays a
        // placeholder instead of starting a download behind the grid.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.isSynchronous = false
        options.resizeMode = .fast
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)

        // A cancelled or resource-less tile answers `nil` through the same gate
        // as a delivered one — the caller never has to catch anything.
        let gate = ContinuationGate<UIImage?>()
        let handle = ImageRequestHandle()
        return await withTaskCancellationHandler {
            handle.store(manager.requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    gate.finish(with: .success(nil))
                } else if let image, (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    // `.opportunistic` hands over a fast low-quality frame first;
                    // only the final one settles the tile.
                    gate.finish(with: .success(image))
                } else if image == nil, info?[PHImageErrorKey] != nil {
                    gate.finish(with: .success(nil))
                }
            })
            if Task.isCancelled {
                handle.cancel(manager)
                gate.finish(with: .success(nil))
            }
            return (try? await gate.value) ?? nil
        } onCancel: {
            handle.cancel(manager)
            gate.finish(with: .success(nil))
        }
    }

    func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String) {
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        let createdAt = ISO8601.immichFormatter.string(from: created)
        let modifiedAt = ISO8601.immichFormatter.string(from: modified)
        return (createdAt, modifiedAt)
    }

    func saveImage(data: Data) async throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("image.\(Self.imageExtension(for: data))")
        try data.write(to: fileURL, options: .atomic)

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            identifier = request?.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else {
            throw APIError.decoding("Photos save returned no local identifier")
        }
        return identifier
    }

    /// Sniffs the leading bytes for a HEIC/HEIF brand; anything else gets the
    /// safe `jpg` extension (Photos re-detects the actual content type).
    private static func imageExtension(for data: Data) -> String {
        let head = String(data: data.prefix(16), encoding: .ascii) ?? ""
        if head.contains("ftypheic") || head.contains("ftypheix") || head.contains("ftypmif1") {
            return "heic"
        }
        return "jpg"
    }

    func saveVideo(at fileURL: URL) async throws -> String {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            identifier = request?.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else {
            throw APIError.decoding("Photos save returned no local identifier")
        }
        return identifier
    }
}

// MARK: - BackupAssetSource

extension PhotoLibraryServiceImpl: BackupAssetSource {
    /// User albums (name + count, sorted by localized title) followed by the
    /// smart albums the exclusion UI can offer. Smart albums carry a stable
    /// `BackupAlbum.SmartID` rather than a Photos `localIdentifier`, so a
    /// persisted exclusion keeps its meaning across reinstalls.
    func fetchAlbums() -> [BackupAlbum] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        var albums: [BackupAlbum] = []
        albums.reserveCapacity(collections.count + Self.smartAlbumIDs.count)
        collections.enumerateObjects { collection, _, _ in
            guard let name = collection.localizedTitle, !name.isEmpty else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            albums.append(BackupAlbum(id: collection.localIdentifier, name: name, count: assets.count))
        }
        albums.append(contentsOf: Self.smartAlbums())
        return albums
    }

    /// Smart albums offered for exclusion, in a fixed order.
    private static let smartAlbumIDs = [
        BackupAlbum.SmartID.screenshots,
        BackupAlbum.SmartID.selfPortraits,
        BackupAlbum.SmartID.bursts,
        BackupAlbum.SmartID.videos,
    ]

    /// Only the non-empty ones — an exclusion toggle for an album the library
    /// doesn't have is noise.
    private static func smartAlbums() -> [BackupAlbum] {
        smartAlbumIDs.compactMap { id in
            guard let collection = collection(forAlbumID: id) else { return nil }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return nil }
            return BackupAlbum(id: id, name: collection.localizedTitle ?? id, count: count, isSmart: true)
        }
    }

    /// Resolves a scoping id: a `BackupAlbum.SmartID` maps to its smart album,
    /// anything else is a user-album `localIdentifier`.
    private static func collection(forAlbumID albumID: String) -> PHAssetCollection? {
        if let subtype = smartAlbumSubtype(for: albumID) {
            return PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil
            ).firstObject
        }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        ).firstObject
    }

    private static func smartAlbumSubtype(for albumID: String) -> PHAssetCollectionSubtype? {
        switch albumID {
        case BackupAlbum.SmartID.screenshots: return .smartAlbumScreenshots
        case BackupAlbum.SmartID.selfPortraits: return .smartAlbumSelfPortraits
        case BackupAlbum.SmartID.bursts: return .smartAlbumBursts
        case BackupAlbum.SmartID.videos: return .smartAlbumVideos
        default: return nil
        }
    }

    /// All library assets (creation date DESC), or the union of the selected
    /// albums, minus every asset that lives in an excluded album. Assets in
    /// several albums dedupe by localIdentifier. The exclusion is resolved by
    /// subtracting identifier sets up front — one `PHAsset.fetchAssets` per
    /// excluded album (none by default) instead of an album lookup per asset,
    /// which is what made a whole-library scan stall.
    func fetchCandidates(in albumIDs: Set<String>, excluding excludedAlbumIDs: Set<String>) -> [BackupCandidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Force Photos to pre-fetch creationDate, duration, isFavorite
        // so that makeCandidate() and exportOriginal() do not trigger the per-asset
        // "Missing prefetched properties for PHAssetOriginalMetadataProperties" warning.
        // The predicate does not filter anything — it only acts as a property hint.
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")

        let excludedIDs = Self.excludedAssetIDs(excludedAlbumIDs)

        var samplers: [PHAsset] = []
        if albumIDs.isEmpty {
            let result = PHAsset.fetchAssets(with: options)
            result.enumerateObjects { asset, _, _ in samplers.append(asset) }
        } else {
            var seen = Set<ObjectIdentifier>()
            for albumID in albumIDs {
                guard let collection = Self.collection(forAlbumID: albumID) else { continue }
                let result = PHAsset.fetchAssets(in: collection, options: options)
                result.enumerateObjects { asset, _, _ in
                    if seen.insert(ObjectIdentifier(asset)).inserted { samplers.append(asset) }
                }
            }
        }
        // Build candidates in a per-asset autorelease pool: makeCandidate calls
        // PHAssetResource.assetResources, which autoreleases Photos objects that
        // would otherwise pile up across a whole-library scan.
        var candidates: [BackupCandidate] = []
        candidates.reserveCapacity(samplers.count)
        for asset in samplers {
            autoreleasepool {
                if excludedIDs.contains(asset.localIdentifier) { return }
                prefetchProperties(of: asset)
                if let candidate = makeCandidate(asset) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    /// Point lookup for a retry: one `PHAsset.fetchAssets(withLocalIdentifiers:)`
    /// — the same call the thumbnail loader makes — instead of enumerating the
    /// whole library, then the same candidate construction as the full scan so
    /// sizes and Live Photo flags match. Ids Photos no longer holds simply
    /// aren't in the result; the run then has nothing to do rather than an error.
    func fetchCandidates(ids: [String]) -> [BackupCandidate] {
        guard !ids.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Same property hint as the full scan: without it every per-asset read
        // logs "Missing prefetched properties for PHAssetOriginalMetadataProperties".
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var candidates: [BackupCandidate] = []
        candidates.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            autoreleasepool {
                self.prefetchProperties(of: asset)
                if let candidate = self.makeCandidate(asset) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    /// Identifier set of every asset living in an excluded album. Reads only
    /// `localIdentifier` — no property prefetch, so this costs no metadata.
    private static func excludedAssetIDs(_ albumIDs: Set<String>) -> Set<String> {
        guard !albumIDs.isEmpty else { return [] }
        var ids = Set<String>()
        for albumID in albumIDs {
            guard let collection = collection(forAlbumID: albumID) else { continue }
            PHAsset.fetchAssets(in: collection, options: nil)
                .enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    /// Which of `deviceAlbumIDs` each asset belongs to, one fetch per album.
    /// Same shape as `excludedAssetIDs(_:)` and for the same reason: resolving
    /// an album's membership by asking each asset where it lives costs a Photos
    /// round-trip per asset, which is what made a whole-library scan stall.
    /// Hidden assets are left out — a hidden photo is not backed up, so it must
    /// not seed a mirror either. An album with no asset, or an id the library
    /// doesn't have, contributes nothing.
    func albumMembership(deviceAlbumIDs: Set<String>) -> [String: [String]] {
        guard !deviceAlbumIDs.isEmpty else { return [:] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        var membership: [String: [String]] = [:]
        for albumID in deviceAlbumIDs {
            guard let collection = Self.collection(forAlbumID: albumID) else { continue }
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                membership[asset.localIdentifier, default: []].append(albumID)
            }
        }
        return membership
    }

    /// Streams the asset's original resource to a temp file on disk (never a
    /// full `Data` in memory). `isNetworkAccessAllowed` lets iCloud-only
    /// originals download; a stall watchdog guards a hung download.
    func exportOriginal(
        for candidate: BackupCandidate,
        into directory: URL,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL {
        let asset = try asset(for: candidate)
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video })
            ?? resources.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo })
            ?? resources.first else {
            throw APIError.decoding("No original resource for \(candidate.id)")
        }
        return try await writeResource(resource, filenameHint: candidate.fileName, into: directory, onState: onState)
    }

    /// The video paired with a Live Photo's still, or nil when the asset has no
    /// paired resource. Same export path as the still — a Live Photo on an
    /// optimized library has *two* iCloud-only resources, and both need the
    /// 1005 retry and the stall watchdog.
    func exportPairedVideo(
        for candidate: BackupCandidate,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> BackupPairedVideo? {
        let asset = try asset(for: candidate)
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }) else { return nil }
        let url = try await writeResource(
            resource, filenameHint: resource.originalFilename, into: BackupExportDirectory.backup, onState: onState
        )
        return BackupPairedVideo(
            url: url,
            fileName: resource.originalFilename,
            duration: Int(max(0, asset.duration))
        )
    }

    /// Fetches the PHAsset behind a candidate, properties prefetched so the
    /// "missing prefetched properties" fetch never lands on the main queue.
    private func asset(for candidate: BackupCandidate) throws -> PHAsset {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [candidate.id], options: options).firstObject else {
            throw APIError.decoding("PHAsset not found for \(candidate.id)")
        }
        prefetchProperties(of: asset)
        return asset
    }

    /// Writes one Photos resource to a temp file and returns its URL. Shared by
    /// the still and the paired video on purpose: the 1005 retry, the stall
    /// watchdog and the partial-file cleanup are the whole reason an
    /// iCloud-optimized library survives a backup, and a second copy of them
    /// would drift. Cancelling the calling Task cancels the PhotoKit request,
    /// deletes the partial file and throws `CancellationError`.
    private func writeResource(
        _ resource: PHAssetResource,
        filenameHint: String,
        into dir: URL,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString)-\(filenameHint)")
        return try await Self.exportResource(
            to: dest,
            source: .photoKit(resource),
            stallInterval: Self.loadTimeoutSeconds,
            retryAttempts: Self.cloudRetryAttempts,
            retryDelayNanos: Self.cloudRetryDelayNanos,
            onState: onState
        )
    }

    /// Creates `url` empty and opens it for writing; `nil` if either step fails.
    static func openEmptyFile(_ url: URL) -> FileHandle? {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }

    /// The export loop of `writeResource`, with PhotoKit (`source`) and the file
    /// opening (`openFile`) injected so cancellation, the watchdog, the 1005
    /// retry and write errors are testable without a photo library.
    static func exportResource(
        to dest: URL,
        source: ResourceDataSource,
        stallInterval: TimeInterval,
        retryAttempts: Int,
        retryDelayNanos: UInt64,
        openFile: (URL) -> FileHandle? = PhotoLibraryServiceImpl.openEmptyFile,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL {
        // iCloud-optimized originals may report a transient 1005 ("not local and
        // not preparing") before the download is scheduled. Retry a few times
        // with a short backoff — re-issuing the request nudges iCloud to start —
        // and only then surface the failure (retried again on the next run).
        var attempt = 0
        while true {
            // A Stop between two attempts must not start another download.
            try Task.checkCancellation()
            // `requestData` (not `writeData`): it is the only PhotoKit call that
            // returns an id `cancelDataRequest` accepts, so a cancelled run can
            // stop an iCloud download. The chunks are written to `dest` here.
            guard let handle = openFile(dest) else {
                try? FileManager.default.removeItem(at: dest)
                throw CocoaError(.fileWriteUnknown)
            }
            let writer = ResourceFileWriter(handle: handle)
            let request = ResourceDataRequest(cancelRequest: source.cancelDataRequest)
            let gate = ContinuationGate<Void>()
            // A wall-clock deadline would abort a slow-but-healthy iCloud download
            // (which can legitimately take minutes) and delete its half-written temp
            // file. Instead, a stall watchdog trips only after `stallInterval`
            // with neither a progress tick nor completion — so a download that keeps
            // making progress is never dropped, only a truly hung request is. It
            // does not cancel the request: the download lands in the library and
            // the deferred asset is picked up by the next run.
            let watchdog = StallWatchdog(interval: stallInterval) {
                gate.finish(with: .failure(BackupExportError.cloudDownloadPending))
            }
            watchdog.pet()
            let requestID = source.requestData(
                { fraction in
                    watchdog.pet()
                    onState(.downloadingFromICloud(fraction: fraction))
                },
                { data in
                    watchdog.pet()
                    if let writeError = writer.append(data) {
                        request.cancel()
                        gate.finish(with: .failure(writeError))
                    }
                },
                { error in
                    watchdog.cancel()
                    let closeError = writer.close()
                    gate.finish(with: (error ?? closeError).map { .failure($0) } ?? .success(()))
                }
            )
            request.store(requestID)
            do {
                try await withTaskCancellationHandler {
                    try await gate.value
                } onCancel: {
                    request.cancel()
                    gate.finish(with: .failure(CancellationError()))
                }
                return dest
            } catch {
                _ = writer.close()
                try? FileManager.default.removeItem(at: dest)
                // Whatever error Photos reports after `cancelDataRequest`, a
                // cancelled Task never retries.
                if Task.isCancelled { throw CancellationError() }
                attempt += 1
                if Self.isCloudNotReady(error) {
                    if attempt < retryAttempts {
                        onState(.retryingICloud(attempt: attempt))
                        // No `try?`: a Stop during the backoff must end the export.
                        try await Task.sleep(nanoseconds: retryDelayNanos)
                        continue
                    }
                    throw BackupExportError.cloudDownloadPending
                }
                throw error
            }
        }
    }

    /// Deletes the backup's export directory (`BackupExportDirectory.backup`) and
    /// nothing else — the "On this device" Check exports elsewhere, so a run
    /// starting mid-Check cannot delete a file being hashed. Safe to call only at
    /// the start of a run — no export of the current run has written there yet, so
    /// this only reclaims orphans from a killed run.
    func purgeStaleExports() {
        try? FileManager.default.removeItem(at: BackupExportDirectory.backup)
    }

    /// Maps a PHAsset to its value-typed candidate.
    private func makeCandidate(_ asset: PHAsset) -> BackupCandidate? {
        let kind: BackupAssetKind = asset.mediaType == .video ? .video : .image
        let timestamps = isoTimestamps(for: asset)
        let resources = PHAssetResource.assetResources(for: asset)
        let originalName = resources.first(where: { $0.type == .photo || $0.type == .video })?.originalFilename
        return BackupCandidate(
            id: asset.localIdentifier,
            kind: kind,
            fileName: originalName ?? (kind == .video ? "Video" : "Photo"),
            fileCreatedAt: timestamps.createdAt,
            fileModifiedAt: timestamps.modifiedAt,
            duration: kind == .video ? Int(max(0, asset.duration)) : nil,
            isFavorite: asset.isFavorite,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            fileSize: Self.originalSize(of: asset)
        )
    }

    /// Bytes the asset's original(s) occupy on the wire: the still plus, for a
    /// Live Photo, its paired video — both are uploaded, so both count.
    ///
    /// PhotoKit exposes no public byte size on `PHAssetResource`, so this reads
    /// the `fileSize` key every non-downloading size reader uses, guarded by a
    /// selector check: on a resource that doesn't answer it (some iCloud-only
    /// ones) the size stays unknown, which the UI renders as "Unknown size"
    /// rather than a wrong number. Nothing is downloaded to measure it.
    private static func originalSize(of asset: PHAsset) -> Int64? {
        let wanted: Set<PHAssetResourceType> = asset.mediaType == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto, .pairedVideo, .fullSizePairedVideo]
        var bytes: Int64 = 0
        var found = false
        for resource in PHAssetResource.assetResources(for: asset) where wanted.contains(resource.type) {
            guard resource.responds(to: NSSelectorFromString("fileSize")),
                  let size = resource.value(forKey: "fileSize") as? NSNumber else { continue }
            bytes += size.int64Value
            found = true
        }
        return found ? bytes : nil
    }

    private func prefetchProperties(of asset: PHAsset) {
        // Read all properties that makeCandidate/exportOriginal access. This forces
        // PhotosKit to cache them so the "Missing prefetched properties" warning
        // disappears. Access must happen on the main thread before any async switch.
        _ = asset.localIdentifier
        _ = asset.mediaType
        _ = asset.mediaSubtypes
        _ = asset.duration
        _ = asset.isFavorite
    }
}

// MARK: - LocalCleanupSource

extension PhotoLibraryServiceImpl: LocalCleanupSource {
    /// iPhone's half of upstream's `_deleteBatchSize` (`cleanup.service.dart`:
    /// 2000 on Android, 10000 on iOS; doc `docs/docs/features/mobile-app.mdx`
    /// § Free Up Space). One `performChanges` per batch — Photos refuses a
    /// single request covering a whole library.
    private static let deleteBatchSize = 10_000

    /// How many identifiers go to `PHAsset.fetchAssets(withLocalIdentifiers:)`
    /// at once. The ledger can track an entire library, and one call with tens
    /// of thousands of identifiers makes Photos build a very large intermediate
    /// result for no benefit.
    private static let identifierFetchChunkSize = 500

    /// The assets that are on this device *and* provably on the server, with
    /// everything the user asked to keep filtered out.
    ///
    /// The ordering of the filters is the safety property: shared albums and
    /// kept albums are subtracted by identifier set before anything is even
    /// looked at, then the cutoff, then the keeps.
    func cleanupCandidates(
        cutoff: Date,
        keepFavorites: Bool,
        keepMediaType: CleanupKeepMediaType,
        keepAlbumIDs: Set<String>,
        backedUpIDs: Set<String>
    ) -> CleanupScanResult {
        guard !backedUpIDs.isEmpty else {
            return CleanupScanResult(
                candidates: [], skippedNotOnServer: 0, skippedInSharedAlbum: 0, scannedCount: 0
            )
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Property hint, not a filter: it forces Photos to pre-fetch
        // creationDate/duration/isFavorite so reading them per asset neither
        // warns nor hits the store once per asset (same as `fetchCandidates`).
        options.predicate = NSPredicate(format: "creationDate != nil AND duration != nil AND isFavorite != nil")

        // Both exclusions are resolved once into identifier sets, the strategy
        // `excludedAssetIDs(_:)` already uses: one fetch per album, instead of
        // an album lookup per asset (which is what made a whole-library scan
        // stall under the old filename heuristics).
        let sharedAlbumIDs = Self.iCloudSharedAlbumAssetIDs()
        let keptAlbumIDs = Self.excludedAssetIDs(keepAlbumIDs)

        var candidates: [CleanupCandidate] = []
        var skippedInSharedAlbum = 0
        var scannedCount = 0

        for chunk in Self.chunks(of: Array(backedUpIDs), size: Self.identifierFetchChunkSize) {
            PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: options)
                .enumerateObjects { asset, _, _ in
                    // Per-asset pool: `PHAssetResource.assetResources`
                    // autoreleases Photos objects that would otherwise pile up
                    // across a whole library (same reason as `fetchCandidates`).
                    autoreleasepool {
                        let id = asset.localIdentifier
                        if sharedAlbumIDs.contains(id) {
                            skippedInSharedAlbum += 1
                            return
                        }
                        scannedCount += 1
                        guard !keptAlbumIDs.contains(id) else { return }
                        // Inclusive: "Free Up Space will only look for photos and
                        // videos on or before this date".
                        guard let creationDate = asset.creationDate, creationDate <= cutoff else { return }
                        if keepFavorites, asset.isFavorite { return }
                        guard let backup = self.makeCandidate(asset) else { return }
                        // "Keep photos" is what stays, so a video is a
                        // candidate — and the other way round.
                        if keepMediaType == .photos, backup.kind == .video { return }
                        if keepMediaType == .videos, backup.kind == .image { return }
                        candidates.append(CleanupCandidate(
                            id: id,
                            kind: backup.kind,
                            fileName: backup.fileName,
                            creationDate: creationDate,
                            byteSize: Self.byteSize(of: asset),
                            isFavorite: backup.isFavorite
                        ))
                    }
                }
        }

        return CleanupScanResult(
            candidates: candidates,
            skippedNotOnServer: 0,
            skippedInSharedAlbum: skippedInSharedAlbum,
            scannedCount: scannedCount
        )
    }

    /// Removes the originals from the photo library — and only from there. The
    /// server copy is what the whole feature promises to keep.
    func deleteLocalAssets(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var deleted = 0
        for index in stride(from: 0, to: ids.count, by: Self.deleteBatchSize) {
            let batch = Array(ids[index..<min(index + Self.deleteBatchSize, ids.count)])
            var assets: [PHAsset] = []
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: batch, options: nil)
            assets.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
            // An asset already gone from Photos (deleted there since the scan)
            // resolves to nothing: the batch is empty and counts for zero,
            // like upstream's "a batch that deletes nothing doesn't count".
            guard !assets.isEmpty else { continue }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            deleted += assets.count
        }
        return deleted
    }

    /// Every asset living in an iCloud Shared Album. iOS cannot remove an item
    /// from such an album from the device, so they are never offered: removing
    /// them here would delete the user's original without freeing the album.
    private static func iCloudSharedAlbumAssetIDs() -> Set<String> {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil
        )
        var ids = Set<String>()
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil)
                .enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        }
        return ids
    }

    /// Bytes the asset's resources occupy on disk.
    ///
    /// `PHAssetResource` exposes no public `fileSize`, and exporting the
    /// resource to measure it would download every iCloud-optimized original —
    /// the one thing this screen must not do, since the premise is that the
    /// server already holds those bytes. Photos does keep the size reachable
    /// through KVC; the `responds(to:)` guard keeps an OS that stops exposing it
    /// from raising `NSUnknownKeyException`, in which case the size reads 0 and
    /// "Reclaimable" understates rather than lies.
    private static func byteSize(of asset: PHAsset) -> Int64 {
        let selector = NSSelectorFromString("fileSize")
        return PHAssetResource.assetResources(for: asset).reduce(into: Int64(0)) { total, resource in
            guard resource.responds(to: selector),
                  let size = resource.value(forKey: "fileSize") as? NSNumber else { return }
            total += size.int64Value
        }
    }

    private static func chunks(of ids: [String], size: Int) -> [[String]] {
        guard size > 0 else { return [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}

/// Single-delivery async gate bridging a completion-handler API to
/// async/await. Robust to the completion firing *before* the awaiter installs
/// its continuation — common with fast, fully-local PhotosKit resources whose
/// `requestData`/`requestImageData` completion lands in the window between the
/// request call and `await gate.value`. The first result is stashed and
/// delivered as soon as `value` is awaited; later `finish` calls (e.g. the
/// timeout that lost the race) are ignored. Without this, a dropped resume
/// left the awaiter hung until the deadline, surfacing every local asset as a
/// bogus "export timed out".
final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var settled = false

    var value: Value {
        get async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                if let pending {
                    lock.unlock()
                    continuation.resume(with: pending)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    func finish(with result: Result<Value, Error>) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true
        let cont = continuation
        continuation = nil
        if cont == nil { pending = result }
        lock.unlock()
        cont?.resume(with: result)
    }
}

/// Trips `onStall` only after `interval` seconds elapse with no `pet()` and no
/// `cancel()`. Each `pet()` (a progress tick) postpones the deadline, so a
/// slow-but-progressing transfer is never aborted; a request that produces no
/// bytes for `interval` is. Thread-safe via a private serial queue.
private final class StallWatchdog: @unchecked Sendable {
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "immich.export.watchdog")
    private var item: DispatchWorkItem?
    private var stopped = false
    private let onStall: () -> Void

    init(interval: TimeInterval, onStall: @escaping () -> Void) {
        self.interval = interval
        self.onStall = onStall
    }

    /// Restart the countdown from now — call on start and on every progress tick.
    func pet() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.item?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.onStall()
            }
            self.item = work
            self.queue.asyncAfter(deadline: .now() + self.interval, execute: work)
        }
    }

    /// Stop for good — the transfer finished (success or failure).
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.item?.cancel()
            self.item = nil
        }
    }
}

/// Carries an in-flight `PHImageRequestID` across the cancellation boundary.
/// The id only exists once `requestImage` returns, while the `onCancel` handler
/// can fire at any moment — so the hand-off is lock-guarded instead of captured
/// by value. An id that never landed cancels nothing (Photos never started).
private final class ImageRequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID = PHInvalidImageRequestID

    func store(_ requestID: PHImageRequestID) {
        lock.lock()
        id = requestID
        lock.unlock()
    }

    func cancel(_ manager: PHImageManager) {
        lock.lock()
        let requestID = id
        lock.unlock()
        guard requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }
}

/// The data API of one PhotoKit resource, injected into `exportResource` so
/// tests can script chunks, completion and progress without a photo library.
struct ResourceDataSource: Sendable {
    let requestData: @Sendable (
        _ progress: @escaping @Sendable (Double) -> Void,
        _ dataReceived: @escaping @Sendable (Data) -> Void,
        _ completion: @escaping @Sendable (Error?) -> Void
    ) -> PHAssetResourceDataRequestID
    let cancelDataRequest: @Sendable (PHAssetResourceDataRequestID) -> Void

    static func photoKit(_ resource: PHAssetResource) -> ResourceDataSource {
        ResourceDataSource(
            requestData: { progress, dataReceived, completion in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                options.progressHandler = { progress($0) }
                return PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: dataReceived,
                    completionHandler: completion
                )
            },
            cancelDataRequest: { PHAssetResourceManager.default().cancelDataRequest($0) }
        )
    }
}

/// Carries an in-flight `PHAssetResourceDataRequestID` across the cancellation
/// boundary. The id only exists once `requestData` returns, while `cancel()`
/// can arrive at any moment and from any queue: whichever of `store`/`cancel`
/// comes second sends the single `cancelRequest`, with the stored id. An id
/// that never lands cancels nothing, and nothing is cancelled without `cancel()`.
final class ResourceDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelRequest: @Sendable (PHAssetResourceDataRequestID) -> Void
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var cancelSent = false

    init(
        cancelRequest: @escaping @Sendable (PHAssetResourceDataRequestID) -> Void = {
            PHAssetResourceManager.default().cancelDataRequest($0)
        }
    ) {
        self.cancelRequest = cancelRequest
    }

    func store(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        id = requestID
        lock.unlock()
        sendCancelIfNeeded()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        sendCancelIfNeeded()
    }

    private func sendCancelIfNeeded() {
        lock.lock()
        let target: PHAssetResourceDataRequestID?
        if cancelled, !cancelSent, let id {
            cancelSent = true
            target = id
        } else {
            target = nil
        }
        lock.unlock()
        if let target { cancelRequest(target) }
    }
}

/// Appends the chunks `requestData` delivers to the export file. Photos calls
/// the data handler and the completion handler on an arbitrary serial queue, and
/// a stalled or cancelled export may still deliver late chunks: once closed (or
/// failed) the writer ignores them, so nothing lands after the file is released.
final class ResourceFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var failure: Error?
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Returns the write error the first time one happens, `nil` otherwise
    /// (including for chunks ignored because the writer is closed or failed).
    func append(_ data: Data) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, failure == nil else { return nil }
        do {
            try handle.write(contentsOf: data)
            return nil
        } catch {
            failure = error
            return error
        }
    }

    /// Idempotent: only the first call touches the handle. Returns the write
    /// failure if there was one, else the close error.
    func close() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        do {
            try handle.close()
            return failure
        } catch {
            return failure ?? error
        }
    }
}
