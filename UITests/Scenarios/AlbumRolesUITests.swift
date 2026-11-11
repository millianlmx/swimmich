import XCTest

/// Lot L-02 — album owner, editing by editors, sort order.
///
/// Needs `UITests/stubs/immich_stub_album_roles.py` (label `album-roles`) on the
/// port in `IMMICH_STUB_URL` (default `http://127.0.0.1:8421`). Launch:
/// `.omp/orchestration/uitest.sh <worktree> <log> UITests/stubs/immich_stub_album_roles.py AlbumRolesUITests/<test>`.
///
/// The stub serves three albums whose names are data: "Our Trip" (owner = the
/// signed-in user, editor Alice, viewer Bob, photos of 2020, 2022 and 2024),
/// "Carol Editable" (the user is an editor) and "Carol Read Only" (a viewer).
/// Everything else is matched by accessibility identifier, never localized text,
/// except the system-provided menu entry "Shared With" and the tab bar labels
/// (the language is pinned to English, as in the sibling scenarios).
final class AlbumRolesUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // Keep in step with immich_stub_album_roles.py.
    private let me = "11111111-1111-4111-8111-111111111111"
    private let alice = "44444444-4444-4444-8444-0000000a11ce"
    private let ourTrip = "Our Trip"
    private let ourTripId = "55555555-5555-4555-8555-000000000001"
    private let carolEditable = "Carol Editable"
    private let carolEditableId = "55555555-5555-4555-8555-000000000002"
    private let photo2020 = "bbbbbbbb-3333-4333-8333-000000002020"
    private let photo2022 = "bbbbbbbb-3333-4333-8333-000000002022"
    private let photo2024 = "bbbbbbbb-3333-4333-8333-000000002024"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        guard stubIsReachable() else { throw StubUnreachable(url: stub) }
    }

    // MARK: - AC-7

    func test_AC_7() {
        startApp(version: "2.6.1")
        openAlbumsTab()
        openCard(ourTrip)
        openAlbumMenu()
        XCTAssertTrue(app.buttons["Shared With"].waitForExistence(timeout: 10), "the owner's menu has no Shared With")
        app.buttons["Shared With"].tap()

        XCTAssertTrue(element("albumShareOwnerRow_\(me)").waitForExistence(timeout: 20),
                      "the owner row must be the user designated by ownerId — elements: \(describeScreen())")
        XCTAssertFalse(element("albumShareOwnerRow_\(alice)").exists,
                       "the first v2 member (an editor) must not be shown as the owner")
        XCTAssertTrue(element("albumShareCollaborator_\(alice)").waitForExistence(timeout: 10),
                      "the editor is listed as a collaborator")
        let role = element("albumShareRole_\(alice)")
        XCTAssertTrue(role.exists, "the role menu of the editor is missing")
        let text = "\(role.value ?? "") \(role.label)"
        XCTAssertTrue(text.contains("Editor"), "the editor must read as Editor, got: \(text)")
    }

    // MARK: - AC-9

    func test_AC_9() {
        startApp(version: "3.4.0")
        openAlbumsTab()
        openCard(carolEditable)
        openAlbumMenu()
        XCTAssertTrue(element("albumEditAction").waitForExistence(timeout: 10), "an editor on v3 must be offered the edit action")
        element("albumEditAction").tap()

        XCTAssertFalse(element("editAlbumActivityToggle").exists, "an editor never sees the activity toggle")
        replaceText(of: element("editAlbumNameField"), with: "Carol Renamed")
        replaceText(of: element("editAlbumDescriptionField"), with: "New words")
        element("editAlbumSaveButton").tap()

        XCTAssertTrue(waitForHeroTitle("Carol Renamed"), "the hero title never showed the new name")

        // Back to the list and reopen: the new values are the server's.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The list is not reloaded when the detail pops: its card may still carry the old name.
        XCTAssertTrue(tapAnyButton(["Carol Renamed", carolEditable], timeout: 30), "the album card is missing")
        XCTAssertTrue(waitForHeroTitle("Carol Renamed"))
        openAlbumMenu()
        element("albumEditAction").tap()
        XCTAssertEqual(element("editAlbumDescriptionField").value as? String, "New words")

        let patches = stubRequests().filter { $0.method == "PATCH" && $0.path == "/api/albums/\(carolEditableId)" }
        guard let patch = patches.first else {
            return XCTFail("the server never received PATCH /api/albums/\(carolEditableId) — requests: \(describeRequests())")
        }
        XCTAssertEqual(patch.body["albumName"] as? String, "Carol Renamed")
        XCTAssertEqual(patch.body["description"] as? String, "New words")
        XCTAssertNil(patch.body["isActivityEnabled"], "an editor must not send the activity key")
    }

    // MARK: - AC-10

    func test_AC_10() {
        startApp(version: "2.6.1")
        openAlbumsTab()
        // Reached through the merged list: the stub serves it only with shared=true on v2.
        openCard(carolEditable)
        openAlbumMenu()
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 10), "the album menu never opened")
        XCTAssertFalse(element("albumEditAction").exists, "an editor on 2.6.1 must not be offered the edit action")
    }

    // MARK: - AC-83

    func test_AC_83() {
        startApp(version: "2.6.2")
        openAlbumsTab()
        openCard(carolEditable)   // listed through GET /api/albums?shared=true
        openAlbumMenu()
        XCTAssertTrue(element("albumEditAction").waitForExistence(timeout: 10), "an editor on 2.6.2 is offered the edit action")
        element("albumEditAction").tap()
        XCTAssertFalse(element("editAlbumActivityToggle").exists, "an editor never sees the activity toggle")
        replaceText(of: element("editAlbumNameField"), with: "Carol Edited On 262")
        element("editAlbumSaveButton").tap()
        XCTAssertTrue(waitForHeroTitle("Carol Edited On 262"))

        let requests = stubRequests()
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.path == "/api/albums" && $0.params["shared"] == "true" },
                      "the list never asked for shared albums — requests: \(describeRequests())")
        guard let patch = requests.first(where: { $0.method == "PATCH" && $0.path == "/api/albums/\(carolEditableId)" }) else {
            return XCTFail("no PATCH for the edited album — requests: \(describeRequests())")
        }
        XCTAssertNil(patch.body["isActivityEnabled"])
    }

    // MARK: - AC-11

    func test_AC_11() {
        startApp(version: "3.4.0")
        openAlbumsTab()
        openCard(ourTrip)
        XCTAssertTrue(tile(photo2024).waitForExistence(timeout: 30), "newest-first by default: the 2024 tile is expected")

        openAlbumMenu()
        XCTAssertTrue(element("albumOrderMenu").waitForExistence(timeout: 10), "the owner's menu has no sort order")
        element("albumOrderMenu").tap()
        XCTAssertTrue(element("albumOrderOldest").waitForExistence(timeout: 10))
        element("albumOrderOldest").tap()

        XCTAssertTrue(waitForRequest { $0.method == "PATCH" && $0.path == "/api/albums/\(self.ourTripId)" && $0.body["order"] as? String == "asc" },
                      "the server never received order = asc — requests: \(describeRequests())")

        // Relaunch the app, reopen the album: the first tile is the oldest photo.
        app.terminate()
        reachAuthenticatedShell()
        openAlbumsTab()
        openCard(ourTrip)
        XCTAssertTrue(tile(photo2020).waitForExistence(timeout: 30))
        XCTAssertTrue(tile(photo2022).exists && tile(photo2024).exists)
        XCTAssertEqual(firstTileIdentifier(), "assetTile_\(photo2020)",
                       "the top-left tile must be the oldest photo — tiles: \(tileIdentifiersByPosition())")
    }

    // MARK: - Flow

    private func startApp(version: String) {
        reset()
        setProvider("manual")
        let set = stubCall("GET", "/stub/version?v=\(version)")
        XCTAssertEqual(set.status, 200, "the stub did not accept the version \(version)")
        reachAuthenticatedShell()
    }

    private func openAlbumsTab() {
        let tab = app.tabBars.buttons["Albums"].firstMatch
        guard tab.waitForExistence(timeout: 30) else {
            return XCTFail("the Albums tab is missing — tab bar buttons: \(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        }
        tab.tap()
    }

    private func openCard(_ name: String) {
        XCTAssertTrue(tapAnyButton([name], timeout: 30),
                      "no card named \(name) — buttons on screen: \(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    private func openAlbumMenu() {
        let menu = element("albumActionsMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the album menu is missing")
        menu.tap()
    }

    private func waitForHeroTitle(_ name: String, timeout: TimeInterval = 20) -> Bool {
        let title = element("albumHeroTitle")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if title.exists && title.label == name { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func replaceText(of field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "text field missing")
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement { element("assetTile_\(assetId)") }

    private func tileIdentifiersByPosition() -> [String] {
        let tiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex
        return tiles
            .map { (id: $0.identifier, frame: $0.frame) }
            .sorted { (abs($0.frame.minY - $1.frame.minY) > 4) ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
            .map(\.id)
    }

    private func firstTileIdentifier() -> String? { tileIdentifiersByPosition().first }

    private func describeScreen() -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty }
    }

    // MARK: - Wire

    private struct StubRequest {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: Any]
    }

    private func stubRequests() -> [StubRequest] {
        guard let raw = stubGET("/__requests"),
              let entries = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
            XCTFail("the stub's request log is unreadable")
            return []
        }
        return entries.map {
            StubRequest(method: $0["method"] as? String ?? "", path: $0["path"] as? String ?? "",
                        params: ($0["params"] as? [String: String]) ?? [:], body: ($0["body"] as? [String: Any]) ?? [:])
        }
    }

    private func describeRequests() -> String {
        stubRequests().map { "\($0.method) \($0.path) \($0.params) \($0.body)" }.joined(separator: "\n")
    }

    private func waitForRequest(timeout: TimeInterval = 20, _ matches: (StubRequest) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if stubRequests().contains(where: matches) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
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

    private func stubCall(_ method: String, _ path: String, timeout: TimeInterval = 10) -> (status: Int?, json: Any?) {
        guard let url = URL(string: "\(stub)\(path)") else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var payload: Any?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if let data { payload = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else { return (nil, nil) }
        return (status, payload)
    }

    private func stubIsReachable() -> Bool {
        stubCall("GET", "/api/server/ping", timeout: 3).status == 200
    }

    private func reset() {
        let body = stubGET("/__reset")
        XCTAssertEqual(body?.contains("\"reset\"") ?? false, true, "the stub did not answer /__reset (got \(body ?? "nothing"))")
    }

    private func setProvider(_ mode: String) {
        let body = stubGET("/__provider?mode=\(mode)")
        XCTAssertEqual(body, "{\"provider\": \"\(mode)\"}", "Stub did not answer /__provider")
    }

    private struct StubUnreachable: Error, CustomStringConvertible {
        let url: String
        var description: String { "Local Immich stub not running on \(url) — a skipped or unreachable run is a failure" }
    }

    // MARK: - Sign-in (copied from AlbumPaginationUITests, the reference)

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

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    private enum Launch: Equatable { case welcome, shell, neither }

    private func welcomeOrShell() -> Launch {
        let shell = app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch
        if shell.exists { return .shell }
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
            XCTFail("Login screen did not appear — screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    private func reachAuthenticatedShell() {
        app.launch()
        if waitForEither(timeout: 30, welcomeOrShell) == .welcome {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30),
                      "the authenticated shell never appeared — screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(stubRequests().isEmpty, "the app has sent \(stub) nothing — a session restored from another slot's port?")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }
    }
}
