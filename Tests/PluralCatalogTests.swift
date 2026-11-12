import XCTest
@testable import ImmichSwiftUI

/// B-21: every counted label of the catalog agrees with its number, in every
/// shipped language. Two views of the same fact: the catalog as a document (the
/// forms the translators wrote) and the catalog as the app resolves it (the
/// text a given count renders in a given language).
final class PluralCatalogTests: XCTestCase {

    private static let shippedLanguages = ["fr", "de", "es", "it"]

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) { return url }
            url.deleteLastPathComponent()
        }
        return url
    }

    private static func loadStrings() throws -> [String: [String: Any]] {
        let url = repoRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(object?["strings"] as? [String: [String: Any]])
        return strings
    }

    private static func localization(_ strings: [String: [String: Any]], _ key: String, _ language: String) throws -> [String: Any] {
        let entry = try XCTUnwrap(strings[key], "missing key \(key)")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "\(key): no localizations")
        return try XCTUnwrap(localizations[language] as? [String: Any], "\(key): missing \(language)")
    }

    private static func value(of unit: Any?) -> String? {
        ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private static func plural(of holder: [String: Any]) -> [String: Any]? {
        (holder["variations"] as? [String: Any])?["plural"] as? [String: Any]
    }

    /// Every text of one language of one key: the plain value, each plural form
    /// and each form of each substitution.
    private static func texts(of localization: [String: Any]) -> [String] {
        var result: [String] = []
        if let text = value(of: localization) { result.append(text) }
        if let forms = plural(of: localization) { result += forms.values.compactMap { value(of: $0) } }
        for substitution in (localization["substitutions"] as? [String: Any] ?? [:]).values {
            if let holder = substitution as? [String: Any], let forms = plural(of: holder) {
                result += forms.values.compactMap { value(of: $0) }
            }
        }
        return result
    }

    /// The English text a localization renders for counts (English has one form
    /// for 1 and another for the rest): the document is the only source, `en`
    /// has no `.lproj`.
    private static func render(_ localization: [String: Any], counts: [Int]) throws -> String {
        func form(_ holder: [String: Any], _ count: Int) throws -> String {
            let forms = try XCTUnwrap(plural(of: holder))
            return try XCTUnwrap(value(of: forms[count == 1 ? "one" : "other"]))
        }
        if plural(of: localization) != nil {
            return try form(localization, counts[0]).replacingOccurrences(of: "%lld", with: String(counts[0]))
        }
        var text = try XCTUnwrap(value(of: localization))
        let substitutions = try XCTUnwrap(localization["substitutions"] as? [String: Any])
        for (name, raw) in substitutions {
            let holder = try XCTUnwrap(raw as? [String: Any])
            let argument = try XCTUnwrap(holder["argNum"] as? Int)
            let count = counts[argument - 1]
            text = text.replacingOccurrences(
                of: "%#@\(name)@",
                with: try form(holder, count).replacingOccurrences(of: "%arg", with: String(count))
            )
        }
        return text
    }

    // MARK: - The two labels of AC-32

    func test_AC_32_photoAndSelectedFormsInFourLanguages() throws {
        let photos: [String: (String, String)] = [
            "fr": ("1 photo", "2 photos"), "de": ("1 Foto", "2 Fotos"),
            "es": ("1 foto", "2 fotos"), "it": ("1 foto", "2 foto"),
        ]
        let selected: [String: (String, String)] = [
            "fr": ("1 sélectionné", "2 sélectionnés"), "de": ("1 ausgewählt", "2 ausgewählt"),
            "es": ("1 seleccionado", "2 seleccionados"), "it": ("1 selezionato", "2 selezionati"),
        ]
        for code in Self.shippedLanguages {
            let (onePhoto, twoPhotos) = try XCTUnwrap(photos[code])
            XCTAssertEqual(try catalogString("%lld photos", language: code, 1), onePhoto, code)
            XCTAssertEqual(try catalogString("%lld photos", language: code, 2), twoPhotos, code)
            let (oneSelected, twoSelected) = try XCTUnwrap(selected[code])
            XCTAssertEqual(try catalogString("%lld selected", language: code, 1), oneSelected, code)
            XCTAssertEqual(try catalogString("%lld selected", language: code, 2), twoSelected, code)
        }
    }

    /// French counts 0 and 1 as singular, English counts 0 as plural: the
    /// selection title of a screen with nothing chosen follows each language.
    func test_AC_32_1_selectedFollowsEachLanguageRule() throws {
        XCTAssertEqual(try catalogString("%lld selected", language: "fr", 0), "0 sélectionné")
        XCTAssertEqual(try catalogString("%lld selected", language: "fr", 1), "1 sélectionné")
        XCTAssertEqual(try catalogString("%lld selected", language: "fr", 2), "2 sélectionnés")

        let strings = try Self.loadStrings()
        let english = try Self.localization(strings, "%lld selected", "en")
        let forms = try XCTUnwrap(Self.plural(of: english))
        XCTAssertEqual(Self.value(of: forms["one"]), "%lld selected")
        XCTAssertEqual(Self.value(of: forms["other"]), "%lld selected")
    }

    // MARK: - Every counted key

    /// (key, counts, English text, French text) for 1 and 2 of every counted
    /// key; a key with several counters alternates 1, 2, 1… and 2, 1, 2…
    private static let countedKeys: [(String, [Int], String, String)] = [
        ("%lld photos", [1], "1 photo", "1 photo"),
        ("%lld photos", [2], "2 photos", "2 photos"),
        ("%lld videos", [1], "1 video", "1 vidéo"),
        ("%lld videos", [2], "2 videos", "2 vidéos"),
        ("%lld items", [1], "1 item", "1 élément"),
        ("%lld items", [2], "2 items", "2 éléments"),
        ("%lld people", [1], "1 person", "1 personne"),
        ("%lld people", [2], "2 people", "2 personnes"),
        ("%lld files", [1], "1 file", "1 fichier"),
        ("%lld files", [2], "2 files", "2 fichiers"),
        ("%lld folders", [1], "1 folder", "1 dossier"),
        ("%lld folders", [2], "2 folders", "2 dossiers"),
        ("%lld selected", [1], "1 selected", "1 sélectionné"),
        ("%lld selected", [2], "2 selected", "2 sélectionnés"),
        ("%lld photos in a stack", [1], "1 photo in a stack", "1 photo dans une pile"),
        ("%lld photos in a stack", [2], "2 photos in a stack", "2 photos dans une pile"),
        ("%lld photos in stack", [1], "1 photo in stack", "1 photo dans la pile"),
        ("%lld photos in stack", [2], "2 photos in stack", "2 photos dans la pile"),
        ("%lld years ago", [1], "1 year ago", "il y a 1 an"),
        ("%lld years ago", [2], "2 years ago", "il y a 2 ans"),
        ("%lld albums", [1], "1 album", "1 album"),
        ("%lld albums", [2], "2 albums", "2 albums"),
        ("%lld assets", [1], "1 asset", "1 élément"),
        ("%lld assets", [2], "2 assets", "2 éléments"),
        ("%lld copies", [1], "1 copy", "1 copie"),
        ("%lld copies", [2], "2 copies", "2 copies"),
        ("%lld permissions", [1], "1 permission", "1 autorisation"),
        ("%lld permissions", [2], "2 permissions", "2 autorisations"),
        ("%lld active", [1], "1 active", "1 actif"),
        ("%lld active", [2], "2 active", "2 actifs"),
        ("%lld not on server", [1], "1 not on server", "1 absent du serveur"),
        ("%lld not on server", [2], "2 not on server", "2 absents du serveur"),
        ("%lld on server", [1], "1 on server", "1 sur le serveur"),
        ("%lld on server", [2], "2 on server", "2 sur le serveur"),
        ("%lld couldn't be backed up", [1], "1 couldn't be backed up", "1 n'a pas pu être sauvegardée"),
        ("%lld couldn't be backed up", [2], "2 couldn't be backed up", "2 n'ont pas pu être sauvegardées"),
        ("%lld photos safe on Immich", [1], "1 photo safe on Immich", "1 photo en sécurité sur Immich"),
        ("%lld photos safe on Immich", [2], "2 photos safe on Immich", "2 photos en sécurité sur Immich"),
        ("Preparing %lld photos", [1], "Preparing 1 photo", "Préparation de 1 photo"),
        ("Preparing %lld photos", [2], "Preparing 2 photos", "Préparation de 2 photos"),
        ("Review %lld items", [1], "Review 1 item", "Vérifier 1 élément"),
        ("Review %lld items", [2], "Review 2 items", "Vérifier 2 éléments"),
        ("Delete %lld items from this device?", [1], "Delete 1 item from this device?", "Supprimer 1 élément de cet appareil ?"),
        ("Delete %lld items from this device?", [2], "Delete 2 items from this device?", "Supprimer 2 éléments de cet appareil ?"),
        ("%lld items moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and they stay available in Immich.", [1], "1 item moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and it stays available in Immich.", "1 élément déplacé vers l'album « Récents supprimés » du système. C'est en le vidant que l'espace est réellement libéré, et il reste disponible dans Immich."),
        ("%lld items moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and they stay available in Immich.", [2], "2 items moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and they stay available in Immich.", "2 éléments déplacés vers l'album « Récents supprimés » du système. C'est en le vidant que l'espace est réellement libéré, et ils restent disponibles dans Immich."),
        ("Log out %lld devices", [1], "Log out 1 device", "Déconnecter 1 appareil"),
        ("Log out %lld devices", [2], "Log out 2 devices", "Déconnecter 2 appareils"),
        ("Log out %lld other devices?", [1], "Log out 1 other device?", "Déconnecter 1 autre appareil ?"),
        ("Log out %lld other devices?", [2], "Log out 2 other devices?", "Déconnecter les 2 autres appareils ?"),
        ("Last %lld days", [1], "Last 1 day", "1 dernier jour"),
        ("Last %lld days", [2], "Last 2 days", "2 derniers jours"),
        ("%lld stars", [1], "1 star", "1 étoile"),
        ("%lld stars", [2], "2 stars", "2 étoiles"),
        ("Rate %lld stars", [1], "Rate 1 star", "Noter 1 étoile"),
        ("Rate %lld stars", [2], "Rate 2 stars", "Noter 2 étoiles"),
        ("Rating, %lld stars", [1], "Rating, 1 star", "Note, 1 étoile"),
        ("Rating, %lld stars", [2], "Rating, 2 stars", "Note, 2 étoiles"),
        ("Rating filter: %lld stars", [1], "Rating filter: 1 star", "Filtre de note : 1 étoile"),
        ("Rating filter: %lld stars", [2], "Rating filter: 2 stars", "Filtre de note : 2 étoiles"),
        ("Show %lld hidden people", [1], "Show 1 hidden person", "Afficher 1 personne masquée"),
        ("Show %lld hidden people", [2], "Show 2 hidden people", "Afficher 2 personnes masquées"),
        ("Delete %lld assets?", [1], "Delete 1 asset?", "Supprimer 1 élément ?"),
        ("Delete %lld assets?", [2], "Delete 2 assets?", "Supprimer 2 éléments ?"),
        ("%lld photos belong to a partner and were not changed.", [1], "1 photo belongs to a partner and was not changed.", "1 photo appartenant à un partenaire n'a pas été modifiée."),
        ("%lld photos belong to a partner and were not changed.", [2], "2 photos belong to a partner and were not changed.", "2 photos appartenant à un partenaire n'ont pas été modifiées."),
        ("%lld photos belong to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.", [1], "1 photo belongs to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.", "1 photo appartenant à un partenaire ne sera pas supprimée. Les autres sont retirées de votre photothèque. Action irréversible."),
        ("%lld photos belong to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.", [2], "2 photos belong to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.", "2 photos appartenant à un partenaire ne seront pas supprimées. Les autres sont retirées de votre photothèque. Action irréversible."),
        ("Remove %lld photos from this album?", [1], "Remove 1 photo from this album?", "Retirer 1 photo de cet album ?"),
        ("Remove %lld photos from this album?", [2], "Remove 2 photos from this album?", "Retirer 2 photos de cet album ?"),
        ("Upload %lld items", [1], "Upload 1 item", "Envoyer 1 élément"),
        ("Upload %lld items", [2], "Upload 2 items", "Envoyer 2 éléments"),
        ("%lld items could not be uploaded.", [1], "1 item could not be uploaded.", "1 élément n'a pas pu être envoyé."),
        ("%lld items could not be uploaded.", [2], "2 items could not be uploaded.", "2 éléments n'ont pas pu être envoyés."),
        ("Delete %lld duplicates?", [1], "Delete 1 duplicate?", "Supprimer 1 doublon ?"),
        ("Delete %lld duplicates?", [2], "Delete 2 duplicates?", "Supprimer 2 doublons ?"),
        ("%lld albums selected", [1], "1 album selected", "1 album sélectionné"),
        ("%lld albums selected", [2], "2 albums selected", "2 albums sélectionnés"),
        ("%lld albums excluded", [1], "1 album excluded", "1 album exclu"),
        ("%lld albums excluded", [2], "2 albums excluded", "2 albums exclus"),
        ("%lld albums mirrored", [1], "1 album mirrored", "1 album reflété"),
        ("%lld albums mirrored", [2], "2 albums mirrored", "2 albums reflétés"),
        ("%lld uploaded", [1], "1 uploaded", "1 envoyée"),
        ("%lld uploaded", [2], "2 uploaded", "2 envoyées"),
        ("%lld failed", [1], "1 failed", "1 en échec"),
        ("%lld failed", [2], "2 failed", "2 en échec"),
        ("%lld waiting for Wi-Fi", [1], "1 waiting for Wi-Fi", "1 en attente du Wi-Fi"),
        ("%lld waiting for Wi-Fi", [2], "2 waiting for Wi-Fi", "2 en attente du Wi-Fi"),
        ("%lld waiting for iCloud", [1], "1 waiting for iCloud", "1 en attente d'iCloud"),
        ("%lld waiting for iCloud", [2], "2 waiting for iCloud", "2 en attente d'iCloud"),
        ("%lld waiting", [1], "1 waiting", "1 en attente"),
        ("%lld waiting", [2], "2 waiting", "2 en attente"),
        ("Finished with %lld failed", [1], "Finished with 1 failed", "Terminé avec 1 échec"),
        ("Finished with %lld failed", [2], "Finished with 2 failed", "Terminé avec 2 échecs"),
        ("%lld favorites", [1], "1 favorite", "1 favori"),
        ("%lld favorites", [2], "2 favorites", "2 favoris"),
        ("%lld photos · %lld videos", [1, 2], "1 photo · 2 videos", "1 photo · 2 vidéos"),
        ("%lld photos · %lld videos", [2, 1], "2 photos · 1 video", "2 photos · 1 vidéo"),
        ("%lld photos · %lld places", [1, 2], "1 photo · 2 places", "1 photo · 2 lieux"),
        ("%lld photos · %lld places", [2, 1], "2 photos · 1 place", "2 photos · 1 lieu"),
        ("%lld uploaded · %lld already on server", [1, 2], "1 uploaded · 2 already on server", "1 envoyée · 2 déjà sur le serveur"),
        ("%lld uploaded · %lld already on server", [2, 1], "2 uploaded · 1 already on server", "2 envoyées · 1 déjà sur le serveur"),
        ("%lld uploaded · %lld failed", [1, 2], "1 uploaded · 2 failed", "1 envoyée · 2 en échec"),
        ("%lld uploaded · %lld failed", [2, 1], "2 uploaded · 1 failed", "2 envoyées · 1 en échec"),
        ("%lld added · %lld already there · %lld failed", [1, 2, 1], "1 added · 2 already there · 1 failed", "1 ajoutée · 2 déjà présentes · 1 en échec"),
        ("%lld added · %lld already there · %lld failed", [2, 1, 2], "2 added · 1 already there · 2 failed", "2 ajoutées · 1 déjà présente · 2 en échec"),
        ("%lld photos uploaded, %lld failed.", [1, 2], "1 photo uploaded, 2 failed.", "1 photo envoyée, 2 en échec."),
        ("%lld photos uploaded, %lld failed.", [2, 1], "2 photos uploaded, 1 failed.", "2 photos envoyées, 1 en échec."),
        ("%lld uploaded, %lld failed.", [1, 2], "1 uploaded, 2 failed.", "1 envoyée, 2 en échec."),
        ("%lld uploaded, %lld failed.", [2, 1], "2 uploaded, 1 failed.", "2 envoyées, 1 en échec."),
        ("%lld active · %lld waiting · %lld completed · %lld failed", [1, 2, 1, 2], "1 active · 2 waiting · 1 completed · 2 failed", "1 active · 2 en attente · 1 terminée · 2 en échec"),
        ("%lld active · %lld waiting · %lld completed · %lld failed", [2, 1, 2, 1], "2 active · 1 waiting · 2 completed · 1 failed", "2 actives · 1 en attente · 2 terminées · 1 en échec"),
    ]

    func test_AC_32_2_countedKeysHaveTheirFrenchForms() throws {
        for (key, counts, _, french) in Self.countedKeys {
            XCTAssertEqual(try catalogString(key, language: "fr", arguments: counts), french, "\(key) \(counts)")
        }
    }

    func test_AC_32_2_englishFormsInTheDocument() throws {
        let strings = try Self.loadStrings()
        for (key, counts, english, _) in Self.countedKeys {
            let localization = try Self.localization(strings, key, "en")
            XCTAssertEqual(try Self.render(localization, counts: counts), english, "\(key) \(counts)")
        }
    }

    /// Mots italiens invariables identiques à l'anglais : the only renderings in
    /// de, es and it that may equal the English one. Anything else equal to the
    /// English text is an untranslated form.
    private static let identicalToEnglish: Set<String> = ["it|%lld videos|1", "it|%lld files|1", "it|%lld albums|1"]

    /// Decision #12: the German, Spanish and Italian forms are really written
    /// and agreed — no "(s)" placeholder, the counter is in every form, and the
    /// text for 1 and for 2 is not the English one.
    func test_AC_32_2_translatedFormsInEveryLanguage() throws {
        let strings = try Self.loadStrings()
        let parenthesised = try NSRegularExpression(pattern: #"\([^)\s]{1,4}\)"#)
        let keys = Array(Set(Self.countedKeys.map(\.0))).sorted()
        XCTAssertEqual(keys.count, 56, "the closed list of S-2 and S-3")

        for key in keys {
            for code in Self.shippedLanguages {
                let localization = try Self.localization(strings, key, code)

                // (a) no parenthesised suffix in any value or form
                for text in Self.texts(of: localization) {
                    let range = NSRange(text.startIndex..., in: text)
                    XCTAssertNil(parenthesised.firstMatch(in: text, range: range), "\(code) \(key): '\(text)'")
                }

                // (b) the counter (or %arg / %#@name@) is in every form
                if let forms = Self.plural(of: localization) {
                    for (form, unit) in forms {
                        let text = try XCTUnwrap(Self.value(of: unit))
                        XCTAssertTrue(text.contains("%lld"), "\(code) \(key) \(form): '\(text)' lacks its counter")
                    }
                }
                if let substitutions = localization["substitutions"] as? [String: Any] {
                    let template = try XCTUnwrap(Self.value(of: localization))
                    for (name, raw) in substitutions {
                        XCTAssertTrue(template.contains("%#@\(name)@"), "\(code) \(key): \(name) not referenced")
                        let holder = try XCTUnwrap(raw as? [String: Any])
                        for (form, unit) in try XCTUnwrap(Self.plural(of: holder)) {
                            let text = try XCTUnwrap(Self.value(of: unit))
                            XCTAssertTrue(text.contains("%arg"), "\(code) \(key) \(name).\(form): '\(text)'")
                        }
                    }
                }

                // (c) de, es and it differ from the English text for 1 and for 2
                guard code != "fr" else { continue }
                let english = try Self.localization(strings, key, "en")
                let counters = key.components(separatedBy: "%lld").count - 1
                for count in [1, 2] {
                    let counts = Array(repeating: count, count: counters)
                    let rendered = try catalogString(key, language: code, arguments: counts)
                    let reference = try Self.render(english, counts: counts)
                    if rendered == reference && !Self.identicalToEnglish.contains("\(code)|\(key)|\(count)") {
                        XCTFail("\(code) \(key) for \(count): '\(rendered)' is the English text")
                    }
                }
            }
        }
    }

    // MARK: - The version notice and the legacy keys

    func test_AC_32_6_versionNoticeKeyHasNoHardcodedVersion() throws {
        let strings = try Self.loadStrings()
        let key = "Detected text search requires Immich %@ or later."
        XCTAssertTrue(key.contains("%@"), "en: the version is an argument")
        XCTAssertFalse(key.contains("3.2"), "en: no version written in the key")
        for code in Self.shippedLanguages {
            let localization = try Self.localization(strings, key, code)
            let text = try XCTUnwrap(Self.value(of: localization))
            XCTAssertTrue(text.contains("%@"), "\(code): the version is an argument")
            XCTAssertFalse(text.contains("3.2"), "\(code): no version written in the translation")
        }
        XCTAssertNil(strings["Detected text search requires Immich 3.2 or later."], "the hard-coded key is gone")
    }

    func test_AC_32_8_noLegacyCountedKeys() throws {
        let strings = try Self.loadStrings()
        let legacy = [
            "1 photo", "1 video", "1 person", "1 file", "1 folder", "1 favorite", "1 selected",
            "1 photo in a stack", "1 year ago", "%@ photos", "%@ favorites", "%lld Photos", "%lld star",
            "%lld item%@", "%lld photo%@", "%lld Photo%@", "Remove %lld photo%@ from this album?",
            "Detected text search requires Immich 3.2 or later.",
        ]
        for key in legacy {
            XCTAssertNil(strings[key], "\(key) is a hand-made plural of the past")
        }
        XCTAssertEqual(strings.keys.filter { $0.contains("(s)") }.sorted(), [])
    }
}
