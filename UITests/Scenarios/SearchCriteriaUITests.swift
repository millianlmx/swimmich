import XCTest

/// End-to-end scenarios for the Search tab's criteria (L-23): people, tags, the
/// display options (not in album / favourites / archive), the file-name and
/// description text modes, Smart search with filters, and the grid density.
///
/// They run against `immich_stub_search_filters.py`, which serves a small
/// library (Alice, Bob and the hidden Carla; the tags `Voyages` and
/// `Voyages/Japon`; archived, out-of-album, tagged and named photos) and FILTERS
/// it on the criteria a body carries, in both languages of
/// `POST /api/search/metadata` — so each test asserts what was sent AND which
/// tiles the screen then shows. Tests name controls by `accessibilityIdentifier`
/// and never by localized text.
///
/// Run one with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/search-criteria.uitest.log \
///         UITests/stubs/immich_stub_search_filters.py SearchCriteriaUITests/test_AC_42 --erase
///
/// A test that needs two server generations relaunches the app between them:
/// the version probe is cached for the whole session.
final class SearchCriteriaUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var launched = false
    /// Net change this test made to the Columns preference; undone in tearDown
    /// so no later scenario reads a changed density.
    private var columnsDelta = 0

    // The stub's fixtures.
    private let alice = "a11ce000-0000-4000-8000-000000000001"
    private let bob = "b0b00000-0000-4000-8000-000000000002"
    private let carla = "ca41a000-0000-4000-8000-000000000003"
    private let tagVoyages = "7a9e5000-0000-4000-8000-000000000001"
    private let tagJapon = "7a9e5000-0000-4000-8000-000000000002"
    private let p2 = "f1000000-0000-4000-8000-000000000002"
    private let p3 = "f1000000-0000-4000-8000-000000000003"
    private let j1 = "f1000000-0000-4000-8000-000000000005"
    private let a1 = "f1000000-0000-4000-8000-000000000006"
    private let z1 = "f1000000-0000-4000-8000-000000000008"
    private let img = "f1000000-0000-4000-8000-000000000009"
    private let fixturePrefix = "f1000000-"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
        addTeardownBlock { [self] in
            guard columnsDelta != 0 else { return }
            restoreColumns()
        }
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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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

    /// A fresh session against the generation asked for. The first call of a
    /// test resets the stub; the next ones relaunch the app (a version probe
    /// is cached per session) and keep the request log, which is read from the
    /// mark `sessionMark` records.
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

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    private func openFilters() {
        let button = app.buttons.matching(identifier: "searchFilterButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Filters button is not in the Search toolbar — \(screenText())")
        button.tap()
        XCTAssertTrue(element("searchFilterSheet").waitForExistence(timeout: 20),
                      "the Filters sheet never opened — \(screenText())")
    }

    /// A control of the Filters sheet, scrolled into view if the `Form` has not
    /// drawn it yet.
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

    /// The switch sits at the trailing edge of its row.
    private func tapSwitch(_ identifier: String) {
        sheetControl(identifier).coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func tapDone() {
        let done = app.buttons.matching(identifier: "searchFilterDone").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the sheet's Done button is missing")
        done.tap()
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back")
        back.tap()
        sleep(1)
    }

    /// Sheet → People → rows, then back to the sheet.
    private func choosePeople(_ ids: [String]) {
        sheetControl("searchFilterPeople").tap()
        for id in ids {
            let row = element("searchPersonRow_\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 20), "no row for person \(id) — \(screenText())")
            row.tap()
        }
        goBack()
    }

    private func chooseTag(_ id: String) {
        sheetControl("searchFilterTags").tap()
        let row = element("searchTagRow_\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no row for tag \(id) — \(screenText())")
        row.tap()
        goBack()
    }

    private var searchField: XCUIElement { app.searchFields.firstMatch }

    private func typeQuery(_ text: String) {
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "the search field is missing")
        searchField.tap()
        searchField.typeText(text)
    }

    private func clearQuery(_ current: String) {
        searchField.tap()
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    private func chooseMode(_ mode: String) {
        let menu = app.buttons.matching(identifier: "searchModeMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the search mode menu is missing")
        menu.tap()
        let item = app.buttons.matching(identifier: "searchTextMode_\(mode)").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no `searchTextMode_\(mode)` item — \(screenText())")
        item.tap()
    }

    /// Ids of the fixture photos the results grid shows now.
    private func fixtureTiles() -> Set<String> {
        let tiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_\(fixturePrefix)'"))
        return Set(tiles.allElementsBoundByIndex.map { String($0.identifier.dropFirst("assetTile_".count)) })
    }

    private func assertTiles(_ expected: Set<String>, _ what: String) {
        let reached = waitUntil(40) { fixtureTiles() == expected }
        XCTAssertTrue(reached, "\(what): the grid shows \(fixtureTiles().sorted()), expected \(expected.sorted()) — \(screenText())")
    }

    /// Columns of the results grid, measured on the width of one tile so one
    /// result is enough: `n = round((window − 2 × 4 + 2) / (tile + 2))`, with
    /// the 4 pt inset and 2 pt seams of the grid.
    private func gridColumns() -> Int {
        let tile = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "no tile to measure the grid on — \(screenText())")
        let window = app.windows.firstMatch.frame.width
        return Int(((window - 8 + 2) / (tile.frame.width + 2)).rounded())
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
        private func group(_ key: String) -> [String: Any]? { (body["filter"] as? [String: Any])?[key] as? [String: Any] }

        var personIds: [String]? { structured ? group("personIds")?["all"] as? [String] : body["personIds"] as? [String] }
        var tagIds: [String]? { structured ? group("tagIds")?["all"] as? [String] : body["tagIds"] as? [String] }
        var visibility: String? { structured ? group("visibility")?["eq"] as? String : string("visibility") }
        var notInAlbum: Bool {
            structured ? (group("hasAlbums")?["eq"] as? Bool) == false : (body["isNotInAlbum"] as? Bool) == true
        }
        var fileName: String? { structured ? group("originalFileName")?["like"] as? String : string("originalFileName") }
        var description: String? { structured ? group("description")?["like"] as? String : string("description") }
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

    /// The criteria a body carries, checked in whichever language it speaks.
    /// `nil` means "must be absent".
    private func assertCriteria(_ request: StubRequest, people: [String]? = nil, tags: [String]? = nil,
                                notInAlbum: Bool = false, visibility: String,
                                fileName: String? = nil, description: String? = nil, _ what: String) {
        let body = request.bodyJSON
        XCTAssertEqual(request.personIds, people, "\(what): personIds — body: \(body)")
        XCTAssertEqual(request.tagIds, tags, "\(what): tagIds — body: \(body)")
        XCTAssertEqual(request.notInAlbum, notInAlbum, "\(what): not in album — body: \(body)")
        XCTAssertEqual(request.visibility, visibility, "\(what): visibility — body: \(body)")
        XCTAssertEqual(request.fileName, fileName, "\(what): file name — body: \(body)")
        XCTAssertEqual(request.description, description, "\(what): description — body: \(body)")
    }

    // MARK: - AC-42 / AC-209

    func test_AC_42() {
        startSession(major: 1, minor: 119)
        openFilters()
        choosePeople([alice, bob])
        tapDone()

        let request = waitForSearch("two people") { ($0.personIds ?? []).count == 2 }
        XCTAssertEqual(request.personIds, [alice, bob], "the request must carry both ids, in selection order — \(request.bodyJSON)")
        assertTiles([p2], "two people")
    }

    func test_AC_209() {
        startSession(major: 1, minor: 119)
        openFilters()
        sheetControl("searchFilterPeople").tap()

        let field = element("searchPeopleFilterField")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the people filter field is missing")
        XCTAssertTrue(element("searchPersonRow_\(alice)").waitForExistence(timeout: 20))
        field.tap()
        field.typeText("al")
        XCTAssertTrue(waitUntil(10) { !self.element("searchPersonRow_\(self.bob)").exists },
                      "the filter \"al\" must hide Bob")
        XCTAssertTrue(element("searchPersonRow_\(alice)").exists, "the filter \"al\" must keep Alice")
        XCTAssertFalse(element("searchPersonRow_\(carla)").exists, "a hidden person must never be listed")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        XCTAssertTrue(element("searchPersonRow_\(bob)").waitForExistence(timeout: 10))
        XCTAssertFalse(element("searchPersonRow_\(carla)").exists, "a hidden person must never be listed")
        element("searchPersonRow_\(alice)").tap()
        element("searchPersonRow_\(bob)").tap()
        goBack()
        tapDone()

        let request = waitForSearch("Alice and Bob") { ($0.personIds ?? []).count == 2 }
        XCTAssertEqual(request.personIds, [alice, bob])
        assertTiles([p2], "Alice and Bob")
        let people = stubRequests().filter { $0.path == "/api/people" }
        XCTAssertFalse(people.isEmpty, "the picker never read /api/people")
        for request in people {
            XCTAssertNotEqual(request.params["withHidden"], "true", "the picker must not ask for hidden people")
        }
    }

    // MARK: - AC-210

    func test_AC_210() {
        startSession(major: 1, minor: 119)
        openFilters()
        sheetControl("searchFilterTags").tap()

        let voyages = element("searchTagRow_\(tagVoyages)")
        let japon = element("searchTagRow_\(tagJapon)")
        XCTAssertTrue(voyages.waitForExistence(timeout: 20), "the tag Voyages is not listed — \(screenText())")
        XCTAssertTrue(japon.waitForExistence(timeout: 20), "the tag Japon is not listed")
        // The path is data (the tag's `value`), not a catalogue string.
        XCTAssertTrue(japon.label.contains("Voyages/Japon"), "Japon must read as its path — label: \(japon.label)")
        japon.tap()
        goBack()
        tapDone()

        let request = waitForSearch("tag Japon") { $0.tagIds != nil }
        XCTAssertEqual(request.tagIds, [tagJapon], "only the id of the chosen tag travels — \(request.bodyJSON)")
        assertTiles([j1], "tag Japon")
    }

    // MARK: - AC-211

    func test_AC_211() {
        for (major, minor) in [(1, 119), (3, 4)] {
            startSession(major: major, minor: minor)
            let pass = "server \(major).\(minor)"

            chooseMode("metadata")
            typeQuery("photo")
            let plain = waitForSearch("\(pass): Metadata without filter") { !$0.isSmart }
            XCTAssertEqual(plain.visibility, "timeline", "\(pass): the visibility is explicit — \(plain.bodyJSON)")
            XCTAssertEqual(plain.structured, major == 3, "\(pass): wrong request language — \(plain.bodyJSON)")
            XCTAssertTrue(waitUntil(30) { !self.fixtureTiles().isEmpty }, "\(pass): no result — \(screenText())")
            XCTAssertFalse(fixtureTiles().contains(a1), "\(pass): an archived photo is shown with Archive unticked")
            XCTAssertFalse(fixtureTiles().contains(z1), "\(pass): an archived photo is shown with Archive unticked")

            openFilters()
            tapSwitch("searchFilterArchive")
            tapDone()
            let archived = waitForSearch("\(pass): Archive") { !$0.isSmart && $0.visibility == "archive" }
            XCTAssertEqual(archived.visibility, "archive", "\(pass): \(archived.bodyJSON)")
            assertTiles([a1, z1], "\(pass): Archive")

            chooseMode("smart")
            let smart = waitForSearch("\(pass): Smart with text") { $0.isSmart }
            XCTAssertEqual(smart.string("query"), "photo", "\(pass): \(smart.bodyJSON)")
            XCTAssertEqual(smart.visibility, "archive", "\(pass): Smart carries the visibility, flat — \(smart.bodyJSON)")
            XCTAssertNil(smart.body["filter"], "\(pass): a Smart body is never structured — \(smart.bodyJSON)")
        }
    }

    // MARK: - AC-212

    func test_AC_212() {
        startSession(major: 1, minor: 119)

        chooseMode("filename")
        typeQuery("img_12")
        let byName = waitForSearch("file name") { $0.fileName != nil }
        XCTAssertEqual(byName.fileName, "img_12", "\(byName.bodyJSON)")
        XCTAssertNil(byName.string("query"), "a file-name search carries no `query` — \(byName.bodyJSON)")
        XCTAssertNil(byName.description, "\(byName.bodyJSON)")
        assertTiles([img], "file name")
        XCTAssertTrue(element("searchFilterChip_originalFileName").waitForExistence(timeout: 10),
                      "the file-name criterion has no chip")
        let badge = element("searchFilterButton")
        XCTAssertTrue((badge.value as? String ?? "").contains("1"), "the badge must count the text criterion — \(badge.value as? String ?? "nil")")

        clearQuery("img_12")
        chooseMode("description")
        typeQuery("biarritz")
        let byDescription = waitForSearch("description") { $0.description == "biarritz" }
        XCTAssertNil(byDescription.fileName, "\(byDescription.bodyJSON)")
        XCTAssertNil(byDescription.string("query"), "\(byDescription.bodyJSON)")
        assertTiles([img], "description")

        chooseMode("smart")
        let smart = waitForSearch("back to Smart") { $0.isSmart }
        XCTAssertEqual(smart.string("query"), "biarritz", "\(smart.bodyJSON)")
        XCTAssertEqual(smart.visibility, "timeline", "\(smart.bodyJSON)")
        XCTAssertNil(smart.fileName, "\(smart.bodyJSON)")
        XCTAssertNil(smart.description, "\(smart.bodyJSON)")
    }

    // MARK: - AC-213

    func test_AC_213() {
        startSession(major: 1, minor: 119)
        openFilters()
        choosePeople([alice, bob])
        chooseTag(tagJapon)
        tapSwitch("searchFilterNotInAlbum")
        tapSwitch("searchFilterArchive")
        tapDone()

        assertTiles([z1], "every criterion")
        for field in ["personIds", "tagIds", "isNotInAlbum", "visibility"] {
            XCTAssertTrue(element("searchFilterChip_\(field)").waitForExistence(timeout: 20), "no chip for \(field)")
        }
        let badge = element("searchFilterButton")
        XCTAssertTrue((badge.value as? String ?? "").contains("4"), "the badge must count 4 criteria — \(badge.value as? String ?? "nil")")

        let mark = searches().count
        tapChipRemove("tagIds")
        let withoutTag = waitForSearch("tag removed") { $0.tagIds == nil && $0.personIds != nil }
        XCTAssertGreaterThan(searches().count, mark)
        assertCriteria(withoutTag, people: [alice, bob], notInAlbum: true, visibility: "archive", "tag removed")
        XCTAssertFalse(element("searchFilterChip_tagIds").exists, "the removed chip is still there")

        openFilters()
        let reset = app.buttons.matching(identifier: "searchFilterReset").firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset button")
        reset.tap()
        let cleared = waitForSearch("Reset") { $0.personIds == nil && $0.visibility == "timeline" && !$0.notInAlbum }
        assertCriteria(cleared, visibility: "timeline", "Reset")
        tapDone()

        // The text modes have a chip of their own, and its cross returns to Smart.
        chooseMode("filename")
        typeQuery("img_12")
        XCTAssertTrue(element("searchFilterChip_originalFileName").waitForExistence(timeout: 30))
        tapChipRemove("originalFileName")
        let smart = waitForSearch("chip removed") { $0.isSmart }
        XCTAssertEqual(smart.string("query"), "img_12", "\(smart.bodyJSON)")
        XCTAssertNil(smart.fileName, "\(smart.bodyJSON)")
        XCTAssertEqual(searchField.value as? String, "img_12", "the text must stay in the field")
    }

    /// The cross of a chip. The chips sit in a horizontal scroll view: with four of
    /// them the last ones start past the window's edge, so the row is swiped left
    /// until the cross can be tapped.
    private func tapChipRemove(_ field: String) {
        let cross = element("searchFilterChipRemove_\(field)")
        XCTAssertTrue(cross.waitForExistence(timeout: 10), "no chip for \(field) — \(screenText())")
        let firstChip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchFilterChip_'")).firstMatch
        for _ in 0..<5 where !cross.isHittable { firstChip.swipeLeft() }
        cross.tap()
    }

    // MARK: - AC-43

    func test_AC_43() {
        for (major, minor) in [(1, 119), (3, 4)] {
            startSession(major: major, minor: minor)
            let pass = "server \(major).\(minor)"

            openFilters()
            tapSwitch("searchFilterArchive")
            tapDone()
            var request = waitForSearch("\(pass): Archive") { !$0.isSmart && $0.visibility == "archive" }
            assertCriteria(request, visibility: "archive", "\(pass): Archive")
            XCTAssertEqual(request.structured, major == 3, "\(pass): wrong request language — \(request.bodyJSON)")
            assertTiles([a1, z1], "\(pass): Archive")
            XCTAssertEqual(gridColumns(), 3, "\(pass): Archive — the grid must have the preferred 3 columns")

            openFilters()
            tapSwitch("searchFilterNotInAlbum")
            tapDone()
            request = waitForSearch("\(pass): not in album") { !$0.isSmart && $0.notInAlbum }
            assertCriteria(request, notInAlbum: true, visibility: "archive", "\(pass): not in album")
            assertTiles([z1], "\(pass): not in album")
            XCTAssertEqual(gridColumns(), 3, "\(pass): not in album — columns")

            openFilters()
            chooseTag(tagJapon)
            tapDone()
            request = waitForSearch("\(pass): tag") { !$0.isSmart && $0.tagIds != nil }
            assertCriteria(request, tags: [tagJapon], notInAlbum: true, visibility: "archive", "\(pass): tag")
            assertTiles([z1], "\(pass): tag")
            XCTAssertEqual(gridColumns(), 3, "\(pass): tag — columns")

            chooseMode("filename")
            typeQuery("kyoto")
            request = waitForSearch("\(pass): file name") { $0.fileName == "kyoto" }
            assertCriteria(request, tags: [tagJapon], notInAlbum: true, visibility: "archive",
                           fileName: "kyoto", "\(pass): file name")
            assertTiles([z1], "\(pass): file name")
            XCTAssertEqual(gridColumns(), 3, "\(pass): file name — columns")

            chooseMode("description")
            request = waitForSearch("\(pass): description") { $0.description == "kyoto" }
            assertCriteria(request, tags: [tagJapon], notInAlbum: true, visibility: "archive",
                           description: "kyoto", "\(pass): description")
            assertTiles([z1], "\(pass): description")
            XCTAssertEqual(gridColumns(), 3, "\(pass): description — columns")

            let rejected = stubRequests().dropFirst(sessionMark).filter { $0.isSearch && $0.body["filter"] != nil && $0.body["page"] != nil }
            XCTAssertTrue(rejected.isEmpty, "\(pass): a body mixed the two languages — \(describe(Array(rejected)))")
        }
    }

    // MARK: - AC-215

    private func searchCount() -> Int { searches().count }

    func test_AC_215() {
        startSession(major: 1, minor: 119)
        openFilters()
        tapSwitch("searchFilterArchive")
        tapDone()
        assertTiles([a1, z1], "Archive")
        XCTAssertEqual(gridColumns(), 3, "the default density is 3 columns")

        setColumns(by: 2)
        XCTAssertEqual(gridColumns(), 5, "the grid must follow the Columns preference (5)")

        let before = searchCount()
        setColumns(by: -3)
        XCTAssertEqual(gridColumns(), 2, "the grid must follow the Columns preference (2)")
        XCTAssertEqual(searchCount(), before, "changing the density must not send a search")
    }

    /// Me sheet → Preferences → the Columns stepper, then back to the results. The
    /// Me sheet is opened from the Photos tab: in results mode the Search toolbar
    /// carries seven items, and on an iPhone the avatar goes into the system's
    /// overflow menu, where it has no identifier of its own.
    private func setColumns(by steps: Int) {
        let photos = app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 15), "no Photos tab")
        photos.tap()
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Profile avatar missing")
        avatar.tap()
        sleep(4)
        let row = app.buttons.matching(identifier: "preferencesRow").firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(row.exists, "Preferences row missing — \(screenText())")
        row.tap()
        let stepper = element("preferencesColumnsStepper")
        XCTAssertTrue(stepper.waitForExistence(timeout: 15), "the Columns stepper is missing")
        let label = steps > 0 ? "Increment" : "Decrement"
        for _ in 0..<abs(steps) {
            let button = stepper.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(label) button on the Columns stepper")
            button.tap()
            columnsDelta += steps > 0 ? 1 : -1
        }
        goBack()
        dismissMeSheet()
        openSearchTab()
    }

    /// The Me sheet is dragged down from its navigation bar: a drag inside the
    /// form would scroll the form instead.
    private func dismissMeSheet() {
        let searchTab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { searchTab.exists && searchTab.isHittable }
        }
        XCTAssertTrue(dismissed, "the Me sheet never dismissed")
    }

    private func restoreColumns() {
        guard launched else { return }
        app.terminate()
        app.launch()
        guard app.tabBars.buttons.firstMatch.waitForExistence(timeout: 30) else { return }
        let delta = columnsDelta
        columnsDelta = 0
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        guard avatar.waitForExistence(timeout: 15) else { return }
        avatar.tap()
        sleep(4)
        let row = app.buttons.matching(identifier: "preferencesRow").firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        guard row.exists else { return }
        row.tap()
        let stepper = element("preferencesColumnsStepper")
        guard stepper.waitForExistence(timeout: 15) else { return }
        for _ in 0..<abs(delta) { stepper.buttons[delta > 0 ? "Decrement" : "Increment"].tap() }
    }

    // MARK: - AC-218

    func test_AC_218() {
        for (major, minor) in [(2, 0), (3, 4)] {
            startSession(major: major, minor: minor)
            let pass = "server \(major).\(minor)"

            typeQuery("plage")
            waitForSearch("\(pass): Smart without filter") { $0.isSmart }
            openFilters()
            choosePeople([alice])
            tapDone()

            let smart = waitForSearch("\(pass): Smart with Alice") { $0.isSmart && $0.personIds != nil }
            XCTAssertEqual(smart.string("query"), "plage", "\(pass): \(smart.bodyJSON)")
            XCTAssertEqual(smart.personIds, [alice], "\(pass): \(smart.bodyJSON)")
            XCTAssertEqual(smart.visibility, "timeline", "\(pass): \(smart.bodyJSON)")
            XCTAssertEqual(smart.body["page"] as? Int, 1, "\(pass): \(smart.bodyJSON)")
            XCTAssertNil(smart.body["filter"], "\(pass): \(smart.bodyJSON)")
            assertTiles([p3], "\(pass): Smart with Alice")
            _ = waitForSearch("\(pass): page 2") { $0.isSmart && ($0.body["page"] as? Int) == 2 && $0.personIds == [self.alice] }

            // No text: the filters alone become a Metadata search.
            clearQuery("plage")
            openFilters()
            tapDone()
            let metadata = waitForSearch("\(pass): empty text") { !$0.isSmart && $0.personIds == [self.alice] }
            XCTAssertEqual(metadata.personIds, [alice], "\(pass): \(metadata.bodyJSON)")

            // A new text takes the search back to Smart, filters kept. Only a
            // request sent AFTER the typing counts.
            let sentBefore = searches().count
            typeQuery("plage")
            let back = waitForSearch("\(pass): text again", after: sentBefore) {
                $0.isSmart && $0.string("query") == "plage" && $0.personIds == [self.alice]
            }
            XCTAssertEqual(back.personIds, [alice], "\(pass): \(back.bodyJSON)")
            assertTiles([p3], "\(pass): Smart again")

            let refused = stubRequests().dropFirst(sessionMark).filter { $0.isSmart && $0.body["filter"] != nil }
            XCTAssertTrue(refused.isEmpty, "\(pass): a Smart body was structured — \(describe(Array(refused)))")
        }
    }

    // MARK: - L-23b: selection and batch actions

    private let album = "a1b2c3d4-0000-4000-8000-000000000001"
    private var p1: String { fixturePrefix + "0000-4000-8000-000000000001" }

    private func searchAlice() {
        openFilters()
        choosePeople([alice])
        tapDone()
        assertTiles([p1, p2, p3], "Alice")
    }

    private func enterSelection() {
        let select = element("searchSelectButton")
        XCTAssertTrue(select.waitForExistence(timeout: 30), "no Select entry above the results — \(screenText())")
        select.tap()
    }

    private func pick(_ ids: [String]) {
        for id in ids {
            let tile = element("assetTile_\(id)")
            XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tile \(id) — \(screenText())")
            tile.tap()
        }
    }

    /// The title of the selection carries the count. Digits only: the words
    /// around them depend on the language.
    private func titleShows(_ count: Int) -> Bool {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", String(count))).firstMatch
        return waitUntil(15) { title.exists }
    }

    private func writes(_ method: String, _ path: String) -> [StubRequest] {
        Array(stubRequests().dropFirst(sessionMark)).filter { $0.method == method && $0.path == path }
    }

    @discardableResult
    private func waitForWrite(_ method: String, _ path: String, _ what: String,
                              _ condition: (StubRequest) -> Bool = { _ in true }) -> StubRequest {
        _ = waitUntil(40) { writes(method, path).contains(where: condition) }
        guard let found = writes(method, path).last(where: condition) else {
            XCTFail("\(what): no \(method) \(path) was sent — log:\n\(describe(Array(stubRequests().dropFirst(sessionMark))))")
            return StubRequest(method: "", path: "", params: [:], body: [:])
        }
        return found
    }

    private func bodyIds(_ request: StubRequest) -> Set<String> {
        Set(request.body["ids"] as? [String] ?? [])
    }

    private func tapSelectionAction(_ identifier: String) {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no `\(identifier)` in the selection bar — \(screenText())")
        button.tap()
    }

    func test_AC_216() {
        startSession(major: 1, minor: 119)
        // Two results a page, the second one eight seconds late: the grid is
        // usable while it loads.
        XCTAssertNotNil(stubGET("/__paging?size=2&delay=8"), "the stub did not take the paging")
        openFilters()
        choosePeople([alice])
        tapDone()
        XCTAssertTrue(element("assetTile_\(p1)").waitForExistence(timeout: 40), "page 1 never showed — \(screenText())")

        enterSelection()
        XCTAssertTrue(titleShows(0), "the title with nothing chosen carries no 0 — \(screenText())")
        pick([p1])
        XCTAssertTrue(titleShows(1), "the title for one carries no 1 — \(screenText())")
        XCTAssertTrue(element("searchSelectionCancelButton").exists,
                      "a touch on a thumbnail in selection opened the viewer")

        // The next page lands; the first photo stays selected.
        XCTAssertTrue(element("assetTile_\(p3)").waitForExistence(timeout: 60), "page 2 never loaded — \(screenText())")
        XCTAssertTrue(titleShows(1), "the selection did not survive the next page — \(screenText())")
        pick([p3])
        XCTAssertTrue(titleShows(2), "the title for two carries no 2 — \(screenText())")
        pick([p3])
        XCTAssertTrue(titleShows(1), "a second touch must uncheck — \(screenText())")
        pick([p3])
        XCTAssertTrue(titleShows(2), "the photo is not checked again — \(screenText())")

        tapSelectionAction("searchSelectionCancelButton")
        XCTAssertTrue(element("searchSelectButton").waitForExistence(timeout: 15), "Cancel did not leave the selection")

        // A long press enters the selection and checks the photo.
        element("assetTile_\(p2)").press(forDuration: 1.0)
        XCTAssertTrue(titleShows(1), "a long press did not start a selection — \(screenText())")
    }

    func test_AC_44() {
        startSession(major: 1, minor: 119)
        searchAlice()
        enterSelection()
        pick([p1, p2, p3])
        XCTAssertTrue(titleShows(3), "the title does not say 3 — \(screenText())")

        tapSelectionAction("favoriteSelectedButton")
        for id in [p1, p2, p3] {
            let request = waitForWrite("PUT", "/api/assets/\(id)", "favourite of \(id)") { ($0.body["isFavorite"] as? Bool) == true }
            XCTAssertEqual(request.body["isFavorite"] as? Bool, true, "\(id): \(request.bodyJSON)")
        }
        XCTAssertEqual(Set(stubRequests().dropFirst(sessionMark)
            .filter { $0.method == "PUT" && $0.path.hasPrefix("/api/assets/") }.map(\.path)).count, 3,
            "one favourite request per photo")

        // The favourite closes the selection, as on the timeline: choose the three again.
        enterSelection()
        pick([p1, p2, p3])
        XCTAssertTrue(titleShows(3), "the title does not say 3 after the heart — \(screenText())")
        tapSelectionAction("addToAlbumButton")
        let row = element("addToAlbumRow_\(album)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the album sheet lists no album — \(screenText())")
        row.tap()
        let add = waitForWrite("PUT", "/api/albums/\(album)/assets", "the album step")
        XCTAssertEqual(bodyIds(add), [p1, p2, p3], "one add carrying the three photos — \(add.bodyJSON)")
        XCTAssertEqual(writes("PUT", "/api/albums/\(album)/assets").count, 1, "a single request for the album")
    }

    func test_AC_217() {
        startSession(major: 1, minor: 119)
        searchAlice()

        // Archive off: the selection archives.
        enterSelection()
        pick([p1, p2])
        XCTAssertFalse(element("unarchiveButton").exists, "Unarchive offered on live photos")
        tapSelectionAction("archiveButton")
        let archive = waitForWrite("PUT", "/api/assets", "archive") { $0.string("visibility") == "archive" }
        XCTAssertEqual(bodyIds(archive), [p1, p2], archive.bodyJSON)
        assertTiles([p3], "after archiving")

        // Archive on: the grid lists archived photos and offers Unarchive.
        openFilters()
        tapSwitch("searchFilterArchive")
        tapDone()
        assertTiles([p1, p2, z1], "Archive on")
        enterSelection()
        pick([p1, p2])
        XCTAssertTrue(element("unarchiveButton").waitForExistence(timeout: 15), "no Unarchive on archived results")
        XCTAssertFalse(element("archiveButton").exists, "Archive offered on archived results")
        tapSelectionAction("unarchiveButton")
        let unarchive = waitForWrite("PUT", "/api/assets", "unarchive") { $0.string("visibility") == "timeline" }
        XCTAssertEqual(bodyIds(unarchive), [p1, p2], unarchive.bodyJSON)
        assertTiles([z1], "after unarchiving")

        // Back to live photos: the locked folder, the stack, the download, the bin.
        openFilters()
        tapSwitch("searchFilterArchive")
        tapDone()
        assertTiles([p1, p2, p3], "Archive off again")
        enterSelection()
        pick([p1])
        tapSelectionAction("moveToLockedFolderButton")
        let locked = waitForWrite("PUT", "/api/assets", "locked folder") { $0.string("visibility") == "locked" }
        XCTAssertEqual(bodyIds(locked), [p1], locked.bodyJSON)
        assertTiles([p2, p3], "after the locked folder")

        enterSelection()
        pick([p2, p3])
        tapSelectionAction("stackButton")
        let stack = waitForWrite("POST", "/api/stacks", "stack")
        XCTAssertEqual(stack.body["assetIds"] as? [String], [p2, p3], "the cover is the first of the grid — \(stack.bodyJSON)")
        assertTiles([p2, p3], "after stacking")

        enterSelection()
        pick([p3])
        tapSelectionAction("deleteSelectedButton")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the delete confirmation never came up")
        let confirm = alert.buttons.matching(labelPredicate(["Delete", "Supprimer", "Löschen", "Eliminar", "Elimina"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no destructive button — \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        confirm.tap()
        let bin = waitForWrite("DELETE", "/api/assets", "the bin")
        XCTAssertEqual(bodyIds(bin), [p3], bin.bodyJSON)
        XCTAssertEqual(bin.body["force"] as? Bool, false, "the bin, not a permanent delete — \(bin.bodyJSON)")
        assertTiles([p2], "after the bin")

        // Last: the download leaves a progress panel behind.
        enterSelection()
        pick([p2])
        tapSelectionAction("downloadSelectionButton")
        let info = waitForWrite("POST", "/api/download/info", "download")
        XCTAssertEqual(info.body["assetIds"] as? [String], [p2], info.bodyJSON)
    }
}
