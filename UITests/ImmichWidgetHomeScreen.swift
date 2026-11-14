import XCTest

/// End-to-end verification of the Home Screen widget (issue #19): signs in
/// against the local stub, adds the Photos widget through SpringBoard, then
/// screenshots and logs what the widget process actually fetched.
///
/// Why this test exists: the widget runs in its ownext process, with its own
/// Info.plist (App Transport Security) and its own keychain access. Neither is
/// exercised by the unit tests, and both were wrong on 2026-09-13 — the appex
/// had no ATS exception (so an HTTP server is unreachable from the widget) and
/// the session was never written to the shared keychain group. The widget then
/// rendered an empty tile with a perfectly green test suite.
///
/// The device must be signed in already (`ImmichRenderScreenshots` walks the
/// OAuth flow) and the stub must answer on 8421:
///
///     python3 UITests/stubs/immich_stub_memories.py 8421
///
/// Skips when either is missing, so a plain scheme run stays green.
final class ImmichWidgetHomeScreen: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        print("SHOT /tmp/shot-\(name).png")
    }

    /// First *hittable* button whose label contains `text`. The edit-mode menu
    /// stays in the hierarchy behind every sheet, so a plain lookup can tap a
    /// hidden copy and silently do nothing.
    private func hittableButton(containing text: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let query = springboard.buttons.matching(predicate)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0..<query.count where query.element(boundBy: index).isHittable {
                return query.element(boundBy: index)
            }
            usleep(400_000)
        }
        return nil
    }

    func test_photosWidgetShowsPhotos() throws {
        app.launch()
        // The widget reads the session the app publishes on launch: without a
        // signed-in app there is nothing for it to draw.
        try XCTSkipUnless(
            app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
            "Sign in first (ImmichRenderScreenshots/test_01_onboardingAndOAuthSignIn)"
        )
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("wg-01-home")

        // Home Screen → edit mode → widget gallery.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2.0)
        sleep(3)
        if let edit = hittableButton(containing: "Modifier", timeout: 6) ?? hittableButton(containing: "Edit", timeout: 2) {
            edit.tap()
            sleep(2)
        }
        shot("wg-02-edit-mode")

        guard let addWidget = hittableButton(containing: "Ajouter un widget", timeout: 8)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the edit menu has no widget entry — SpringBoard flow changed")
        }
        addWidget.tap()
        sleep(4)
        shot("wg-03-gallery")

        let gallerySearch = springboard.searchFields["Rechercher des widgets"].firstMatch
        guard gallerySearch.waitForExistence(timeout: 15) else {
            return XCTFail("widget gallery never appeared")
        }
        gallerySearch.tap()
        gallerySearch.typeText("Swimmich")
        sleep(3)
        shot("wg-04-search")

        let result = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Swimmich'")).firstMatch
        guard result.waitForExistence(timeout: 10) else {
            return XCTFail("the gallery lists no Swimmich widget")
        }
        result.tap()
        sleep(3)
        shot("wg-05-widget-options")

        // The sheet opens on the first widget of the bundle (the backup tile) and
        // pages horizontally: walk to the Photos one, which is what this test is
        // about — and about what made the failure visible in the first place.
        // The pager is the widget preview itself (its `value` says "Widget"), and
        // its element label is "<App>, <configuration display name>".
        let preview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Widget'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "the sheet shows no widget preview")
        // The sheet title is the widget's `configurationDisplayName`, localized
        // ("Photos Swimmich" here) — match on the word, not on the English order.
        let photosTitle = springboard.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Photos'")).firstMatch
        for page in 0..<8 where !photosTitle.exists {
            preview.swipeLeft()
            sleep(2)
            print("PAGE \(page + 1): \(preview.label)")
        }
        shot("wg-05b-photos-page")
        XCTAssertTrue(photosTitle.waitForExistence(timeout: 5), "never reached the Photos widget page")

        // The sheet's own button reads "Ajouter le widget" — not the edit menu's
        // "Ajouter un widget".
        guard let place = hittableButton(containing: "Ajouter le widget", timeout: 10)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the widget sheet has no add button")
        }
        place.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("wg-06-home-with-widget")
        // WidgetKit asks for a timeline a few seconds after placement — this is
        // the window where the provider runs in the extension process.
        sleep(25)
        shot("wg-07-widget-rendered")
        print("WIDGET-PLACED")
    }
}

