import XCTest

/// End-to-end scenario for the Timeline's "Favorites" filter: the viewer opened
/// from the filtered grid un-favorites then re-favorites a photo.
///
/// What the scenario proves, on the WIRE and on the screen:
///
/// 1. With the filter on, `GET /api/timeline/bucket` carries `isFavorite=true`
///    like `/buckets` does (the stub answers the whole timeline otherwise).
/// 2. The viewer's heart writes `PUT /api/assets/:id` with `isFavorite`
///    false, then true — the second tap is a write even though the first one
///    already took the photo out of the grid (`TimelineView` calls
///    `vm.setFavorite(id:isFavorite:)` with the viewer's target value, not a
///    toggle that would no-op on an id the grid no longer holds).
/// 3. The viewer stays on the photo (the second tap reaches the same heart),
///    the grid has lost the tile on close, and it shows it again after a
///    refresh: the stub's favorites follow the writes, so that is the proof the
///    re-favorite reached the server.
///
/// One `XCTestCase` per feature, in its own file, against its own committed
/// stub. The helpers are copied from `StarRatingsUITests` on purpose (the
/// repository's rule: no shared UI-test support file).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/favorites-filter.uitest.log \
///         UITests/stubs/immich_stub_favorites_filter.py \
///         FavoritesFilterUITests/test_AC21_viewerUnfavoriteThenRefavorite
final class FavoritesFilterUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The shell's first timeline asset.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

    /// The one asset the stub leaves NON-favorite at reset (`WITNESS` in
    /// `immich_stub_favorites_filter.py`): on the All grid, never on the
    /// Favorites one. Its tile tells which of the two grids is on screen.
    private let witness = "aaaaaaaa-1111-4111-8111-000000000006"

    private let favoritesLabels = ["Favorites", "Favoris", "Favoriten", "Favoritos", "Preferiti"]
    private let allLabels = ["All", "Tout", "Alle", "Todos", "Tutti"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The scenario's onboarding and `app.tabBars.buttons["Photos"]` only know
        // English labels (French too for the onboarding): pin the language.
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

    // MARK: - Helpers (copied from StarRatingsUITests)

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    private func setProvider(_ mode: String) {
        let url = URL(string: "\(stub)/__provider?mode=\(mode)")!
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "Stub did not answer")
        XCTAssertEqual(body, "{\"provider\": \"\(mode)\"}")
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

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
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

    /// Welcome → server URL → login. Leaves the app on the login screen.
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
            shot("s02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    private func tapTile(_ assetId: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = tile(assetId)
        guard tile.waitForExistence(timeout: 30) else {
            let tiles = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
                .allElementsBoundByIndex.map(\.identifier)
            return XCTFail("the timeline never rendered \(tiles.count) tiles (\(tiles)) against \(stub); "
                           + "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))",
                           file: file, line: line)
        }
        if tile.isHittable {
            tile.tap()
        } else {
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    // MARK: - Filter menu

    /// Opens the filter menu and taps the entry whose label is EXACTLY one of
    /// `labels` ("All" must not match a button that merely contains "All").
    private func chooseFilter(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.buttons.matching(identifier: "filterMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the filter menu is missing", file: file, line: line)
        menu.tap()
        let exact = NSPredicate(format: "label IN %@", labels)
        let item = app.descendants(matching: .any).matching(exact).firstMatch
        guard item.waitForExistence(timeout: 10) else {
            return XCTFail("the filter menu has no entry among \(labels) — screen reads: "
                           + "\(app.descendants(matching: .any).allElementsBoundByIndex.map(\.label))",
                           file: file, line: line)
        }
        item.tap()
    }

    // MARK: - Grid helpers

    private func visibleTileIdentifiers() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    /// The All grid is on screen: it shows the non-favorite witness.
    private func waitForAllGrid(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile(witness).waitForExistence(timeout: 30),
                      "the All grid never showed the non-favorite witness \(witness) — tiles: \(visibleTileIdentifiers())",
                      file: file, line: line)
    }

    /// The Favorites grid, reloaded from the server, is on screen. `reloadFirstPage`
    /// keeps the previous grid until the first bucket arrives and restores it if
    /// that bucket fails: the witness leaving proves the filtered response is
    /// shown, and not coming back with the photo proves it was not a restore.
    private func waitForFavoritesGrid(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tile(witness).waitForNonExistence(timeout: 30),
                      "the non-favorite witness is still on screen: the Favorites grid never replaced the All grid",
                      file: file, line: line)
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30), message, file: file, line: line)
        XCTAssertFalse(tile(witness).exists,
                       "the witness came back with the photo: the Favorites bucket failed and the All grid was restored",
                       file: file, line: line)
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let isFavoriteSent: Bool?
    }

    private func stubRequests() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func favoriteWrites() -> [StubRequest] {
        stubRequests().filter { $0.method == "PUT" && $0.path == "/api/assets/\(photo)" }
    }

    /// The favorite writes logged so far, re-read until there are `count` of
    /// them (bounded: it reports what it saw instead of sleeping a fixed time).
    private func waitForFavoriteWrites(_ count: Int, timeout: TimeInterval = 20) -> [StubRequest] {
        var found = favoriteWrites()
        let deadline = Date().addingTimeInterval(timeout)
        while found.count < count, Date() < deadline {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "stub poll")], timeout: 0.5)
            found = favoriteWrites()
        }
        return found
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params) isFavoriteSent=\(String(describing: $0.isFavoriteSent))" }
            .joined(separator: "\n")
    }

    // MARK: - Scenario

    func test_AC21_viewerUnfavoriteThenRefavorite() throws {
        // 1. Launch and enter the app.
        reset()
        setProvider("manual")
        app.launch()

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("s01-welcome")
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

        // 2. Filter the timeline on favorites.
        waitForAllGrid()
        chooseFilter(favoritesLabels)

        // 3. The month's content was asked with the same filter as the month list.
        waitForFavoritesGrid("the Favorites grid never showed the photo")
        let bucketReads = stubRequests().filter { $0.method == "GET" && $0.path == "/api/timeline/bucket" }
        XCTAssertTrue(bucketReads.contains { $0.params["isFavorite"] == "true" },
                      "no GET /api/timeline/bucket carried isFavorite=true — got:\n\(describe(bucketReads))")
        shot("s04-favorites-grid")

        // 4. Open the viewer on the photo.
        tapTile(photo)
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer never showed its chrome")
        let heart = app.buttons.matching(identifier: "viewerFavoriteButton").firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 20), "the viewer has no favorite button")

        // 5. Un-favorite: PUT isFavorite=false.
        heart.tap()
        let first = waitForFavoriteWrites(1)
        guard first.count >= 1 else {
            shot("s05b-no-unfavorite-write")
            return XCTFail("the un-favorite never reached the stub:\n\(describe(stubRequests()))")
        }
        XCTAssertEqual(first[0].isFavoriteSent, false, "the first heart tap must write isFavorite=false")

        // 6. Re-favorite: the viewer is still on the photo, the write is sent
        // although the grid already lost the tile.
        XCTAssertTrue(heart.waitForExistence(timeout: 10), "the viewer left the photo after the un-favorite")
        heart.tap()
        let writes = waitForFavoriteWrites(2)
        guard writes.count == 2 else {
            shot("s06b-no-refavorite-write")
            return XCTFail("expected 2 favorite writes, saw \(writes.count):\n\(describe(stubRequests()))")
        }
        XCTAssertEqual(writes.map(\.isFavoriteSent), [false, true],
                       "the writes must be un-favorite then re-favorite — got:\n\(describe(writes))")

        // 7. Close: the grid reflects the un-favorite, the re-favorite is not re-inserted.
        back.tap()
        XCTAssertTrue(tile(photo).waitForNonExistence(timeout: 20),
                      "the un-favorited photo is still in the Favorites grid")
        shot("s07-grid-without-photo")

        // 8. Refresh through the menu: All, then Favorites again.
        chooseFilter(allLabels)
        waitForAllGrid()
        chooseFilter(favoritesLabels)

        // 9. The re-favorite was written: the photo is back.
        waitForFavoritesGrid("the re-favorited photo never came back after a refresh")
        shot("s09-grid-with-photo")
    }
}
