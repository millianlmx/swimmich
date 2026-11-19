import AVFoundation
import Photos
import UIKit

// MARK: - Device half of the merged Photos timeline

/// The photos and videos of this device's library that are not proven on the
/// server yet, as timeline items (`AssetReactItem.deviceAssetID` set). The
/// Photos tab mixes them with the server's, month by month, so the tab shows
/// the whole library like Apple Photos does — a photo just taken is there
/// before the backup sends it.
///
/// Never twice: an asset the backup ledger proves on the server
/// (`uploadedLocalIDs`) is left out here, and a photo the server has without
/// the ledger knowing it (sent by another app, or before this install) is
/// recognised by its capture time when the months are merged
/// (`MergedTimeline.dedupeKey`).
protocol DeviceTimelineSource: Sendable {
    /// Device-only items, newest first. `excluding` holds the library ids the
    /// ledger proves on the server. Empty without read access to the library:
    /// this never asks for it.
    func deviceOnlyItems(excluding uploaded: Set<String>, favoritesOnly: Bool) async -> [AssetReactItem]
}

/// The production source: one PhotoKit fetch, off the main actor.
struct PhotoKitDeviceTimelineSource: DeviceTimelineSource {
    func deviceOnlyItems(excluding uploaded: Set<String>, favoritesOnly: Bool) async -> [AssetReactItem] {
        await Task.detached(priority: .userInitiated) {
            Self.read(excluding: uploaded, favoritesOnly: favoritesOnly)
        }.value
    }

    static func read(excluding uploaded: Set<String>, favoritesOnly: Bool) -> [AssetReactItem] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var predicates = [
            NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
            ),
        ]
        if favoritesOnly { predicates.append(NSPredicate(format: "favorite == YES")) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let assets = PHAsset.fetchAssets(with: options)
        var items: [AssetReactItem] = []
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            guard !uploaded.contains(asset.localIdentifier), let item = Self.item(for: asset) else { return }
            items.append(item)
        }
        return items
    }

    /// The timeline item of one library asset. Only properties Photos keeps in
    /// its fetch (no location, no resources): the whole library is read at once.
    static func item(for asset: PHAsset) -> AssetReactItem? {
        guard let created = asset.creationDate else { return nil }
        let iso = ISO8601.immichFormatter.string(from: created)
        let isVideo = asset.mediaType == .video
        let ratio = asset.pixelHeight > 0 ? Double(asset.pixelWidth) / Double(asset.pixelHeight) : 1
        return AssetReactItem(
            id: AssetReactItem.deviceIDPrefix + asset.localIdentifier,
            ownerId: "",
            ratio: ratio,
            isFavorite: asset.isFavorite,
            visibility: AssetVisibility.timeline.rawValue,
            isTrashed: false,
            isImage: !isVideo,
            thumbhash: nil,
            createdAt: iso,
            fileCreatedAt: iso,
            localOffsetHours: Double(TimeZone.current.secondsFromGMT(for: created)) / 3600,
            duration: isVideo ? Int((asset.duration * 1000).rounded()) : nil,
            livePhotoVideoId: nil,
            projectionType: nil,
            city: nil,
            country: nil,
            latitude: nil,
            longitude: nil,
            stack: [],
            pixelSize: PixelSize(width: asset.pixelWidth, height: asset.pixelHeight),
            deviceAssetID: asset.localIdentifier
        )
    }
}

// MARK: - Merging the two halves

/// Pure arithmetic of the merged timeline (testable without PhotoKit).
enum MergedTimeline {
    /// `"yyyy-MM"` of a bucket key (`"2024-06-01"` or `"2024-06-01T00:00:00.000Z"`)
    /// or of an item's `fileCreatedAt`.
    static func monthKey(_ value: String) -> String {
        String(value.prefix(7))
    }

    /// The server's month list with the device-only months folded in: a month
    /// both have counts both; a month only the device has is inserted under the
    /// key `"yyyy-MM-01"`. Newest first, like the server's list.
    static func buckets(
        server: [TimeBucketsResponseDto],
        deviceCounts: [String: Int]
    ) -> [TimeBucketsResponseDto] {
        guard !deviceCounts.isEmpty else { return server }
        var merged: [TimeBucketsResponseDto] = []
        var seen = Set<String>()
        for bucket in server {
            let month = monthKey(bucket.timeBucket)
            seen.insert(month)
            merged.append(TimeBucketsResponseDto(timeBucket: bucket.timeBucket, count: bucket.count + (deviceCounts[month] ?? 0)))
        }
        for (month, count) in deviceCounts where !seen.contains(month) && count > 0 {
            merged.append(TimeBucketsResponseDto(timeBucket: "\(month)-01", count: count))
        }
        return merged.sorted { monthKey($0.timeBucket) > monthKey($1.timeBucket) }
    }

