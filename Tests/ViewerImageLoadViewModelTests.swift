import XCTest
@testable import ImmichSwiftUI

@MainActor
final class ViewerImageLoadViewModelTests: XCTestCase {

    func test_AC_57_7_failureThenRetryThenLoaded() {
        let vm = ViewerImageLoadViewModel()
        XCTAssertEqual(vm.phase, .loading)
        XCTAssertFalse(vm.showsRetry)
        XCTAssertFalse(vm.showsRetryProgress, "the first display shows no spinner")

        vm.record(.failed, forAttempt: 0)
        XCTAssertTrue(vm.showsRetry)

        vm.retry()
        XCTAssertEqual(vm.attempt, 1)
        XCTAssertEqual(vm.phase, .loading)
        XCTAssertTrue(vm.showsRetryProgress)
        XCTAssertFalse(vm.showsRetry)

        vm.record(.loaded, forAttempt: 1)
        XCTAssertEqual(vm.phase, .loaded)
        XCTAssertFalse(vm.showsRetry)
        XCTAssertFalse(vm.showsRetryProgress)
    }

    func test_AC_57_2_retryThatFailsAgainShowsRetry() {
        let vm = ViewerImageLoadViewModel()
        vm.record(.failed, forAttempt: 0)
        vm.retry()

        vm.record(.failed, forAttempt: 1)

        XCTAssertTrue(vm.showsRetry)
        XCTAssertFalse(vm.showsRetryProgress)
        vm.retry()
        XCTAssertEqual(vm.attempt, 2, "the button works again after a second failure")
    }

    func test_AC_57_3_staleOutcomeIsIgnored() {
        let vm = ViewerImageLoadViewModel()
        vm.record(.failed, forAttempt: 0)
        vm.retry()

        vm.record(.failed, forAttempt: 0)
        XCTAssertEqual(vm.phase, .loading, "a result of attempt 0 arriving after the retry changes nothing")

        vm.record(.loaded, forAttempt: 0)
        XCTAssertEqual(vm.phase, .loading)
    }

    func test_AC_57_2_retryIsIgnoredUnlessFailed() {
        let vm = ViewerImageLoadViewModel()
        vm.retry()
        XCTAssertEqual(vm.attempt, 0, "loading: no duplicate request")

        vm.record(.loaded, forAttempt: 0)
        vm.retry()
        XCTAssertEqual(vm.attempt, 0, "loaded: nothing to retry")
        XCTAssertEqual(vm.phase, .loaded)
    }
}
