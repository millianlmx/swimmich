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
    var errorMessage: String?

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Sorted queue names so the jobs list is stable across refreshes.
    var sortedJobNames: [String] { jobs.keys.sorted() }

    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let u = client.getAdminUsers()
            async let j = client.getJobsStatus()
            async let l = client.getLibraries()
            let (users, jobs, libraries) = try await (u, j, l)
            self.users = users
            self.jobs = jobs
            self.libraries = libraries
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
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
