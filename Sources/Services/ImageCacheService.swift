import Foundation

/// The app's thumbnail and preview caches behind one contract: the decoded-image
/// `NSCache`, the ThumbHash `NSCache` and the HTTP disk cache of the `images`
/// session.
///
/// Deliberately **not** what `LocalDataPurger` empties on sign-out: no offline
/// copy, no map marker, no widget image, no Keychain item, no session and no
/// trusted-server approval is touched here.
final class ImageCacheService: ImageCacheManaging, @unchecked Sendable {
    private let memory: ImageCache
    private let thumbhashes: ThumbHashDecoder
    private let disk: URLCache

    init(
        memory: ImageCache = .shared,
        thumbhashes: ThumbHashDecoder = .shared,
        disk: URLCache = AuthenticatedAsyncImage.imageDiskCache
    ) {
        self.memory = memory
        self.thumbhashes = thumbhashes
        self.disk = disk
    }

    func diskUsageBytes() async throws -> Int64 {
        // Walks the cache's files: off the caller's executor.
        let disk = disk
        return await Task.detached(priority: .utility) { Int64(disk.currentDiskUsage) }.value
    }

    func clear() async {
        // The epoch bump drops loads that were in flight, so none of them
        // repopulates the cache right after.
        await memory.removeAll()
        thumbhashes.clearCache()
        disk.removeAllCachedResponses()
    }
}