    /// What makes a device photo "the same" as a server photo when the ledger
    /// does not know it: its kind and its capture time to the second. Every
    /// uploader sends the library's creation date as `fileCreatedAt` (this
    /// app, the official one), so a photo already on the server matches; two
    /// different photos of the same kind taken in the same second do not
    /// exist outside a burst, whose frames Photos keeps as one asset.
    static func dedupeKey(_ item: AssetReactItem) -> String {
        "\(item.isImage ? "i" : "v")|\(item.fileCreatedAt.prefix(19))"
    }

    /// One month's server items and device items, newest first. A device item
    /// whose key is in `serverKeys` (this month's server items, and any loaded
    /// before) is the server's copy already on screen: left out.
    static func items(
        server: [AssetReactItem],
        device: [AssetReactItem],
        serverKeys: Set<String> = []
    ) -> [AssetReactItem] {
        guard !device.isEmpty else { return server }
        let known = serverKeys.union(server.map(dedupeKey))
        let fresh = device.filter { !known.contains(dedupeKey($0)) }
        guard !fresh.isEmpty else { return server }
        return (server + fresh).sorted { $0.fileCreatedAt > $1.fileCreatedAt }
    }
}

// MARK: - Device media

/// What the app does with a device-only photo or video: its image, its video
/// file, a copy to share, its deletion. PhotoKit behind plain values.
enum DeviceMedia {
    private static func asset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    /// The image of a library asset, `maxPixelSize` on its longer side
    /// (`fill`: on its shorter side, for a square tile). `allowsNetwork`
    /// downloads an iCloud-only original (the viewer); a grid tile never does.
    static func image(
        localIdentifier: String,
        maxPixelSize: Int,
        fill: Bool,
        allowsNetwork: Bool
    ) async -> UIImage? {
        guard let asset = asset(localIdentifier) else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        let side = CGFloat(max(maxPixelSize, 1))
        let size = CGSize(width: side, height: side)
        let gate = ContinuationGate<UIImage?>()
        let handle = ImageRequestHandle()
        return await withTaskCancellationHandler {
            handle.store(manager.requestImage(
                for: asset, targetSize: size, contentMode: fill ? .aspectFill : .aspectFit, options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    gate.finish(with: .success(nil))
                } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    gate.finish(with: .success(image))
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

    /// A file URL AVFoundation can play for a library video: the current
    /// version, else the original (a slow-motion video's current version is a
    /// composition, which has no file). Downloads an iCloud-only video.
    static func videoURL(localIdentifier: String) async -> URL? {
        guard let asset = asset(localIdentifier), asset.mediaType == .video else { return nil }
        if let url = await videoURL(asset, version: .current) { return url }
        return await videoURL(asset, version: .original)
    }

    private static func videoURL(_ asset: PHAsset, version: PHVideoRequestOptionsVersion) async -> URL? {
        let options = PHVideoRequestOptions()
        options.version = version
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: (avAsset as? AVURLAsset)?.url)
            }
        }
    }

    /// Writes the asset's original to a file of its own directory under
    /// `tmp/immich-share` and returns it; the caller removes the directory
    /// once the share sheet closes. Downloads an iCloud-only original.
    static func exportForSharing(localIdentifier: String) async throws -> URL {
        guard let asset = asset(localIdentifier) else { throw CocoaError(.fileNoSuchFile) }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video })
            ?? resources.first else { throw CocoaError(.fileNoSuchFile) }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return file
    }

    /// Deletes library assets. Photos asks the user to confirm (its own sheet:
    /// an app cannot delete a photo silently). `true` when they are gone —
    /// also when none of them was still in the library. `false` when the user
    /// declined or Photos refused.
    static func delete(localIdentifiers: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return true }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }

    /// Whether a library asset still exists.
    static func exists(localIdentifier: String) -> Bool {
        asset(localIdentifier) != nil
    }
}
