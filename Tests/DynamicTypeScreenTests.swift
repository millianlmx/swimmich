import SwiftUI
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// L-13 (AC-26, AC-26.1, AC-26.3, AC-26.8) on whole screens: each screen is
/// hosted with a long and a short label side by side, in English and in German,
/// and read through its accessibility tree (`HostedScreen`). Same measurements
/// as the walks of `DynamicTypeUITests` (nothing overlaps, the long label is
/// shown whole, the text follows the size), without a launched app.
@MainActor
final class DynamicTypeScreenTests: XCTestCase {

    private static let languages = ["en", "de"]
    private static let longPartnerName = "Maximiliana Wilhelmina Konstantinopoulou-Featherstonehaugh"
    private static let longAlbumName = "Summer holidays in the Gorges du Verdon with the whole family"
    private static let longLinkDescription = "Weekend photos for the grandparents and the cousins abroad"
    private static let longUserEmail = "maximiliana.wilhelmina.konstantinopoulou-featherstonehaugh@photos.example.org"

    // MARK: - Fixtures

    private final class NoWidgetSession: WidgetSessionStoring, @unchecked Sendable {
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { nil }
        func clear() {}
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DynamicTypeScreenTests-\(UUID().uuidString)")!
    }

    private func partner(_ id: String, _ name: String, inTimeline: Bool = false) -> PartnerResponseDto {
        PartnerResponseDto(
            id: id, name: name, email: "\(id)@example.org",
            profileImagePath: "", avatarColor: "#3366FF",
            profileChangedAt: "2024-01-01T00:00:00.000Z", inTimeline: inTimeline
        )
    }

