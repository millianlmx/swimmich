import Foundation
import Observation

/// Account storage shown on the Me hub, Media Stats and "On this device".
///
/// Two independent reads of the *calling account* (never the instance):
/// - `GET /api/users/me` → used bytes and quota (`usage`);
/// - `GET /api/assets/statistics` → own photo / video counts (`counts`).
///
/// Each half is a `Reading`: a number on screen is a number that was just read.
/// A failed (re)read turns that half into `.unavailable` — never `0` — while the
/// other half keeps its own outcome. A cancelled read (SwiftUI cancels the task
/// of `.refreshable` / `.task`) is not a failure and leaves the half untouched.
/// `GET /api/server/statistics` (instance totals, admins only) is read by the
/// Administration screen alone.
@Observable
@MainActor
final class StorageStatsViewModel {
    enum Reading<Value: Equatable>: Equatable {
        case notLoaded
        case loaded(Value)
        case unavailable(message: String)
    }

    struct Usage: Equatable {
        let usedBytes: Int64
        /// `nil` = unlimited (no quota, or quota 0).
        let quotaBytes: Int64?

        var fraction: Double? {
            quotaBytes.map { min(Double(usedBytes) / Double($0), 1) }
        }
    }

    struct Counts: Equatable {
        let photos: Int
        let videos: Int
        var total: Int { photos + videos }
    }

    let client: any ImmichClient

    private(set) var usage: Reading<Usage> = .notLoaded
    private(set) var counts: Reading<Counts> = .notLoaded
    private(set) var isLoading = false

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Reads both halves in parallel (re-entrancy guarded). One half failing
    /// never interrupts the other.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let userResult = Self.capture { try await self.client.getMyUser() }
        async let statsResult = Self.capture { try await self.client.getAssetStatistics() }
        let (user, stats) = await (userResult, statsResult)

        switch user {
        case .success(let user):
            usage = .loaded(Usage(
                usedBytes: Int64(user.quotaUsageInBytes ?? 0),
                quotaBytes: user.quotaSizeInBytes.flatMap { $0 > 0 ? Int64($0) : nil }
            ))
        case .failure(let error):
            usage = Self.settle(usage, after: error)
        }
        switch stats {
        case .success(let stats):
            counts = .loaded(Counts(photos: stats.images, videos: stats.videos))
        case .failure(let error):
            counts = Self.settle(counts, after: error)
        }
    }

    /// Localized byte count (locale-aware: "3,4 Mo" / "34 MB" / ...).
    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func capture<T>(_ read: @escaping () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    /// Cancellation keeps the previous state; any other error is `.unavailable`.
    private static func settle<V: Equatable>(_ previous: Reading<V>, after error: Error) -> Reading<V> {
        if UserFacingError.isCancellation(error) || Task.isCancelled { return previous }
        return .unavailable(message: error.userFacingMessage ?? UserFacingError.genericMessage)
    }
}
