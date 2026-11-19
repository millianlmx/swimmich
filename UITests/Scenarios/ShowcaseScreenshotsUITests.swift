import XCTest

/// Takes the showcase pictures of `README.md` and `README.fr.md`
/// (`docs/showcase/*.png`) on a real Immich library: every feature, from the
/// timeline to Wrapped. Run it with `Scripts/showcase.sh`, which records the
/// simulator's screen for the demo video while it runs.
///
/// Not a regression scenario: each step looks for its screen, waits for it to
/// settle and writes the picture; a step that cannot reach its screen is
/// reported and the walk goes on (`continueAfterFailure`). It skips unless
/// `SWIMMICH_SHOWCASE_DIR` and the server's address and account are set
/// (`TEST_RUNNER_` prefix: Xcode hands `TEST_RUNNER_<NAME>` to the runner as
/// `<NAME>`). `MARK <name> <unix time>` lines tell the video where each
/// player is on screen.
///
/// Its helpers are copied from `ReadmeScreenshotsUITests` on purpose (the
/// repository's rule: no shared UI-test support file).
final class ShowcaseScreenshotsUITests: XCTestCase {

    private var app: XCUIApplication!
    private var outputDirectory: URL!
    private var server = ""
    private var email = ""
    private var password = ""

    /// The album the album features run on, and the words the reel is made of.
    private let album = ProcessInfo.processInfo.environment["SWIMMICH_SHOWCASE_ALBUM"] ?? "Mountains"
    private let query = ProcessInfo.processInfo.environment["SWIMMICH_SHOWCASE_QUERY"] ?? "beach"
    /// The person Growing Up runs on (the first of the list when not found).
    private let person = ProcessInfo.processInfo.environment["SWIMMICH_SHOWCASE_PERSON"] ?? "The 11x Developer"

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["SWIMMICH_SHOWCASE_DIR"], let server = env["SWIMMICH_SHOWCASE_SERVER"],
              let email = env["SWIMMICH_SHOWCASE_EMAIL"], let password = env["SWIMMICH_SHOWCASE_PASSWORD"] else {
            throw XCTSkip("SWIMMICH_SHOWCASE_* is not set; run Scripts/showcase.sh")
        }
        self.server = server
        self.email = email
        self.password = password
        outputDirectory = URL(fileURLWithPath: folder, isDirectory: true)
        // On a device the folder is the Mac's: the pictures travel as the test's
        // attachments instead (Scripts/showcase.sh extracts them).
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    // MARK: - Helpers (copied from ReadmeScreenshotsUITests)

