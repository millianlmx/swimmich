import XCTest

/// Photographs and measures the Search tab (Results mode) in seven states, for the before/after
/// comparison of the Search redesign: home, suggestions, results, filters-sheet, no-results-filtered,
/// filtered, selection. Each state writes `<series>-<state>.png` and `<series>-<state>.txt`.
///
/// This is not a regression scenario: it skips unless `SWIMMICH_CAPTURE_DIR` is set, so no suite writes
/// files by accident (that is also why it has no line in `Scripts/ci-ui-scenarios.txt`). Run it with
/// `Scripts/search-captures.sh <before|after>`, which starts the stub (`immich_stub_readme_screenshots.py`),
/// pins the simulator's status bar and passes the folder and the series (`TEST_RUNNER_` prefix: Xcode hands
/// `TEST_RUNNER_<NAME>` to the test runner as `<NAME>`). `Scripts/ci-search-captures.sh` publishes the files.
///
/// It reaches the screen only through identifiers that survive the redesign (`searchFilterButton`,
/// `searchFilterCity`, `searchFilterDone`, `searchFilterChip_city`, `searchEmptyState`, `searchNoResultsReset`,
/// `searchSelectionCount`, `searchMapEntry`, `assetTile_<id>`) and never targets a control of the old top bar,
/// so the same file photographs the original layout and the new one.
///
/// One `XCTestCase` per feature, in its own file: the helpers are copied from `ReadmeScreenshotsUITests` on
/// purpose (the repository's rule: no shared UI-test support file).
final class SearchCapturesUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var outputDirectory: URL!
    private var series = ""

    private struct SavedEntry: Encodable {
        let id: String
        let name: String
        let query: String
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["SWIMMICH_CAPTURE_DIR"] else {
            throw XCTSkip("SWIMMICH_CAPTURE_DIR is not set; run Scripts/search-captures.sh")
        }
        series = environment["SWIMMICH_CAPTURE_SERIES"] ?? ""
        guard series == "before" || series == "after" else {
            XCTFail("SWIMMICH_CAPTURE_SERIES must be before or after, not '\(series)'")
            throw CaptureError.badSeries
        }
        outputDirectory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Recent and saved searches come from the UserDefaults argument domain: the app is not touched.
        let saved = try JSONEncoder().encode([SavedEntry(id: "capture-saved-1", name: "Garden flowers", query: "flower")])
        let hex = "<" + saved.map { String(format: "%02x", $0) }.joined() + ">"
        app.launchArguments += ["-recentSearches", "(\"sunset\", \"autumn\")", "-savedSearches", hex]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    private enum CaptureError: Error { case badSeries }

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

    // MARK: - Capture and measure

    /// Writes `<series>-<state>.png`, then `<series>-<state>.txt` measured on the same screen. The pictures load
    /// asynchronously and nothing in the accessibility tree says "decoded": a short, bounded pause.
    private func capture(_ state: String) throws {
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = springboard.alerts.allElementsBoundByIndex + app.alerts.allElementsBoundByIndex
        let buttons = alerts.flatMap { $0.buttons.allElementsBoundByIndex.map(\.label) }
        XCTAssertTrue(alerts.isEmpty, "\(state): an alert is on screen: \(buttons.joined(separator: ", "))")
        let data = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertGreaterThan(data.count, 50_000, "\(state): the screenshot is nearly empty")
        try data.write(to: outputDirectory.appendingPathComponent("\(series)-\(state).png"), options: .atomic)
        let measure = measurement(of: state)
        try Data(measure.utf8).write(to: outputDirectory.appendingPathComponent("\(series)-\(state).txt"), options: .atomic)
        print("SHOT \(series)-\(state).png")
    }

    /// The six-line measure of a state: the buttons within reach (not the tiles, the filter chips, the reset
    /// and retry buttons, the tab bar, the clear/Cancel/Close buttons of the search field, nor what lies
    /// outside the window), whether the search field sits in the top quarter of the window, and whether a
    /// filter chip is on screen.
    private func measurement(of state: String) -> String {
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        let tabFrame: CGRect? = tabBar.exists ? tabBar.frame : nil
        let field = app.searchFields.firstMatch
        let fieldFrame: CGRect? = field.exists ? field.frame : nil
        var names: [String] = []
        for button in app.buttons.allElementsBoundByIndex where button.exists && button.isHittable {
            let identifier = button.identifier
            let frame = button.frame
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if identifier.hasPrefix("assetTile_") || identifier.hasPrefix("searchFilterChip") { continue }
            if identifier == "searchActiveFiltersClear" || identifier == "searchNoResultsReset"
                || identifier.hasSuffix("ErrorRetry") { continue }
            if let tabFrame, tabFrame.contains(center) { continue }
            if let fieldFrame {
                if fieldFrame.contains(frame) { continue }
                if identifier.isEmpty, frame.midY >= fieldFrame.minY, frame.midY <= fieldFrame.maxY,
                   ["Cancel", "Close"].contains(button.label) { continue }
            }
            if !window.contains(center) { continue }
            names.append(identifier.isEmpty ? button.label : identifier)
        }
        let fieldAtTop = field.exists && field.isHittable && field.frame.minY < window.height * 0.25
        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'searchFilterChip_'")).firstMatch.exists
        return "series: \(series)\nstate: \(state)\nbuttons: \(names.count)\n"
            + "controls: \(names.sorted().joined(separator: " | "))\n"
            + "field_at_top: \(fieldAtTop ? "yes" : "no")\nchips: \(chips ? "yes" : "no")\n"
    }

    // MARK: - Helpers (copied from ReadmeScreenshotsUITests)

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

    /// Selects the Photos tab and waits until it is the selection. The Search bubble lands on Search only when
    /// the last content tab is Photos (`RootView`, `onChange(of: selection)`).
    private func selectPhotosTab() {
        let photos = app.tabBars.buttons.matching(labelPredicate(["Photos"])).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 20), "no Photos tab — \(screenState())")
        photos.tap()
        XCTAssertTrue(waitUntil(10) { photos.isSelected }, "the Photos tab was not selected — \(screenState())")
    }

    /// Opens the Search tab and returns its search field. From Albums the Search bubble is a "+" that opens
    /// New Album and puts Albums back (`handleBubbleTap`), so Photos is selected first.
    private func openSearchField() -> XCUIElement {
        selectPhotosTab()
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "no Search tab — \(screenState())")
        searchTab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field — \(screenState())")
        return field
    }

    // MARK: - The seven states

    private var firstTile: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_cccccccc'")).firstMatch
    }

    /// The first tile of the grid that can be touched (a tile of a lazy grid can exist below the fold).
    private func touchableTile() -> XCUIElement? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_cccccccc'"))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    private func openFiltersSheet(_ state: String) {
        let button = element("searchFilterButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20), "\(state): no searchFilterButton — \(screenState())")
        button.tap()
        XCTAssertTrue(element("searchFilterCity").waitForExistence(timeout: 20),
                      "\(state): the Filters sheet did not open — \(screenState())")
    }

    private func closeFiltersSheet() {
        let done = element("searchFilterDone")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no searchFilterDone — \(screenState())")
        done.tap()
    }

    func test_AC_1_capturesTheSevenSearchStates() throws {
        get("/__reset")
        get("/__provider?mode=manual")
        signIn()

        // 1. Home: Explore (its Map entry first), before any search.
        let field = openSearchField()
        XCTAssertTrue(element("searchMapEntry").waitForExistence(timeout: 20),
                      "home: no searchMapEntry — \(screenState())")
        try capture("home")

        // 2. Suggestions: the empty field lists the seeded saved and recent searches.
        field.tap()
        let listed = waitUntil(15) {
            self.app.staticTexts.matching(self.labelPredicate(["Garden flowers"])).firstMatch.exists
                && self.app.staticTexts.matching(self.labelPredicate(["sunset"])).firstMatch.exists
        }
        XCTAssertTrue(listed, "suggestions: the seeded searches are not listed (launch-argument defaults) — \(screenState())")
        try capture("suggestions")

        // 3. Results: a word that matches photos, keyboard dismissed by the return key.
        field.typeText("nature\n")
        let shown = waitUntil(30) { self.firstTile.exists && self.firstTile.isHittable && !self.element("searchEmptyState").exists }
        XCTAssertTrue(shown, "results: no touchable photo for 'nature' — \(screenState())")
        try capture("results")

        // 4. Filters sheet, empty.
        openFiltersSheet("filters-sheet")
        try capture("filters-sheet")

        // 5. A city no photo of 'nature' is in: no results, filters active.
        let city = element("searchFilterCity")
        city.tap()
        city.typeText("Hong Kong")
        closeFiltersSheet()
        let empty = waitUntil(30) { self.element("searchEmptyState").exists && self.element("searchNoResultsReset").exists }
        XCTAssertTrue(empty, "no-results-filtered: no empty state with a reset button — \(screenState())")
        try capture("no-results-filtered")

        // 6. Filtered: the city replaced by one where 'nature' photos were taken.
        openFiltersSheet("filtered")
        let cityField = element("searchFilterCity")
        cityField.tap()
        let current = (cityField.value as? String) ?? ""
        cityField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        cityField.typeText("Québec")
        closeFiltersSheet()
        let filtered = waitUntil(30) { self.element("searchFilterChip_city").exists && self.touchableTile() != nil }
        XCTAssertTrue(filtered, "filtered: no city chip with photos — \(screenState())")
        try capture("filtered")

        // 7. Selection: a long press on the first tile starts it; the test stops there.
        guard let tile = touchableTile() else {
            XCTFail("selection: no touchable tile — \(screenState())")
            return
        }
        tile.press(forDuration: 1.0)
        XCTAssertTrue(element("searchSelectionCount").waitForExistence(timeout: 15),
                      "selection: the long press did not start the selection — \(screenState())")
        try capture("selection")
    }
}
