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
