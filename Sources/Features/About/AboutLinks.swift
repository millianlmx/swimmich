import Foundation

/// Public pages the About screen opens (privacy policy per shipped language, support).
///
/// The policy lives as Markdown in the public `millianlmx/swimmich` repository
/// and GitHub renders it without a sign-in. `PRIVACY.md` is the English
/// version; the others carry the language code before the extension.
enum AboutLinks {
    private static let repository = "https://github.com/millianlmx/swimmich"

    /// The repository's issue tracker.
    static let support = URL(string: "\(repository)/issues")!

    /// The policy in `languageCode`'s language, or the English one when that
    /// language isn't shipped (or there is none).
    static func privacyPolicy(languageCode: String?) -> URL {
        let file: String
        switch AppLanguage.language(for: languageCode)?.code {
        case let code? where code != "en":
            file = "PRIVACY.\(code).md"
        default:
            file = "PRIVACY.md"
        }
        return URL(string: "\(repository)/blob/main/\(file)")!
    }
}
