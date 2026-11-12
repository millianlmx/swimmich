import Foundation

/// Album activity state: comments + per-asset likes (P3 activity-feed).
@MainActor
@Observable
final class ActivityFeedViewModel {
    private let client: any ImmichClient
    let albumId: String
    /// Current signed-in user; owns the "is this like mine?" decision.
    private let currentUserId: String

    var activities: [ActivityResponseDto] = []
    var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the feed was read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the feed, cleared by a success. Written by
    /// `load()` only.
    private(set) var loadErrorMessage: String?
    /// Failure of the last action (comment, like, delete).
    var errorMessage: String?
    /// Bumped by every `load()`, so only the last read writes its result.
    private var loadGeneration = 0
    var isSending = false

    init(client: any ImmichClient, albumId: String, currentUserId: String) {
        self.client = client
        self.albumId = albumId
        self.currentUserId = currentUserId
    }

    /// True when an activity carrying a like originates from the current user —
    /// that's the reaction the user can retract.
    func hasMyLike(_ activity: ActivityResponseDto) -> Bool {
        guard case .like = activity.type else { return false }
        return activity.user.id == currentUserId
    }

    /// What the feed renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: activities.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// Full album feed, newest first: first read, "Try Again" and `.task`
    /// (never pulls). Separates sorting from network so the list stays stable
    /// while reloading; the feed is replaced only by a success, and a newer
    /// read supersedes one still in flight.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await client.getActivities(albumId: albumId, assetId: nil)
            guard generation == loadGeneration else { return }
            activities = fetched.sorted { $0.createdAt > $1.createdAt }
            hasLoaded = true
            loadErrorMessage = nil
        } catch {
            guard generation == loadGeneration, let message = error.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    /// Pull-to-refresh: `load()` flagged so the screen keeps its current
    /// rendering.
    func refresh() async {
        isRefreshing = true
        await load()
        isRefreshing = false
    }

    /// Posts a comment; on success the row is appended server-side, on throw
    /// the composer keeps its text (errorMessage surfaced).
    func addComment(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        let dto = ActivityCreateDto(albumId: albumId, type: .comment, assetId: nil, comment: trimmed)
        do {
            let created = try await client.createActivity(dto: dto)
            activities.insert(created, at: 0)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Likes the photo behind `activity`, or retracts the current user's own
    /// like. Activities posted on the album itself (`assetId == nil`) carry no
    /// photo to like: no request unless it is the user's own like.
    /// try-then-mutate: state list untouched on throw.
    func toggleLike(activity: ActivityResponseDto) async {
        if hasMyLike(activity) {
            await unlike(activityId: activity.id)
        } else {
            guard let assetId = activity.assetId else { return }
            await like(assetId: assetId)
        }
    }

    /// Whether the row shows a heart: any photo activity, or the current
    /// user's own album-level like (which keeps its "Unlike").
    func canToggleLike(_ activity: ActivityResponseDto) -> Bool {
        activity.assetId != nil || hasMyLike(activity)
    }

    private func like(assetId: String) async {
        let dto = ActivityCreateDto(albumId: albumId, type: .like, assetId: assetId, comment: nil)
        do {
            _ = try await client.createActivity(dto: dto)
            await load()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func unlike(activityId: String) async {
        do {
            try await client.deleteActivity(id: activityId)
            await load()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Deletes an activity (server enforces ownership). Removes locally only
    /// on success.
    func deleteActivity(id: String) async {
        do {
            try await client.deleteActivity(id: id)
            activities.removeAll { $0.id == id }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}