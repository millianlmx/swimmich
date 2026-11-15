import UIKit
import XCTest
@testable import ImmichSwiftUI

/// `SystemIdleTimer` against the real `UIApplication` (the unit-test host is
/// the app): a seam that did not write through would keep the screen lit — or
/// dark — behind the back of the slideshow's own bookkeeping.
@MainActor
final class SystemIdleTimerTests: XCTestCase {

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    func test_AC_58_1_writesReachTheSystemIdleTimer() {
        let timer = SystemIdleTimer()

        timer.isIdleTimerDisabled = true
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        timer.isIdleTimerDisabled = false
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    func test_AC_58_1_startsFromTheCurrentSystemValue() {
        UIApplication.shared.isIdleTimerDisabled = true

        let timer = SystemIdleTimer()

        XCTAssertTrue(timer.isIdleTimerDisabled, "`releaseScreen()` restores what this reports")
    }
}
