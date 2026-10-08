import Foundation
import Observation

/// Per-user server storage statistics (P1 storage-stats card).
///
/// Wraps `GET /api/server/statistics` for a single observer: photo/video
/// counts, total bytes used and the server quota (when the server defines
/// one). The VM keeps the raw numbers; the view formats them via `format`.
@Observable
@MainActor
final class StorageStatsViewModel {
    let client: any ImmichClient

    var photos = 0
    var videos = 0
    var usage: Int64 = 0
    var quotaSizeInBytes: Int64?
    var isLoading = false
    var errorMessage: String?

    /// True once a fetch succeeded — lets the view distinguish "empty server"
    /// from "never loaded" (P1 storage-stats AC-1030).
    private(set) var didLoad = false

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Fetches statistics once per invocation (re-entrancy guarded). Errors
    /// surface in `errorMessage`; the view offers a retry via `load()`.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let stats = try await client.getServerStatistics()
            photos = stats.photos
            videos = stats.videos
            usage = Int64(stats.usage)
            // First user-level entry carrying a quota wins; no quota → bar hidden.
            var quota: Int64?
            for entry in stats.usageByUser where (entry.quotaSizeInBytes ?? 0) > 0 {
                quota = Int64(entry.quotaSizeInBytes ?? 0)
                break
            }
            quotaSizeInBytes = quota
            didLoad = true
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Localized byte count (locale-aware: "3,4 Mo" / "34 MB" / ...).
    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}