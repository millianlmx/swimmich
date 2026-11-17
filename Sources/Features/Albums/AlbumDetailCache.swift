import Foundation

/// The album screens already read this session, kept in memory: an album
/// opened again shows its photos at once, and a quiet read then replaces them
/// in place. Without it every opening started from a skeleton and read the
/// whole first page again.
///
/// Emptied on every session change (`LocalDataPurger.activateAccount`, which
/// sign-out also runs), so an account never sees another's albums.
@MainActor
final class AlbumDetailCache {
    static let shared = AlbumDetailCache()

    struct Snapshot: Equatable {
        let album: AlbumResponseDto
        let assets: [AssetReactItem]
        /// The next page the server announced (nil: the grid was complete).
        let nextPage: Int?
        /// Direction of the page 1 that established `assets`.
        let pageOrder: String?
    }

    /// Albums kept; storing one more drops the least recently stored.
    let capacity: Int
    private var snapshots: [String: Snapshot] = [:]
    private var recency: [String] = []

    init(capacity: Int = 12) {
        self.capacity = capacity
    }

    func snapshot(for albumId: String) -> Snapshot? {
        snapshots[albumId]
    }

    func store(_ snapshot: Snapshot, for albumId: String) {
        snapshots[albumId] = snapshot
        recency.removeAll { $0 == albumId }
        recency.append(albumId)
        while recency.count > capacity {
            snapshots[recency.removeFirst()] = nil
        }
    }

    func remove(_ albumId: String) {
        snapshots[albumId] = nil
        recency.removeAll { $0 == albumId }
    }

    func removeAll() {
        snapshots = [:]
        recency = []
    }
}