    /// Writes `<name>.png` after `settle` seconds (the pictures load
    /// asynchronously; nothing in the accessibility tree says "decoded").
    private func capture(_ name: String, settle: TimeInterval = 3) {
        Thread.sleep(forTimeInterval: settle)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if (try? screenshot.pngRepresentation.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)) != nil {
            print("SHOT \(name).png")
        }
    }

    /// A player on screen from now: the video cuts its clip from here.
    private func mark(_ name: String) {
        print("MARK \(name) \(Date().timeIntervalSince1970)")
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Taps `target` once it is on screen and hittable. A tap on an element
    /// that is not hittable throws and ends the whole walk: the step is
    /// reported instead, and the walk goes on.
    @discardableResult
    private func safeTap(_ target: XCUIElement, _ what: String, timeout: TimeInterval = 20) -> Bool {
        let onScreen = { target.exists && target.isHittable }
        // A system prompt ("Save password?") can come up at any time and cover the screen.
        guard waitUntil(timeout, onScreen) || { dismissSystemPrompts(); return waitUntil(10, onScreen) }() else {
            XCTFail("\(what) is not on screen — \(screenState())")
            return false
        }
        target.tap()
        return true
    }

    @discardableResult
    private func tap(_ identifier: String, timeout: TimeInterval = 20) -> Bool {
        safeTap(element(identifier), identifier, timeout: timeout)
    }

    @discardableResult
    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            return safeTap(candidate, "button \(labels)", timeout: 5)
        }
        return false
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    /// What the screen reads, from one snapshot of the accessibility tree: the
    /// screen can change between two queries, and a query on an element gone
    /// fails the walk.
    private func screenState() -> String {
        guard let root = try? app.snapshot() else { return "no snapshot" }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, !node.label.isEmpty, texts.count < 15 { texts.append(node.label) }
            if node.elementType == .button, !node.label.isEmpty, buttons.count < 15 { buttons.append(node.label) }
            node.children.forEach(walk)
        }
        walk(root)
        return "screen reads \(texts), buttons \(buttons)"
    }

    private func openTab(_ labels: [String]) {
        let tab = app.tabBars.buttons.matching(labelPredicate(labels)).firstMatch
        safeTap(tab, "tab \(labels)")
    }

    /// Waits for a full-screen feature to leave its preparation (`preparing`
    /// gone) — the walk does not fail when it takes long, it captures anyway.
    private func waitForPreparation(_ preparing: String, timeout: TimeInterval) {
        let loading = element(preparing)
        _ = waitUntil(timeout) { !loading.exists }
    }

    // MARK: - Sign-in

    private func signIn() {
        app.launch()
        let getStarted = app.buttons.matching(labelPredicate(["Get Started"])).firstMatch
        if !getStarted.waitForExistence(timeout: 20), app.tabBars.firstMatch.exists {
            dismissSystemPrompts()
            return
        }
        XCTAssertTrue(tapAnyButton(["Get Started"], timeout: 40), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        safeTap(field, "the server field")
        // A field seeded with an earlier server: put the cursor at its end before
        // deleting, or what follows a mid-text cursor stays glued to the new URL.
        for _ in 0..<3 where (field.value as? String) != server {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            let seeded = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count + 8))
            field.typeText(server)
        }
        XCTAssertEqual(field.value as? String, server, "the server field holds another address")
        XCTAssertTrue(tapAnyButton(["Check connection"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue"])).firstMatch.waitForExistence(timeout: 30),
                      "Server never became reachable")
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            tapAnyButton(["Continue"])
            onLogin = element("loginEmailField").waitForExistence(timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear")
        safeTap(element("loginEmailField"), "the email field")
        element("loginEmailField").typeText(email)
        safeTap(element("loginPasswordField"), "the password field")
        element("loginPasswordField").typeText(password)
        tap("loginSignInButton")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "Sign-in did not reach the shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 8) { whatsNewDone.tap() }
        dismissSystemPrompts()
    }

    /// Notifications, Photos access, "Save password?": whatever the system
    /// asks, the walk declines. The prompts are in the simulator's language
    /// (not the app's), and "Save password?" is drawn in the app's process.
    private func dismissSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Not Now", "Pas maintenant", "Plus tard", "Don’t Allow", "Don't Allow", "Ne pas autoriser", "Never", "Jamais"]
        for _ in 0..<4 {
            var dismissed = false
            for process in [app!, springboard] {
                for label in labels {
                    let button = process.buttons[label]
                    if button.exists, button.isHittable {
                        button.tap()
                        dismissed = true
                    }
                }
            }
            if !dismissed { return }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Saving to the photo library asks for access the first time: the walk allows it.
    private func allowPhotosAccess() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow Full Access", "Allow", "OK", "Autoriser l’accès complet", "Autoriser"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 4), button.isHittable {
                button.tap()
                return
            }
        }
    }

    // MARK: - The walk

    /// `SWIMMICH_SHOWCASE_ONLY` (comma-separated: photos, albums, search, map,
    /// people, memories, wrapped) runs those steps alone — Growing Up needs
    /// Vision, which a simulator cannot run, so it is taken on a device.
    func test_capturesTheShowcase() throws {
        let only = Set((ProcessInfo.processInfo.environment["SWIMMICH_SHOWCASE_ONLY"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let steps: [(String, () -> Void)] = [
            ("photos", photos), ("albums", albumFeatures), ("search", search), ("map", map),
            ("people", people), ("memories", memories), ("wrapped", wrapped),
        ]
        signIn()
        for (name, step) in steps where only.isEmpty || only.contains(name) { step() }
    }

    private func photos() {
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 40), "the timeline never rendered")
        capture("timeline", settle: 5)
        // The tiles report no hit point under the floating header and scrubber:
        // a point in the middle of the grid opens the photo there.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55)).tap()
        if element("viewerBackButton").waitForExistence(timeout: 20) {
            capture("viewer", settle: 4)
            tap("viewerBackButton")
        }
    }

    /// Opens the showcase album from the Albums tab (scrolled to).
    private func openAlbum() -> Bool {
        openTab(["Albums"])
        _ = element("albumsLibrarySection").waitForExistence(timeout: 20)
        let title = app.staticTexts.matching(NSPredicate(format: "label == %@", album)).firstMatch
        for _ in 0..<40 where !(title.exists && title.isHittable) {
            app.swipeUp()
            _ = title.waitForExistence(timeout: 1)
        }
        guard title.exists else {
            XCTFail("album \(album) not found — \(screenState())")
            return false
        }
        guard safeTap(title, "album \(album)") else { return false }
        return element("albumDetailEmptyState").waitForExistence(timeout: 3) == false
    }

    /// Opens the album's ⋯ menu and picks `items` (its label, or the name
    /// iOS reads for its icon). A menu left open covers every later step: it
    /// is closed when the item is not there.
    private func albumMenu(_ items: [String]) -> Bool {
        let menu = app.buttons.matching(labelPredicate(["Album actions"])).firstMatch
        guard safeTap(menu, "the album menu") else { return false }
        if tapAnyButton(items, timeout: 10) { return true }
        XCTFail("no \(items) in the album menu — \(screenState())")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        return false
    }

    private func albumFeatures() {
        openTab(["Albums"])
        capture("albums", settle: 4)
        guard openAlbum() else { return }
        capture("album", settle: 5)

        if albumMenu(["Road Trip"]) {
            waitForPreparation("roadTripPreparing", timeout: 90)
            _ = element("roadTripPlayer").waitForExistence(timeout: 30)
            mark("roadtrip")
            Thread.sleep(forTimeInterval: 8)
            capture("roadtrip", settle: 6)
            tap("roadTripCloseButton")
        }
        if albumMenu(["Color Mosaic", "Small Grid"]) {
            _ = element("colorMosaicPreview").waitForExistence(timeout: 30)
            capture("mosaic", settle: 25)
            tap("colorMosaicCloseButton")
        }
        if albumMenu(["Photo Dump"]) {
            waitForPreparation("photoDumpPreparing", timeout: 90)
            capture("photodump", settle: 6)
            tap("photoDumpCloseButton")
        }
        if albumMenu(["Reel"]) {
            waitForPreparation("reelPreparing", timeout: 90)
            _ = element("reelPlayer").waitForExistence(timeout: 30)
            mark("reel")
            capture("reel", settle: 4)
            Thread.sleep(forTimeInterval: 10)
            tap("reelCloseButton")
        }
    }

    private func search() {
        openTab(["Photos"])
        let searchTab = app.tabBars.buttons.matching(labelPredicate(["Search"])).firstMatch
        guard safeTap(searchTab, "the Search tab") else { return }
        capture("explore", settle: 5)
        let field = app.searchFields.firstMatch
        guard safeTap(field, "the search field") else { return }
        field.typeText("\(query)\n")
        let result = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40), "the search returned no photo")
        capture("search", settle: 5)
        if tap("searchReelButton") {
            waitForPreparation("reelPreparing", timeout: 90)
            _ = element("reelPlayer").waitForExistence(timeout: 30)
            mark("searchreel")
            capture("searchreel", settle: 1)
            Thread.sleep(forTimeInterval: 10)
            tap("reelCloseButton")
        }
        // Back to Explore: the field's ✕ clears the words, the ✕ beside it
        // closes the search (and its keyboard), so the map preview shows again.
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists && clear.isHittable { clear.tap() }
        let close = app.buttons.matching(labelPredicate(["Close", "Cancel"])).firstMatch
        if close.waitForExistence(timeout: 3), close.isHittable { close.tap() }
        if app.keyboards.count > 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        }
    }

    private func map() {
        let entry = element("searchMapEntry")
        for _ in 0..<6 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        guard safeTap(entry, "the map entry") else { return }
        capture("map", settle: 10)
        if tap("mapPosterButton") {
            _ = element("mapPosterPreview").waitForExistence(timeout: 60)
            capture("mapposter", settle: 4)
            tap("mapPosterCloseButton")
        }
        tap("searchMapClose", timeout: 5)
    }

    private func people() {
        openTab(["Albums"])
        let row = element("peopleRow")
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeDown() }
        guard tap("peopleRow") else { return }
        _ = element("peopleScreen").waitForExistence(timeout: 20)
        capture("people", settle: 5)
        let named = app.staticTexts.matching(NSPredicate(format: "label == %@", person)).firstMatch
        for _ in 0..<8 where !(named.exists && named.isHittable) { app.swipeUp() }
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'personRow_'")).firstMatch
        guard safeTap(named.exists ? named : first, "the person \(person)") else { return }
        if tap("personGrowingUpAction") {
            waitForPreparation("growingUpPreparing", timeout: 180)
            _ = element("growingUpPlayer").waitForExistence(timeout: 30)
            mark("growingup")
            capture("growingup", settle: 4)
            Thread.sleep(forTimeInterval: 8)
            // The exported film is the video's clip: it stays in the app's
            // temporary folder, where Scripts/showcase.sh copies it from.
            if tap("growingUpExportButton") {
                allowPhotosAccess()
                if element("growingUpSaved").waitForExistence(timeout: 180) {
                    print("EXPORTED growingup")
                    // The film lives in the app's tmp only while this screen is open:
                    // showcase.sh copies it off the device meanwhile.
                    _ = app.staticTexts["never"].waitForExistence(timeout: 45)
                }
            }
            tap("growingUpCloseButton")
        }
    }

    private func memories() {
        openTab(["Memories"])
        capture("memories", settle: 6)
        guard tap("memoriesThenAndNowButton") else { return }
        waitForPreparation("thenAndNowLoading", timeout: 120)
        capture("thenandnow-list", settle: 4)
        let spot = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'thenAndNowSpot_'")).firstMatch
        if spot.waitForExistence(timeout: 10), safeTap(spot, "a then and now spot") {
            waitForPreparation("thenAndNowPreparing", timeout: 60)
            let picture = element("thenAndNowPicture")
            if picture.waitForExistence(timeout: 30) {
                mark("thenandnow")
                // Sweep from one year to the other.
                let left = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
                let right = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                left.press(forDuration: 0.1, thenDragTo: right)
                right.press(forDuration: 0.1, thenDragTo: picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                capture("thenandnow", settle: 2)
            }
            safeTap(app.navigationBars.buttons.firstMatch, "back")
        }
        safeTap(app.navigationBars.buttons.firstMatch, "back")
    }

    private func wrapped() {
        openTab(["Memories"])
        guard tap("memoriesWrappedButton") else { return }
        // The demo library ends before this year: last year's story.
        waitForPreparation("wrappedLoading", timeout: 120)
        if tap("wrappedYearMenu", timeout: 10) {
            let lastYear = String(Calendar.current.component(.year, from: Date()) - 1)
            tapAnyButton([lastYear], timeout: 10)
        }
        waitForPreparation("wrappedLoading", timeout: 240)
        _ = element("wrappedCard_intro").waitForExistence(timeout: 30)
        mark("wrapped")
        let names = ["wrapped-intro", "wrapped-months", "wrapped-people", "wrapped-places", "wrapped-colors", "wrapped-best", "wrapped-outro"]
        for (index, name) in names.enumerated() {
            if index > 0 { app.swipeLeft() }
            capture(name, settle: 2)
        }
        tap("wrappedCloseButton")
    }
}
