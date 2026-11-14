import XCTest

/// End-to-end scenarios of lot L-27: the default share quality, the log level,
/// the image cache and the result alerts of the offline-cache purges.
///
/// It drives the real app against `immich_stub_share_caches.py`, and asserts on
/// the WIRE (`/__requests`, read as a difference before/after a gesture) what a
/// screenshot cannot prove: which file a share downloaded (`/original` or
/// `thumbnail?size=preview`), whether a re-opened album went back to the server
/// (the image cache), whether a cancelled or closed share still produced a sheet.
/// Everything on screen is found by IDENTIFIER, and the two segmented pickers by
/// segment INDEX (0 = Original / All, 1 = Preview / Warnings, 2 = Errors), so the
/// scenario does not depend on the language.
///
/// The iOS share sheet is "open" when an element with the identifier
/// `ActivityListView` (or `UIActivityContentView`) exists, or when the system
/// sheet's own close button does. The test never drives it: on iOS 26 the app
/// stops reporting idle while the sheet is up, so a tap or swipe on it can stall
/// XCUITest ("Stall on main thread", or a swipe on an empty frame). Once seen,
/// the sheet is left by relaunching the app (`leaveIOSSheet`), session kept.
///
/// One test per criterion (AC-50, AC-52, AC-270, AC-272, AC-273, AC-275, AC-277,
/// AC-279, AC-280). Each one signs in on its own, resets the stub, and gives its
/// preferences back (a Preferences value outlives a relaunch).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/share-caches.uitest.log \
///         UITests/stubs/immich_stub_share_caches.py ShareAndCachesUITests/test_AC_50 --erase
///
/// `--erase` is required for `test_AC_270`: it asserts the default of a fresh
/// install.
final class ShareAndCachesUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // MARK: - The stub's fixtures (recopied from immich_stub_share_caches.py)

    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"
    private let video = "aaaaaaaa-1111-4111-8111-000000000002"
    private let album = "22222222-2222-4222-8222-000000000027"
    private let albumPhotoPrefix = "bbbbbbbb-1111-4111-8111-"

    private static let welcome = ["Your photo library", "Votre photothèque"]
    private static let resetLabels = ["Reset", "Zurücksetzen", "Restablecer", "Réinitialiser", "Reimposta"]

    /// The character `AppLogEntry.message` puts between a call and its outcome.
    private let arrow = "\u{2192}"

    /// `-authServerURL ()` forgets the server, so the first launch of a test
    /// walks the onboarding whatever session an earlier test left.
    private let launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-authServerURL", "()"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        // A dead server also fails the ping below: bring it back first.
        stubQuiet("/control/network?down=0")
        guard stubIsReachable() else { return }
        app.terminate()
        app.launchArguments = launchArguments
        app.launch()
        XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                      "the cleanup launch did not reach the onboarding: the session may have survived")
        app.terminate()
    }

    // MARK: - The scenarios

    /// AC-270: the default is Preview; the choice survives a relaunch; Reset
    /// brings Preview back.
    func test_AC_270() throws {
        try start()
        openPreferences()
        assertSegment("preferencesShareQualityPicker", 1, selected: true, "a fresh install must default to Preview")
        assertSegment("preferencesShareQualityPicker", 0, selected: false, "Original must not be the default")

        chooseSegment("preferencesShareQualityPicker", 0)
        assertSegment("preferencesShareQualityPicker", 0, selected: true, "the picker must read back Original")
        leavePreferencesAndHub()

        relaunch()
        openPreferences()
        assertSegment("preferencesShareQualityPicker", 0, selected: true,
                      "Original must survive a relaunch — that is what persisting it means")

        let reset = reveal(element("preferencesResetButton"))
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "the Preferences form has no Reset row")
        reset.tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Reset did not raise a confirmation")
        let confirm = dialog.buttons.matching(labelPredicate(Self.resetLabels)).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "no Reset button in the confirmation — buttons: \(dialog.buttons.allElementsBoundByIndex.map(\.label))")
        confirm.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !dialog.exists }, "the confirmation stayed up after Reset")
        assertSegment("preferencesShareQualityPicker", 1, selected: true, "Reset must bring Preview back")
        leavePreferencesAndHub()
    }

    /// AC-50: the header button of the actions sheet shares in the default
    /// quality, without asking.
    func test_AC_50() throws {
        try start()

        // Original: `/original`, never a thumbnail of P1.
        setShareQuality(0)
        openSettledViewer(photo)
        var before = stubRequests().count
        shareFromActionsSheet()
        XCTAssertTrue(waitForWire(30) { log in
            log.dropFirst(before).contains { self.isOriginal($0, of: self.photo) }
        }, "sharing with 'Original' never asked for /api/assets/\(photo)/original — got:\n\(describe(Array(stubRequests().dropFirst(before))))")
        XCTAssertTrue(waitForIOSSheet(timeout: 30), "the iOS share sheet did not open (Original) — \(screenReads())")
        var diff = Array(stubRequests().dropFirst(before))
        XCTAssertTrue(diff.filter { isThumbnail($0, of: photo) }.isEmpty,
                      "sharing with 'Original' also fetched a thumbnail of P1 — got:\n\(describe(diff))")
        leaveIOSSheet()

        // Preview: only `thumbnail?size=preview`.
        setShareQuality(1)
        openSettledViewer(photo)
        before = stubRequests().count
        shareFromActionsSheet()
        XCTAssertTrue(waitForWire(30) { log in
            log.dropFirst(before).contains { self.isPreview($0, of: self.photo) }
        }, "sharing with 'Preview' never asked for thumbnail?size=preview — got:\n\(describe(Array(stubRequests().dropFirst(before))))")
        XCTAssertTrue(waitForIOSSheet(timeout: 30), "the iOS share sheet did not open (Preview) — \(screenReads())")
        diff = Array(stubRequests().dropFirst(before))
        XCTAssertTrue(diff.filter { isOriginal($0, of: photo) }.isEmpty,
                      "sharing with 'Preview' downloaded the original — got:\n\(describe(diff))")
        XCTAssertTrue(diff.filter { isThumbnail($0, of: photo) }.allSatisfy { $0.params["size"] == "preview" },
                      "sharing with 'Preview' fetched a thumbnail that is not size=preview — got:\n\(describe(diff))")
        leaveIOSSheet()
    }

    /// AC-272: a long press on Share chooses the quality of ONE share, shares at
    /// once (no actions sheet) and leaves the setting alone; dismissing the menu
    /// shares nothing; a video only offers Original.
    func test_AC_272() throws {
        try start()
        setShareQuality(1)
        openSettledViewer(photo)

        // Long press → Original: `/original`, the iOS sheet, no actions sheet.
        var before = stubRequests().count
        longPressShare()
        let original = element("shareQualityChoice_original")
        XCTAssertTrue(original.waitForExistence(timeout: 10), "the long press offered no 'Original' choice — \(screenReads())")
        XCTAssertTrue(element("shareQualityChoice_preview").exists, "the long press on a photo offered no 'Preview' choice")
        original.tap()
        XCTAssertTrue(waitForWire(30) { log in
            log.dropFirst(before).contains { self.isOriginal($0, of: self.photo) }
        }, "choosing 'Original' never asked for the original — got:\n\(describe(Array(stubRequests().dropFirst(before))))")
        XCTAssertTrue(waitForIOSSheet(timeout: 30), "the iOS share sheet did not open after the choice — \(screenReads())")
        XCTAssertFalse(element("shareSheetNativeShareButton").exists,
                       "the long press opened the actions sheet instead of sharing at once")
        leaveIOSSheet()
        openSettledViewer(photo)

        // A plain tap still shares in the setting (Preview).
        before = stubRequests().count
        shareFromActionsSheet()
        XCTAssertTrue(waitForWire(30) { log in
            log.dropFirst(before).contains { self.isPreview($0, of: self.photo) }
        }, "the header button did not share the Preview setting — got:\n\(describe(Array(stubRequests().dropFirst(before))))")
        XCTAssertTrue(waitForIOSSheet(timeout: 30), "the iOS share sheet did not open for the header share")
        XCTAssertTrue(stubRequests().dropFirst(before).filter { isOriginal($0, of: photo) }.isEmpty,
                      "the header share downloaded the original although the setting is Preview")
        leaveIOSSheet()

        // The one-off choice left the setting alone.
        openPreferences()
        assertSegment("preferencesShareQualityPicker", 1, selected: true, "a one-off choice must not change the setting")
        leavePreferencesAndHub()

        // Dismissing the menu without choosing shares nothing.
        openSettledViewer(photo)
        before = stubRequests().count
        longPressShare()
        XCTAssertTrue(element("shareQualityChoice_original").waitForExistence(timeout: 10), "the menu did not open")
        dismissMenu()
        Thread.sleep(forTimeInterval: 3)
        let diff = Array(stubRequests().dropFirst(before))
        XCTAssertTrue(diff.filter { isOriginal($0, of: photo) || isThumbnail($0, of: photo) }.isEmpty,
                      "dismissing the menu without a choice still downloaded P1 — got:\n\(describe(diff))")
        XCTAssertFalse(iosSheetOpen, "dismissing the menu opened the share sheet")
        closeViewer()

        // A video only offers Original.
        openViewer(video)
        Thread.sleep(forTimeInterval: 2)
        longPressShare()
        XCTAssertTrue(element("shareQualityChoice_original").waitForExistence(timeout: 10),
                      "a video's menu offers no 'Original' — \(screenReads())")
        XCTAssertFalse(element("shareQualityChoice_preview").exists, "a video's menu offers 'Preview'")
        dismissMenu()
        closeViewer()
    }

    /// AC-273: the log level is set from the Me hub, keeps the lines already
    /// listed, and survives a relaunch.
    func test_AC_273() throws {
        try start()
        openHub()

        openAppLogs()
        let before = Array(logRows().prefix(3))
        XCTAssertFalse(before.isEmpty, "the App Logs list was empty at the 'All' level — nothing to keep")
        goBack()

        chooseSegment("advancedLogLevelPicker", 2)
        assertSegment("advancedLogLevelPicker", 2, selected: true, "the picker must read back Errors")

        openAppLogs()
        for row in before {
            XCTAssertTrue(findRow(row), "the line '\(row)' disappeared when the level moved to Errors — "
                          + "rows:\n\(logRows().joined(separator: "\n"))")
        }
        goBack()
        closeHub()

        relaunch()
        openHub()
        assertSegment("advancedLogLevelPicker", 2, selected: true, "Errors must survive a relaunch")

        chooseSegment("advancedLogLevelPicker", 0)
        assertSegment("advancedLogLevelPicker", 0, selected: true, "the level must go back to All")
        closeHub()
    }

    /// AC-52 (and AC-274, AC-275 of the same flow): the image cache keeps an
    /// album's thumbnails, "Clear" empties it and an album is fetched again.
    func test_AC_52() throws {
        try start()

        var mark = stubRequests().count
        openAlbum()
        XCTAssertTrue(waitForWire(30) { log in
            self.albumThumbnailIDs(Array(log.dropFirst(mark))).count >= 6
        }, "the album never asked for its thumbnails — got:\n\(describe(Array(stubRequests().dropFirst(mark).suffix(12))))")
        Thread.sleep(forTimeInterval: 2)
        let firstVisit = Set(albumThumbnailIDs(Array(stubRequests().dropFirst(mark))))
        closeAlbum()

        openHub()
        XCTAssertTrue(waitUntil(timeout: 15) { (self.cacheSizeInteger() ?? 0) >= 1 },
                      "the image cache never reported at least 1 MB after an album visit — it reads '\(cacheSizeText())'")
        let sizeBefore = cacheSizeText()

        // Cancel: nothing changes.
        reveal(element("clearImageCacheButton")).tap()
        let cancel = element("clearImageCacheCancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "'Clear Image Cache' raised no confirmation")
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !cancel.exists }, "the confirmation stayed up after Cancel")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(cacheSizeText(), sizeBefore, "Cancel changed the image cache size")
        closeHub()

        // AC-274: the album comes back from the cache, without one request for a thumbnail it already had.
        mark = stubRequests().count
        openAlbum()
        XCTAssertTrue(firstAlbumTile().waitForExistence(timeout: 20), "the album showed no tile after Cancel")
        Thread.sleep(forTimeInterval: 4)
        let repeated = albumThumbnailIDs(Array(stubRequests().dropFirst(mark))).filter { firstVisit.contains($0) }
        XCTAssertTrue(repeated.isEmpty,
                      "after Cancel the album asked again for \(repeated.count) thumbnail(s) it already had")
        closeAlbum()

        // Clear: the alert, then an empty cache.
        openHub()
        reveal(element("clearImageCacheButton")).tap()
        let confirm = element("clearImageCacheConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "'Clear Image Cache' raised no confirmation")
        confirm.tap()
        let done = element("imageCacheClearedDismiss")
        XCTAssertTrue(done.waitForExistence(timeout: 20), "no 'Image Cache Cleared' alert after confirming")
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { self.cacheSizeInteger() == 0 },
                      "the image cache size does not read 0 after clearing — it reads '\(cacheSizeText())'")
        closeHub()

        // AC-275: the album is fetched again.
        mark = stubRequests().count
        openAlbum()
        XCTAssertTrue(waitForWire(30) { log in
            !Set(self.albumThumbnailIDs(Array(log.dropFirst(mark)))).isDisjoint(with: firstVisit)
        }, "after clearing, the album did not ask again for its thumbnails — got:\n\(describe(Array(stubRequests().dropFirst(mark).suffix(12))))")
        closeAlbum()
    }

    /// AC-275 (offline): clearing the image cache keeps the offline photos, which
    /// then open without any network.
    func test_AC_275() throws {
        try start()
        downloadForOffline(photo)

        openHub()
        reveal(element("clearImageCacheButton")).tap()
        let confirm = element("clearImageCacheConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "'Clear Image Cache' raised no confirmation")
        confirm.tap()
        let done = element("imageCacheClearedDismiss")
        XCTAssertTrue(done.waitForExistence(timeout: 20), "no 'Image Cache Cleared' alert")
        done.tap()
        closeHub()

        XCTAssertEqual(stubGet("/control/network?down=1"), "{\"down\": true}", "the stub did not go down")
        openOfflineStorage()
        let row = reveal(element("offlineAsset_\(photo)"))
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "Offline Storage no longer lists the kept photo after the cache was cleared — \(screenReads())")
        row.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20),
                      "the offline photo did not open without a network — \(screenReads())")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(element("viewerBackButton").exists, "the viewer left by itself while offline")
        XCTAssertFalse(element("shareFailedDismiss").exists, "an error alert appeared on the offline photo")
        closeViewer()
        stubQuiet("/control/network?down=0")
    }

    /// AC-277: each of the three purge screens shows the result alert and leaves
    /// no offline photo.
    func test_AC_277() throws {
        try start()

        // Sync Status.
        downloadForOffline(photo)
        openSyncStatus()
        let clear = reveal(element("syncStatusClearOffline"))
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "no 'Clear offline cache' action on Sync Status")
        XCTAssertTrue(waitUntil(timeout: 20) { clear.isEnabled }, "the purge stayed disabled with an offline photo")
        clear.tap()
        tapElement("syncStatusClearOfflineConfirm", "no confirmation on Sync Status")
        tapElement("offlinePurgeSucceededDismiss", "no purge result alert on Sync Status", timeout: 30)
        XCTAssertTrue(waitUntil(timeout: 15) { !clear.isEnabled }, "the purge left offline photos counted on Sync Status")
        tapElement("syncStatusDone", "no way out of Sync Status")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("syncStatusDone").exists }, "Sync Status did not close")
        assertNoOfflinePhotos("after the purge from Sync Status")

        // Download Info.
        downloadForOffline(photo)
        openHub()
        let info = reveal(app.buttons.matching(identifier: "downloadInfoRow").firstMatch)
        XCTAssertTrue(info.waitForExistence(timeout: 10), "no Download Info row in the hub")
        info.tap()
        let purge = reveal(element("downloadInfoPurgeButton"))
        XCTAssertTrue(purge.waitForExistence(timeout: 20), "no purge on Download Info — \(screenReads())")
        purge.tap()
        tapElement("downloadInfoPurgeConfirm", "no confirmation on Download Info")
        tapElement("offlinePurgeSucceededDismiss", "no purge result alert on Download Info", timeout: 30)
        goBack()
        closeHub()
        assertNoOfflinePhotos("after the purge from Download Info")

        // Offline Storage.
        downloadForOffline(photo)
        openOfflineStorage()
        XCTAssertTrue(reveal(element("offlineAsset_\(photo)")).waitForExistence(timeout: 20),
                      "Offline Storage does not list the downloaded photo — \(screenReads())")
        reveal(element("clearAllOffline")).tap()
        tapElement("clearAllOfflineConfirm", "no confirmation on Offline Storage")
        tapElement("offlinePurgeSucceededDismiss", "no purge result alert on Offline Storage", timeout: 30)
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element("offlineAsset_\(self.photo)").exists },
                      "Offline Storage still lists the photo after its own purge")
        XCTAssertFalse(element("clearAllOffline").exists, "the purge action is still offered with no offline photo")
    }

    /// AC-279: a failed download shows the failure alert and opens no iOS sheet,
    /// from the header button and from the long press, in both qualities.
    func test_AC_279() throws {
        try start()

        // Original.
        setShareQuality(0)
        openSettledViewer(photo)
        stubControl("original?mode=fail&status=500")
        shareFromActionsSheet()
        assertShareFailed("the header share of the original")
        longPressShare()
        tapElement("shareQualityChoice_original", "the long press offered no 'Original'")
        assertShareFailed("the long-press share of the original")
        stubControl("original?mode=ok")
        closeViewer()

        // Preview.
        setShareQuality(1)
        openSettledViewer(photo)
        stubControl("preview?mode=fail&status=500")
        shareFromActionsSheet()
        assertShareFailed("the header share of the preview")
        longPressShare()
        tapElement("shareQualityChoice_preview", "the long press offered no 'Preview'")
        assertShareFailed("the long-press share of the preview")
        stubControl("preview?mode=ok")
        closeViewer()
    }

    /// AC-280: cancelling a slow share, or leaving the viewer during it, shares
    /// nothing and shows no failure.
    func test_AC_280() throws {
        try start()
        setShareQuality(0)
        openSettledViewer(photo)
        stubControl("original?mode=slow&seconds=10")

        // The cancel button.
        shareFromActionsSheet()
        let progress = element("shareDownloadProgress")
        XCTAssertTrue(progress.waitForExistence(timeout: 15), "no progress card for a slow share — \(screenReads())")
        let cancel = element("shareDownloadCancelButton")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the progress card has no cancel button")
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !progress.exists }, "the progress card outlived the cancel by 3 s")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(iosSheetOpen, "a cancelled share opened the iOS sheet")
        XCTAssertFalse(element("shareFailedDismiss").exists, "a cancelled share showed a failure alert")

        // Leaving the viewer during the progress.
        shareFromActionsSheet()
        XCTAssertTrue(element("shareDownloadProgress").waitForExistence(timeout: 15), "no progress card for the second slow share")
        closeViewer()
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 15), "not back on the timeline after the viewer closed")
        let deadline = Date().addingTimeInterval(14)
        while Date() < deadline {
            XCTAssertFalse(iosSheetOpen, "a share started in a closed viewer opened the iOS sheet")
            XCTAssertFalse(element("shareFailedDismiss").exists, "a share started in a closed viewer showed a failure alert")
            Thread.sleep(forTimeInterval: 0.5)
        }
        stubControl("original?mode=ok")
    }

    // MARK: - The viewer

    private func openViewer(_ id: String) {
        let tile = element("assetTile_\(id)")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the tile \(id) is not on the timeline — \(screenReads())")
        tile.tap()
        XCTAssertTrue(app.buttons["viewerBackButton"].waitForExistence(timeout: 20),
                      "the photo viewer never opened — \(screenReads())")
    }

    /// Opens the photo and lets the viewer finish its own preview fetch, so a
    /// journal difference taken afterwards measures the gesture alone. A viewer
    /// that serves the preview from memory sends nothing: the wait is bounded and
    /// does not fail.
    private func openSettledViewer(_ id: String) {
        let mark = stubRequests().count
        openViewer(id)
        _ = waitForWire(8) { log in log.dropFirst(mark).contains { self.isPreview($0, of: id) } }
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func closeViewer() {
        var closed = false
        for _ in 0..<4 where !closed {
            let back = app.buttons["viewerBackButton"]
            guard back.exists else { break }
            if back.isHittable { back.tap() } else { app.swipeDown() }
            closed = waitUntil(timeout: 6) { !self.app.buttons["viewerBackButton"].exists }
        }
        XCTAssertTrue(closed, "the photo viewer never dismissed — every later step would read the covered screen")
    }

    private func shareFromActionsSheet() {
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no Share button — \(screenReads())")
        share.tap()
        let header = element("shareSheetNativeShareButton")
        XCTAssertTrue(header.waitForExistence(timeout: 15), "the Share button opened no actions sheet — \(screenReads())")
        header.tap()
    }

    private func longPressShare() {
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no Share button — \(screenReads())")
        share.press(forDuration: 1.0)
    }

    /// Closes the quality menu without choosing: a tap away from it. The tap may
    /// also toggle the viewer's chrome, which is put back if it hid Share.
    private func dismissMenu() {
        let away = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        away.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.element("shareQualityChoice_original").exists },
                      "the quality menu stayed up after a tap away from it")
        if !element("viewerShareButton").waitForExistence(timeout: 2) {
            away.tap()
            _ = element("viewerShareButton").waitForExistence(timeout: 3)
        }
    }

    /// A failed share: the failure alert, no iOS sheet. Dismisses the alert.
    private func assertShareFailed(_ what: String) {
        let dismiss = element("shareFailedDismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30), "\(what) showed no failure alert — \(screenReads())")
        XCTAssertFalse(iosSheetOpen, "\(what) failed yet the iOS share sheet opened")
        dismiss.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { !self.element("shareFailedDismiss").exists }, "the failure alert stayed up")
    }

    // MARK: - The iOS share sheet

    private var iosSheet: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["ActivityListView", "UIActivityContentView"]))
            .firstMatch
    }

    /// The system sheet's own close button (the actions sheet's one carries the
    /// identifier `closeShareSheet`).
    private var iosSheetCloseButton: XCUIElement {
        app.buttons.matching(identifier: "Close").firstMatch
    }

    private var iosSheetOpen: Bool { iosSheet.exists || iosSheetCloseButton.exists }

    private func waitForIOSSheet(timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { self.iosSheetOpen }
    }

    /// Leaves an open iOS share sheet without touching it: the app is relaunched
    /// on the same session (see the type's comment), and the viewer with it.
    private func leaveIOSSheet() {
        relaunch()
        XCTAssertFalse(iosSheetOpen, "the iOS share sheet outlived the relaunch")
    }

    // MARK: - Offline

    /// Keeps `id` for offline use from the actions sheet, then comes back to the timeline.
    private func downloadForOffline(_ id: String) {
        openViewer(id)
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no Share button — \(screenReads())")
        share.tap()
        let download = reveal(element("downloadForOfflineButton"))
        XCTAssertTrue(download.waitForExistence(timeout: 20), "no 'Download for Offline' in the actions sheet — \(screenReads())")
        download.tap()
        XCTAssertTrue(element("offlineAvailableRow").waitForExistence(timeout: 60),
                      "the photo never became available offline — \(screenReads())")
        tapElement("closeShareSheet", "no way out of the actions sheet")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("closeShareSheet").exists }, "the actions sheet did not close")
        closeViewer()
    }

    private func openOfflineStorage() {
        goToAlbumsRoot()
        let row = reveal(app.buttons.matching(identifier: "offlineStorageRow").firstMatch)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Offline Storage row in the Library — \(screenReads())")
        row.tap()
        XCTAssertTrue(element("offlineStorageScreen").waitForExistence(timeout: 20),
                      "Offline Storage did not open — \(screenReads())")
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func assertNoOfflinePhotos(_ context: String) {
        openOfflineStorage()
        XCTAssertFalse(element("offlineAsset_\(photo)").exists, "Offline Storage still lists the photo \(context)")
        XCTAssertFalse(element("clearAllOffline").exists, "Offline Storage still offers to clear photos \(context)")
        goBack()
        goToPhotosRoot()
    }

    private func openSyncStatus() {
        selectTab("Photos")
        let button = app.buttons.matching(identifier: "syncStatusButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the Sync Status button is missing from the bar")
        button.tap()
        XCTAssertTrue(element("syncStatusDone").waitForExistence(timeout: 15), "Sync Status did not open — \(screenReads())")
    }

    // MARK: - The albums

    private func openAlbum() {
        goToAlbumsRoot()
        let card = reveal(app.buttons.matching(identifier: "albumCard_\(album)").firstMatch)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no card for the album — \(screenReads())")
        card.tap()
        XCTAssertTrue(element("albumHeroTitle").waitForExistence(timeout: 20), "the album did not open — \(screenReads())")
    }

    private func closeAlbum() {
        goBack()
        XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 15), "not back on the Albums tab")
    }

    private func firstAlbumTile() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assetTile_" + albumPhotoPrefix))
            .firstMatch
    }

    private func goToAlbumsRoot() {
        selectTab("Albums")
        for _ in 0..<6 {
            let section = element("albumsLibrarySection")
            if section.exists && section.isHittable { return }
            let back = element("viewerBackButton")
            if back.exists && back.isHittable { back.tap(); Thread.sleep(forTimeInterval: 0.8); continue }
            goBack()
        }
        XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 20), "no Library section on the Albums tab")
    }

    private func goToPhotosRoot() {
        selectTab("Photos")
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 20), "the Photos tab shows no tile — \(screenReads())")
    }

    // MARK: - The Me hub

    private func openHub() {
        selectTab("Photos")
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "no Me avatar on the timeline")
        avatar.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20), "the Me hub did not open")
        Thread.sleep(forTimeInterval: 2)
    }

    /// The Me hub has no Done button: it is dragged down from its navigation bar,
    /// and the dismissal is verified (the covered timeline stays in the tree).
    private func closeHub() {
        var dismissed = false
        for attempt in 0..<4 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(timeout: 6) { !self.element("profileList").exists }
        }
        XCTAssertTrue(dismissed, "the Me hub never dismissed")
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 15), "not back on the timeline after the hub")
    }

    private func openPreferences() {
        openHub()
        let row = reveal(element("preferencesRow"))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Preferences row in the Me hub — \(screenReads())")
        row.tap()
        XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20),
                      "the Preferences form never appeared — \(screenReads())")
    }

    private func leavePreferencesAndHub() {
        goBack()
        closeHub()
    }

    /// The share quality is persisted: every test that needs one sets it itself.
    private func setShareQuality(_ index: Int) {
        openPreferences()
        chooseSegment("preferencesShareQualityPicker", index)
        assertSegment("preferencesShareQualityPicker", index, selected: true, "the picker must read back the choice")
        leavePreferencesAndHub()
    }

    private func openAppLogs() {
        let row = reveal(element("appLogsRow"))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no App Logs row in the Me hub")
        row.tap()
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "the App Logs screen never loaded")
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// The log screen's rows: one element per line, labelled `"<level> <message>"`;
    /// the arrow tells a row from the picker, the toolbar and the titles.
    private func logRows() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", arrow))
            .allElementsBoundByIndex
            .map(\.label)
    }

    /// Scrolls the list (down, then back up) until a row reads exactly `label`.
    private func findRow(_ label: String) -> Bool {
        for direction in [true, false] {
            for _ in 0..<10 {
                if logRows().contains(label) { return true }
                if direction { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return logRows().contains(label)
    }

    private func cacheSizeText() -> String {
        let value = reveal(element("imageCacheSizeValue"))
        guard value.waitForExistence(timeout: 10) else { return "" }
        if !value.label.isEmpty { return value.label }
        return (value.value as? String) ?? ""
    }

    /// The number the size row reads. `LabeledContent` merges the row, so the
    /// identified element's label is "Image Cache, 5 MB": the last run of digits
    /// is the size.
    private func cacheSizeInteger() -> Int? {
        cacheSizeText().split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) }
    }

    // MARK: - Segmented pickers

    private func segmentedControl(_ identifier: String) -> XCUIElement {
        app.segmentedControls.matching(identifier: identifier).firstMatch
    }

    private func chooseSegment(_ identifier: String, _ index: Int) {
        let control = reveal(segmentedControl(identifier))
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on screen — \(screenReads())")
        let segment = control.buttons.element(boundBy: index)
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "\(identifier) has no segment \(index)")
        if !segment.isSelected { segment.tap() }
        XCTAssertTrue(waitUntil(timeout: 6) { segment.isSelected }, "segment \(index) of \(identifier) never got selected")
    }

    private func assertSegment(_ identifier: String, _ index: Int, selected: Bool, _ comment: String) {
        let control = reveal(segmentedControl(identifier))
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on screen — \(screenReads())")
        let segment = control.buttons.element(boundBy: index)
        XCTAssertTrue(waitUntil(timeout: 6) { segment.isSelected == selected },
                      "segment \(index) of \(identifier) is \(segment.isSelected ? "" : "not ")selected — \(comment)")
    }

    // MARK: - Reading and moving around the screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenReads() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    /// Scrolls (down, then up) until the target is on screen and hittable: a
    /// `Form` and a `LazyVGrid` only publish what they rendered.
    @discardableResult
    private func reveal(_ target: XCUIElement) -> XCUIElement {
        for down in [true, false] {
            for _ in 0..<12 where !(target.exists && target.isHittable) {
                if down { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if target.exists && target.isHittable { break }
        }
        return target
    }

    private func tapElement(_ identifier: String, _ message: String, timeout: TimeInterval = 15) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(message) — \(screenReads())")
        target.tap()
    }

    private func selectTab(_ label: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no \(label) tab — \(screenReads())")
        tab.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back — \(screenReads())")
        back.tap()
        Thread.sleep(forTimeInterval: 0.9)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    // MARK: - Launch and sign-in

    private func start() throws {
        if app.state != .notRunning { app.terminate() }
        stubGet("/__reset")
        stubGet("/__provider?mode=manual")
        app.launchArguments = launchArguments
        app.launch()
        signIn()
        settleOnShell()
    }

    /// The same session again (the arguments no longer forget the server).
    private func relaunch() {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        settleOnShell()
    }

    /// The first system sign-in of a freshly erased simulator is slow (the alert,
    /// then a cold `SafariViewService`) and, on a loaded pool, can outlast a fixed
    /// wait: a stuck attempt is restarted from the onboarding, never failed on the
    /// first miss.
    private func signIn() {
        for attempt in 0..<3 {
            if attempt > 0 {
                app.terminate()
                stubGet("/__provider?mode=manual")
                app.launchArguments = launchArguments
                app.launch()
            }
            XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                          "the onboarding did not appear — the scenario would start from a stale session")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent(timeout: 20)
            if tapAuthorizeInProvider(timeout: 45) { break }
            if attempt == 2 {
                XCTFail("Authorize link not reachable in the auth sheet after 3 attempts")
                return
            }
        }
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell")
    }

    private func settleOnShell() {
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 40),
                      "the timeline never rendered — \(screenReads())")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 5) {
            whatsNewDone.tap()
            XCTAssertTrue(waitUntil(timeout: 10) { !whatsNewDone.exists }, "What's New never closed")
        }
    }

    // MARK: - Helpers (copied from `ContentCollectionsUITests`, one file per feature)

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let button = app.buttons.containing(predicate).firstMatch
        let direct = app.buttons.matching(predicate).firstMatch
        for candidate in [direct, button] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        let direct = app.buttons.matching(predicate).firstMatch
        let contained = app.buttons.containing(predicate).firstMatch
        for candidate in [direct, contained] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    /// Welcome → server URL → login. Leaves the app on the login screen.
    private func walkOnboardingToLogin() {
        _ = tapAnyButton(["Get Started", "Commencer"], timeout: 15)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != stub {
            field.typeText(stub)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        // The keyboard covers the CTA: scrolling dismisses it, a bounded retry covers the animation.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenReads())")
    }

    /// Taps the system "Continue" of the sign-in alert, whenever it shows within
    /// `timeout`; returns early once the provider page itself is up.
    private func dismissSystemSignInAlertIfPresent(timeout: TimeInterval = 12) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let authorize = NSPredicate(format: "label CONTAINS 'Authorize'")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for label in ["Continue", "Continuer"] {
                let system = springboard.alerts.buttons[label]
                if system.exists { system.tap(); return }
                let inApp = app.alerts.buttons[label]
                if inApp.exists { inApp.tap(); return }
            }
            if safari.links.matching(authorize).firstMatch.exists { return }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
    }

    /// The provider page lives in `SafariViewService`, a separate process.
    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch,
                          safari.buttons.matching(predicate).firstMatch] {
            if candidate.waitForExistence(timeout: timeout) {
                candidate.tap()
                return true
            }
        }
        return false
    }

    // MARK: - The stub

    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(stub)/api/server/ping") else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        return done.wait(timeout: .now() + 5) == .success && ok
    }

    @discardableResult
    private func stubGet(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer \(path)")
        return body
    }

    /// A control that must never fail a test (the tear-down path).
    private func stubQuiet(_ path: String) {
        guard let url = URL(string: "\(stub)\(path)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 4)
    }

    private func stubControl(_ path: String) {
        let body = stubGet("/control/\(path)")
        XCTAssertFalse(body.isEmpty, "the stub rejected the control /control/\(path)")
    }

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
    }

    private func stubRequests() -> [StubRequest] {
        (try? JSONDecoder().decode([StubRequest].self, from: Data(stubGet("/__requests").utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.isEmpty ? "(nothing)" : requests.map { "\($0.method) \($0.path) params=\($0.params)" }
            .joined(separator: "\n")
    }

    /// Bounded poll on the journal: a POSITIVE assertion waits for its own request.
    private func waitForWire(_ timeout: TimeInterval, _ condition: ([StubRequest]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition(stubRequests()) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return condition(stubRequests())
    }

    private func isOriginal(_ request: StubRequest, of id: String) -> Bool {
        request.method == "GET" && request.path == "/api/assets/\(id)/original"
    }

    private func isThumbnail(_ request: StubRequest, of id: String) -> Bool {
        request.method == "GET" && request.path == "/api/assets/\(id)/thumbnail"
    }

    private func isPreview(_ request: StubRequest, of id: String) -> Bool {
        isThumbnail(request, of: id) && request.params["size"] == "preview"
    }

    /// The album photos a thumbnail was requested for, in request order.
    private func albumThumbnailIDs(_ log: [StubRequest]) -> [String] {
        log.compactMap { request in
            guard request.method == "GET", request.path.hasSuffix("/thumbnail") else { return nil }
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count == 4, parts[3] == "thumbnail", parts[2].hasPrefix(albumPhotoPrefix) else { return nil }
            return parts[2]
        }
    }
}
