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
    var errorMessage: String?
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

    /// Full album feed, newest first. Separates sorting from network so the
    /// list stays stable while reloading.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.getActivities(albumId: albumId, assetId: nil)
            activities = fetched.sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
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

    /// Likes or unlikes the asset behind `activity` (comments and likes carry
    /// an `assetId`). try-then-mutate: state list untouched on throw.
    func toggleLike(activity: ActivityResponseDto) async {
        if hasMyLike(activity) {
            await unlike(activityId: activity.id)
        } else {
            await like(assetId: activity.assetId)
        }
    }

    private func like(assetId: String) async {
        guard !assetId.isEmpty else { return }
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