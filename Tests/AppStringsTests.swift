import XCTest
@testable import ImmichSwiftUI

/// Source-level guard for the string catalog (P5 i18n, issue #21).
///
/// `LocalizationTests` covers what the *bundle* resolves at runtime; this file
/// covers the catalog as a document — the key/translation matrix the app is
/// compiled against, which the runtime can only observe one lookup at a time.
final class AppStringsTests: XCTestCase {

    private static var repoRoot: URL {
        // Tests run from the DerivedData build dir; walk up to the repo root
        // via the project file that always lives at the root.
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func loadCatalog() throws -> [String: Any] {
        let path = repoRoot.appendingPathComponent("Resources/Localizable.xcstrings").path
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object)
    }

    /// Every language the picker offers, minus the source language: the catalog
    /// keys are the English strings themselves, so English needs no entry.
    private static let shippedTranslations = ["fr", "de", "es", "it"]

    func test_catalog_isValidJSONWithExpectedSize() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(strings.count, 196, "Catalog must keep growing")
    }

    func test_catalog_tabBarKeysHaveFrenchTranslations() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in ["Photos", "Memories", "Albums", "People", "Shared", "Me", "Search"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing tab key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "No localizations for \(key)")
            XCTAssertNotNil(localizations["fr"], "Missing French translation for \(key)")
        }
    }

    /// The contract the Language screen relies on: a language can only be
    /// offered if the catalog carries it for *every* string with words in it.
    /// Placeholder-only keys (`%@`, `· %@`) and pure-symbol keys (`360°`) have
    /// nothing to translate and legitimately stay untranslated.
    func test_catalog_translatesEveryStringInEveryShippedLanguage() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        var incomplete: [String] = []

        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.shippedTranslations where localizations[language] == nil {
                if Self.hasWords(key) { incomplete.append("\(language): \(key)") }
            }
        }

        XCTAssertEqual(incomplete.sorted(), [], "Keys shipped without a translation")
    }

    func test_catalog_memoryCardKeysHaveFrenchTranslations() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let keys = [
            "Couldn't load memories", "Last year", "%lld years ago",
            "1 photo", "%lld photos", "1 video", "%lld videos"
        ]
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing memory key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "No localizations for \(key)")
            XCTAssertNotNil(localizations["fr"], "Missing French translation for \(key)")
        }
    }

    func test_AC_17_1_birthdayKeysAreTranslatedInEveryShippedLanguage() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let birthday = try XCTUnwrap(strings["%@'s birthday"] as? [String: Any])
        let birthdayLocalizations = try XCTUnwrap(birthday["localizations"] as? [String: Any])
        let age = try XCTUnwrap(strings["%lld years old"] as? [String: Any])
        let ageLocalizations = try XCTUnwrap(age["localizations"] as? [String: Any])

        for language in ["en", "fr", "de", "es", "it"] {
            let unit = try XCTUnwrap(birthdayLocalizations[language] as? [String: Any], "birthday \(language)")
            let value = ((unit["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            XCTAssertFalse(value.isEmpty, "birthday \(language)")

            let localization = try XCTUnwrap(ageLocalizations[language] as? [String: Any], "age \(language)")
            let variations = try XCTUnwrap(localization["variations"] as? [String: Any], "age \(language)")
            let plural = try XCTUnwrap(variations["plural"] as? [String: Any], "age \(language)")
            for form in ["one", "other"] {
                let formUnit = try XCTUnwrap(plural[form] as? [String: Any], "age \(language) \(form)")
                let text = ((formUnit["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                XCTAssertFalse(text.isEmpty, "age \(language) \(form)")
            }
        }
    }

    func test_AC_60_6_epilogueKeysAreTranslatedInEveryShippedLanguage() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in ["All caught up", "Check back tomorrow for more memories", "Start Over"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["en", "fr", "de", "es", "it"] {
                let unit = localizations[language] as? [String: Any]
                let value = ((unit?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
            }
        }
    }

    /// True when a key carries something a translator can act on: format
    /// specifiers and punctuation alone do not.
    private static func hasWords(_ key: String) -> Bool {
        let withoutFormatSpecifiers = key.replacingOccurrences(
            of: #"%(\d+\$)?[@dfslu]|%lld|%@"#, with: "", options: .regularExpression
        )
        return withoutFormatSpecifiers.rangeOfCharacter(from: .letters) != nil
    }
}
