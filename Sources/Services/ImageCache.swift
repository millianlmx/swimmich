import UIKit

/// Thread-safe in-memory image cache backed by `NSCache`.
///
/// Premium-feel prerequisite (AC-200): eliminates refetch/flicker when cells
/// scroll back into view. `NSCache` auto-evicts under memory pressure, so we
/// don't hand-roll eviction. Keyed by the full URL string (incl. `?c=thumbhash`
/// query) so server-side thumbnail changes naturally invalidate.
///
/// Actor-isolated for cheap, correct concurrency — callers `await` access.
actor ImageCache {

    /// Shared app-wide instance used by `AuthenticatedAsyncImage`.
    static let shared = ImageCache()

    /// An image is keyed by the address of the account's connection, whichever of
    /// its addresses (local or external) served it (L-26): a thumbnail already
    /// seen on one address serves on the other without a request.
    private let addressBook: ServerAddressBook

    init(addressBook: ServerAddressBook = .shared) {
        self.addressBook = addressBook
    }

    nonisolated private func key(for url: URL) -> NSString {
        addressBook.canonicalURL(for: url).absoluteString as NSString
    }

    /// `NSCache` is documented thread-safe ("add, remove, and query items from
    /// different threads without locking"), which is what makes the
    /// synchronous `cachedImage(for:)` read sound. Never mutated outside this actor.
    nonisolated(unsafe) private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // Soft cap only — NSCache is free to ignore; it always honors memory
        // warnings by evicting. Avoids hard limits that would shrink the hit
        // rate on large timelines.
        c.countLimit = 400              // ~400 thumbnails resident
        c.totalCostLimit = 80 * 1024 * 1024   // ~80MB decoded
        return c
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: key(for: url))
    }

    /// Synchronous read for callers that must not wait (the viewer's opening
    /// animation starts on the very next frame, with no `await`).
    nonisolated func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: key(for: url))
    }

    /// Monotonic purge counter. Loaders read it before their network await and
    /// pass it to `store`, so a load that straddles `removeAll()` can't
    /// repopulate the cache with pre-purge data.
    private(set) var epoch = 0

    /// Stores `image` only if no `removeAll()` happened since `epoch` was read.
    func store(_ image: UIImage, for url: URL, epoch: Int) {
        guard epoch == self.epoch else { return }
        // Cost ≈ decoded bytes; falls back to 1 if size unknown.
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: key(for: url), cost: cost)
    }

    /// Removes the cached image for a URL, if any. Useful for tests + future
    /// invalidation flows (e.g. after asset edit).
    func remove(for url: URL) {
        cache.removeObject(forKey: key(for: url))
    }

    /// Clears the entire cache.
    func removeAll() {
        epoch += 1
        cache.removeAllObjects()
    }
}
