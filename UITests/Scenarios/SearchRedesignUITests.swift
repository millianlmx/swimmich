import XCTest

/// End-to-end scenarios for the redesigned Results screen of the Search tab: a bar of four
/// commands (Filters, the "Search options" menu, sync, avatar), the menu that holds the text
/// modes, the detected-text toggle, "Save search…" and "Select", the one rating control in the
/// Filters sheet, and the chips of the active criteria over the grid and over "No results".
///
/// They run against `immich_stub_search_filters.py` (`/__reset`, `/__version`, `/__requests`,
/// `/__paging`) — except the error state, which runs against `immich_stub_list_states.py` — so each
/// test asserts what the screen shows AND what was sent. Tests name controls by
/// `accessibilityIdentifier`, never by localized text, except where the text is the criterion
/// (the field's invite, a mode's title, a saved search's name); the app runs in English.
///
/// Run one with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/search-redesign.uitest.log \
///         UITests/stubs/immich_stub_search_filters.py SearchRedesignUITests/test_AC_2 --erase
///
/// The helpers are copies of the neighbouring scenarios' (no shared support file, by the repo's rule):
/// the stub session of `SearchCriteriaUITests`, the measure of `SearchCapturesUITests` and the
/// overlap checks of `DynamicTypeUITests`.
final class SearchRedesignUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var launched = false

    // The stub's fixtures: "plage" finds P3 and P4.
    private let p3 = "f1000000-0000-4000-8000-000000000003"
    private let p4 = "f1000000-0000-4000-8000-000000000004"

    /// The button counts `SearchCapturesUITests` measured on the unchanged screen (series
    /// `before`, commit 9377e9e of `ci/search-captures-before`).
    private let buttonsBefore = ["home": 8, "results": 9, "filtered": 9, "no-results-filtered": 8]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - Stub plumbing

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

    private func stubGET(_ path: String, timeout: TimeInterval = 10) -> String? {
        guard let url = URL(string: "\(stub)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var body: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else { return nil }
        return body
    }

    private func reset() {
        let body = stubGET("/__reset")
        XCTAssertEqual(body?.contains("\"reset\"") ?? false, true,
                       "the stub did not answer /__reset (got \(body ?? "nothing"))")
    }

    private func setServerVersion(major: Int, minor: Int) {
        let expected = "{\"version\": \"\(major).\(minor).0\"}"
        XCTAssertEqual(stubGET("/__version?major=\(major)&minor=\(minor)"), expected,
                       "the stub did not take the server generation \(major).\(minor)")
    }

    private func setProvider(_ mode: String) {
        XCTAssertEqual(stubGET("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}", "Stub did not answer /__provider")
    }

    // MARK: - Session (welcome → login → Search tab)

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func screenText() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
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

    private enum Launch: Equatable { case welcome, shell, neither }

    private func welcomeOrShell() -> Launch {
        if app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch.exists { return .shell }
        if app.staticTexts.matching(labelPredicate(["Your photo library", "Votre photothèque"])).firstMatch.exists {
            return .welcome
        }
        return .neither
    }

    private func waitForEither(timeout: TimeInterval, _ probe: () -> Launch) -> Launch {
        let deadline = Date().addingTimeInterval(timeout)
        var state = probe()
        while state == .neither && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            state = probe()
        }
        return state
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
        for label in ["Continue", "Continuer"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

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

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
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
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = app.staticTexts.matching(labelPredicate(loginCopy)).firstMatch.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenText())")
    }

    private func reachAuthenticatedShell() {
        app.launch()
        if waitForEither(timeout: 30, welcomeOrShell) == .welcome {
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "the authenticated shell never appeared — \(screenText())")
        XCTAssertFalse(stubRequests().isEmpty,
                       "the app has sent \(stub) nothing — a session restored from another slot's port?")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
    }

    private func openSearchTab() {
        let tab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30),
                      "no Search tab — tab bar reads: \(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        tab.tap()
    }

    /// A fresh session against the generation asked for. The first call of a test resets the stub;
    /// the next ones relaunch the app (a version probe is cached per session) and keep the request
    /// log, which is read from the mark `sessionMark` records.
    private var sessionMark = 0

    private func startSession(major: Int, minor: Int) {
        if launched {
            app.terminate()
        } else {
            reset()
            setProvider("manual")
        }
        setServerVersion(major: major, minor: minor)
        reachAuthenticatedShell()
        openSearchTab()
        launched = true
        sessionMark = stubRequests().count
    }

    // MARK: - Screen helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func count(_ identifier: String) -> Int {
        app.descendants(matching: .any).matching(identifier: identifier).count
    }

    private func staticText(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    private var searchField: XCUIElement { app.searchFields.firstMatch }

    /// Types `text` and presses return: the search runs and the keyboard goes away.
    private func typeQuery(_ text: String) {
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "the search field is missing — \(screenText())")
        searchField.tap()
        searchField.typeText(text + "\n")
        XCTAssertTrue(waitUntil(5) { self.app.keyboards.count == 0 }, "the keyboard stayed up after return")
    }

    private func clearQuery(_ current: String) {
        searchField.tap()
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    private var firstTile: XCUIElement? {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    private func waitForTile(_ what: String) {
        XCTAssertTrue(waitUntil(30) { self.firstTile != nil }, "\(what): no touchable photo — \(screenText())")
    }

    /// "plage" submitted, and its photos on screen.
    private func searchBeach() {
        typeQuery("plage")
        waitForTile("results of plage")
    }

    private func openFilters() {
        let button = element("searchFilterButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Filters button is not in the Search bar — \(screenText())")
        button.tap()
        XCTAssertTrue(element("searchFilterSheet").waitForExistence(timeout: 20),
                      "the Filters sheet never opened — \(screenText())")
    }

    /// A control of the Filters sheet, scrolled into view if the `Form` has not drawn it yet.
    private func sheetControl(_ identifier: String) -> XCUIElement {
        let control = element(identifier)
        let deadline = Date().addingTimeInterval(10)
        while !control.exists && Date() < deadline {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(control.exists, "`\(identifier)` is not in the Filters sheet — \(screenText())")
        return control
    }

    private func tapDone() {
        let done = element("searchFilterDone")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the sheet's Done button is missing")
        done.tap()
        XCTAssertTrue(element("searchFilterSheet").waitForNonExistence(timeout: 10), "the Filters sheet did not close")
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back")
        back.tap()
        sleep(1)
    }

    /// The Photos option of the Type picker, wherever the picker draws its options (a menu or a pushed
    /// list); the tab bar's own "Photos" is not it.
    private func choosePhotosType() {
        sheetControl("searchFilterType").tap()
        let tabs = app.tabBars.firstMatch
        func option() -> XCUIElement? {
            let tabFrame: CGRect? = tabs.exists ? tabs.frame : nil
            let candidates = app.buttons.matching(NSPredicate(format: "label == 'Photos'")).allElementsBoundByIndex
                + app.staticTexts.matching(NSPredicate(format: "label == 'Photos'")).allElementsBoundByIndex
            return candidates.first { candidate in
                guard candidate.exists, candidate.isHittable else { return false }
                if let tabFrame, tabFrame.contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)) { return false }
                return true
            }
        }
        XCTAssertTrue(waitUntil(10) { option() != nil }, "no Photos option in the Type picker — \(screenText())")
        option()?.tap()
        if !waitUntil(3, { self.element("searchFilterDone").isHittable }) { goBack() }
    }

    /// The criteria set through the sheet, then Done.
    private func applyFilters(city: String? = nil, rating: Int? = nil, photosOnly: Bool = false) {
        openFilters()
        if let rating {
            let star = app.buttons.matching(identifier: "searchFilterStar\(rating)").firstMatch
            XCTAssertTrue(star.waitForExistence(timeout: 10), "the \(rating)-star control of the sheet is missing")
            star.tap()
        }
        if photosOnly { choosePhotosType() }
        if let city {
            let field = sheetControl("searchFilterCity")
            field.tap()
            field.typeText(city)
        }
        tapDone()
    }

    // MARK: - The "Search options" menu

    private func optionItem(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    /// Any item of the open menu: the text modes, the detected-text toggle, Save and Select. The menu is
    /// open when one of them is there — not when one given mode is, since a mode that is the current one
    /// may be exposed differently from the others.
    private var menuItems: NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH 'searchTextMode_' OR identifier == 'searchOcrFilterToggle' "
                    + "OR identifier == 'searchSaveButton' OR identifier == 'searchSelectButton'")
    }

    private func menuIsOpen() -> Bool {
        app.buttons.matching(menuItems).firstMatch.exists
    }

    /// What the accessibility tree offers, for a failure message: `screenText()` reads static texts only,
    /// which says nothing of a menu's items.
    private func buttonsDump() -> String {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(60).map {
            "\($0.identifier.isEmpty ? "-" : $0.identifier)|\($0.label)|\($0.isHittable ? "hit" : "no")"
        }
        return "buttons: \(buttons) — menus: \(app.menus.count), popovers: \(app.popovers.count), "
            + "menu items: \(app.menuItems.allElementsBoundByIndex.map(\.label))"
    }

    private func openOptions() {
        let menu = optionItem("searchModeMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the Search options menu is missing — \(screenText())")
        XCTAssertTrue(waitUntil(20) { menu.isHittable }, "the Search options menu cannot be touched — \(screenText())")
        menu.tap()
        XCTAssertTrue(waitUntil(10) { self.menuIsOpen() },
                      "the menu did not open — \(screenText()) — \(buttonsDump())")
    }

    /// A touch beside the menu, which is anchored on the right.
    private func closeOptions() {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(waitUntil(5) { !self.menuIsOpen() }, "the menu did not close — \(screenText()) — \(buttonsDump())")
    }

    /// Picks a text mode: the menu, then `searchTextMode_<mode>`; returns once the menu answers again.
    private func chooseMode(_ mode: String) {
        openOptions()
        let item = optionItem("searchTextMode_\(mode)")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no `searchTextMode_\(mode)` item — \(screenText())")
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "the menu did not close after `\(mode)` — \(screenText())")
        let menu = optionItem("searchModeMenu")
        XCTAssertTrue(waitUntil(5) { menu.exists && menu.isHittable }, "the menu's button never answered again — \(screenText())")
    }

    // MARK: - What is within reach

    /// The buttons within reach of the screen, by the measure of `SearchCapturesUITests`: not the tiles,
    /// the filter chips, the reset and retry buttons, the tab bar, the clear/Cancel/Close buttons of the
    /// search field, nor what lies outside the window. With `region`, only those centred in it.
    private func countedButtons(inside region: CGRect? = nil) -> [XCUIElement] {
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        let tabFrame: CGRect? = tabBar.exists ? tabBar.frame : nil
        let field = app.searchFields.firstMatch
        let fieldFrame: CGRect? = field.exists ? field.frame : nil
        var found: [XCUIElement] = []
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
            if let region, !region.contains(center) { continue }
            found.append(button)
        }
        return found
    }

    private func name(of button: XCUIElement) -> String {
        button.identifier.isEmpty ? button.label : button.identifier
    }

    private func reachableControls() -> [String] {
        countedButtons().map(name(of:)).sorted()
    }

    /// The bar of the screen: exactly its four commands, and no system overflow.
    private func assertBar(_ what: String) {
        XCTAssertTrue(waitUntil(20) { self.element("profileAvatar").exists && self.element("profileAvatar").isHittable },
                      "\(what): the bar never settled — \(screenText())")
        let bar = app.navigationBars.firstMatch.frame
        let controls = countedButtons(inside: bar).map(name(of:)).sorted()
        XCTAssertEqual(controls, ["profileAvatar", "searchFilterButton", "searchModeMenu", "syncStatusButton"],
                       "\(what): the bar holds \(controls)")
        let overflow = app.buttons.allElementsBoundByIndex.filter {
            $0.identifier == "OverflowBarButtonItem" || $0.label == "More"
        }
        XCTAssertTrue(overflow.isEmpty, "\(what): the system folded commands into an overflow button — \(overflow.map(name(of:)))")
    }

    // MARK: - Wire helpers

    private struct StubRequest {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: Any]

        var isSearch: Bool { method == "POST" && (path == "/api/search/metadata" || path == "/api/search/smart") }
        var isSmart: Bool { path == "/api/search/smart" }
        /// Metadata bodies of a v3.2+ server carry `filter`; every other body is flat.
        var structured: Bool { !isSmart && body["filter"] != nil }
        var bodyJSON: String {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        func string(_ key: String) -> String? { body[key] as? String }
        func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
        var fileName: String? { string("originalFileName") }
        var ocrMatches: String? {
            ((body["filter"] as? [String: Any])?["ocr"] as? [String: Any])?["matches"] as? String
        }
    }

    private func stubRequests() -> [StubRequest] {
        guard let raw = stubGET("/__requests"),
              let entries = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
            XCTFail("stub did not answer /__requests with JSON")
            return []
        }
        return entries.map { entry in
            StubRequest(method: entry["method"] as? String ?? "",
                        path: entry["path"] as? String ?? "",
                        params: (entry["params"] as? [String: String]) ?? [:],
                        body: (entry["body"] as? [String: Any]) ?? [:])
        }
    }

    /// The searches of the current session, in order.
    private func searches() -> [StubRequest] {
        Array(stubRequests().dropFirst(sessionMark)).filter(\.isSearch)
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.isEmpty ? "(none)" : requests.map { "\($0.method) \($0.path) body=\($0.bodyJSON)" }.joined(separator: "\n")
    }

    /// Waits for a search of the session that satisfies `condition`, and returns the last one that does.
    @discardableResult
    private func waitForSearch(_ what: String, timeout: TimeInterval = 40, after mark: Int = 0,
                               _ condition: (StubRequest) -> Bool) -> StubRequest {
        func candidates() -> [StubRequest] { Array(searches().dropFirst(mark)) }
        _ = waitUntil(timeout) { candidates().contains(where: condition) }
        guard let found = candidates().last(where: condition) else {
            XCTFail("\(what): no matching search was sent — log:\n\(describe(searches()))")
            return StubRequest(method: "", path: "", params: [:], body: [:])
        }
        return found
    }

    // MARK: - AC-2, AC-3: the bar

    func test_AC_2() {
        startSession(major: 2, minor: 0)
        assertBar("at rest, no search")
    }

    func test_AC_3() {
        startSession(major: 2, minor: 0)
        searchBeach()
        applyFilters(city: "Paris", rating: 4)
        XCTAssertTrue(element("searchFilterChip_city").waitForExistence(timeout: 30), "no city chip — \(screenText())")
        XCTAssertTrue(element("searchFilterChip_rating").waitForExistence(timeout: 30), "no rating chip — \(screenText())")
        assertBar("beach with 2 active criteria")
    }

    // MARK: - AC-3.1: the count of commands

    func test_AC_3_1() {
        startSession(major: 2, minor: 0)
        var counts: [String: [String]] = [:]

        // home
        XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "home: no prompt — \(screenText())")
        counts["home"] = reachableControls()

        // results
        searchBeach()
        counts["results"] = reachableControls()

        // filtered
        applyFilters(city: "Paris")
        XCTAssertTrue(element("searchFilterChip_city").waitForExistence(timeout: 30), "filtered: no city chip — \(screenText())")
        waitForTile("filtered")
        counts["filtered"] = reachableControls()

        // no-results-filtered
        clearQuery("plage")
        typeQuery("zzz")
        XCTAssertTrue(waitUntil(30) {
            self.element("searchEmptyState").exists && self.element("searchNoResultsReset").exists
                && self.element("searchFilterChip_city").exists
        }, "no-results-filtered: no empty state with reset and chip — \(screenText())")
        counts["no-results-filtered"] = reachableControls()

        for (state, before) in buttonsBefore.sorted(by: { $0.key < $1.key }) {
            let controls = counts[state] ?? []
            XCTAssertLessThanOrEqual(controls.count, 8, "\(state): \(controls.count) commands: \(controls)")
            XCTAssertLessThan(controls.count, before, "\(state): \(controls.count) commands, \(before) before: \(controls)")
        }
    }

    // MARK: - AC-4, AC-5: sync and avatar without the Photos tab

    func test_AC_4() {
        startSession(major: 2, minor: 0)
        searchBeach()
        let avatar = element("profileAvatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "no avatar in the Search bar — \(screenText())")
        avatar.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 10), "the Me hub did not open — \(screenText())")
    }

    func test_AC_5() {
        startSession(major: 2, minor: 0)
        searchBeach()
        let sync = element("syncStatusButton")
        XCTAssertTrue(sync.waitForExistence(timeout: 20), "no sync button in the Search bar — \(screenText())")
        sync.tap()
        XCTAssertTrue(element("syncStatusRunNow").waitForExistence(timeout: 10), "the sync status did not open — \(screenText())")
    }

    // MARK: - AC-6: the sheet keeps its sections

    func test_AC_6() {
        startSession(major: 2, minor: 0)
        openFilters()
        var swipes = 0
        for header in ["People & Tags", "Rating", "OCR text", "Location", "Camera", "Type", "Display", "Dates"] {
            let text = staticText(header)
            while !text.exists && swipes < 8 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(text.exists, "no section header '\(header)' after \(swipes) swipes — \(screenText())")
        }
    }

    // MARK: - AC-7: the file name mode in two touches

    func test_AC_7() {
        startSession(major: 2, minor: 0)
        typeQuery("plage")
        openOptions()
        let item = optionItem("searchTextMode_filename")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no File name item — \(screenText())")
        item.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5), "the menu did not close — \(screenText())")

        waitForSearch("file name", { $0.path == "/api/search/metadata" && $0.fileName == "plage" })
        XCTAssertTrue(element("searchFilterChip_originalFileName").waitForExistence(timeout: 20),
                      "no file name chip — \(screenText())")
        XCTAssertEqual(optionItem("searchModeMenu").value as? String, "File name", "the menu's value is not the current mode")
        openOptions()
        XCTAssertEqual(optionItem("searchTextMode_filename").label, "File name")
        closeOptions()
        clearQuery("plage")
        XCTAssertEqual(searchField.placeholderValue, "Search by file name", "the invite does not follow the mode")
    }

    // MARK: - AC-8: the one rating control

    func test_AC_8() {
        startSession(major: 2, minor: 0)
        openFilters()
        let star = app.buttons.matching(identifier: "searchFilterStar4").firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 10), "no 4-star control in the sheet — \(screenText())")
        star.tap()
        tapDone()
        waitForSearch("rating 4", { $0.number("rating") == 4 })
        XCTAssertTrue(element("searchFilterChip_rating").waitForExistence(timeout: 20), "no rating chip — \(screenText())")
    }

    // MARK: - AC-9, AC-10: the detected-text toggle

    func test_AC_9() {
        startSession(major: 3, minor: 2)
        chooseMode("metadata")
        typeQuery("sunset")
        openOptions()
        let toggle = optionItem("searchOcrFilterToggle")
        var enabled = toggle.exists && toggle.isEnabled
        let deadline = Date().addingTimeInterval(25)
        while !enabled && Date() < deadline {
            // The menu is read when it opens: the mode picked since is only known to a reopened one.
            closeOptions()
            openOptions()
            enabled = toggle.exists && toggle.isEnabled
        }
        XCTAssertTrue(enabled, "the detected-text toggle stayed disabled in Metadata on a 3.2 server — \(screenText())")
        toggle.tap()
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5), "the menu did not close — \(screenText())")

        waitForSearch("detected text", { $0.structured && $0.ocrMatches == "sunset" && $0.body["query"] == nil })
        openOptions()
        let latched = optionItem("searchOcrFilterToggle")
        let state = latched.label
        XCTAssertTrue(state.contains("Search typed text in detected text") && state.contains("On") && !state.contains("Off"),
                      "VoiceOver would not hear the toggle is on: label '\(state)', value \(String(describing: latched.value)) — \(buttonsDump())")
        closeOptions()
    }

    func test_AC_10() {
        startSession(major: 2, minor: 0)
        chooseMode("metadata")
        typeQuery("sunset")
        openOptions()
        let toggle = optionItem("searchOcrFilterToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no detected-text toggle in the menu — \(screenText())")
        XCTAssertFalse(toggle.isEnabled, "the detected-text toggle is on offer on a 2.0 server")
        XCTAssertTrue(toggle.label.contains("Search typed text in detected text") && toggle.label.contains("Off"),
                      "the detected-text toggle does not read off: label '\(toggle.label)'")
        closeOptions()

        openFilters()
        XCTAssertTrue(sheetControl("searchFilterVersionNotice").exists, "no version notice in the sheet")
        XCTAssertFalse(sheetControl("searchFilterOCR").isEnabled, "the sheet's OCR field is enabled on a 2.0 server")
        let withOcr = searches().filter { $0.bodyJSON.contains("\"ocr\"") }
        XCTAssertTrue(withOcr.isEmpty, "a search carried the detected-text criterion:\n\(describe(withOcr))")
    }

    // MARK: - AC-11: save a search

    func test_AC_11() {
        startSession(major: 2, minor: 0)
        typeQuery("plage")
        openOptions()
        let save = optionItem("searchSaveButton")
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save search item — \(screenText())")
        XCTAssertTrue(save.isEnabled, "Save search is disabled with a text typed")
        save.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the name alert did not come up — \(screenText())")
        let nameField = alert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "no name field in the alert")
        nameField.tap()
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: ((nameField.value as? String) ?? "plage").count))
        nameField.typeText("Beach days")
        alert.buttons["Save"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "the alert stayed up")

        clearQuery("plage")
        searchField.tap()
        let saved = staticText("Saved")
        XCTAssertTrue(saved.waitForExistence(timeout: 15), "no Saved section on the empty field — \(screenText())")
        let entry = staticText("Beach days")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the saved search is not listed — \(screenText())")
        XCTAssertGreaterThan(entry.frame.minY, saved.frame.minY, "'Beach days' is not under 'Saved'")

        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        openOptions()
        XCTAssertFalse(optionItem("searchSaveButton").isEnabled, "Save search is available with an empty field")
        closeOptions()
    }

    // MARK: - AC-12, AC-22: selection and the grid

    func test_AC_12() {
        startSession(major: 2, minor: 0)
        searchBeach()
        openOptions()
        let select = optionItem("searchSelectButton")
        XCTAssertTrue(select.waitForExistence(timeout: 10), "no Select item — \(screenText())")
        XCTAssertTrue(select.isEnabled, "Select is disabled with results on screen")
        select.tap()

        let count = element("searchSelectionCount")
        XCTAssertTrue(count.waitForExistence(timeout: 15), "the selection did not start — \(screenText())")
        XCTAssertTrue(count.label.contains("0 selected"), "the count reads '\(count.label)'")
        let cancel = element("selectionCancelButton")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "no batch bar — \(screenText())")
        cancel.tap()
        let menu = optionItem("searchModeMenu")
        XCTAssertTrue(waitUntil(15) { menu.exists && menu.isHittable }, "the bar did not come back — \(screenText())")
    }

    func test_AC_22() {
        startSession(major: 2, minor: 0)
        searchBeach()

        // A touch opens the viewer on that photo.
        let tile = element("assetTile_\(p3)")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tile for \(p3) — \(screenText())")
        tile.tap()
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer did not open — \(screenText())")
        XCTAssertTrue(element("viewerImage_\(p3)").waitForExistence(timeout: 20), "the viewer is not on \(p3) — \(screenText())")
        back.tap()

        // A long press starts the selection with that photo.
        let other = element("assetTile_\(p4)")
        XCTAssertTrue(other.waitForExistence(timeout: 20), "no tile for \(p4) — \(screenText())")
        other.press(forDuration: 1.0)
        let count = element("searchSelectionCount")
        XCTAssertTrue(count.waitForExistence(timeout: 15), "the long press did not start the selection — \(screenText())")
        XCTAssertTrue(count.label.contains("1 selected"), "the count reads '\(count.label)'")
        element("selectionCancelButton").tap()

        // The last tile asks for the next page.
        XCTAssertNotNil(stubGET("/__paging?size=4"))
        chooseMode("metadata")
        clearQuery("plage")
        typeQuery("x")
        waitForTile("paged results")
        var asked = false
        for _ in 0..<10 where !asked {
            app.swipeUp()
            asked = searches().contains { $0.number("page") == 2 }
        }
        XCTAssertTrue(asked || waitUntil(30) { self.searches().contains { $0.number("page") == 2 } },
                      "scrolling to the last tile asked for no second page — log:\n\(describe(searches()))")
    }

    // MARK: - AC-13: one control each

    func test_AC_13() {
        startSession(major: 3, minor: 2)
        chooseMode("metadata")
        typeQuery("sunset")

        XCTAssertEqual(count("searchRatingFilterMenu"), 0, "a rating menu is on the screen")
        XCTAssertEqual(count("searchOcrFilterToggle"), 0, "the toggle is on the screen, not in the menu")
        XCTAssertEqual(count("searchFilterOCR"), 0, "the sheet's OCR field is on the screen")

        openOptions()
        XCTAssertEqual(count("searchOcrFilterToggle"), 1, "the menu does not hold exactly one detected-text toggle")
        XCTAssertEqual(count("searchRatingFilterMenu"), 0, "a rating menu is in the Search options menu")
        let toggleLabel = optionItem("searchOcrFilterToggle").label
        closeOptions()

        openFilters()
        _ = sheetControl("searchFilterOCR")
        XCTAssertEqual(count("searchFilterStar4"), 1, "the sheet does not hold exactly one 4-star control")
        XCTAssertEqual(count("searchFilterOCR"), 1, "the sheet does not hold exactly one OCR field")
        XCTAssertEqual(count("searchOcrFilterToggle"), 0, "the toggle is also in the sheet")
        XCTAssertEqual(count("searchRatingFilterMenu"), 0, "a rating menu is on the sheet's screen")
        let field = element("searchFilterOCR")
        let fieldLabels = [field.label, field.placeholderValue ?? ""].filter { !$0.isEmpty }
        XCTAssertFalse(fieldLabels.isEmpty, "the OCR field reads nothing")
        XCTAssertFalse(toggleLabel.isEmpty, "the toggle reads nothing")
        XCTAssertFalse(fieldLabels.contains(toggleLabel), "the toggle and the OCR field read the same: '\(toggleLabel)'")
    }

    // MARK: - AC-14, AC-15: the chips

    private func setThreeCriteria() {
        applyFilters(city: "Paris", rating: 4, photosOnly: true)
        for field in ["city", "rating", "type"] {
            XCTAssertTrue(element("searchFilterChip_\(field)").waitForExistence(timeout: 30),
                          "no \(field) chip — \(screenText())")
        }
        waitForTile("three criteria")
    }

    func test_AC_14() {
        startSession(major: 2, minor: 0)
        setThreeCriteria()
        XCTAssertEqual(optionItem("searchFilterButton").value as? String, "3 active")
        guard let tile = firstTile else { return XCTFail("no tile — \(screenText())") }
        for field in ["city", "rating", "type"] {
            let chip = element("searchFilterChip_\(field)")
            XCTAssertLessThanOrEqual(chip.frame.maxY, tile.frame.minY, "the \(field) chip is not above the grid")
        }
    }

    func test_AC_15() {
        startSession(major: 2, minor: 0)
        setThreeCriteria()
        let crosses = ["city", "rating", "type"].map { (field: $0, cross: element("searchFilterChipRemove_\($0)")) }
        guard let last = crosses.max(by: { $0.cross.frame.minX < $1.cross.frame.minX }) else { return }
        let identifier = "searchFilterChipRemove_\(last.field)"
        // The smallest scroll view holding the cross is the chip row, not the grid.
        let row = app.scrollViews.containing(.button, identifier: identifier).allElementsBoundByIndex
            .min { $0.frame.height < $1.frame.height }
        let width = app.windows.firstMatch.frame.width
        for _ in 0..<5 where !(last.cross.frame.minX >= 0 && last.cross.frame.maxX <= width && last.cross.isHittable) {
            row?.swipeLeft()
        }
        let frame = last.cross.frame
        XCTAssertTrue(frame.minX >= 0 && frame.maxX <= width && last.cross.isHittable,
                      "the cross of \(last.field) is not fully on screen: \(frame)")
        XCTAssertGreaterThanOrEqual(frame.width, 44, "the cross is narrower than 44 pt")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "the cross is shorter than 44 pt")

        let mark = searches().count
        last.cross.tap()
        XCTAssertTrue(element("searchFilterChip_\(last.field)").waitForNonExistence(timeout: 20),
                      "the \(last.field) chip is still there")
        for field in ["city", "rating", "type"] where field != last.field {
            XCTAssertTrue(element("searchFilterChip_\(field)").exists, "the \(field) chip went with it")
        }
        XCTAssertTrue(waitUntil(30) { self.searches().count > mark }, "removing a criterion sent no search")
    }

    // MARK: - AC-16, AC-17: the field and the home

    func test_AC_16() {
        startSession(major: 2, minor: 0)
        func assertFieldAtTop(_ state: String) {
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(searchField.waitForExistence(timeout: 20), "\(state): no search field — \(screenText())")
            XCTAssertTrue(searchField.isHittable, "\(state): the search field cannot be touched")
            XCTAssertLessThan(searchField.frame.minY, window.height * 0.25, "\(state): the field is not at the top")
        }
        assertFieldAtTop("without results")
        searchBeach()
        assertFieldAtTop("with results")

        element("searchModeSegment_explore").tap()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 15), "Explorer still shows the field")
        XCTAssertTrue(waitUntil(15) {
            self.element("exploreEmptyState").exists
                || self.app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'explorePlaceCard_'")).firstMatch.exists
        }, "one touch did not reach Explorer — \(screenText())")
        element("searchModeSegment_map").tap()
        XCTAssertTrue(element("mapSettingsButton").waitForExistence(timeout: 20), "one touch did not reach the map — \(screenText())")
        element("searchModeSegment_results").tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 15), "the field did not come back — \(screenText())")
    }

    func test_AC_17() {
        startSession(major: 2, minor: 0)
        let title = element("searchPromptTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no prompt title — \(screenText())")
        let tabTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : CGFloat.greatestFiniteMagnitude
        let sentence = app.staticTexts.allElementsBoundByIndex.first {
            !$0.label.isEmpty && $0.frame.minY >= title.frame.maxY - 1 && $0.frame.maxY <= tabTop + 1
        }
        XCTAssertNotNil(sentence, "no sentence under the title — \(screenText())")
        XCTAssertTrue(searches().isEmpty, "opening the tab sent a search:\n\(describe(searches()))")
    }

    // MARK: - AC-18: recents and saved

    private struct SavedEntry: Encodable {
        let id: String
        let name: String
        let query: String
    }

    func test_AC_18() throws {
        // Recent and saved searches come from the UserDefaults argument domain.
        let saved = try JSONEncoder().encode([SavedEntry(id: "redesign-saved-1", name: "Garden flowers", query: "flower")])
        let hex = "<" + saved.map { String(format: "%02x", $0) }.joined() + ">"
        app.launchArguments += ["-recentSearches", "(\"sunset\", \"autumn\")", "-savedSearches", hex]
        startSession(major: 2, minor: 0)

        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "no search field — \(screenText())")
        searchField.tap()
        for label in ["Saved", "Recent", "Garden flowers", "sunset"] {
            XCTAssertTrue(staticText(label).waitForExistence(timeout: 15), "the suggestions do not list '\(label)' — \(screenText())")
        }
        staticText("sunset").tap()
        waitForSearch("recent search", { $0.string("query") == "sunset" })
    }

    // MARK: - AC-19, AC-20: empty and error

    func test_AC_19() {
        startSession(major: 2, minor: 0)
        applyFilters(city: "Paris")
        typeQuery("zzz")
        XCTAssertTrue(waitUntil(30) {
            self.element("searchEmptyState").exists && self.element("searchNoResultsReset").exists
                && self.element("searchFilterChip_city").exists
        }, "no empty state with its reset and the city chip — \(screenText())")

        let mark = searches().count
        element("searchNoResultsReset").tap()
        XCTAssertTrue(element("searchNoResultsReset").waitForNonExistence(timeout: 20), "the reset is still offered")
        XCTAssertFalse(element("searchFilterChip_city").exists, "the city chip stayed after the reset")
        XCTAssertTrue(waitUntil(30) { self.searches().count > mark }, "the reset sent no search")
        let first = searches()[mark]
        for key in ["city", "rating", "type", "personIds", "tagIds"] {
            XCTAssertFalse(first.bodyJSON.contains("\"\(key)\""), "the search after the reset still carries \(key): \(first.bodyJSON)")
        }
    }

    func test_AC_20() {
        reset()
        setProvider("manual")
        reachAuthenticatedShell()
        openSearchTab()
        launched = true
        sessionMark = stubRequests().count
        XCTAssertNotNil(stubGET("/control/script?route=search&steps=500,ok&delay=0"))

        typeQuery("liststates")
        XCTAssertTrue(element("searchError").waitForExistence(timeout: 30), "no error state after the 500 — \(screenText())")
        let retry = element("searchErrorRetry")
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "no Try Again after the 500 — \(screenText())")
        retry.tap()
        waitForTile("after Try Again")
        let sent = searches().filter { $0.bodyJSON.contains("liststates") }
        XCTAssertGreaterThanOrEqual(sent.count, 2, "Try Again sent no new search — log:\n\(describe(searches()))")
    }

    // MARK: - AC-25: labels, values and targets

    private func assertReadable(_ buttons: [XCUIElement], _ what: String) {
        for button in buttons {
            let id = name(of: button)
            XCTAssertFalse(button.label.isEmpty, "\(what): '\(id)' has no label")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(what): '\(id)' is \(button.frame.width) pt wide")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(what): '\(id)' is \(button.frame.height) pt tall")
        }
    }

    private func assertBarReadable(_ what: String) {
        let bar = app.navigationBars.firstMatch.frame
        let segments = ["results", "explore", "map"].map { element("searchModeSegment_\($0)") }
        assertReadable(countedButtons(inside: bar) + segments, what)
    }

    func test_AC_25() {
        startSession(major: 2, minor: 0)

        // Home.
        XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "no home — \(screenText())")
        assertBarReadable("home")
        let menu = optionItem("searchModeMenu")
        XCTAssertEqual(menu.label, "Search options")
        XCTAssertEqual(menu.value as? String, "Smart")
        XCTAssertEqual(optionItem("searchFilterButton").value as? String, "No active filters")

        // Results with a city chip.
        searchBeach()
        applyFilters(city: "Paris")
        XCTAssertTrue(element("searchFilterChip_city").waitForExistence(timeout: 30), "no city chip — \(screenText())")
        assertBarReadable("results")
        XCTAssertEqual(optionItem("searchFilterButton").value as? String, "1 active")
        for cross in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchFilterChipRemove_'")).allElementsBoundByIndex
        where cross.isHittable {
            assertReadable([cross], "chip")
        }

        // The open menu.
        openOptions()
        let items = ["searchTextMode_smart", "searchTextMode_metadata", "searchTextMode_filename",
                     "searchTextMode_description", "searchOcrFilterToggle", "searchSaveButton", "searchSelectButton"]
        assertReadable(items.map(optionItem), "menu")
        let ocrLabel = optionItem("searchOcrFilterToggle").label
        XCTAssertTrue(ocrLabel.contains("Search typed text in detected text") && ocrLabel.contains("Off"),
                      "the detected-text toggle does not read off: label '\(ocrLabel)'")
        closeOptions()
    }

    // MARK: - AC-26: the largest text size (CI line: accessibility-extra-extra-extra-large)

    private struct OverlapCandidate {
        let frame: CGRect
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        let scrolls: Bool
        var name: String { identifier.isEmpty ? label : identifier }
    }

    /// The accessibility label of a sheet's system grabber, in the scenarios' languages.
    private static let sheetGrabberLabels: Set<String> = ["Sheet Grabber", "Aufzeichnungsblatt"]

    private func assertInWindow(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.exists, "no '\(identifier)' — \(screenText())")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(target.frame.minX, 0, "\(identifier) starts left of the window")
        XCTAssertLessThanOrEqual(target.frame.maxX, window.width + 0.5, "\(identifier) runs past the window's right edge")
    }

    /// Texts, buttons, fields and switches on the screen: no two overlap by more than 1 pt both ways,
    /// unless one contains the other (a text in its button). Content of a scroll view that runs under
    /// fixed chrome is not an overlap. The window is read once, as a snapshot; hittability is only
    /// asked of the two elements of an overlapping pair.
    private func assertNoOverlap(_ what: String) {
        let main = app.windows.firstMatch
        let root: XCUIElementSnapshot
        do { root = try main.snapshot() } catch {
            return XCTFail("\(what): no snapshot of the main window: \(error)")
        }
        let window = root.frame
        let types: Set<XCUIElement.ElementType> = [.staticText, .button, .textField, .secureTextField, .switch]
        let containers: Set<XCUIElement.ElementType> = [.scrollView, .table, .collectionView]
        var seen: [OverlapCandidate] = []
        func carriesText(_ node: XCUIElementSnapshot) -> Bool {
            node.children.contains { $0.elementType == .staticText || carriesText($0) }
        }
        func walk(_ node: XCUIElementSnapshot, scrolls: Bool) {
            let type = node.elementType
            if type == .tabBar { return }
            if types.contains(type), !node.frame.isEmpty, node.frame.intersects(window),
               !(type == .button && (Self.sheetGrabberLabels.contains(node.label) || carriesText(node))) {
                seen.append(OverlapCandidate(frame: node.frame, type: type, identifier: node.identifier,
                                             label: node.label, scrolls: scrolls))
            }
            for child in node.children { walk(child, scrolls: scrolls || containers.contains(type)) }
        }
        walk(root, scrolls: false)

        var hittable: [String: Bool] = [:]
        func isHittable(_ candidate: OverlapCandidate) -> Bool {
            let key = "\(candidate.type.rawValue)|\(candidate.frame)|\(candidate.identifier)|\(candidate.label)"
            if let known = hittable[key] { return known }
            let matches = main.descendants(matching: candidate.type)
                .matching(NSPredicate(format: "identifier == %@ AND label == %@", candidate.identifier, candidate.label))
                .allElementsBoundByIndex
            let result = (matches.first { $0.frame == candidate.frame } ?? matches.first)?.isHittable ?? false
            hittable[key] = result
            return result
        }
        for (index, first) in seen.enumerated() {
            for second in seen[(index + 1)...] where first.scrolls == second.scrolls {
                let shared = first.frame.intersection(second.frame)
                guard !shared.isNull, shared.width > 1, shared.height > 1 else { continue }
                let nested = first.frame.insetBy(dx: -1, dy: -1).contains(second.frame)
                    || second.frame.insetBy(dx: -1, dy: -1).contains(first.frame)
                guard !nested, isHittable(first), isHittable(second) else { continue }
                XCTFail("\(what): '\(first.name)' \(first.frame) overlaps '\(second.name)' \(second.frame)")
            }
        }
    }

    func test_AC_26() {
        startSession(major: 2, minor: 0)
        XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "no home — \(screenText())")
        assertNoOverlap("home")

        searchBeach()
        applyFilters(city: "Paris")
        XCTAssertTrue(element("searchFilterChip_city").waitForExistence(timeout: 30), "no city chip — \(screenText())")
        assertNoOverlap("results with a chip")

        openFilters()
        assertNoOverlap("Filters sheet")
        for swipe in 1...3 {
            app.swipeUp()
            assertNoOverlap("Filters sheet after \(swipe) swipes")
        }
        tapDone()

        for identifier in ["searchFilterButton", "searchModeMenu", "syncStatusButton", "profileAvatar", "searchFilterChip_city"] {
            assertInWindow(identifier)
        }
    }
}
