import Foundation
import XCTest
@testable import ImmichSwiftUI

/// Resolves a catalog key the way the app does, for tests that assert *which*
/// message a view model surfaces.
///
/// `String(localized:)` follows the language of the running process, so pinning
/// the English source in an expectation makes the test pass or fail with the
/// simulator's language instead of with the code under test. Resolving the
/// expected text through the same catalog keeps the assertion about the code:
/// a wrong key, a wrong count or a missing translation still fails it.
func localizedString(_ key: String) -> String {
    String(localized: String.LocalizationValue(stringLiteral: key))
}

/// Same, with the `%lld` / `%@` placeholders filled in — this reverses the
/// interpolation the call site performed to build the key. The localized object
/// the bundle returns carries the plural and substitution rules of the catalog,
/// so formatting it applies the same form as `String(localized:)` would.
func localizedString(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, locale: .current, arguments: arguments)
}

/// The key rendered in one shipped language, whatever the language of the
/// process: the `<language>.lproj` bundle of the app plus the locale of that
/// language (the plural category follows the formatting locale, not the bundle).
/// `en` has no `.lproj` (it is the development language): asking for it fails
/// the test, the English forms are read from the catalog document instead.
func catalogString(_ key: String, language: String, arguments: [CVarArg]) throws -> String {
    let (bundle, locale) = try pinnedLanguage(language)
    let format = bundle.localizedString(forKey: key, value: nil, table: nil)
    return String(format: format, locale: locale, arguments: arguments)
}

func catalogString(_ key: String, language: String, _ arguments: CVarArg...) throws -> String {
    try catalogString(key, language: language, arguments: arguments)
}

/// Bundle and locale to hand to the label functions that take `bundle:` and
/// `locale:` (fr → `fr.lproj` + fr_FR, de → de_DE, es → es_ES, it → it_IT).
func language(_ code: String) throws -> (bundle: Bundle, locale: Locale) {
    try pinnedLanguage(code)
}

private func pinnedLanguage(_ code: String) throws -> (bundle: Bundle, locale: Locale) {
    let app = Bundle(for: AppLanguageStore.self)
    let path = try XCTUnwrap(
        app.path(forResource: code, ofType: "lproj"),
        "\(code).lproj is not compiled into the app (English has none: read the catalog document)"
    )
    let bundle = try XCTUnwrap(Bundle(path: path))
    return (bundle, Locale(identifier: "\(code)_\(code.uppercased())"))
}
