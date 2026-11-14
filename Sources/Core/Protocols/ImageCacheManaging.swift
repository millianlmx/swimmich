import Foundation

/// The thumbnail and preview caches the "Advanced" section measures and empties
/// (memory decoders and the HTTP disk cache). Offline copies, the map cache and
/// the widgets' images are not part of it.
protocol ImageCacheManaging: Sendable {
    /// Bytes the image cache occupies on disk, index files included. Throws
    /// when the size cannot be measured.
    func diskUsageBytes() async throws -> Int64

    /// Empties every image cache. Reports nothing: callers measure again to
    /// learn what is left.
    func clear() async
}
