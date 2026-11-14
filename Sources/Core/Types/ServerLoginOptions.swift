import Foundation

/// The sign-in modes a server accepts (L-28): the password form, the SSO
/// button, or both. Read for the server the user validated, never inferred
/// from another one.
struct ServerLoginOptions: Equatable, Sendable {
    let passwordLogin: Bool
    let oauth: Bool
    /// The provider label the server publishes (`oauth.buttonText`). `nil` on
    /// servers that serve the legacy features route, which carries no label.
    let oauthButtonText: String?

    /// `GET /api/public/config` appears in Immich v3.2.0 (PR #30881); the same
    /// release deprecates `GET /api/server/features`. Below it, the features
    /// route is the only one served.
    static let publicConfigMinimum = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)

    /// Whether `version` serves the public configuration route. An unknown
    /// version is treated as an older server: the features route is served by
    /// every supported version, the public one is not.
    static func servesPublicConfig(_ version: ServerVersionResponseDto?) -> Bool {
        guard let version else { return false }
        let minimum = publicConfigMinimum
        return version.isAtLeast(major: minimum.major, minor: minimum.minor, patch: minimum.patch)
    }
}

/// The part of `GET /api/public/config` (v3.2+) that decides the sign-in form.
/// Unknown keys are ignored.
struct PublicLoginConfigDto: Decodable, Equatable {
    struct PasswordLogin: Decodable, Equatable { let enabled: Bool }
    struct OAuth: Decodable, Equatable {
        let enabled: Bool
        let buttonText: String
    }

    let passwordLogin: PasswordLogin
    let oauth: OAuth

    var options: ServerLoginOptions {
        ServerLoginOptions(passwordLogin: passwordLogin.enabled, oauth: oauth.enabled, oauthButtonText: oauth.buttonText)
    }
}

/// The part of `GET /api/server/features` (every supported version, deprecated
/// from v3.2.0) that decides the sign-in form. Unknown keys are ignored.
struct ServerFeaturesLoginDto: Decodable, Equatable {
    let passwordLogin: Bool
    let oauth: Bool

    var options: ServerLoginOptions {
        ServerLoginOptions(passwordLogin: passwordLogin, oauth: oauth, oauthButtonText: nil)
    }
}
