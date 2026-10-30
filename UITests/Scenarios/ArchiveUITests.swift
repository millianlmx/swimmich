import XCTest

/// End-to-end scenarios for Archive / Unarchive: the Timeline's cell menu and
/// selection bar, and the photo viewer opened from the Timeline, from Search
/// (no archive callback: standalone path) and from the Map (visibility unknown
/// until the viewer reads it).
///
/// What is proved, on the WIRE (`PUT /api/assets`: ids + visibility) and on the
/// screen (which entry is offered, which tile is left, whether the viewer left
/// the page, where a refusal is shown).
///
/// Each test resets the stub, configures which assets it considers archived
/// (`/api/__archive/configure`) and signs in. Helpers are copied from
/// `FavoritesFilterUITests`, `ReadOnlyModeUITests`, `SearchFiltersUITests` and
/// `MapSettingsUITests` (the repository's rule: no shared UI-test support file).
///
///     python3 UITests/stubs/immich_stub_archive.py 8421 &
///     TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \
///         -scheme ImmichSwiftUI -only-testing:ImmichSwiftUIUITests/ArchiveUITests
final class ArchiveUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// Below the pinned header of the grid (the first row sits under it).
    private let A = "aaaaaaaa-1111-4111-8111-000000000004"
    private let B = "aaaaaaaa-1111-4111-8111-000000000005"
    private var all: [String] { (1...6).map { "aaaaaaaa-1111-4111-8111-\(String(format: "%012d", $0))" } }

    private let archivedLabels = ["Archived", "Archivé", "Archiviert", "Archivado", "Archiviati"]
    private let unarchiveLabels = ["Unarchive", "Désarchiver", "Dearchivieren", "Desarchivar", "Rimuovi dall'archivio"]
    private let archiveLabels = ["Archive", "Archiver", "Archivieren", "Archivar", "Archivia"]
    private let serverErrorSnippets = [
        "The server ran into a problem", "Le serveur a rencontré un problème",
        "Auf dem Server ist ein Problem aufgetreten", "El servidor ha tenido un problema",
        "Il server ha riscontrato un problema",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
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

    private func get(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "stub did not answer \(path)")
        return body
    }

    private func reset() { _ = get("/__reset") }

    private func setProvider(_ mode: String) {
        XCTAssertEqual(get("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    private func configure(archived: [String], refuse: Bool = false) {
        _ = get("/api/__archive/configure?archived=\(archived.joined(separator: ","))&refuse=\(refuse ? 1 : 0)")
    }

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let ids: [String]?
        let visibility: String?
    }

    private func stubRequests() -> [StubRequest] {
        (try? JSONDecoder().decode([StubRequest].self, from: Data(get("/__requests").utf8))) ?? []
    }

    private func wire(_ method: String, _ path: String) -> [StubRequest] {
        stubRequests().filter { $0.method == method && $0.path == path }
    }

    private func puts() -> [StubRequest] { wire("PUT", "/api/assets") }

    /// Re-reads the log until `count` requests of that shape are there (bounded).
    private func waitForWire(_ method: String, _ path: String, atLeast count: Int,
                             timeout: TimeInterval = 20) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var found = wire(method, path)
        while found.count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            found = wire(method, path)
        }
        return found
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) ids=\(String($0.ids?.description ?? "-")) visibility=\($0.visibility ?? "-")" }
            .joined(separator: "\n")
    }

    // MARK: - Sign-in helpers (copied)

    private func shot(_ name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation,
                                       uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func exactPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: "label IN %@", labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let direct = app.buttons.matching(predicate).firstMatch
        let contained = app.buttons.containing(predicate).firstMatch
        for candidate in [direct, contained] where candidate.waitForExistence(timeout: timeout) {
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

    /// A button whose label is EXACTLY one of `labels` ("Map" must not match "Map settings").
    @discardableResult
    private func tapButton(exactlyOneOf labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: labels.map { _ in "label == %@" }.joined(separator: " OR "),
                                    argumentArray: labels)
        let button = app.buttons.matching(predicate).firstMatch
        guard button.waitForExistence(timeout: timeout) else { return false }
        button.tap()
        return true
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
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// reset → configure → manual provider → launch → signed in on the grid.
    private func start(archived: [String], refuse: Bool = false) {
        reset()
        configure(archived: archived, refuse: refuse)
        setProvider("manual")
        app.launch()

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }
    }

    // MARK: - Screen helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement {
        element("assetTile_\(assetId)")
    }

    private func tapTile(_ assetId: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = tile(assetId)
        guard tile.waitForExistence(timeout: 30) else {
            return XCTFail("tile \(assetId) never rendered; screen reads: "
                           + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))", file: file, line: line)
        }
        if tile.isHittable {
            tile.tap()
        } else {
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Taps the filter entry whose label is EXACTLY one of `labels`.
    private func chooseFilter(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.buttons.matching(identifier: "filterMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the filter menu is missing", file: file, line: line)
        menu.tap()
        let item = app.descendants(matching: .any).matching(exactPredicate(labels)).firstMatch
        guard item.waitForExistence(timeout: 10) else {
            return XCTFail("the filter menu has no entry among \(labels)", file: file, line: line)
        }
        item.tap()
    }

    private func openArchivedGrid() {
        chooseFilter(archivedLabels)
    }

    /// Long-presses the tile: the context menu is up when this returns.
    private func openMenu(of assetId: String) {
        let tile = tile(assetId)
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "tile \(assetId) missing")
        tile.press(forDuration: 1.5)
    }

    private func menuEntries(_ labels: [String]) -> XCUIElement {
        app.buttons.matching(exactPredicate(labels)).firstMatch
    }

    private func selectTiles(_ ids: [String]) {
        let select = app.buttons.matching(identifier: "selectButton").firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 20), "no Select entry above the grid")
        select.tap()
        for id in ids {
            let cell = tile(id)
            XCTAssertTrue(cell.waitForExistence(timeout: 20), "tile \(id) missing")
            cell.tap()
        }
    }

    private func openViewer(on assetId: String) {
        tapTile(assetId)
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never showed its chrome")
    }

    private func serverErrorText() -> XCUIElement {
        app.staticTexts.matching(labelPredicate(serverErrorSnippets)).firstMatch
    }

    // MARK: - Timeline cell menu

    func test_AC1_AC4_archivedCellMenuUnarchives() throws {
        start(archived: all)
        openArchivedGrid()

        openMenu(of: A)
        XCTAssertTrue(menuEntries(unarchiveLabels).waitForExistence(timeout: 10), "the menu has no Unarchive entry")
        XCTAssertFalse(menuEntries(archiveLabels).exists, "the menu still offers Archive")
        shot("archived-cell-menu")

        menuEntries(unarchiveLabels).tap()
        let writes = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(writes.count, 1, "exactly one PUT expected:\n\(describe(stubRequests()))")
        XCTAssertEqual(writes.first?.ids, [A])
        XCTAssertEqual(writes.first?.visibility, "timeline")
        XCTAssertTrue(tile(A).waitForNonExistence(timeout: 20), "the unarchived photo is still in the Archived grid")
    }

    // MARK: - Selection bar

    func test_AC5_AC6_archivedSelectionUnarchives() throws {
        start(archived: all)
        openArchivedGrid()
        selectTiles([A, B])

        let unarchive = app.buttons.matching(identifier: "unarchiveButton").firstMatch
        XCTAssertTrue(unarchive.waitForExistence(timeout: 10), "the selection bar has no Unarchive button")
        XCTAssertTrue(unarchive.isEnabled)
        XCTAssertFalse(app.buttons.matching(identifier: "archiveButton").firstMatch.exists,
                       "the selection bar still offers Archive")

        unarchive.tap()
        let writes = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(writes.count, 1, "one request for the whole selection:\n\(describe(stubRequests()))")
        XCTAssertEqual(Set(writes.first?.ids ?? []), [A, B])
        XCTAssertEqual(writes.first?.visibility, "timeline")
        XCTAssertTrue(tile(A).waitForNonExistence(timeout: 20))
        XCTAssertTrue(tile(B).waitForNonExistence(timeout: 20))
        XCTAssertTrue(unarchive.waitForNonExistence(timeout: 10), "selection mode did not close")
    }

    // MARK: - Viewer opened from the Timeline

    func test_AC8_AC9_viewerUnarchiveFromArchivedGrid() throws {
        start(archived: all)
        openArchivedGrid()
        openViewer(on: A)

        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15), "the viewer has no Unarchive button")
        XCTAssertTrue(unarchiveLabels.contains(unarchive.label), "label reads \(unarchive.label)")
        XCTAssertFalse(element("viewerArchiveButton").exists)

        unarchive.tap()
        let first = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(first.first?.ids, [A])
        XCTAssertEqual(first.first?.visibility, "timeline")
        XCTAssertTrue(element("viewerBackButton").exists, "the viewer closed instead of showing the next photo")

        // The current page is now B: a second tap targets it.
        XCTAssertTrue(unarchive.waitForExistence(timeout: 10))
        unarchive.tap()
        let second = waitForWire("PUT", "/api/assets", atLeast: 2)
        XCTAssertEqual(second.count, 2, describe(stubRequests()))
        XCTAssertEqual(second.last?.ids, [B], "the viewer stayed on the unarchived page")

        element("viewerBackButton").tap()
        XCTAssertTrue(tile(A).waitForNonExistence(timeout: 20), "A is still in the Archived grid")
    }

    func test_AC11_viewerArchiveFromAllLeavesPhoto() throws {
        start(archived: [])
        openViewer(on: A)

        let archive = element("viewerArchiveButton")
        XCTAssertTrue(archive.waitForExistence(timeout: 15), "the viewer has no Archive button")
        archive.tap()
        let first = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(first.first?.ids, [A])
        XCTAssertEqual(first.first?.visibility, "archive")

        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()
        let second = waitForWire("PUT", "/api/assets", atLeast: 2)
        XCTAssertEqual(second.last?.ids, [B], "the viewer stayed on the archived page")

        element("viewerBackButton").tap()
        XCTAssertTrue(tile(A).waitForNonExistence(timeout: 20), "A is still in the grid")
    }

    func test_AC12_viewerUnarchiveLastPhotoCloses() throws {
        start(archived: [A])
        openArchivedGrid()
        openViewer(on: A)

        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15))
        unarchive.tap()

        XCTAssertTrue(element("viewerBackButton").waitForNonExistence(timeout: 10), "the viewer stayed open")
        let writes = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(writes.first?.ids, [A])
        XCTAssertEqual(writes.first?.visibility, "timeline")
    }

    func test_AC16_viewerRefusalShownInViewer() throws {
        start(archived: all, refuse: true)
        openArchivedGrid()
        openViewer(on: A)

        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15))
        unarchive.tap()

        XCTAssertEqual(waitForWire("PUT", "/api/assets", atLeast: 1).first?.ids, [A])
        XCTAssertTrue(serverErrorText().waitForExistence(timeout: 10), "no refusal message in the viewer")
        XCTAssertTrue(element("viewerBackButton").exists, "the refusal must be visible while the viewer is open")

        element("viewerBackButton").tap()
        XCTAssertTrue(tile(A).waitForExistence(timeout: 20), "A left the grid although the server refused")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            XCTAssertEqual(app.alerts.count, 0, "the grid presented the refusal a second time")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func test_AC19_lastPageRefusalAlertsInGrid() throws {
        start(archived: [A], refuse: true)
        openArchivedGrid()
        openViewer(on: A)

        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15))
        unarchive.tap()

        XCTAssertTrue(element("viewerBackButton").waitForNonExistence(timeout: 10), "the viewer stayed open")
        XCTAssertEqual(waitForWire("PUT", "/api/assets", atLeast: 1).first?.ids, [A])
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert once the viewer closed")
        XCTAssertTrue(alert.staticTexts.matching(labelPredicate(serverErrorSnippets)).firstMatch.exists,
                      "the alert does not carry the refusal — it reads \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(tile(A).waitForExistence(timeout: 20), "A left the grid although the server refused")
    }

    // MARK: - Viewer opened from Search (no archive callback)

    func test_AC10_searchViewerUnarchives() throws {
        start(archived: [A, B])

        let searchTab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 30), "no Search tab")
        searchTab.tap()

        let filters = app.buttons.matching(identifier: "searchFilterButton").firstMatch
        XCTAssertTrue(filters.waitForExistence(timeout: 20), "the Filters button is missing")
        filters.tap()
        let city = app.descendants(matching: .textField).matching(identifier: "searchFilterCity").firstMatch
        XCTAssertTrue(city.waitForExistence(timeout: 20), "the Filters sheet never opened")
        city.tap()
        city.typeText("Arch")
        let done = app.buttons.matching(identifier: "searchFilterDone").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the sheet's Done button is missing")
        done.tap()

        openViewer(on: A)
        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15), "the Search viewer has no Unarchive button")
        XCTAssertFalse(element("viewerArchiveButton").exists)

        unarchive.tap()
        let first = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(first.first?.ids, [A])
        XCTAssertEqual(first.first?.visibility, "timeline")

        XCTAssertTrue(unarchive.waitForExistence(timeout: 10))
        unarchive.tap()
        let second = waitForWire("PUT", "/api/assets", atLeast: 2)
        XCTAssertEqual(second.last?.ids, [B], "the viewer stayed on the unarchived page")
        XCTAssertEqual(second.last?.visibility, "timeline")
    }

    // MARK: - Viewer opened from the Map (visibility unknown)

    func test_AC18_mapViewerResolvesArchivedPhoto() throws {
        start(archived: [A])

        let searchTab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "no Search tab")
        searchTab.tap()
        XCTAssertTrue(tapButton(exactlyOneOf: ["Map", "Carte", "Karte"], timeout: 20), "no Map segment")
        XCTAssertTrue(element("mapSettingsButton").waitForExistence(timeout: 25), "the map never drew")

        let thumb = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Arch-4'")).firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 30), "the photo sheet never showed the archived photo")
        thumb.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never opened")

        let unarchive = element("viewerUnarchiveButton")
        XCTAssertTrue(unarchive.waitForExistence(timeout: 15), "the map viewer never resolved the visibility")
        XCTAssertFalse(element("viewerArchiveButton").exists, "the viewer offered Archive for an archived photo")
        XCTAssertFalse(wire("GET", "/api/assets/\(A)").isEmpty, "the viewer never read the asset")

        unarchive.tap()
        let writes = waitForWire("PUT", "/api/assets", atLeast: 1)
        XCTAssertEqual(writes.first?.ids, [A])
        XCTAssertEqual(writes.first?.visibility, "timeline")
        XCTAssertTrue(element("viewerBackButton").waitForNonExistence(timeout: 10), "the viewer stayed on A")
    }
}
