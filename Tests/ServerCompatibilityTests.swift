import XCTest
@testable import ImmichSwiftUI

/// The inline notice for a server outside Swimmich's supported range (L-28, B-32.3).
final class ServerCompatibilityTests: XCTestCase {

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> ServerVersionResponseDto {
        ServerVersionResponseDto(major: major, minor: minor, patch: patch, prerelease: nil)
    }

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle(for: AppLanguageStore.self).path(forResource: language, ofType: "lproj"),
            "no \(language).lproj in the app bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    // AC-54: below 2.0.0 the notice names the server's version and the minimum; 3.4.0 and 2.0.0 raise none.
    func test_AC_54_tooOldNamesVersionAndMinimum() throws {
        let warning = try XCTUnwrap(ServerCompatibility.warning(for: version(1, 119, 0)))

        XCTAssertEqual(warning, .tooOld(version: "1.119.0"))
        XCTAssertTrue(warning.message.contains("1.119.0"), "the server's version: \(warning.message)")
        XCTAssertTrue(warning.message.contains("2.0.0"), "the minimum version: \(warning.message)")
        XCTAssertNil(ServerCompatibility.warning(for: version(3, 4, 0)))
        XCTAssertNil(ServerCompatibility.warning(for: version(2, 0, 0)))
        XCTAssertNil(ServerCompatibility.warning(for: version(3, 99, 99)))
        XCTAssertEqual(ServerCompatibility.warning(for: version(1, 999, 999)), .tooOld(version: "1.999.999"))
    }

    // AC-336: from 4.0.0 the notice says the version is above the supported range; unreadable raises none.
    func test_AC_336_tooNewAndUnreadable() throws {
        let warning = try XCTUnwrap(ServerCompatibility.warning(for: version(4, 0, 0)))

        XCTAssertEqual(warning, .tooNew(version: "4.0.0"))
        XCTAssertTrue(warning.message.contains("4.0.0"))
        XCTAssertTrue(warning.message.contains("3.x"), "the supported range: \(warning.message)")
        XCTAssertNil(ServerCompatibility.warning(for: nil))
    }

    // AC-336: a version that cannot be read does not make the server unreachable.
    @MainActor
    func test_AC_336_unreadableVersionStaysReachable() async {
        let suite = "ServerCompatibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.serverVersionError = APIError.decoding("oops")
        let auth = AuthViewModel(client: mock, keychain: MockKeychainStore(), defaults: defaults)
        auth.serverURLString = "https://photos.example.com"

        await auth.connectServer()

        XCTAssertEqual(auth.serverStatus, .reachable(version: nil))
        XCTAssertNil(ServerCompatibility.warning(for: nil))
    }

    // AC-337: both messages are translated, with the version in place, in every shipped language.
    func test_AC_337_warningTranslatedInFiveLanguages() throws {
        // The English source texts, written out: `Bundle.main` follows the
        // language of the machine that runs the test, so it cannot be the baseline.
        let cases: [(warning: ServerVersionWarning, shown: String, english: String)] = [
            (.tooOld(version: "1.119.0"), "1.119.0",
             "This server runs Immich 1.119.0. Swimmich supports Immich 2.0.0 and later: some features may not work."),
            (.tooNew(version: "4.1.2"), "4.1.2",
             "This server runs Immich 4.1.2, newer than the versions Swimmich supports (up to 3.x): some features may not work."),
        ]
        for language in ["fr", "de", "es", "it"] {
            let bundle = try bundle(language)
            for item in cases {
                let translated = item.warning.localizedMessage(bundle: bundle)
                XCTAssertFalse(translated.isEmpty)
                XCTAssertNotEqual(translated, item.english, "\(language) is still English: \(translated)")
                XCTAssertTrue(translated.contains(item.shown), "\(language) lost the version: \(translated)")
                XCTAssertFalse(translated.contains("%@"), "\(language) left the placeholder: \(translated)")
            }
        }
    }
}
