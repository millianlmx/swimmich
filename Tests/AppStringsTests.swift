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

    // MARK: - Identity (AC-29.1, AC-29.2)

    private static func values(of entry: Any?) -> [String] {
        let localizations = ((entry as? [String: Any])?["localizations"] as? [String: Any]) ?? [:]
        return localizations.values.compactMap {
            (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    func test_AC_29_1_lockKeysNameSwimmich() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in ["Swimmich Locked", "Unlock Swimmich"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing key \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in Self.shippedTranslations {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = try XCTUnwrap(unit?["value"] as? String, "\(key): missing \(language)")
                XCTAssertTrue(value.contains("Swimmich"), "\(key) (\(language)) must name Swimmich: \(value)")
            }
        }
        for key in ["PhotoVault Locked", "Unlock PhotoVault"] {
            XCTAssertNil(strings[key], "\(key) is the old brand")
        }
    }

    func test_AC_29_2_noPhotoVaultInCatalogOrSourceLiterals() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let inCatalog = strings.filter { key, value in
            key.contains("PhotoVault") || Self.values(of: value).contains { $0.contains("PhotoVault") }
        }.keys.sorted()
        XCTAssertEqual(inCatalog, [], "No catalog key or value may say PhotoVault")

        var offenders: [String] = []
        for (path, lines) in try Self.scannedSourceLines() {
            for line in lines where Self.stringSegments(in: line.text).contains(where: { $0.contains("PhotoVault") }) {
                offenders.append("\(path):\(line.number)")
            }
        }
        XCTAssertEqual(offenders, [], "No string literal may say PhotoVault")
    }

    /// "Immich" names the compatible server and nothing else: every catalog key
    /// or value that still carries the word is a server reference, and a
    /// translation names the server as often as its English key does.
    static let serverReferences: Set<String> = [
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
        "Forgets every photo Swimmich has recorded as backed up — the tracked count goes to zero. The next backup then re-checks the whole library against the server. Nothing is deleted from Immich or from Photos, and already-uploaded photos are skipped again, but on an iCloud-optimized library the re-check reads a lot of metadata and can take a long time. Prefer \"Check server now\" when only a few photos are missing.",
        "Swimmich doesn't create any account. Your account lives on your Immich server: to delete it, contact that server's administrator."
    ]

    /// Server mentions that do not go through the catalog (plain `String`s built
    /// in `UploadViewModel.albumSectionFooter`).
    static let uncataloguedServerLiterals: [String] = [
        "Only photos in the albums you picked are backed up. Nothing is ever deleted from Immich or from Photos.",
        "Photos in the albums you picked are left out of every backup. Nothing is ever deleted from Immich or from Photos."
    ]

    func test_AC_29_2_immichOnlyNamesTheServer() throws {
        let catalog = try Self.loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        var offenders: [String] = []
        for (key, value) in strings {
            if (key.contains("Immich") || Self.values(of: value).contains { $0.contains("Immich") })
                && !Self.serverReferences.contains(key) {
                offenders.append(key)
            }
        }
        XCTAssertEqual(offenders.sorted(), [], "Immich must only name the server")

        // A translation must not rebrand a server mention ("supprimé d'Swimmich")
        // or drop one.
        for key in Self.serverReferences {
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

    /// The same rule on the Swift sources, so a later merge that brings the app
    /// name back as a literal ("Welcome to Immich") fails here. A line may cite
    /// the server through a known fragment; whatever "Immich" is left once those
    /// are erased is an app name.
    func test_AC_29_2_immichInSourceLiteralsOnlyNamesTheServer() throws {
        let placeholder = #"%(?:\d+\$)?(?:lld|ld|d|@|f|s|u)"#
        var fragments: [String] = []
        for key in Self.serverReferences {
            let pieces = key.replacingOccurrences(of: placeholder, with: "\u{0}", options: .regularExpression)
                .components(separatedBy: "\u{0}")
            fragments += pieces.filter { $0.contains("Immich") }.map(Self.sourceForm)
        }
        fragments += Self.uncataloguedServerLiterals.map(Self.sourceForm)

        var offenders: [String] = []
        for (path, lines) in try Self.scannedSourceLines() {
            for line in lines where Self.stringSegments(in: line.text).contains(where: Self.namesImmich) {
                var erased = line.text
                for fragment in fragments { erased = erased.replacingOccurrences(of: fragment, with: "") }
                if Self.stringSegments(in: erased).contains(where: Self.namesImmich) {
                    offenders.append("\(path):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Immich may only name the server in a string literal")
    }

    private static func sourceForm(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func namesImmich(_ segment: String) -> Bool {
        segment.range(of: #"\bImmich\b"#, options: .regularExpression) != nil
    }

    /// The string-literal segments of one source line.
    private static func stringSegments(in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""[^"\\]*(\\.[^"\\]*)*""#) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
            Range($0.range, in: line).map { String(line[$0]) }
        }
    }

    /// Every `.swift` file of the app, widgets and share extension, comments
    /// removed (a comment-only line is dropped, a trailing ` //` comment cut).
    private static func scannedSourceLines() throws -> [(path: String, lines: [(number: Int, text: String)])] {
        var result: [(path: String, lines: [(number: Int, text: String)])] = []
        for directory in ["Sources", "ImmichWidgets", "ImmichShareExtension"] {
            let base = repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            var urls: [URL] = []
            for case let url as URL in walker where url.pathExtension == "swift" { urls.append(url) }
            for url in urls.sorted(by: { $0.path < $1.path }) {
                let text = try String(contentsOf: url, encoding: .utf8)
                var lines: [(number: Int, text: String)] = []
                for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                    if raw.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { continue }
                    lines.append((index + 1, strippingTrailingComment(raw)))
                }
                result.append((String(url.path.dropFirst(repoRoot.path.count + 1)), lines))
            }
        }
        return result
    }

    private static func strippingTrailingComment(_ line: String) -> String {
        let chars = Array(line)
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == " ", i + 2 < chars.count, chars[i + 1] == "/", chars[i + 2] == "/" {
                return String(chars[..<i])
            }
            i += 1
        }
        return line
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