    private func user(_ id: String, name: String, email: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: name, email: email, profileImagePath: "",
            avatarColor: "#3366FF", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func link(_ id: String, _ description: String) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: id, description: description, password: nil, userId: "owner", key: "key-\(id)",
            type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: false, allowDownload: true,
            showMetadata: true, slug: nil
        )
    }

    private func album(_ id: String, _ name: String) -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: false,
            hasSharedLink: false, assetCount: 3, isActivityEnabled: false, order: nil,
            albumUsers: [], ownerId: "me"
        )
    }

    private func makeMock() -> MockImmichClient {
        let mock = MockImmichClient()
        let long = partner("dt-partner-long", Self.longPartnerName, inTimeline: true)
        let short = partner("dt-partner-short", "Bo")
        mock.partnersSharedWithResponse = [long, short]
        mock.partnersSharedByResponse = [long, short]
        mock.getUsersResponse = [
            user("dt-user-long", name: Self.longPartnerName, email: Self.longUserEmail),
            user("dt-user-short", name: "Bo", email: "bo@x.org"),
        ]
        mock.albumsResponse = [album("dt-album-long", Self.longAlbumName), album("dt-album-short", "Paris")]
        mock.sharedLinksResponse = [link("dt-link-long", Self.longLinkDescription), link("dt-link-short", "Trip")]
        return mock
    }

    /// Hosts `view` with the objects the app's root puts in the environment.
    private func host(_ view: some View, _ mock: MockImmichClient, size: DynamicTypeSize = .accessibility5,
                      language: String, height: CGFloat = 3000) -> HostedScreen {
        let auth = AuthViewModel(
            client: mock, keychain: MockKeychainStore(), defaults: makeDefaults(),
            widgetSession: NoWidgetSession(), reloadWidgets: {}
        )
        return HostedScreen(
            view
                .environment(auth)
                .environment(AlbumsViewModel(client: mock))
                .environment(AppSettingsStore(defaults: makeDefaults()))
                .environment(ReadOnlyModeStore(defaults: makeDefaults())),
            size: size, language: language, height: height
        )
    }

    private func partnersScreen(_ mock: MockImmichClient, size: DynamicTypeSize = .accessibility5,
                                language: String) -> HostedScreen {
        host(NavigationStack { PartnersView(vm: PartnersViewModel(client: mock)) }, mock, size: size, language: language)
    }

    private func preferencesScreen(_ mock: MockImmichClient, size: DynamicTypeSize = .accessibility5,
                                   language: String) -> HostedScreen {
        let vm = PreferencesViewModel(store: AppSettingsStore(defaults: makeDefaults()))
        // At AX5 the form is about 7000 pt tall: the window shows it whole.
        return host(NavigationStack { PreferencesView(vm: vm) }, mock, size: size, language: language, height: 9000)
    }

    private func createAlbumScreen(_ mock: MockImmichClient, size: DynamicTypeSize = .accessibility5,
                                   language: String) -> HostedScreen {
        host(CreateAlbumSheet(vm: AlbumsViewModel(client: mock), preselectedAssetIds: nil), mock, size: size, language: language)
    }

    private func searchScreen(_ mock: MockImmichClient, size: DynamicTypeSize = .accessibility5,
                              language: String) -> HostedScreen {
        let container = DependencyContainer.shared
        let view = SearchView(
            vm: SearchViewModel(client: mock),
            mapVM: container.makeMapViewModel(accountID: "dt"),
            downloads: container.makeDownloadQueueViewModel()
        )
        return host(view, mock, size: size, language: language)
    }

    // MARK: - AC-26.3 / AC-26.8: whole screens at AX5, in English and in German

    func test_AC_26_3_addToAlbumSheet() async {
        for language in Self.languages {
            let mock = makeMock()
            let screen = host(AddToAlbumPickerSheet(selectedAssetIds: ["a1"]), mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("addToAlbumRow_dt-album-short") else { continue }
            screen.assertNoOverlap()
            screen.assertRowGrows(long: "addToAlbumRow_dt-album-long", short: "addToAlbumRow_dt-album-short")
        }
    }

    func test_AC_26_3_editAlbumSheet() async {
        for language in Self.languages {
            let mock = makeMock()
            let sheet = EditAlbumSheet(vm: AlbumDetailViewModel(client: mock, albumId: "dt-album-long"))
            let screen = host(sheet, mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("editAlbumNameField") else { continue }
            screen.assertNoOverlap()
        }
    }

    func test_AC_26_3_searchPrompt() async {
        for language in Self.languages {
            let screen = searchScreen(makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("searchPromptTitle") else { continue }
            screen.assertNoOverlap()
            screen.assertInWindow("searchPromptTitle")
        }
    }


    func test_AC_26_3_partnersScreen() async {
        for language in Self.languages {
            let screen = partnersScreen(makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("partnerRowName-dt-partner-short") else { continue }
            screen.assertNoOverlap()
            screen.assertFullyShown(long: "partnerRowName-dt-partner-long", short: "partnerRowName-dt-partner-short")
        }
    }

    func test_AC_26_3_invitePartnerSheet() async {
        for language in Self.languages {
            let mock = makeMock()
            let screen = host(InvitePartnerSheet(vm: PartnersViewModel(client: mock), currentUserId: "me"), mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("inviteCandidate-dt-user-short") else { continue }
            screen.assertNoOverlap()
            screen.assertRowGrows(long: "inviteCandidate-dt-user-long", short: "inviteCandidate-dt-user-short")
        }
    }

    func test_AC_26_3_createAlbumSheet() async {
        for language in Self.languages {
            let screen = createAlbumScreen(makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("createAlbumNameHeader") else { continue }
            screen.assertNoOverlap()
            screen.assertInWindow("createAlbumNameHeader")
        }
    }

    func test_AC_26_3_preferencesScreen() async {
        for language in Self.languages {
            let screen = preferencesScreen(makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("preferencesResetButton") else { continue }
            screen.assertNoOverlap()
        }
    }

    func test_AC_26_3_languageList() async {
        for language in Self.languages {
            let vm = LanguageSettingsViewModel(store: AppLanguageStore(defaults: makeDefaults()))
            let screen = host(NavigationStack { LanguageSettingsView(vm: vm) }, makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("languageRow.it") else { continue }
            screen.assertNoOverlap()
        }
    }

    func test_AC_26_3_sharedLinksScreen() async {
        for language in Self.languages {
            let mock = makeMock()
            let view = SharedLinksView(vm: SharedLinksViewModel(client: mock)) { baseURL, externalDomain in
                SharedLinkViewerViewModel(client: mock, baseURL: baseURL, externalDomain: externalDomain)
            }
            let screen = host(view, mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("sharedLinkRow_dt-link-short") else { continue }
            screen.assertNoOverlap()
            screen.assertFullyShown(long: "sharedLinkTitle_dt-link-long", short: "sharedLinkTitle_dt-link-short")
        }
    }

    func test_AC_26_3_editSharedLinkSheet() async {
        for language in Self.languages {
            let sheet = EditSharedLinkSheet(link: link("dt-link-long", Self.longLinkDescription)) { _ in true }
            let screen = host(sheet, makeMock(), language: language)
            defer { screen.close() }
            guard await screen.waitFor("confirmEditSharedLink") else { continue }
            screen.assertNoOverlap()
        }
    }

    func test_AC_26_3_createSharedLinkSheet() async {
        for language in Self.languages {
            let mock = makeMock()
            let screen = host(CreateSharedLinkSheet(vm: SharedLinksViewModel(client: mock)), mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("confirmCreateSharedLink") else { continue }
            screen.assertNoOverlap()
        }
    }

    func test_AC_26_3_searchFilterSheet() async {
        for language in Self.languages {
            let mock = makeMock()
            let screen = host(SearchFilterSheet(vm: SearchViewModel(client: mock)), mock, language: language)
            defer { screen.close() }
            guard await screen.waitFor("searchFilterDone") else { continue }
            screen.assertNoOverlap()
        }
    }

    // MARK: - AC-26 / AC-26.1: the same screens from the smallest size to AX5

    /// AC-26: nothing overlaps at the smallest size either.
    func test_AC_26_screensAtXS() async {
        let mock = makeMock()
        let screens: [(String, HostedScreen)] = [
            ("partnerRowName-dt-partner-short", partnersScreen(mock, size: .xSmall, language: "en")),
            ("preferencesResetButton", preferencesScreen(mock, size: .xSmall, language: "en")),
            ("createAlbumNameHeader", createAlbumScreen(mock, size: .xSmall, language: "en")),
            ("searchPromptTitle", searchScreen(mock, size: .xSmall, language: "en")),
        ]
        for (landmark, screen) in screens {
            defer { screen.close() }
            guard await screen.waitFor(landmark) else { continue }
            screen.assertNoOverlap()
        }
    }

    /// AC-26.1: a landmark of each screen is strictly taller from XS to L to AX5.
    func test_AC_26_1_landmarksFollowTheTextSize() async {
        let mock = makeMock()
        let sizes: [DynamicTypeSize] = [.xSmall, .large, .accessibility5]
        let landmarks: [(String, (DynamicTypeSize) -> HostedScreen)] = [
            ("partnerRowName-dt-partner-short", { self.partnersScreen(mock, size: $0, language: "en") }),
            ("preferencesGroupPicker", { self.preferencesScreen(mock, size: $0, language: "en") }),
            ("createAlbumNameHeader", { self.createAlbumScreen(mock, size: $0, language: "en") }),
            ("searchPromptTitle", { self.searchScreen(mock, size: $0, language: "en") }),
        ]
        for (landmark, make) in landmarks {
            var heights: [CGFloat] = []
            for size in sizes {
                let screen = make(size)
                defer { screen.close() }
                guard await screen.waitFor(landmark) else { continue }
                heights.append(screen.textFrame(landmark).height)
            }
            guard heights.count == 3 else { continue }
            XCTAssertLessThan(heights[0], heights[1], "\(landmark): XS (\(heights[0])) must be smaller than L (\(heights[1]))")
            XCTAssertLessThan(heights[1], heights[2], "\(landmark): L (\(heights[1])) must be smaller than AX5 (\(heights[2]))")
        }
    }
}
