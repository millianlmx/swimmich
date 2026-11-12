import Foundation

/// "API Keys" (gap G20): the keys of the *current* account. `GET /api/api-keys`
/// is scoped to the bearer of the token and guarded by `apiKey.read`, not by an
/// admin permission — which is exactly why this surface cannot stay behind
/// `if auth.isAdmin` in the Me hub.
///
/// Deliberately not the admin panel's view model: that one's `load()` also fires
/// users, jobs and libraries, and it exposes `createUser`/`deleteUser`/
/// `deleteLibrary` to a screen any account can open. The only seam shared here is
/// `ImmichClient`.
@Observable
@MainActor
final class UserApiKeysViewModel {
    private let client: any ImmichClient

    var keys: [ApiKeyResponseDto] = []

    /// The key that carries the request (`GET /api/api-keys/me`, a singular
    /// `ApiKeyResponseDto`, never the list). Informative only: the app
    /// authenticates with a session token, so this is not what signs the calls
    /// the user makes from the app.
    var myKey: ApiKeyResponseDto?

    var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the list was read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the list, cleared by a success. Written by
    /// `load()` only.
    private(set) var loadErrorMessage: String?
    /// Failure of the last action (create, rotate, delete).
    var errorMessage: String?
    /// Bumped by every `load()`, so only the last read writes its result.
    private var loadGeneration = 0

    /// The plaintext secret between its creation (or rotation) and the single
    /// alert that shows it. The server returns it once and never again, so it
    /// lives here and nowhere else: never logged, never persisted.
    var pendingSecret: String?

    /// The key awaiting confirmation. The row's swipe only sets the target —
    /// nothing is rotated or revoked until the dialog is accepted.
    var rotationTarget: ApiKeyResponseDto?
    var deletionTarget: ApiKeyResponseDto?

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Loading

    /// What the "Your keys" section renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: keys.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// First read, "Try Again" and `.task` (never pulls). The list is replaced
    /// only by a success; a newer read supersedes one still in flight.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await client.getAPIKeys()
            guard generation == loadGeneration else { return }
            keys = fetched
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

    /// Best-effort by design: a server that refuses `GET /api/api-keys/me` to a
    /// session-authenticated caller hides the information row, it does not turn
    /// the whole screen into an error.
    func loadMyKey() async {
        myKey = try? await client.getMyAPIKey()
    }

    // MARK: - Actions

    /// `false` when nothing reached the server, so the create sheet stays open
    /// with the user's input intact.
    func create(name: String, permissions: [String]) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "Name is required.")
            return false
        }
        do {
            let resp = try await client.createAPIKey(name: trimmed, permissions: permissions)
            pendingSecret = resp.secret
            errorMessage = nil
            await load()
            return true
        } catch {
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Rotates a key: the server invalidates the previous secret immediately and
    /// answers with the new one, shown through the same single alert as a
    /// creation. Nothing local is stored, so nothing local can go stale.
    func rotate(_ key: ApiKeyResponseDto) async {
        rotationTarget = nil
        do {
            let resp = try await client.rotateAPIKey(id: key.id)
            pendingSecret = resp.secret
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func delete(_ key: ApiKeyResponseDto) async {
        deletionTarget = nil
        do {
            try await client.deleteAPIKey(id: key.id)
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Closes the secret's only display: the value is unrecoverable afterwards,
    /// which is what the server promises.
    func dismissSecret() {
        pendingSecret = nil
    }

    // MARK: - Projections

    /// `createdAt` is an ISO timestamp carrying milliseconds; the repo's parser
    /// accepts both shapes, and a malformed value reads as `Unknown` rather than
    /// as a blank row.
    func formattedCreatedAt(_ key: ApiKeyResponseDto) -> String {
        guard let raw = key.createdAt, let date = LongDateFormatter.parse(isoTimestamp: raw) else {
            return String(localized: "Unknown")
        }
        return AppDateFormat.string(from: date, style: .longDate)
    }

    func permissionsSummary(_ key: ApiKeyResponseDto) -> String {
        APIKeyPermission.summary(for: key.permissions ?? [])
    }
}
