import XCTest
@testable import ImmichSwiftUI

/// The priority table of `ListRenderState.resolve` (L-16, S-1): what a list
/// screen shows for each combination of its five read facts.
final class ListRenderStateTests: XCTestCase {

    private func resolve(
        empty: Bool,
        loaded: Bool = false,
        loading: Bool = false,
        refreshing: Bool = false,
        error: String? = nil
    ) -> ListRenderState {
        ListRenderState.resolve(
            isEmpty: empty, hasLoaded: loaded, isLoading: loading,
            isRefreshing: refreshing, loadError: error
        )
    }

    func test_AC_142_resolve_beforeAnyReadIsLoadingNotEmpty() {
        XCTAssertEqual(resolve(empty: true), .loading)
    }

    func test_AC_142_resolve_firstReadInFlightIsLoading() {
        XCTAssertEqual(resolve(empty: true, loading: true), .loading)
    }

    func test_AC_149_resolve_failedFirstReadIsErrorNotEmpty() {
        XCTAssertEqual(resolve(empty: true, error: "boom"), .error("boom"))
    }

    func test_AC_147_resolve_successfulEmptyReadIsEmpty() {
        XCTAssertEqual(resolve(empty: true, loaded: true), .empty)
    }

    func test_AC_149_resolve_tryAgainFromErrorShowsLoadingNotError() {
        // "Try Again": in flight, not a pull. The indicator wins over the error.
        XCTAssertEqual(resolve(empty: true, loading: true, error: "boom"), .loading)
    }

    func test_AC_154_resolve_pullFromErrorKeepsErrorWhileReading() {
        XCTAssertEqual(
            resolve(empty: true, loading: true, refreshing: true, error: "boom"),
            .error("boom")
        )
    }

    func test_AC_154_resolve_pullFromEmptyKeepsEmptyWhileReading() {
        XCTAssertEqual(
            resolve(empty: true, loaded: true, loading: true, refreshing: true),
            .empty
        )
    }

    func test_AC_143_resolve_tryAgainWithDataIsReloading() {
        XCTAssertEqual(
            resolve(empty: false, loaded: true, loading: true, error: "boom"),
            .data(.reloading)
        )
    }

    func test_AC_143_resolve_pullWithDataStaysIdle() {
        XCTAssertEqual(
            resolve(empty: false, loaded: true, loading: true, refreshing: true),
            .data(.idle)
        )
    }

    func test_AC_152_resolve_failedRefreshWithDataIsFailedBanner() {
        XCTAssertEqual(
            resolve(empty: false, loaded: true, error: "boom"),
            .data(.failed("boom"))
        )
    }

    func test_AC_152_resolve_dataWithoutErrorIsIdle() {
        XCTAssertEqual(resolve(empty: false, loaded: true), .data(.idle))
    }
}
