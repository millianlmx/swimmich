import XCTest
@testable import ImmichSwiftUI

/// The one rule that keeps an edited photo on the device until its edit is on
/// the server (`PhotoLibraryServiceImpl.keepsForUnconfirmedEdit`).
final class PhotoLibraryCleanupEditFilterTests: XCTestCase {

    private func keeps(
        adjusted: Bool = true, signature: String = "t1", confirmed: [String: String]?
    ) -> Bool {
        PhotoLibraryServiceImpl.keepsForUnconfirmedEdit(
            id: "a", hasAdjustments: adjusted, signature: signature, confirmedEdits: confirmed
        )
    }

    func test_AC_207_unconfirmedEditDecision() {
        XCTAssertFalse(keeps(confirmed: nil), "setting off: the original alone decides, even for an edited photo")
        XCTAssertFalse(keeps(adjusted: false, confirmed: [:]), "never edited: nothing to confirm")
        XCTAssertFalse(keeps(confirmed: ["a": "t1"]), "the current edit is confirmed")
        XCTAssertTrue(keeps(confirmed: [:]), "edited after the last pass: kept")
        XCTAssertTrue(keeps(signature: "t2", confirmed: ["a": "t1"]), "an older edit does not confirm the current one")
    }
}
