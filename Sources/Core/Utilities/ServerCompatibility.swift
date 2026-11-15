import Foundation

/// The server's version is outside the range Swimmich is built for (L-28).
/// Informational only: it never blocks a sign-in.
enum ServerVersionWarning: Equatable {
    case tooOld(version: String)
    case tooNew(version: String)

    /// The text of the inline notice, in the language of `bundle`.
    func localizedMessage(bundle: Bundle) -> String {
        switch self {
        case .tooOld(let version):
            String(
                localized: "This server runs Immich \(version). Swimmich supports Immich 2.0.0 and later: some features may not work.",
                bundle: bundle
            )
        case .tooNew(let version):
            String(
                localized: "This server runs Immich \(version), newer than the versions Swimmich supports (up to 3.x): some features may not work.",
                bundle: bundle
            )
        }
    }

    var message: String { localizedMessage(bundle: .main) }
}

enum ServerCompatibility {
    /// First and last major versions the app supports: Immich 2.x to 3.x.
    /// The official client warns when the app's major is below the server's, or
    /// above it by more than one; for Swimmich's supported majors (2 and 3)
    /// that is "below 2.0.0" and "4.0.0 and above".
    private static let oldestMajor = 2
    private static let newestMajor = 3

    /// `nil` when the version is compatible or unknown: an unreadable version
    /// says nothing about the server, so no notice is raised.
    static func warning(for version: ServerVersionResponseDto?) -> ServerVersionWarning? {
        guard let version else { return nil }
        let text = "\(version.major).\(version.minor).\(version.patch)"
        if version.major < oldestMajor { return .tooOld(version: text) }
        if version.major > newestMajor { return .tooNew(version: text) }
        return nil
    }
}
