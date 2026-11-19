import XCTest

/// Takes the screenshots of `README.md` and `README.fr.md` (`docs/screenshots/*.png`):
/// the loaded Photos timeline, the viewer, Albums, Search and Backup, over the
/// CC0 sample photos served by `immich_stub_readme_screenshots.py`.
///
/// This is not a regression scenario: it asserts that each screen is on display
/// (never its loading, empty or error state) and writes the picture. It skips
/// unless `SWIMMICH_SCREENSHOT_DIR` is set, so no suite writes files by accident.
/// Run it with `Scripts/screenshots.sh`, which starts the stub, pins the
/// simulator's status bar and passes the folder (`TEST_RUNNER_` prefix: Xcode
/// hands `TEST_RUNNER_<NAME>` to the test runner as `<NAME>`).
///
/// One `XCTestCase` per feature, in its own file: the helpers are copied from
/// `TimelineScrubberUITests` on purpose (the repository's rule: no shared UI-test
/// support file).
final class ReadmeScreenshotsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var outputDirectory: URL!

    /// `immich_stub_readme_screenshots.py`: asset n of the timeline, newest first.
    private func photoID(_ n: Int) -> String { String(format: "cccccccc-0000-4000-8000-%012d", n) }
    private func albumID(_ k: Int) -> String { String(format: "dddddddd-0000-4000-8000-%012d", k) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let folder = ProcessInfo.processInfo.environment["SWIMMICH_SCREENSHOT_DIR"] else {
            throw XCTSkip("SWIMMICH_SCREENSHOT_DIR is not set; run Scripts/screenshots.sh")
        }
        outputDirectory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

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

    // MARK: - Helpers (copied from TimelineScrubberUITests)

    /// Writes `docs/screenshots/<name>.png`. The pictures load asynchronously and
    /// nothing in the accessibility tree says "decoded": a short, bounded pause.
    private func capture(_ name: String) throws {
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = springboard.alerts.allElementsBoundByIndex + app.alerts.allElementsBoundByIndex
        let buttons = alerts.flatMap { $0.buttons.allElementsBoundByIndex.map(\.label) }
        XCTAssertTrue(alerts.isEmpty, "\(name): an alert is on screen: \(buttons.joined(separator: ", "))")
        let data = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertGreaterThan(data.count, 50_000, "\(name): the screenshot is nearly empty")
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
        print("SHOT \(name).png")
    }

    private func get(_ path: String) {
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "\(stub)\(path)")!) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "Stub did not answer \(path)")
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
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

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func dismissSystemSignInAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Continue", "Continuer"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 6) {
                button.tap()
                return
            }
        }
    }

    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch,
                          safari.buttons.matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    /// Welcome → server URL → login → SSO → authenticated shell.
    private func signIn() {
        app.launch()
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 40), "Welcome CTA missing")
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
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(["Sign in to Immich", "Connectez-vous à Immich"], timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear")
        XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 8) { whatsNewDone.tap() }
    }

    private func openTab(_ labels: [String]) {
        let tab = app.tabBars.buttons.matching(labelPredicate(labels)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no tab \(labels)")
        tab.tap()
    }

    private var searchTab: XCUIElement {
        app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch"])).firstMatch
    }

    /// What the screen holds, for a failure message that can be acted on (the CI log is unreadable: the
    /// message is all the run reports).
    private func screenState() -> String {
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map { "\($0.label)\($0.isSelected ? "*" : "")" }
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(20)
        let search = searchTab.exists ? "hittable \(searchTab.isHittable), frame \(searchTab.frame)" : "absent"
        return "tabs \(tabs); Search tab \(search); searchFields \(app.searchFields.count); "
            + "textFields \(app.textFields.count); sheets \(app.sheets.count); alerts \(app.alerts.count); "
            + "keyboards \(app.keyboards.count); screen reads \(Array(texts))"
    }

    /// Selects the Photos tab and waits until it is the selection. The Search results toolbar crowds the
    /// profile avatar out: both the Search and the Backup steps start from Photos.
    private func selectPhotosTab() {
        let photos = app.tabBars.buttons.matching(labelPredicate(["Photos"])).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 20), "no Photos tab — \(screenState())")
        photos.tap()
        XCTAssertTrue(waitUntil(10) { photos.isSelected }, "the Photos tab was not selected — \(screenState())")
    }

    /// Opens the Search tab and returns its search field. The bubble is Search from every tab; Photos is
    /// selected first so each step starts from the same place, as `ContentCollectionsUITests.goToSearchRoot()`
    /// does.
    private func openSearchField() -> XCUIElement {
        selectPhotosTab()
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "no Search tab — \(screenState())")
        searchTab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field — \(screenState())")
        return field
    }

    /// A row of a pushed screen, by IDENTIFIER (copied from `UploadDetailUITests`). A `Form` only
    /// publishes what it rendered, so it is scrolled into view first: `up` walks down the list.
    private func row(_ identifier: String, swiping direction: String = "up", swipes: Int = 10) -> XCUIElement {
        let element = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            if direction == "down" { app.swipeDown() } else { app.swipeUp() }
            _ = element.waitForExistence(timeout: 1)
        }
        return element
    }

    // MARK: - The five screens

    func test_AC_7_capturesTheFiveScreens() throws {
        get("/__reset")
        get("/__provider?mode=manual")
        signIn()

        // 1. Photos: the first and last tiles of the first screen, no skeleton, no banner.
        XCTAssertTrue(element("assetTile_\(photoID(1))").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub)")
        XCTAssertTrue(element("assetTile_\(photoID(9))").exists, "the grid has fewer than nine tiles")
        // A tile of a lazy grid can exist below the fold: `exists` does not put it in the picture.
        for n in 1...9 {
            let tile = element("assetTile_\(photoID(n))")
            XCTAssertTrue(waitUntil(10) { tile.exists && tile.isHittable },
                          "timeline: tile \(n) is not on screen: the capture would show fewer than nine photos")
        }
        XCTAssertFalse(element("timelineLoadingSkeleton").exists, "the timeline is still loading")
        XCTAssertFalse(element("timelineLoadErrorBanner").exists, "the timeline shows an error")
        try capture("timeline")

        // 2. Viewer: the first photo full screen.
        element("assetTile_\(photoID(1))").tap()
        XCTAssertTrue(element("viewerImage_\(photoID(1))").waitForExistence(timeout: 20), "the viewer did not open")
        try capture("viewer")
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from the viewer")
        back.tap()

        // 3. Albums: the four album cards.
        openTab(["Albums"])
        // The Library section tops the scroll view and its 12 tiles push the album cards below the fold; the
        // cards sit in a LazyVGrid, so one that is off screen is not in the accessibility tree at all. Wait for
        // the screen itself, then scroll until all four cards exist and fit together.
        XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 20), "the Albums tab did not open")
        let cards = (1...4).map { element("albumCard_\(albumID($0))") }
        let fourCardsOnScreen = { cards.allSatisfy { $0.exists && $0.isHittable } }
        for _ in 0..<8 where !fourCardsOnScreen() {
            app.swipeUp()
            _ = waitUntil(2, fourCardsOnScreen)
        }
        XCTAssertFalse(element("albumsEmptyState").exists, "Albums shows its empty state")
        XCTAssertFalse(element("albumsRetryButton").exists, "Albums shows its error state")
        XCTAssertTrue(fourCardsOnScreen(), "albums: the four album cards never fit on screen together")
        try capture("albums")

        // 4. Search: a word that matches photos, keyboard dismissed.
        let field = openSearchField()
        field.tap()
        field.typeText("nature\n") // the return key submits the search and dismisses the keyboard
        let results = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_cccccccc'")).firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 30), "the search returned no photo")
        XCTAssertFalse(element("searchEmptyState").exists, "Search shows its empty state")
        try capture("search")

        // 5. Backup: the Me hub's Backup screen, opened from the Photos timeline (the capture above is
        // a Search screen; the walk goes back to Photos for the hub).
        selectPhotosTab()
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing — \(screenState())")
        hub.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20),
                      "the Me sheet did not open — \(screenState())")
        let backupRow = app.buttons.matching(identifier: "backupRow").firstMatch
        for _ in 0..<10 where !(backupRow.exists && backupRow.isHittable) {
            app.swipeUp()
            _ = backupRow.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(backupRow.exists, "Backup row missing in the Me hub — \(screenState())")
        backupRow.tap()
        let toggle = element("autoBackupToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "the Backup screen did not open — \(screenState())")

        // The progress section is below the fold. `runBackupButton` and `cancelBackupButton` are the two
        // exclusive branches of `if vm.running`: a hittable Run button proves no pass is running, so the
        // picture cannot show a thumbnail of the simulator's own library.
        let runButton = row("runBackupButton", swiping: "up")
        if !(runButton.exists && runButton.isHittable) {
            XCTFail((app.buttons.matching(identifier: "cancelBackupButton").firstMatch.exists
                     ? "a backup is running: the capture would show a photo of the simulator's library"
                     : "the Backup screen has no Run now button in its progress section")
                    + " — \(screenState())")
        }

        // Back to the top, never one swipe too many: at the top of the list a swipe pulls the hub sheet down.
        let toggleOnScreen = { toggle.exists && toggle.isHittable }
        for _ in 0..<10 where !toggleOnScreen() {
            app.swipeDown()
            _ = waitUntil(1.5, toggleOnScreen)
        }
        XCTAssertTrue(toggleOnScreen(), "the Backup screen did not scroll back to its top")

        // The count of photos left to back up: a number above 0 (— means Photos access is missing).
        let count = element("backupRemainderCount")
        XCTAssertTrue(count.waitForExistence(timeout: 30), "backupRemainderCount is missing — \(screenState())")
        var label = ""
        let counted = waitUntil(30) {
            label = count.label
            return (Int(label.filter(\.isWholeNumber)) ?? 0) > 0
        }
        if !counted {
            XCTFail((label == "—"
                     ? "Photos access is not granted (backupRemainderCount reads —): simctl privacy grant did not hold"
                     : "backupRemainderCount reads \(label), expected a count above 0")
                    + " — \(screenState())")
        }
        try capture("backup")
    }
}