/// L-30 (B-35, AC-61.6) — what the unit tests cannot see: WidgetKit archives the
/// entry at the NEW image sizes and draws it, instead of leaving the widget on its
/// waiting state (the failure that hid for two days behind 8×8 stub images).
///
/// Against `immich_stub_widgets.py` (previews of 1440×1920 / 1920×1440, the size of a
/// real Immich preview): the app signs in, the widget is posed on the Home Screen
/// in its large size through SpringBoard, and the scenario waits for SpringBoard to
/// expose its photos — elements labelled "Photo, from <day>" (the waiting state's
/// photos have no day, hence no digit) — then reads the stub's journal: one
/// `size=preview&edited=true` request per DRAWN photo, none for the others. It
/// asserts no pixel size (SpringBoard exposes none): the sizes are proved by
/// `WidgetDisplaySizeTests`. Observed on the CI's iPhone 17 simulator, not a device.
///
/// Both tests are in `Scripts/ci-ui-scenarios.txt` with `--erase`: a widget posed by
/// an earlier test would falsify the gallery search.
final class WidgetDisplaySizeUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
    }

    /// The shell's timeline assets, in the order of the Photos wall.
    private static let assets = (1...6).map { String(format: "aaaaaaaa-1111-4111-8111-%012d", $0) }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: Tests

    /// Photos, large: the newest photo and three satellites are drawn (4 previews);
    /// the fifth photo received is not.
    func test_AC_61_6_photosLarge() throws {
        try signIn()
        try poseLargeWidget(
            title: NSPredicate(format: "label CONTAINS 'Swimmich' AND label CONTAINS 'Photos'")
        )
        XCTAssertTrue(
            waitUntil(timeout: 90) { self.photoElements().count >= 4 },
            "the large Photos widget never drew 4 dated photos — it stayed on its waiting state "
                + "(entry not archived?): \(photoElements().map(\.label))"
        )
        shot("wd-photos-large-rendered")

        let previews = previewRequests()
        for id in Self.assets.prefix(4) {
            XCTAssertTrue(previews.contains(id), "no size=preview&edited=true request for drawn photo \(id): \(previews)")
        }
        XCTAssertFalse(previews.contains(Self.assets[4]), "the fifth photo is not drawn: it must not be downloaded")
    }

    /// Favorites, large, with ONE favourite: its tile is the biggest of all (1092×1146 px).
    func test_AC_61_6_favoritesLargeOneFavorite() throws {
        try signIn()
        try poseLargeWidget(
            title: NSPredicate(format: "label CONTAINS 'Swimmich' AND (label CONTAINS 'Favorites' OR label CONTAINS 'Favoris')")
        )
        XCTAssertTrue(
            waitUntil(timeout: 90) { self.photoElements().count >= 1 },
            "the large Favorites widget never drew its photo — it stayed on its waiting state: \(photoElements().map(\.label))"
        )
        shot("wd-favorites-large-rendered")

        let previews = previewRequests()
        XCTAssertTrue(previews.contains(Self.assets[0]), "the favourite was not asked at size=preview&edited=true: \(previews)")
    }

    // MARK: Widget on the Home Screen

    /// Elements SpringBoard exposes for the photos a widget draws: "Photo, from
    /// <day>" or "Video …". The label carries a digit (the day), the waiting
    /// state's does not, and neither does the Photos app icon.
    private func photoElements() -> [XCUIElement] {
        let predicate = NSPredicate(
            format: "(label BEGINSWITH 'Photo' OR label BEGINSWITH 'Video' OR label BEGINSWITH 'Vidéo') AND label MATCHES '.*[0-9].*'"
        )
        return springboard.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
    }

    /// Poses the widget whose sheet title matches `title`, in its large size, and
    /// checks what SpringBoard shows is a large widget (at least 0.8 × the
    /// screen's width, at least as tall as wide).
    private func poseLargeWidget(title: NSPredicate) throws {
        sleep(3)
        reset()
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("wd-01-home")

        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2.0)
        sleep(3)
        if let edit = hittableButton(containing: "Modifier", timeout: 6) ?? hittableButton(containing: "Edit", timeout: 2) {
            edit.tap()
            sleep(2)
        }
        guard let addWidget = hittableButton(containing: "Ajouter un widget", timeout: 8)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the edit menu has no widget entry — SpringBoard flow changed")
        }
        addWidget.tap()
        sleep(4)

        let gallerySearch = [springboard.searchFields["Rechercher des widgets"], springboard.searchFields["Search Widgets"]]
            .first { $0.waitForExistence(timeout: 8) }
        guard let gallerySearch else { return XCTFail("the widget gallery never appeared") }
        gallerySearch.tap()
        gallerySearch.typeText("Swimmich")
        sleep(3)
        let result = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Swimmich'")).firstMatch
        guard result.waitForExistence(timeout: 10) else { return XCTFail("the gallery lists no Swimmich widget") }
        result.tap()
        sleep(3)

        // The sheet pages horizontally over the bundle's widgets, each in its sizes
        // (small, medium, large): reach the widget's page, then its large size.
        let preview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Widget'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "the sheet shows no widget preview")
        let widgetTitle = springboard.staticTexts.matching(title).firstMatch
        for _ in 0..<12 where !widgetTitle.exists {
            preview.swipeLeft()
            sleep(2)
        }
        XCTAssertTrue(widgetTitle.waitForExistence(timeout: 5), "never reached the widget's page")
        for _ in 0..<2 {
            preview.swipeLeft()
            sleep(2)
        }
        shot("wd-02-large-page")

        guard let place = hittableButton(containing: "Ajouter le widget", timeout: 10)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the widget sheet has no add button")
        }
        place.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("wd-03-home-with-widget")

        let width = springboard.frame.width
        let posed = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Swimmich'")).allElementsBoundByIndex
        XCTAssertTrue(
            posed.contains { $0.frame.width >= 0.8 * width && $0.frame.height >= $0.frame.width },
            "the widget posed is not large — SpringBoard shows \(posed.map { "\($0.label) \($0.frame)" })"
        )
    }

    // MARK: Stub journal

    /// Ids asked at `size=preview&edited=true`, from the stub's journal.
    private func previewRequests() -> [String] {
        stubRequests().compactMap { request -> String? in
            let parts = request.path.split(separator: "/").map(String.init)
            guard request.method == "GET", parts.count == 4, parts[0] == "api", parts[1] == "assets", parts[3] == "thumbnail",
                  request.params["size"] == "preview", request.params["edited"] == "true"
            else { return nil }
            return parts[2]
        }
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

    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    // MARK: Sign-in (copied from EditStacksUITests: one file per feature)

    private func signIn() throws {
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(
            app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch.waitForExistence(timeout: 30),
            "OAuth did not reach the authenticated shell"
        )
        let done = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if done.waitForExistence(timeout: 5) {
            done.tap()
            XCTAssertTrue(waitUntil(timeout: 10) { !done.exists }, "What's New never closed")
        }
    }

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seededURL = (field.value as? String) ?? ""
        if !seededURL.isEmpty && seededURL != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seededURL.count))
        }
        if (field.value as? String) != stub {
            field.typeText(stub)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        // The CTA sits under the keyboard the URL raised: scrolling dismisses it.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("wd-900-not-on-login-screen")
            XCTFail("Login screen did not appear")
        }
    }

    private func dismissSystemSignInAlertIfPresent() {
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

    /// The provider page loads in another process (`SafariViewService`): while the
    /// "Authorize" link is awaited, the system's sign-in consent is accepted whenever it is up.
    private func tapAuthorizeInProvider(timeout: TimeInterval = 60) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        let consent = NSPredicate(format: "label IN %@", ["Continue", "Continuer"])
        let candidates = [safari.links.matching(predicate).firstMatch, safari.buttons.matching(predicate).firstMatch]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let authorize = candidates.first(where: { $0.exists }) {
                authorize.tap()
                return true
            }
            for button in [springboard.alerts.buttons.matching(consent).firstMatch,
                           app.alerts.buttons.matching(consent).firstMatch] where button.exists {
                button.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: Helpers

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// First *hittable* SpringBoard button whose label contains `text` (the edit-mode
    /// menu stays in the hierarchy behind every sheet).
    private func hittableButton(containing text: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let query = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", text))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0..<query.count where query.element(boundBy: index).isHittable {
                return query.element(boundBy: index)
            }
            usleep(400_000)
        }
        return nil
    }

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

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }
}

