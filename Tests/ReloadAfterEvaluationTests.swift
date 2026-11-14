import XCTest
@testable import ImmichSwiftUI

private final class FakeScreen: ReloadableScreen {
    var hasLoadError = false
    private(set) var refreshCount = 0
    func refresh() async { refreshCount += 1 }
}

/// L-26: when does the tab on screen reload after an evaluation of the address?
@MainActor
final class ReloadAfterEvaluationTests: XCTestCase {
    private let reloadable: [RootTab] = [.photos, .memories, .albums, .shared]

    private struct Rig {
        let photos = FakeScreen()
        let memories = FakeScreen()
        let albums = FakeScreen()
        let shared = FakeScreen()

        var reloader: VisibleTabReloader {
            VisibleTabReloader(photos: photos, memories: memories, albums: albums, shared: shared)
        }

        func screen(_ tab: RootTab) -> FakeScreen? {
            switch tab {
            case .photos: photos
            case .memories: memories
            case .albums: albums
            case .shared: shared
            case .search: nil
            }
        }

        var counts: [Int] { [photos, memories, albums, shared].map(\.refreshCount) }
    }

    func test_AC_248_changedAddressAlwaysReloads() {
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: true, hasLoadError: false))
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: true, hasLoadError: true))
    }

    func test_AC_237_sameAddressReloadsOnlyAScreenInError() {
        XCTAssertTrue(ReloadAfterEvaluation.shouldReload(changedAddress: false, hasLoadError: true))
        XCTAssertFalse(ReloadAfterEvaluation.shouldReload(changedAddress: false, hasLoadError: false),
                       "a screen that loaded fine is not disturbed by a check that changed nothing")
    }

    func test_AC_237_changedAddressReloadsOnlyTheVisibleTab() async {
        for tab in reloadable {
            let rig = Rig()

            await rig.reloader.reload(tab: tab, after: EvaluationOutcome(id: 1, changedAddress: true))

            XCTAssertTrue(rig.reloader.screen(for: tab) === rig.screen(tab), "\(tab) maps to its own screen")
            for other in reloadable {
                XCTAssertEqual(rig.screen(other)?.refreshCount, other == tab ? 1 : 0, "visible \(tab), checking \(other)")
            }
        }
    }

    func test_AC_248_sameAddressReloadsOnlyAVisibleTabInError() async {
        for tab in reloadable {
            // No screen in error: nothing reloads.
            let healthy = Rig()
            await healthy.reloader.reload(tab: tab, after: EvaluationOutcome(id: 1, changedAddress: false))
            XCTAssertEqual(healthy.counts, [0, 0, 0, 0], "\(tab) loaded fine")

            // The visible tab is in error: it reloads, once, and only it.
            let stranded = Rig()
            stranded.screen(tab)?.hasLoadError = true
            await stranded.reloader.reload(tab: tab, after: EvaluationOutcome(id: 2, changedAddress: false))
            for other in reloadable {
                XCTAssertEqual(stranded.screen(other)?.refreshCount, other == tab ? 1 : 0, "visible \(tab), checking \(other)")
            }

            // Another tab is in error while the visible one is fine: nothing reloads.
            let elsewhere = Rig()
            for other in reloadable where other != tab { elsewhere.screen(other)?.hasLoadError = true }
            await elsewhere.reloader.reload(tab: tab, after: EvaluationOutcome(id: 3, changedAddress: false))
            XCTAssertEqual(elsewhere.counts, [0, 0, 0, 0], "an error on a hidden tab is not this tab's")
        }
    }

    func test_AC_237_searchTabNeverReloads() async {
        for changed in [true, false] {
            let rig = Rig()
            for tab in reloadable { rig.screen(tab)?.hasLoadError = true }

            await rig.reloader.reload(tab: .search, after: EvaluationOutcome(id: 1, changedAddress: changed))

            XCTAssertEqual(rig.counts, [0, 0, 0, 0])
        }
        XCTAssertNil(Rig().reloader.screen(for: .search))
    }

    func test_AC_248_loadErrorIsTheReadFailureNotAnActionFailure() async {
        let offline = URLError(.notConnectedToInternet)

        let memoriesClient = MockImmichClient()
        let memories = MemoriesViewModel(client: memoriesClient)
        memories.errorMessage = "x"
        XCTAssertFalse(memories.hasLoadError, "a failed mutation is not a failed load")
        memoriesClient.memoriesError = offline
        await memories.load()
        XCTAssertTrue(memories.hasLoadError)

        let linksClient = MockImmichClient()
        let links = SharedLinksViewModel(client: linksClient)
        links.actionErrorMessage = "x"
        XCTAssertFalse(links.hasLoadError)
        linksClient.sharedLinksError = offline
        await links.load()
        XCTAssertTrue(links.hasLoadError)

        let albumsClient = MockImmichClient()
        let albums = AlbumsViewModel(client: albumsClient)
        albums.actionErrorMessage = "x"
        XCTAssertFalse(albums.hasLoadError)
        albumsClient.albumsError = offline
        await albums.load()
        XCTAssertTrue(albums.hasLoadError)

        let timeline = TimelineViewModel(client: MockImmichClient())
        timeline.actionErrorMessage = "x"
        XCTAssertFalse(timeline.hasLoadError)
        timeline.loadErrorMessage = "x"
        XCTAssertTrue(timeline.hasLoadError)
    }
}
