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

    /// AC-7 / AC-11: "Immich" names the compatible server and nothing else.
    /// Every catalog key or value that still carries the word must be a server
    /// reference (or the one welcome-screen compatibility line); the app is
    /// "Swimmich", and the new keys ship in every language.
    func test_catalog_immichOnlyNamesTheServer_AC7() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let serverReferences: Set<String> = [
            "Compatible with Immich servers.",
            "Detected text search requires Immich 3.2 or later.",
            "If you forget this password, an administrator has to reset it from the Immich web interface.",
            "Photos in the locked folder are hidden everywhere else and open with your Immich PIN — a separate code from this app lock.",
            "%lld photos safe on Immich",
            "Add or remove a photo from the Immich favorites.",
            "Enter the URL of your Immich instance.",
            "Photos you upload to Immich will appear here.",
            "Sign in to Immich",
            "Uploads new photos from the photo library to Immich.",
            "Use your Immich account to access your photo library.",
            "%@ of originals taken on or before %@. They go to the system Recently Deleted album and stay available in Immich: only the copy on this device is removed.",
            "%lld items moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and they stay available in Immich.",
            "Removed items go to the system Recently Deleted album, which only you can empty — that is what reclaims the space. They stay available in Immich. Items in an iCloud Shared Album are never offered, because iOS cannot remove them from the album.",
            "Forgets every photo Swimmich has recorded as backed up — the tracked count goes to zero. The next backup then re-checks the whole library against the server. Nothing is deleted from Immich or from Photos, and already-uploaded photos are skipped again, but on an iCloud-optimized library the re-check reads a lot of metadata and can take a long time. Prefer \"Check server now\" when only a few photos are missing."
        ]

        var offenders: [String] = []
        for (key, value) in strings {
            let entry = value as? [String: Any] ?? [:]
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let values = localizations.values.compactMap {
                (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            if (key.contains("Immich") || values.contains { $0.contains("Immich") }) && !serverReferences.contains(key) {
                offenders.append(key)
            }
        }
        XCTAssertEqual(offenders.sorted(), [], "Immich must only name the server")

        // Every whitelisted key names the server as many times as its English
        // source does: a translation must not rebrand a server mention
        // ("supprimé d'Swimmich") or drop one.
        for key in serverReferences {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let expected = key.components(separatedBy: "Immich").count - 1
            for language in Self.shippedTranslations {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = try XCTUnwrap(unit?["value"] as? String, "\(key): missing \(language)")
                let actual = value.components(separatedBy: "Immich").count - 1
                XCTAssertEqual(actual, expected, "\(language) value of \"\(key.prefix(40))…\" must name Immich \(expected)× as the key does")
            }
        }

        for key in ["Welcome to Swimmich", "Compatible with Immich servers.", "Swimmich"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in Self.shippedTranslations {
                XCTAssertNotNil(localizations[language], "\(key): missing \(language)")
            }
        }
        XCTAssertNil(strings["Welcome to Immich"], "the old welcome key must be gone")
        XCTAssertNil(strings["Immich"], "the app is not called Immich")
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