/// L-21 (B-25, AC-193) — the Photos widget, posed on the Home Screen in its large size, shows the edited
/// version once the app has saved a server edit and the server has regenerated the thumbnails.
///
/// Against `immich_stub_asset_edits.py` with `regen=5`: the widget draws the photo (the stub serves the
/// original), then the app saves a crop (`PUT /api/assets/{id}/edits`); the server keeps serving the
/// original for 5 s, and within 10 s of the switch the widget must ask `size=preview&edited=true` again
/// and receive the edited rendering. The widget's request is the one WITHOUT `c=` (the app's carry the
/// thumbhash); the stub's journal says which rendering it served (`edited_served`). SpringBoard exposes
/// no pixel, only the elements "Photo, from <day>": the scenario asserts that they are still drawn, and
/// that the bytes the widget received are the edited ones. Observed on the CI's iPhone 17 simulator.
///
/// In `Scripts/ci-ui-scenarios.txt` with `--erase`: a widget posed by an earlier test would falsify the
/// gallery search. Helpers are copied from `WidgetDisplaySizeUITests` (one file per feature, helpers included).
final class EditedWidgetUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    /// The first of the stub's six timeline photos, the newest of the large Photos widget's wall.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: Test

    func test_AC_193_widgetShowsTheEditedImageAfterTheEdit() throws {
        get("/__reset")
        get("/__provider?mode=manual")
        launchSignedIn()
        try poseLargeWidget()

        XCTAssertTrue(
            waitUntil(timeout: 90) { self.photoElements().count >= 4 && !self.widgetPreviews().isEmpty },
            "the large Photos widget never drew its photos and asked the preview — \(photoElements().map(\.label)) \(describe())"
        )
        let drawn = widgetPreviews()
        XCTAssertTrue(drawn.allSatisfy { $0["edited_served"] as? Bool == false },
                      "before the edit the widget receives the original — \(describe())")
        for entry in drawn {
            XCTAssertEqual((entry["params"] as? [String: Any])?["edited"] as? String, "true")
        }

        get("/api/__edits/config?regen=5")
        app.activate()
        let tile = app.descendants(matching: .any).matching(identifier: "assetTile_\(photo)").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the app lost its timeline")
        tile.tap()
        let edit = app.descendants(matching: .any).matching(identifier: "viewerEditButton").firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "the viewer has no edit button")
        edit.tap()
        let mode = app.descendants(matching: .any).matching(identifier: "editorSaveModeLabel").firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 20), "the editor never loaded the photo's context")
        tapEditor("ratioButton.fourByThree")
        let save = app.descendants(matching: .any).matching(identifier: "editorSaveButton").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), "no Save button")
        XCTAssertTrue(waitUntil(timeout: 10) { save.isEnabled }, "Save stayed disabled")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { !self.journalEntries("PUT", "/api/assets/\(self.photo)/edits").isEmpty },
                      "no PUT /edits — \(describe())")
        XCTAssertTrue(journalEntries("POST", "/api/assets").isEmpty, "no new asset: the edits are saved on the photo")

        // The server switches 5 s after the PUT; the widget has 10 s from then.
        let state = getJSON("/api/__edits/state?id=\(photo)")
        let now = (state["now"] as? Double) ?? 0
        let readyAt = (state["readyAt"] as? Double) ?? now
        shot("we-01-after-save")
        let window = max(0, readyAt - now) + 10
        XCTAssertTrue(
            waitUntil(timeout: window) { self.widgetReceivedEditedPreview(after: readyAt) },
            "within 10 s of the switch the widget never asked for, and received, the edited preview — \(describe())"
        )
        for entry in widgetPreviews() {
            XCTAssertEqual((entry["params"] as? [String: Any])?["edited"] as? String, "true", "\(describe())")
        }
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("we-02-home-after-switch")
        XCTAssertGreaterThanOrEqual(photoElements().count, 4, "the widget stopped drawing its photos")
    }

    // MARK: Widget requests

    /// The widget's `GET …/thumbnail?size=preview` of the photo: no `c` (the app's carry the thumbhash).
    private func widgetPreviews() -> [[String: Any]] {
        journal().filter { entry in
            guard entry["method"] as? String == "GET",
                  entry["path"] as? String == "/api/assets/\(photo)/thumbnail",
                  let params = entry["params"] as? [String: Any] else { return false }
            return params["size"] as? String == "preview" && params["c"] == nil
        }
    }

    /// The widget asked for the preview after `time` and the stub served it the edited rendering.
    private func widgetReceivedEditedPreview(after time: Double) -> Bool {
        for entry in widgetPreviews() {
            guard let at = entry["at"] as? Double, let served = entry["edited_served"] as? Bool else { continue }
            if at >= time && served { return true }
        }
        return false
    }

    private func journalEntries(_ method: String, _ path: String) -> [[String: Any]] {
        journal().filter { $0["method"] as? String == method && $0["path"] as? String == path }
    }

    private func describe() -> String {
        journal().map { "\($0["method"] ?? "") \($0["path"] ?? "") \($0["params"] ?? "") \($0["edited_served"] ?? "")" }
            .joined(separator: "\n")
    }

    private func journal() -> [[String: Any]] {
        let object = try? JSONSerialization.jsonObject(with: fetch("/__requests"))
        return (object as? [[String: Any]]) ?? []
    }

    private func getJSON(_ path: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: fetch(path))
        return (object as? [String: Any]) ?? [:]
    }

    private func fetch(_ path: String) -> Data {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var payload = Data()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { payload = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return payload
    }

    private func get(_ path: String) { _ = fetch(path) }

    // MARK: The app

    /// Launches signed in on the session the stub's SSO sign-in hands out, as the launch arguments of
    /// `AuthViewModel`'s keys: the app restores it and publishes it to the widget's shared keychain.
    private func launchSignedIn() {
        var request = URLRequest(url: URL(string: "\(stub)/api/oauth/callback")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var login: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            login = (object as? [String: Any]) ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        guard let token = login["accessToken"] as? String else {
            return XCTFail("the stub's /api/oauth/callback gave no session: \(login)")
        }
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestImageProbe", "YES",
            "-uiTestSessionToken", token, "-authServerURL", stub,
            "-authUserId", (login["userId"] as? String) ?? "",
            "-authUserName", (login["name"] as? String) ?? "",
            "-authUserEmail", (login["userEmail"] as? String) ?? "",
            "-authIsAdmin", ((login["isAdmin"] as? Bool) ?? false) ? "YES" : "NO",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30), "the app did not start signed in")
        let done2 = app.descendants(matching: .any).matching(identifier: "whatsNewDoneButton").firstMatch
        if done2.waitForExistence(timeout: 10) { done2.tap() }
        let tile = app.descendants(matching: .any).matching(identifier: "assetTile_\(photo)").firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the timeline never rendered")
        // The widget reads the session the app publishes once the stored session is validated.
        sleep(3)
    }

    /// Taps an editor control, scrolling the editor up while it is not hittable.
    private func tapEditor(_ identifier: String) {
        let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) missing")
        for _ in 0..<5 where !control.isHittable { app.swipeUp() }
        control.tap()
    }

    // MARK: Widget on the Home Screen

    /// Elements SpringBoard exposes for the photos a widget draws: "Photo, from <day>" (the waiting
    /// state's have no day, hence no digit).
    private func photoElements() -> [XCUIElement] {
        let predicate = NSPredicate(
            format: "(label BEGINSWITH 'Photo' OR label BEGINSWITH 'Video' OR label BEGINSWITH 'Vidéo') AND label MATCHES '.*[0-9].*'"
        )
        return springboard.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
    }

    /// Poses the Photos widget in its large size through SpringBoard (the sequence of `WidgetDisplaySizeUITests`).
    private func poseLargeWidget() throws {
        XCUIDevice.shared.press(.home)
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2.0)
        sleep(3)
        if let edit = hittableButton(containing: "Modifier", timeout: 6) ?? hittableButton(containing: "Edit", timeout: 2) {
            edit.tap()
            sleep(2)
        }
        guard let addWidget = hittableButton(containing: "Ajouter un widget", timeout: 8)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the edit menu has no widget entry — SpringBoard flow changed")
        }
        addWidget.tap()
        sleep(4)

        let gallerySearch = [springboard.searchFields["Rechercher des widgets"], springboard.searchFields["Search Widgets"]]
            .first { $0.waitForExistence(timeout: 8) }
        guard let gallerySearch else { return XCTFail("the widget gallery never appeared") }
        gallerySearch.tap()
        gallerySearch.typeText("Swimmich")
        sleep(3)
        let result = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Swimmich'")).firstMatch
        guard result.waitForExistence(timeout: 10) else { return XCTFail("the gallery lists no Swimmich widget") }
        result.tap()
        sleep(3)

        let preview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Widget'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "the sheet shows no widget preview")
        let title = NSPredicate(format: "label CONTAINS 'Swimmich' AND label CONTAINS 'Photos'")
        let widgetTitle = springboard.staticTexts.matching(title).firstMatch
        for _ in 0..<12 where !widgetTitle.exists {
            preview.swipeLeft()
            sleep(2)
        }
        XCTAssertTrue(widgetTitle.waitForExistence(timeout: 5), "never reached the widget's page")
        for _ in 0..<2 {
            preview.swipeLeft()
            sleep(2)
        }
        guard let place = hittableButton(containing: "Ajouter le widget", timeout: 10)
                ?? hittableButton(containing: "Add Widget", timeout: 2) else {
            return XCTFail("the widget sheet has no add button")
        }
        place.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("we-00-home-with-widget")
    }

    // MARK: Helpers

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// First *hittable* SpringBoard button whose label contains `text` (the edit-mode menu stays in the
    /// hierarchy behind every sheet).
    private func hittableButton(containing text: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let query = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", text))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0..<query.count where query.element(boundBy: index).isHittable {
                return query.element(boundBy: index)
            }
            usleep(400_000)
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }
}
