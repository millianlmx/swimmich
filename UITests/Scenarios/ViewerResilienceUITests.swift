import XCTest

/// End-to-end scenarios of lot L-29 (B-33): the viewer's "Try Again" on a photo
/// and on its details, the haptic of a favorite and of a delete, the screen that
/// stays on during the slideshow, and the video that falls back to the server
/// when its offline copy cannot be read.
///
/// It drives the real app against `immich_stub_viewer_resilience.py`, which fails
/// on demand (`GET /stub/switch?preview=…&details=…&bare=…&playback=…`). Two
/// launch arguments add inert-in-production probes:
///
/// * `-uiTestImageProbe YES`: the value of `viewerImage_<id>` reads
///   `placeholder|failed|loaded <w>x<h> …`.
/// * `-uiTestViewerProbe YES`: the `viewerProbe` element reads
///   `haptic=<none|success#n|warning#n|other#n> idle=<on|off>` — `haptic` is what
///   the haptic gate really returned to SwiftUI, `idle` the system's
///   `isIdleTimerDisabled`.
///
/// Targets identifiers and the stub's data, never a localized label. The two
/// exceptions, both in English because the scenario fixes `-AppleLanguages (en)`:
/// the VoiceOver label of the details spinner, which is the point of AC-57.6, and
/// the delete dialog's buttons when iOS does not expose their identifiers.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/viewer-resilience.uitest.log \
///         UITests/stubs/immich_stub_viewer_resilience.py ViewerResilienceUITests --erase
///
/// The helpers are copied from `MemoriesChainUITests` on purpose: one file per
/// feature, helpers included.
final class ViewerResilienceUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-authServerURL", "()",
        ]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    private let video = "aaaaaaaa-1111-4111-8111-000000000001"
    private let retry = "aaaaaaaa-1111-4111-8111-000000000002"
    private let neighbour = "aaaaaaaa-1111-4111-8111-000000000003"
    private let bare = "aaaaaaaa-1111-4111-8111-000000000004"
    private let timelinePhoto = "aaaaaaaa-1111-4111-8111-000000000003"
    private let hapticOffPhoto = "aaaaaaaa-1111-4111-8111-000000000006"
    private let folderPhoto = "aaaaaaaa-1111-4111-8111-000000000005"

    // MARK: - Helpers (copied, see the type's doc)

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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-viewer-resilience-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-viewer-resilience-\(name).png")
    }

    @discardableResult
    private func get(_ path: String) -> (status: Int?, body: String) {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 8
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var body = ""
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return (status, body)
    }

    private func reset() {
        XCTAssertEqual(get("/__reset").status, 200, "the stub refused /__reset")
        get("/__provider?mode=manual")
    }

    private func flip(_ switches: String) {
        XCTAssertEqual(get("/stub/switch?\(switches)").status, 200, "the stub refused the switches \(switches)")
    }

    private func screenText() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
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

    private func dismissSystemSignInAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Continue", "Continuer"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 6) { button.tap(); return }
        }
        for label in ["Continue", "Continuer"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); return }
        }
    }

    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch,
                          safari.buttons.matching(predicate).firstMatch] {
            if candidate.waitForExistence(timeout: timeout) { candidate.tap(); return true }
        }
        return false
    }

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != stub { field.typeText(stub) }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("not-on-login-screen")
            XCTFail("Login screen did not appear — \(screenText())")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elements(withPrefix prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    // MARK: - Navigation

    private func launchSignedIn(extraArguments: [String] = []) {
        app.launchArguments += extraArguments
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
    }

    private func tile(_ id: String) -> XCUIElement { element("assetTile_\(id)") }

    private func openViewer(on id: String) {
        let target = tile(id)
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no tile \(id) — \(screenText())")
        target.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 25),
                      "the viewer never opened — \(screenText())")
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back button — \(screenText())")
        back.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element("viewerBackButton").exists }, "the viewer did not close")
    }

    /// A viewer action: the pill on the row when it fits, else the ⋯ menu entry.
    private func viewerAction(id: String, menu: String) {
        let pill = element(id)
        if pill.waitForExistence(timeout: 3), pill.isHittable {
            pill.tap()
            return
        }
        let overflow = element("viewerOverflowMenu")
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "\(id) is neither on the row nor behind ⋯")
        overflow.tap()
        let item = element(menu)
        XCTAssertTrue(item.waitForExistence(timeout: 5), "⋯ holds no \(menu)")
        item.tap()
    }

    private func selectTab(_ label: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no \(label) tab — \(screenText())")
        tab.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]?
    }

    private func stubRequests() -> [StubRequest] {
        let body = get("/__requests").body
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func previewRequests(of id: String) -> Int {
        stubRequests().filter {
            $0.method == "GET" && $0.path == "/api/assets/\(id)/thumbnail" && $0.params?["size"] == "preview"
        }.count
    }

    private func playbackRequests() -> Int {
        stubRequests().filter { $0.method == "GET" && $0.path == "/api/assets/\(video)/video/playback" }.count
    }

    // MARK: - Probes

    private func imageProbeValue(_ id: String) -> String {
        (element("viewerImage_\(id)").value as? String) ?? ""
    }

    private func viewerProbe() -> [String: String] {
        let probe = element("viewerProbe")
        guard probe.exists, let value = probe.value as? String else { return [:] }
        var fields: [String: String] = [:]
        for part in value.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    @discardableResult
    private func waitForViewerProbe(_ expected: [String: String], timeout: TimeInterval = 10) -> Bool {
        var last: [String: String] = [:]
        let reached = waitUntil(timeout: timeout) {
            last = self.viewerProbe()
            return expected.allSatisfy { last[$0.key] == $0.value }
        }
        if !reached {
            shot("probe-\(expected.keys.sorted().joined(separator: "-"))")
            XCTFail("the viewer probe never read \(expected) — last read \(last)")
        }
        return reached
    }

    // MARK: - AC-57: "Try Again" on a photo

    func test_AC_57_photoRetry() throws {
        reset()
        flip("preview=fail&bare=fail")
        launchSignedIn(extraArguments: ["-uiTestImageProbe", "YES"])

        // AC-57.4: a failed grid tile keeps its failure tile, with no button.
        XCTAssertTrue(tile(bare).waitForExistence(timeout: 30), "the failing tile is missing — \(screenText())")
        XCTAssertEqual(elements(withPrefix: "viewerImageRetry_").count, 0, "the grid grew a Try Again button")

        // AC-57.1 / AC-57.7: the page shows the failure over the thumbnail, controls usable.
        openViewer(on: retry)
        let button = element("viewerImageRetry_\(retry)")
        XCTAssertTrue(button.waitForExistence(timeout: 30), "no Try Again on the failed page — \(screenText())")
        XCTAssertTrue(element("viewerBackButton").isHittable, "Back is not usable under the failure card")
        XCTAssertTrue(element("viewerFavoriteButton").isHittable, "Favorite is not usable under the failure card")
        shot("failed-over-thumbnail")

        // AC-57.2: a retry that fails again sends a request, then shows the button again.
        let before = previewRequests(of: retry)
        button.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { self.previewRequests(of: self.retry) >= before + 1 },
                      "Try Again sent no preview request")
        XCTAssertTrue(element("viewerImageRetry_\(retry)").waitForExistence(timeout: 15),
                      "the button did not come back after a second failure")
        XCTAssertTrue(element("viewerBackButton").exists, "the viewer closed on the retry")

        // AC-57 / AC-57.7: the preview answers, the retry shows it.
        flip("preview=ok")
        element("viewerImageRetry_\(retry)").tap()
        XCTAssertTrue(waitUntil(timeout: 20) { self.imageProbeValue(self.retry).hasPrefix("loaded 32x32") },
                      "the preview never displayed — probe reads \(imageProbeValue(retry))")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("viewerImageRetry_\(self.retry)").exists },
                      "the failure card stayed over the loaded photo")

        // AC-57.3: the next page is not touched by the first one's failure.
        app.swipeLeft()
        XCTAssertTrue(waitUntil(timeout: 20) { self.imageProbeValue(self.neighbour).hasPrefix("loaded") },
                      "the next photo did not load — probe reads \(imageProbeValue(neighbour))")
        XCTAssertEqual(elements(withPrefix: "viewerImageRetry_").count, 0, "a failure card followed the swipe")

        // AC-57.1: nothing to show under it — the failure card still offers the way out.
        closeViewer()
        openViewer(on: bare)
        XCTAssertTrue(element("viewerImageRetry_\(bare)").waitForExistence(timeout: 30),
                      "no Try Again on a page with no thumbnail either — \(screenText())")
        shot("failed-bare")
    }

    // MARK: - AC-57: "Try Again" on the details

    func test_AC_57_5_detailsRetry() throws {
        reset()
        flip("details=fail")
        launchSignedIn()
        openViewer(on: retry)

        viewerAction(id: "viewerDetailsButton", menu: "viewerMenuDetails")
        XCTAssertTrue(element("viewerInfoError").waitForExistence(timeout: 20), "no error in the info panel — \(screenText())")
        let retryButton = element("viewerInfoErrorRetry")
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5), "no Try Again in the info panel")

        // AC-57.6: while the slow answer is pending the spinner is named for VoiceOver.
        flip("details=slow")
        retryButton.tap()
        let loading = element("viewerInfoLoading")
        XCTAssertTrue(loading.waitForExistence(timeout: 3), "no loading indicator during the retry — \(screenText())")
        XCTAssertEqual(loading.label, "Loading details…")

        // AC-57 / AC-57.5: the details arrive, no error is left.
        XCTAssertTrue(element("viewerInfoDetails").waitForExistence(timeout: 30),
                      "the details never displayed — \(screenText())")
        XCTAssertFalse(element("viewerInfoError").exists, "the error stayed")
        XCTAssertFalse(element("viewerInfoReloadError").exists, "an error banner stayed over the details")
        shot("details-loaded")
    }

    // MARK: - AC-58: haptics

    private func tapDeleteAndAnswer(confirm: Bool) {
        let delete = element("viewerDeleteButton")
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete button — \(screenText())")
        delete.tap()
        // The dialog's identifiers are not always exposed by iOS: fall back on the English label
        // (the scenario fixes the language). The dialog's button is the last one on screen.
        let identifier = confirm ? "viewerDeleteConfirm" : "viewerDeleteCancel"
        let label = confirm ? "Delete" : "Cancel"
        let byId = element(identifier)
        if byId.waitForExistence(timeout: 5) {
            byId.tap()
            return
        }
        let byLabel = app.buttons.matching(NSPredicate(format: "label == %@", label))
        XCTAssertTrue(byLabel.firstMatch.waitForExistence(timeout: 5), "no \(label) in the confirmation — \(screenText())")
        byLabel.allElementsBoundByIndex.last?.tap()
    }

    func test_AC_58_haptics() throws {
        reset()
        launchSignedIn(extraArguments: ["-uiTestViewerProbe", "YES"])

        // Timeline: the surface hands its own favorite and delete callbacks (AC-58.5).
        openViewer(on: timelinePhoto)
        XCTAssertTrue(element("viewerProbe").waitForExistence(timeout: 10), "the probe is missing")
        waitForViewerProbe(["haptic": "none"])
        element("viewerFavoriteButton").tap()
        waitForViewerProbe(["haptic": "success#1"])
        element("viewerFavoriteButton").tap() // AC-58.2: removing the favorite plays one too
        waitForViewerProbe(["haptic": "success#2"])

        tapDeleteAndAnswer(confirm: false) // AC-58.3: Cancel plays nothing and keeps the photo
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(viewerProbe()["haptic"], "success#2", "Cancel played a haptic")
        XCTAssertTrue(element("viewerBackButton").exists, "Cancel closed the viewer")
        tapDeleteAndAnswer(confirm: true)
        waitForViewerProbe(["haptic": "warning#3"])
        closeViewer()

        // The Folders screen: no callbacks from the surface, the viewer drives its own writes.
        selectTab("Albums")
        let folders = element("foldersRow")
        for _ in 0..<5 where !folders.isHittable { app.swipeUp() }
        XCTAssertTrue(folders.waitForExistence(timeout: 20), "no Folders tile — \(screenText())")
        folders.tap()
        let folderRow = element("folderRow_/stub")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 20), "no /stub folder — \(screenText())")
        folderRow.tap()
        openViewer(on: folderPhoto)
        waitForViewerProbe(["haptic": "none"])
        element("viewerFavoriteButton").tap()
        waitForViewerProbe(["haptic": "success#1"])
        tapDeleteAndAnswer(confirm: true)
        waitForViewerProbe(["haptic": "warning#2"])
        closeViewer()

        // AC-58.4: with the setting off nothing is returned. Restored before the end.
        selectTab("Photos")
        setHaptics(on: false)
        defer { setHaptics(on: true) }
        openViewer(on: hapticOffPhoto)
        waitForViewerProbe(["haptic": "none"])
        element("viewerFavoriteButton").tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(viewerProbe()["haptic"], "none", "a haptic was returned with the setting off")
        closeViewer()
    }

    private func setHaptics(on: Bool) {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4)
        let row = app.buttons.matching(identifier: "preferencesRow").firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Preferences row missing — \(screenText())")
        row.tap()
        let toggle = element("preferencesHapticsToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Haptic Feedback toggle is missing")
        let wanted = on ? "1" : "0"
        for _ in 0..<3 where (toggle.value as? String) != wanted {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = waitUntil(timeout: 4) { (toggle.value as? String) == wanted }
        }
        XCTAssertEqual(toggle.value as? String, wanted, "Haptic Feedback never reached \(wanted)")
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        app.swipeDown()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 20), "the Me sheet did not close")
    }

    // MARK: - AC-58.1: the screen stays on

    func test_AC_58_1_slideshowKeepsScreenAwake() throws {
        reset()
        launchSignedIn(extraArguments: ["-uiTestViewerProbe", "YES"])
        openViewer(on: timelinePhoto)
        waitForViewerProbe(["idle": "off"])

        viewerAction(id: "viewerSlideshowButton", menu: "viewerMenuSlideshow")
        XCTAssertTrue(element("slideshowCloseButton").waitForExistence(timeout: 15), "the slideshow never opened")
        waitForViewerProbe(["idle": "on"])

        let playPause = element("slideshowPlayPauseButton")
        if !playPause.isHittable { app.tap() } // controls auto-hide: a tap brings them back
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), "no play/pause control")
        playPause.tap()
        Thread.sleep(forTimeInterval: 1)
        waitForViewerProbe(["idle": "on"]) // paused: still awake

        let close = element("slideshowCloseButton")
        if !close.isHittable { app.tap() }
        close.tap()
        waitForViewerProbe(["idle": "off"])
    }

    // MARK: - AC-59: the offline copy that cannot be read

    func test_AC_59_offlineCopyFallsBack() throws {
        reset()
        launchSignedIn()

        // An offline copy of the video, made from bytes that are not a movie.
        openViewer(on: video)
        XCTAssertTrue(waitUntil(timeout: 30) { self.playbackRequests() >= 1 }, "the video never streamed")
        element("viewerShareButton").tap()
        let remove = element("removeFromOfflineButton")
        let download = element("downloadForOfflineButton")
        if !download.waitForExistence(timeout: 10), remove.exists { // a copy left by an earlier run
            remove.tap()
        }
        XCTAssertTrue(download.waitForExistence(timeout: 15), "no 'Download for offline' — \(screenText())")
        download.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 60), "the offline copy never became available — \(screenText())")
        element("closeShareSheet").tap()
        closeViewer()

        // AC-59: the unreadable copy gives way to the server's stream.
        let streamedBefore = playbackRequests()
        openViewer(on: video)
        XCTAssertTrue(waitUntil(timeout: 40) { self.playbackRequests() > streamedBefore },
                      "the player never fell back to the server")
        XCTAssertTrue(element("videoPlayerPlayPause").waitForExistence(timeout: 20), "the video page shows no transport")
        XCTAssertFalse(element("videoPlayerRetry").exists, "the video stayed in error")

        // AC-59.4: the slideshow plays it too, instead of skipping it.
        let streamedInSlideshow = playbackRequests()
        viewerAction(id: "viewerSlideshowButton", menu: "viewerMenuSlideshow")
        let counter = element("slideshowCounter")
        XCTAssertTrue(counter.waitForExistence(timeout: 15), "the slideshow never opened")
        let slideBefore = counter.label
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(element("slideshowCounter").label, slideBefore, "the slideshow skipped the video")
        XCTAssertGreaterThan(playbackRequests(), streamedInSlideshow, "the slideshow never streamed the video")
        let close = element("slideshowCloseButton")
        if !close.isHittable { app.tap() }
        close.tap()
        closeViewer()

        // AC-59.3: the server fails too — the error state, one switch, no loop.
        flip("playback=fail")
        openViewer(on: video)
        XCTAssertTrue(element("videoPlayerRetry").waitForExistence(timeout: 40), "no Retry when the server fails too")
        let settled = playbackRequests()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(playbackRequests(), settled, "the player kept retrying on its own")

        // AC-59.5: the copy is untouched and still listed.
        element("viewerShareButton").tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "the offline copy is gone — \(screenText())")
        remove.tap() // courtesy to the other scenarios
        _ = download.waitForExistence(timeout: 15)
        element("closeShareSheet").tap()
        closeViewer()
    }
}
