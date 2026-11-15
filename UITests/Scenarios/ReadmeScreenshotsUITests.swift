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

    // MARK: - The five screens

    func test_AC_7_capturesTheFiveScreens() throws {
        get("/__reset")
        get("/__provider?mode=manual")
        signIn()

        // 1. Photos: the first and last tiles of the first screen, no skeleton, no banner.
        XCTAssertTrue(element("assetTile_\(photoID(1))").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub)")
        XCTAssertTrue(element("assetTile_\(photoID(9))").exists, "the grid has fewer than nine tiles")
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
        XCTAssertTrue(element("albumCard_\(albumID(4))").waitForExistence(timeout: 20), "the albums did not load")
        XCTAssertFalse(element("albumsEmptyState").exists, "Albums shows its empty state")
        try capture("albums")

        // 4. Search: a word that matches photos, keyboard dismissed.
        openTab(["Search", "Recherch"])
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("nature\n") // the return key submits the search and dismisses the keyboard
        let results = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_cccccccc'")).firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 30), "the search returned no photo")
        XCTAssertFalse(element("searchEmptyState").exists, "Search shows its empty state")
        try capture("search")

        // 5. Backup: the Me hub's Backup screen.
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        let backupRow = app.buttons.matching(identifier: "backupRow").firstMatch
        for _ in 0..<10 where !(backupRow.exists && backupRow.isHittable) {
            app.swipeUp()
            _ = backupRow.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(backupRow.exists, "Backup row missing in the Me hub")
        backupRow.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "runBackupButton").firstMatch.waitForExistence(timeout: 20),
                      "the Backup screen has no Run now button")
        try capture("backup")
    }
}
