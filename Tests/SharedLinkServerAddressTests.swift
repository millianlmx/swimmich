import XCTest
@testable import ImmichSwiftUI

/// L-26: links handed out name the external address, whichever address the app
/// is using; links received that name any address of this server are ours.
@MainActor
final class SharedLinkServerAddressTests: XCTestCase {
    private let external = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!
    private let key = "a2V5LXNlY3JldC1rZXktdmFsdWUtd2l0aC1sb25nLWJhc2U2NHVybA"

    private func makeAsset() -> AssetReactItem {
        AssetReactItem(
            id: "a1", ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func sharedLink(key: String) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: "link-1", description: nil, password: nil, userId: "owner", key: key, type: .individual,
            createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil, assets: [], album: nil,
            allowUpload: false, allowDownload: true, showMetadata: true, slug: nil
        )
    }

    func test_AC_249_copiedLinkUsesExternal() async {
        let mock = MockImmichClient()
        mock.createSharedLinkResponse = sharedLink(key: "a2V5")
        let vm = PhotoShareViewModel(
            asset: makeAsset(), client: mock, baseURL: local, currentUserId: "owner", publicServerURL: external
        )

        await vm.createPublicLink()

        XCTAssertEqual(vm.linkURL, "https://photos.example.org/share/a2V5", "the app is on the local address; the link is not")
    }

    func test_AC_249_externalDomainWins() async {
        let mock = MockImmichClient()
        mock.createSharedLinkResponse = sharedLink(key: "a2V5")
        let vm = PhotoShareViewModel(
            asset: makeAsset(), client: mock, baseURL: local, externalDomain: "https://public.example.net",
            currentUserId: "owner", publicServerURL: external
        )

        await vm.createPublicLink()

        XCTAssertEqual(vm.linkURL, "https://public.example.net/share/a2V5")
    }

    func test_AC_249_receivedLocalLinkIsOurs() async {
        let mock = MockImmichClient()
        mock.sharedLinkMineResponse = sharedLink(key: key)
        let vm = SharedLinkViewerViewModel(
            client: mock, baseURL: external, publicServerURL: external, serverURLs: [external, local]
        )

        vm.linkText = "http://192.168.1.10:2283/share/\(key)"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .opened)
        XCTAssertEqual(mock.sharedLinkMineCredentials, [.key(key)])
    }

    func test_AC_249_aLinkOfAnotherHostIsStillRefused() async {
        let mock = MockImmichClient()
        let vm = SharedLinkViewerViewModel(
            client: mock, baseURL: external, publicServerURL: external, serverURLs: [external, local]
        )

        vm.linkText = "http://192.168.1.99:2283/share/\(key)"
        await vm.openLink()

        XCTAssertTrue(mock.sharedLinkMineCredentials.isEmpty, "the credential must not be sent to another host")
    }

    func test_AC_249_theLinkOnScreenIsBuiltOnTheExternalAddress() async {
        let mock = MockImmichClient()
        mock.sharedLinkMineResponse = sharedLink(key: key)
        let vm = SharedLinkViewerViewModel(
            client: mock, baseURL: local, publicServerURL: external, serverURLs: [external, local]
        )

        vm.linkText = "http://192.168.1.10:2283/share/\(key)"
        await vm.openLink()

        XCTAssertEqual(vm.publicURL?.host, "photos.example.org")
    }
}
