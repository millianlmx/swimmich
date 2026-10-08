import Foundation
import Observation

/// Backs the album "Shared With" sheet — manages which instance users can
/// access the album and their role (Viewer / Editor).
///
/// Mirror of the Immich share model:
/// - grant  → `PUT /api/albums/:id/users`  (AddUsersDto)
/// - role   → `PUT /api/albums/:id/user/:userId`  (UpdateAlbumUserDto)
/// - revoke → `DELETE /api/albums/:id/user/:userId`
///
/// The current user (album owner) is never listed. Every action is
/// immediate (no Save button) and try-then-mutate: local state changes only
/// after the server call succeeds; on failure the row stays as-is and
/// `actionErrorMessage` is surfaced; a load failure goes to `loadErrorMessage`.
@MainActor
@Observable
final class AlbumShareViewModel {
    private let client: any ImmichClient
    let albumId: String
    private let currentUserId: String

    /// Whether the signed-in user is a server admin. Non-admins only get
    /// `[self]` back from `GET /users` (`UserService.search`), so the directory
    /// is hidden from them — the empty-state message adapts accordingly.
    let isAdmin: Bool

    /// True when the directory returned no listable users (non-admin without
    /// `server.publicUsers`, or a genuinely empty instance).
    var isDirectoryHidden = false

    /// Instance users available to grant access to (self excluded).
    var users: [UserResponseDto] = []

    /// The album owner (signed-in user). Always shown as the first row in the
    /// people card; never revocable. Seeded from `albumUsers` (the server puts
    /// the owner first, with `role == .owner`).
    private(set) var owner: UserResponseDto?

    /// Granted collaborators present in the directory (owner excluded).
    var collaborators: [UserResponseDto] {
        users.filter { roles[$0.id] != nil }
    }

    /// Directory users that can still be invited (not granted, not the owner).
    var inviteCandidates: [UserResponseDto] {
        users.filter { roles[$0.id] == nil }
    }

    /// userId → role for currently-granted collaborators. Local truth for the
    /// UI; seeded from `albumUsers` and mutated only on server success.
    private(set) var roles: [String: AlbumUserRole] = [:]

    /// Full DTOs of granted users from `albumUsers` — used to keep granted
    /// users visible (and revocable) even when missing from `GET /users`.
    private let grantedByID: [String: UserResponseDto]

    /// User ids with an in-flight mutation (toggle/role disabled while busy).
    private(set) var busyUserIds: Set<String> = []

    var isBusy = false
    var loadErrorMessage: String?
    var actionErrorMessage: String?

    /// Test-visible capture of the exact payloads dispatched.
    private(set) var lastAddDto: AddUsersDto?
    private(set) var lastRoleUpdateUserId: String?
    private(set) var lastRoleUpdateDto: UpdateAlbumUserDto?
    private(set) var lastRemovedUserId: String?

    init(
        client: any ImmichClient,
        albumId: String,
        currentUserId: String,
        isAdmin: Bool,
        albumUsers: [AlbumUserResponseDto]
    ) {
        self.client = client
        self.albumId = albumId
        self.currentUserId = currentUserId
        self.isAdmin = isAdmin
        var seeded: [String: AlbumUserRole] = [:]
        var granted: [String: UserResponseDto] = [:]
        var foundOwner: UserResponseDto?
        for entry in albumUsers {
            if foundOwner == nil, entry.role == .owner {
                foundOwner = entry.user
            }
            guard entry.user.id != currentUserId else { continue }
            seeded[entry.user.id] = entry.role
            granted[entry.user.id] = entry.user
        }
        self.roles = seeded
        self.grantedByID = granted
        self.owner = foundOwner ?? albumUsers.first?.user
    }

    func role(for userId: String) -> AlbumUserRole? {
        roles[userId]
    }

    /// Loads instance users (self excluded). Non-admins get only `[self]` back
    /// from `GET /users` unless `server.publicUsers` is enabled — the granted
    /// collaborators (from `albumUsers`) stay visible and manageable either way.
    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let all = try await client.getUsers()
            var directory = all.filter { $0.id != currentUserId }
            // Granted users missing from the directory (e.g. deactivated) are
            // still shown so the owner can revoke access.
            for id in roles.keys where !directory.contains(where: { $0.id == id }) {
                if let user = grantedByID[id] {
                    directory.append(user)
                }
            }
            users = directory
            isDirectoryHidden = !isAdmin && directory.isEmpty
            loadErrorMessage = nil
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
    }

    /// Grants (default Viewer) or revokes access for `user`.
    func toggleAccess(for user: UserResponseDto) async {
        if roles[user.id] != nil {
            await revoke(userId: user.id)
        } else {
            await grant(user)
        }
    }

    /// Grants access with the given role (defaults to Viewer). Re-granting an
    /// already-granted user is a no-op.
    func grant(_ user: UserResponseDto, role: AlbumUserRole = .viewer) async {
        guard roles[user.id] == nil else { return }
        busyUserIds.insert(user.id)
        defer { busyUserIds.remove(user.id) }
        do {
            let dto = AddUsersDto(albumUsers: [AlbumUserDto(userId: user.id, role: role)])
            lastAddDto = dto
            _ = try await client.addUsersToAlbum(albumId: albumId, dto: dto)
            roles[user.id] = role
            actionErrorMessage = nil
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    func revoke(userId: String) async {
        guard roles[userId] != nil else { return }
        busyUserIds.insert(userId)
        defer { busyUserIds.remove(userId) }
        do {
            try await client.removeUserFromAlbum(albumId: albumId, userId: userId)
            lastRemovedUserId = userId
            roles.removeValue(forKey: userId)
            actionErrorMessage = nil
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    /// Changes the role of a granted user. try-then-mutate: local role updates
    /// only after the server call succeeds.
    func setRole(_ role: AlbumUserRole, for userId: String) async {
        guard roles[userId] != nil, roles[userId] != role else { return }
        busyUserIds.insert(userId)
        defer { busyUserIds.remove(userId) }
        do {
            let dto = UpdateAlbumUserDto(role: role)
            lastRoleUpdateDto = dto
            lastRoleUpdateUserId = userId
            try await client.updateAlbumUserRole(albumId: albumId, userId: userId, dto: dto)
            roles[userId] = role
            actionErrorMessage = nil
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }
}
