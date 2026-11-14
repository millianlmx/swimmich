import Foundation

/// View model for the cross-album "Shared" tab (PRD §4). Lists ALL of the
/// user's shared links (album + individual), supports revoking, and creating
/// new album-typed links.
///
/// Reuses the existing `ImmichClient` shared-link endpoints — no new server
/// contract. `getSharedLinks(albumId: nil)` returns every link for the user.
@MainActor
@Observable
final class SharedLinksViewModel {
    private let client: any ImmichClient

    var sharedLinks: [SharedLinkResponseDto] = []
    var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the list was read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the list, cleared by a success. Written by
    /// `load()` only; actions use `actionErrorMessage`.
    private(set) var loadErrorMessage: String?
    var actionErrorMessage: String?
    /// Bumped by every `load()`, so only the last read writes its result.
    private var loadGeneration = 0

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Load

    /// What the list renders (S-1): loading, error, empty or the rows.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: sharedLinks.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// Read without a pull (`.task`, every "Try Again"). The list is replaced
    /// only by a success; a newer read supersedes one still in flight.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            // albumId: nil → list ALL shared links for the authenticated user.
            let fetched = try await client.getSharedLinks(albumId: nil)
            guard generation == loadGeneration else { return }
            sharedLinks = fetched
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

    /// Bumped once per accepted revocation; the view plays a warning haptic on
    /// each change (AC-806). A refused request or Cancel never bumps it.
    private(set) var revokeFeedbackTick = 0

    // MARK: - Revoke

    /// Revokes a shared link. Returns `true` when the link was removed, `false`
    /// on failure (the caller can then re-show the card + surface the error).
    @discardableResult
    func revoke(id: String) async -> Bool {
        do {
            try await client.deleteSharedLink(id: id)
            // try-then-mutate: remove only on success.
            sharedLinks.removeAll { $0.id == id }
            actionErrorMessage = nil
            revokeFeedbackTick &+= 1
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    // MARK: - Edit (AC-1090)

    /// Updates an existing shared link (description, password, expiry,
    /// permissions). Try-then-mutate: the row is replaced only on success.
    @discardableResult
    func updateLink(id: String, dto: SharedLinkEditDto) async -> Bool {
        do {
            let updated = try await client.updateSharedLink(id: id, dto: dto)
            if let idx = sharedLinks.firstIndex(where: { $0.id == id }) {
                sharedLinks[idx] = updated
            }
            actionErrorMessage = nil
            return true
        } catch {
            actionErrorMessage = error.userFacingMessage
            return false
        }
    }

    // MARK: - Create (album-typed)

    /// Creates a new album shared link. The caller provides an `albumId` (from
    /// the user's album list), plus an optional description, password, custom
    /// `slug` and `expiresAt`.
    ///
    /// Returns the created link (or `nil` on failure): the create sheet shows
    /// its public URL on a "link ready" panel, so it needs the server's answer
    /// — the slug especially, which the server stores as sent but which the URL
    /// builder must not have to guess.
    func createAlbumLink(
        albumId: String,
        description: String?,
        password: String?,
        slug: String? = nil,
        expiresAt: Date? = nil
    ) async -> SharedLinkResponseDto? {
        let trimmedPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = (trimmedPassword?.isEmpty ?? true) ? nil : trimmedPassword
        let trimmedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dto = SharedLinkCreateDto(
            type: .album,
            albumId: albumId,
            description: description,
            password: pw,
            expiresAt: expiresAt.map(Self.isoString(from:)),
            slug: (trimmedSlug?.isEmpty ?? true) ? nil : trimmedSlug
        )
        do {
            let link = try await client.createSharedLink(dto: dto)
            sharedLinks.append(link)
            actionErrorMessage = nil
            return link
        } catch {
            actionErrorMessage = error.userFacingMessage
            return nil
        }
    }

    /// Wire format for `expiresAt` — the server takes an ISO-8601 instant.
    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
