import XCTest
@testable import ImmichSwiftUI

/// Runtime side of the i18n contract (issue #21): what the *bundle* resolves,
/// and what the language store persists for the next launch.
///
/// `AppStringsTests` checks the catalog as a document; this file checks the
/// three things a document cannot show — that each shipped language is
/// actually compiled into the app, that a lookup returns a translation instead
/// of silently falling back to English, and that a choice survives a relaunch.
@MainActor
final class LocalizationTests: XCTestCase {

    /// The app bundle: `AppLanguageStore` lives in the app target, and the unit
    /// tests are hosted by it, so this resolves to the same bundle the running
    /// app reads its `.lproj` from.
    private let bundle = Bundle(for: AppLanguageStore.self)

    private var scratchSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratchSuiteName = "i18n-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: scratchSuiteName)
        defaults.removePersistentDomain(forName: scratchSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: scratchSuiteName)
        defaults = nil
        scratchSuiteName = nil
        super.tearDown()
    }

    private func localized(_ key: String, language code: String) throws -> String {
        let path = try XCTUnwrap(
            bundle.path(forResource: code, ofType: "lproj"),
            "\(code).lproj is not compiled into the app — the language would silently show English"
        )
        let languageBundle = try XCTUnwrap(Bundle(path: path))
        return languageBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    // MARK: - The shipped catalogs

    /// A language offered by the picker but missing from the bundle would look
    /// selected while rendering English.
    func test_everyOfferedLanguageShipsACompiledCatalog() {
        for language in AppLanguage.supported where language.code != "en" {
            XCTAssertNotNil(bundle.path(forResource: language.code, ofType: "lproj"),
                            "\(language.code) has no compiled catalog")
        }
    }

    /// The regression this whole card exists for: onboarding copy used to be
    /// hardcoded French, and half the catalog had no translation at all. A key
    /// that resolves to itself means the lookup fell through to English.
    func test_interfaceCopyIsTranslatedInEveryOfferedLanguage() throws {
        // Keys picked for being unambiguous in all five languages: "General"
        // is deliberately absent, being spelled the same in English and Spanish.
        let keys = ["Language", "Map", "Close", "Use System Language"]
        for key in keys {
            var values: Set<String> = [key]
            for code in ["fr", "de", "es", "it"] {
                let value = try localized(key, language: code)
                XCTAssertNotEqual(value, key, "\(key) is untranslated in \(code)")
                values.insert(value)
            }
            XCTAssertEqual(values.count, 5,
                           "\(key) resolves to the same text in several languages: \(values.sorted())")
        }
    }

    /// AC-9: every error-copy key of SP-3 is translated in each shipped language.
    func test_AC9_errorCopiesAreTranslatedInEveryShippedLanguage() throws {
        let keys = [
            "No network connection. Check your connection and try again.",
            "The server ran into a problem. Please try again.",
            "Your session has expired. Please sign in again.",
            "Something went wrong. Please try again.",
        ]
        for key in keys {
            for code in ["fr", "de", "es", "it"] {
                let value = try localized(key, language: code)
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(code)")
                XCTAssertNotEqual(value, key, "\(key) is untranslated in \(code)")
            }
        }
    }

    func test_languageNamesAreLocalizedAndNative() {
        let french = AppLanguage.language(for: "fr")
        XCTAssertEqual(french?.nativeName, "Français")
        XCTAssertEqual(french?.displayName, Locale.current.localizedString(forIdentifier: "fr")?.capitalizedFirstLetter)
        XCTAssertEqual(AppLanguage.language(for: "fr")?.id, "fr")
        XCTAssertNil(AppLanguage.language(for: "xx"))
    }

    func test_pickerOffersExactlyWhatTheBundleCanRender() {
        let available = AppLanguage.available(in: bundle).map(\.code)
        XCTAssertEqual(available, ["en", "fr", "de", "es", "it"])
        XCTAssertEqual(available, AppLanguage.supported.map(\.code))
    }

    // MARK: - The pickers' enum labels

    /// AC-3 : each option label the Preferences pickers and the slideshow menu
    /// render is read from the catalog, key by key.
    ///
    /// `Text(label)` takes a `String`, not a `LocalizedStringKey`, so the call
    /// site has to reach the catalog itself — a bare English literal there is
    /// drawn verbatim and a French device shows "Day". Both sides of the
    /// assertion resolve through the catalog for the process language, so the
    /// test holds on an English destination and fails on a French one the
    /// moment a branch goes back to the raw literal.
    func test_enumLabelsComeFromTheCatalog() {
        let labels: [(label: String, key: String)] = [
            (TimelineGroupBy.day.label, "Day"),
            (TimelineGroupBy.month.label, "Month"),
            (TimelineGroupBy.none.label, "Flat"),
            (SlideshowViewModel.SlideshowTransitionStyle.dissolve.label, "Dissolve"),
            (SlideshowViewModel.SlideshowTransitionStyle.slide.label, "Slide"),
            (SlideshowViewModel.SlideshowTransitionStyle.kenBurns.label, "Ken Burns"),
            (AppTheme.system.label, "System"),
            (AppTheme.light.label, "Light"),
            (AppTheme.dark.label, "Dark"),
            (AppAccent.immich.label, "Immich"),
            (AppAccent.blue.label, "Blue"),
            (AppAccent.green.label, "Green"),
            (AppAccent.orange.label, "Orange"),
            (AppAccent.pink.label, "Pink"),
            (AppAccent.purple.label, "Purple"),
        ]
        for entry in labels {
            XCTAssertEqual(entry.label, localizedString(entry.key),
                           "AC-3 : '\(entry.key)' must be read from the catalog, not rendered as a raw "
                           + "English literal — the label reads '\(entry.label)' where the catalog says "
                           + "'\(localizedString(entry.key))'")
        }
    }

    // MARK: - Persisting the choice

    func test_selectingALanguagePersistsItForTheNextLaunch() throws {
        // Never assume what the simulator runs in: the screen this drives must
        // work whatever the device language is.
        let other = try XCTUnwrap(AppLanguage.supported.first { $0.code != systemLanguageCode })
        let store = AppLanguageStore(defaults: defaults)
        XCTAssertNil(store.selectedCode)
        XCTAssertTrue(store.useSystemLanguage)
        XCTAssertFalse(store.requiresRelaunch, "A fresh process has nothing to apply")

        store.select(other)

        XCTAssertEqual(store.selectedCode, other.code)
        XCTAssertFalse(store.useSystemLanguage)
        XCTAssertEqual(store.effectiveLocale.language.languageCode?.identifier, other.code)
        XCTAssertTrue(store.requiresRelaunch)
        XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), other.code,
                       "The picker's choice must survive a relaunch")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), [other.code],
                       "Bundle lookups follow this key from the next launch on")

        // What the next launch reads: same choice, nothing left to apply.
        let relaunched = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(relaunched.selectedCode, other.code)
        XCTAssertFalse(relaunched.requiresRelaunch)
    }

    func test_applyingSystemLanguageClearsBothKeys() throws {
        let other = try XCTUnwrap(AppLanguage.supported.first { $0.code != systemLanguageCode })
        let store = AppLanguageStore(defaults: defaults)
        store.select(other)

        store.applySystemLanguage()

        XCTAssertNil(store.selectedCode)
        XCTAssertTrue(store.useSystemLanguage)
        // Read the suite's own domain: `AppleLanguages` also exists in the
        // process's global domain, so a plain `array(forKey:)` would see the
        // simulator's own language and never come back nil.
        let persisted = defaults.persistentDomain(forName: scratchSuiteName)
        XCTAssertNil(persisted?[AppLanguageStore.defaultsKey])
        XCTAssertNil(persisted?["AppleLanguages"])
    }

    /// Language the test process itself is running in — the baseline a pin is
    /// compared against.
    private var systemLanguageCode: String {
        Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
    }

    /// Pinning the language the app is already rendering changes nothing on
    /// screen, so it must not nag about a reopen.
    func test_pinningTheLanguageAlreadyInUseDoesNotAskForAReopen() {
        let systemCode = systemLanguageCode
        let store = AppLanguageStore(defaults: defaults)

        store.select(AppLanguage(code: systemCode))

        XCTAssertFalse(store.useSystemLanguage, "An explicit choice is still a pin")
        XCTAssertEqual(store.selectedCode, systemCode)
        XCTAssertFalse(store.requiresRelaunch)
    }

    func test_dismissingTheNoticeKeepsTheChoice() {
        let store = AppLanguageStore(defaults: defaults)
        store.select(AppLanguage(code: "it"))
        XCTAssertTrue(store.requiresRelaunch)

        store.markRelaunchHandled()

        XCTAssertFalse(store.requiresRelaunch)
        XCTAssertEqual(store.selectedCode, "it")
        XCTAssertEqual(defaults.string(forKey: AppLanguageStore.defaultsKey), "it")
    }

    // MARK: - The screen's view model

    func test_viewModelMirrorsTheStoreAndNeverDiverges() throws {
        let other = try XCTUnwrap(AppLanguage.supported.first { $0.code != systemLanguageCode })
        let store = AppLanguageStore(defaults: defaults)
        let vm = LanguageSettingsViewModel(store: store)

        XCTAssertEqual(vm.languages.map(\.code), AppLanguage.available().map(\.code))
        XCTAssertTrue(vm.useSystemLanguage)
        XCTAssertFalse(vm.isSelected(other))

        vm.select(other)

        XCTAssertTrue(vm.isSelected(other))
        XCTAssertFalse(vm.useSystemLanguage)
        XCTAssertEqual(store.selectedCode, other.code, "The store stays the single writer")
        XCTAssertTrue(vm.requiresRelaunch)

        vm.dismissRelaunchPrompt()
        XCTAssertFalse(vm.requiresRelaunch)

        vm.setUseSystemLanguage(true)
        XCTAssertTrue(vm.useSystemLanguage)
        XCTAssertNil(store.selectedCode)
    }

    /// Switching the toggle off must leave a real selection behind: an empty
    /// picker would read as "no language".
    func test_turningTheToggleOffPinsTheLanguageOnScreen() {
        let store = AppLanguageStore(defaults: defaults)
        let vm = LanguageSettingsViewModel(store: store)

        vm.setUseSystemLanguage(false)

        XCTAssertFalse(vm.useSystemLanguage)
        let pinned = store.selectedCode
        XCTAssertNotNil(pinned)
        XCTAssertEqual(pinned, store.effectiveLocale.language.languageCode?.identifier)
        XCTAssertTrue(vm.languages.contains { $0.code == pinned })
    }
}

private extension String {
    /// Mirrors `AppLanguage.displayName`'s capitalization for the comparison
    /// above; kept local so the test does not depend on the private helper.
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
