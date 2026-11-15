import XCTest
@testable import ImmichSwiftUI

/// L-26 (B-9, TN3179): the "local network" usage string belongs to the app's
/// Info.plist only; extensions share the privilege of their container app.
final class LocalNetworkUsageTests: XCTestCase {

    private let key = "NSLocalNetworkUsageDescription"

    func test_AC_250_localNetworkUsageOnTheAppOnly() throws {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
            "Swimmich connects to your Immich server's local address when your phone is on the same network."
        )

        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL, "the app embeds its extensions")
        let extensions = try FileManager.default.contentsOfDirectory(atPath: plugIns.path)
        // Without these two the loop below would assert nothing.
        XCTAssertTrue(extensions.contains("ImmichWidgets.appex"), "\(extensions)")
        XCTAssertTrue(extensions.contains("ImmichShareExtension.appex"), "\(extensions)")

        for name in extensions where name.hasSuffix(".appex") {
            let bundle = try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent(name)), name)
            XCTAssertNil(bundle.object(forInfoDictionaryKey: key), "\(name) must not declare the local network usage")
        }
    }
}
