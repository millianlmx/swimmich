import XCTest
@testable import ImmichSwiftUI

/// What the user may type in an address field, and what an older stored setting decodes to.
final class ServerAddressInputTests: XCTestCase {
    func test_AC_235_normalizesLikeTheConnectionScreen() {
        XCTAssertEqual(ServerAddressInput.normalized(" http://192.168.1.10:2283/ "), .valid(URL(string: "http://192.168.1.10:2283")!))
        XCTAssertEqual(ServerAddressInput.normalized("nas.local"), .valid(URL(string: "https://nas.local")!))
        XCTAssertEqual(ServerAddressInput.normalized("http://nas.local///"), .valid(URL(string: "http://nas.local")!))
        XCTAssertEqual(ServerAddressInput.normalized("https://h/immich/"), .valid(URL(string: "https://h/immich")!))
    }

    func test_AC_235_blankIsEmptyAndMalformedIsInvalid() {
        XCTAssertEqual(ServerAddressInput.normalized("  "), .empty)
        XCTAssertEqual(ServerAddressInput.normalized(""), .empty)
        for bad in ["ftp://nas", "http://", "http://a b", "https://x?y=1", "https://x#f", "http://h:99999",
                    "http://h:0", "http://user:pw@h"] {
            XCTAssertEqual(ServerAddressInput.normalized(bad), .invalid, bad)
        }
    }

    func test_AC_243_settingsDecodeWhenKeysAreMissing() throws {
        let decoded = try JSONDecoder().decode(ServerAddressSettings.self, from: Data(#"{"localURL":"http://a"}"#.utf8))
        XCTAssertEqual(decoded, ServerAddressSettings(localURL: "http://a"))
        XCTAssertFalse(decoded.autoSwitch)
        XCTAssertEqual(try JSONDecoder().decode(ServerAddressSettings.self, from: Data("{}".utf8)), .empty)
    }
}
