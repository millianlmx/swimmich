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

    /// The four permission prompts show the Info.plist text, not the app
    /// catalog. A `NS*UsageDescription` that is missing, empty, or still the
    /// English source in a shipped language would put an English consent
    /// dialog on an otherwise translated device (AC-4).
    func test_infoPlistCatalog_translatesEveryUsageDescription() throws {
        let catalogURL = Self.repoRoot.appendingPathComponent("Resources/InfoPlist.xcstrings")
        let catalogObject = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
        let catalog = try XCTUnwrap(catalogObject as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let plistURL = Self.repoRoot.appendingPathComponent("Resources/Info.plist")
        let plistObject = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), options: [], format: nil
        )
        let infoPlist = try XCTUnwrap(plistObject as? [String: Any])

        let usageKeys = [
            "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription",
            "NSFaceIDUsageDescription", "NSCameraUsageDescription"
        ]
        var incomplete: [String] = []
        for key in usageKeys {
            let english = try XCTUnwrap(infoPlist[key] as? String, "Info.plist lost \(key)")
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any] ?? [:]
            for language in Self.shippedTranslations {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty || value == english { incomplete.append("\(language): \(key)") }
            }
        }

        XCTAssertEqual(incomplete, [], "Usage descriptions shipped without a translation")
        XCTAssertEqual(Set(strings.keys), Set(usageKeys), "InfoPlist.xcstrings must hold exactly the four usage descriptions")
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

    /// True when a key carries something a translator can act on: format
    /// specifiers and punctuation alone do not.
    private static func hasWords(_ key: String) -> Bool {
        let withoutFormatSpecifiers = key.replacingOccurrences(
            of: #"%(\d+\$)?[@dfslu]|%lld|%@"#, with: "", options: .regularExpression
        )
        return withoutFormatSpecifiers.rangeOfCharacter(from: .letters) != nil
    }
}
