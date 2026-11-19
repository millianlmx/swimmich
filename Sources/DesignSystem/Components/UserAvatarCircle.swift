import SwiftUI

/// User avatar: the published profile picture when the server has one, the
/// user's initials on their `avatarColor` otherwise (gap G16).
///
/// Shared by the photo-share sheet, the album "Shared With" sheet, the album
/// detail hero, the activity feed, the partner directory and the photo viewer —
/// they all pass `baseURL`/`token` so the photo of *anyone* they display is
/// shown, not just the signed-in user. Without them the component keeps its
/// previous behaviour (initials, no image round-trip).
struct UserAvatarCircle: View {
    let user: UserResponseDto
    var size: CGFloat = 32
    /// The connected server. `nil` = initials only.
    var baseURL: URL? = nil
    /// Bearer token of the session — the profile-image route takes no token in
    /// the query string, so the header is the only way in.
    var token: String? = nil

    var body: some View {
        ZStack {
            if let photoURL {
                AuthenticatedAsyncImage(url: photoURL, token: token)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .transition(.opacity)
            } else {
                // The server's own colour keeps white initials; the fallback is the
                // accent, whose pale dark-mode value needs `immichOnPrimary`.
                let serverColor = Color(hex: user.avatarColor)
                Circle().fill(serverColor ?? Color.immichPrimary)
                Text(Self.initials(from: user.name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(serverColor == nil ? Color.immichOnPrimary : Color.white)
            }
        }
        .frame(width: size, height: size)
    }

    /// Non-nil only when the server actually holds a photo: an empty
    /// `profileImagePath` (the state after a `DELETE`) must fall back to the
    /// initials rather than request a route that would 404.
    private var photoURL: URL? {
        guard let baseURL, !user.profileImagePath.isEmpty else { return nil }
        return ImmichAssetURL.profileImage(
            userId: user.id,
            changedAt: user.profileChangedAt,
            baseURL: baseURL
        )
    }

    static func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
