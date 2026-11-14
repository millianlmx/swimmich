import XCTest
@testable import ImmichSwiftUI

/// L-26: a road trip reads the address in use when it needs it, not the one it was created with.
@MainActor
final class RoadTripViewModelTests: XCTestCase {
    private final class Address: @unchecked Sendable {
        private let lock = NSLock()
        private var _url: URL
        init(_ url: URL) { _url = url }
        var url: URL {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); _url = newValue; lock.unlock() }
        }
    }

    func test_AC_238_roadTripReadsCurrentAddress() {
        let address = Address(URL(string: "https://photos.example.org")!)
        let vm = RoadTripViewModel(
            client: MockImmichClient(), albumId: "album", selectedAssetIds: nil, albumTitle: "Trip",
            baseURL: { address.url }, token: "tok", photos: MockPhotoLibraryService(), session: { .shared }
        )
        XCTAssertEqual(vm.baseURL.host, "photos.example.org")

        address.url = URL(string: "http://192.168.1.10:2283")!

        XCTAssertEqual(vm.baseURL.host, "192.168.1.10", "the next thumbnail batch and the render read the new address")
        XCTAssertEqual(vm.baseURL.port, 2283)
    }
}
