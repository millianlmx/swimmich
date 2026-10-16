import XCTest
@testable import ImmichSwiftUI

final class AboutLinksTests: XCTestCase {
    private static let base = "https://github.com/millianlmx/swimmich/blob/main/"

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    /// AC-1: each shipped language opens the policy written in that language.
    func test_AC_1_eachShippedLanguageOpensItsOwnPolicy() {
        let table: [(code: String, url: String)] = [
            ("en", Self.base + "PRIVACY.md"),
            ("fr", Self.base + "PRIVACY.fr.md"),
            ("de", Self.base + "PRIVACY.de.md"),
            ("es", Self.base + "PRIVACY.es.md"),
            ("it", Self.base + "PRIVACY.it.md"),
        ]
        for row in table {
            XCTAssertEqual(AboutLinks.privacyPolicy(languageCode: row.code).absoluteString, row.url, row.code)
        }
    }

    /// AC-2: a language the app doesn't ship, or none at all, gets the English policy.
    func test_AC_2_unshippedOrMissingLanguageFallsBackToEnglish() {
        for code in ["ja", "pt", "zh", "", nil] as [String?] {
            XCTAssertEqual(AboutLinks.privacyPolicy(languageCode: code).absoluteString,
                           Self.base + "PRIVACY.md", String(describing: code))
        }
    }

    /// AC-6: Support opens the repository's issues page.
    func test_AC_6_supportOpensRepositoryIssues() {
        XCTAssertEqual(AboutLinks.support.absoluteString, "https://github.com/millianlmx/swimmich/issues")
    }

    /// AC-5: every policy URL the app can produce names a file that exists in
    /// the repository (the public page is that file on `main`).
    func test_AC_5_everyShippedLanguagePolicyFileExistsInTheRepo() {
        for language in AppLanguage.supported {
            let file = AboutLinks.privacyPolicy(languageCode: language.code).lastPathComponent
            let path = Self.repoRoot.appendingPathComponent(file).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(file) is missing at the repo root")
        }
    }
}
