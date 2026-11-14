import XCTest
@testable import ImmichSwiftUI

/// L-26: when does the tab on screen reload after an evaluation of the address?
final class ReloadAfterEvaluationTests: XCTestCase {
    func test_AC_248_changedAddressAlwaysReloads() {
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: true, hasLoadError: false))
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: true, hasLoadError: true))
    }

    func test_AC_237_sameAddressReloadsOnlyAScreenInError() {
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: false, hasLoadError: true))
        XCTAssertFalse(ReloadAfterEvaluation.shouldReload(changedAddress: false, hasLoadError: false),
                       "a screen that loaded fine is not disturbed by a check that changed nothing")
    }
}
