import Foundation

/// Admin panel state (gap #12): users, jobs, libraries. Admin-gated at the view
/// level via `auth.isAdmin`; the VM is plain CRUD over the admin endpoints.
///
/// It no longer carries API keys: the token's own keys are not an admin object
/// (`UserApiKeysViewModel`, gap G20), and one state cannot have two owners.
@Observable
@MainActor
final class AdminViewModel {
    let client: any ImmichClient

    var users: [UserAdminResponseDto] = []
    var jobs: [String: QueueResponseLegacyDto] = [:]
    var libraries: [LibraryResponseDto] = []

    var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once users, jobs and libraries were read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the three lists, cleared by a success.
    /// Written by `load` only.
    private(set) var loadErrorMessage: String?
    /// Failure of the last mutation (user, job, library).
    var errorMessage: String?
    /// Bumped by every `load`, so only the last read writes its result.
    private var loadGeneration = 0

    /// Instance-wide totals (`GET /api/server/statistics`, administrators only).
    private(set) var instanceStats: ServerStatsResponseDto?
    private(set) var instanceStatsError: String?
    private(set) var isLoadingInstanceStats = false

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Sorted queue names so the jobs list is stable across refreshes.
    var sortedJobNames: [String] { jobs.keys.sorted() }

    /// What the three lists render (`data` = the users).
    var renderState: ListRenderState {
        .resolve(
            isEmpty: users.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// First read, "Try Again", `.task` and the reload after a mutation (never
    /// pulls). The lists are replaced only by a success; a newer read
    /// supersedes one still in flight. Without `force`, a read already in
    /// flight is not duplicated.
    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            async let u = client.getAdminUsers()
            async let j = client.getJobsStatus()
            async let l = client.getLibraries()
            let (users, jobs, libraries) = try await (u, j, l)
            guard generation == loadGeneration else { return }
            self.users = users
            self.jobs = jobs
            self.libraries = libraries
            hasLoaded = true
            loadErrorMessage = nil
        } catch {
            guard generation == loadGeneration, let message = error.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    /// Pull-to-refresh: the three admin lists and the instance totals, in
    /// parallel. Each keeps its own outcome.
    func refresh() async {
        async let stats: Void = loadInstanceStats()
        isRefreshing = true
        await load(force: true)
        isRefreshing = false
        await stats
    }

    // MARK: - Instance statistics

    /// Reads the instance totals on their own: `load(force:)` does not touch
    /// them, so one failing never hides the other sections. A cancelled read
    /// (SwiftUI cancels `.task` / `.refreshable`) changes nothing.
    func loadInstanceStats() async {
        guard !isLoadingInstanceStats else { return }
        isLoadingInstanceStats = true
        defer { isLoadingInstanceStats = false }
        do {
            instanceStats = try await client.getServerStatistics()
            instanceStatsError = nil
        } catch {
            if UserFacingError.isCancellation(error) || Task.isCancelled { return }
            instanceStats = nil
            instanceStatsError = error.userFacingMessage ?? UserFacingError.genericMessage
        }
    }

    // MARK: - Users

    func createUser(name: String, email: String, password: String, isAdmin: Bool) async {
        let dto = UserAdminCreateDto(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            storageLabel: nil,
            quotaSizeInBytes: nil,
            shouldChangePassword: nil,
            isAdmin: isAdmin
        )
        do {
            _ = try await client.createAdminUser(dto: dto)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func deleteUser(_ user: UserAdminResponseDto, force: Bool) async {
        do {
            _ = try await client.deleteAdminUser(id: user.id, force: force)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func restoreUser(_ user: UserAdminResponseDto) async {
        do {
            _ = try await client.restoreAdminUser(id: user.id)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Jobs

    func runJob(name: String, command: String) async {
        do {
            _ = try await client.sendJobCommand(name: name, command: command, force: command == "start" ? true : nil)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Libraries

    func scanLibrary(_ library: LibraryResponseDto) async {
        do {
            try await client.scanLibrary(id: library.id)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func deleteLibrary(_ library: LibraryResponseDto) async {
        do {
            try await client.deleteLibrary(id: library.id)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}
