import XCTest

/// End-to-end scenarios for the floating-control style (L-15, AC-30): the
/// controls that float above photos, the map and the timeline share one dark
/// glass, and keep the identifiers and labels they had before it.
///
/// The contrast itself is measured by `FloatingControlStyleTests` from the
/// style's tokens. What a unit test cannot show is the glass over a REAL white
/// photo and a real light map, so this scenario opens the viewer on a pure
/// white photo (`immich_stub_floating_controls.py`), opens the map, and attaches
/// a capture of each, in light then dark appearance. Reading the captures is the
/// reviewer's half of the proof; the assertions here are that every control
/// exists and is touchable (a control hidden behind a mis-ordered glass would
/// not be).
///
/// Run it with the launcher, on an erased device:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/floating.uitest.log \
///         UITests/stubs/immich_stub_floating_controls.py FloatingControlsUITests/<test> --erase
final class FloatingControlsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private let whiteAsset = "aaaaaaaa-1111-4111-8111-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .unspecified
        super.tearDown()
    }

    // MARK: - Helpers (one file per feature, helpers included — see MapSettingsUITests)

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
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "Stub did not answer")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(
            data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func dismissSystemSignInAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Continue", "Continuer"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 6) { button.tap(); return }
        }
        for label in ["Continue", "Continuer"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); return }
        }
    }

    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch, safari.buttons.matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
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
    }

    /// Onboarding → OAuth → the timeline, "What's New" cleared.
    private func reachTimeline() {
        reset()
        setProvider("manual")
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(element("assetTile_\(whiteAsset)").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub)")
    }

    private func assertTouchable(_ identifier: String, _ context: String, timeout: TimeInterval = 20) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: timeout), "\(identifier) missing \(context)")
        XCTAssertTrue(control.isHittable, "\(identifier) is not touchable \(context)")
    }

    // MARK: - Scenarios

    /// AC-30.4: the viewer over a pure white photo and the map keep their
    /// controls and identifiers, in both appearances; captures are attached.
    func test_AC_30_4_controlsOnWhitePhotoAndLightMapKeepTheirIdentifiers() throws {
        reachTimeline()
        let appearances: [(String, XCUIDevice.Appearance)] = [("light", .light), ("dark", .dark)]
        for (name, appearance) in appearances {
            XCUIDevice.shared.appearance = appearance
            let context = "(\(name) appearance)"

            let tile = element("assetTile_\(whiteAsset)")
            XCTAssertTrue(tile.waitForExistence(timeout: 20), "the white photo's tile is missing \(context)")
            tile.tap()
            assertTouchable("viewerBackButton", "in the viewer \(context)")
            assertTouchable("viewerOverflowMenu", "in the viewer \(context)", timeout: 10)
            sleep(1) // the zoom-in and the glass settle before the capture
            capture("viewer-white-\(name)")
            element("viewerBackButton").tap()
            XCTAssertTrue(element("assetTile_\(whiteAsset)").waitForExistence(timeout: 20),
                          "the viewer did not close \(context)")

            let search = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherche", "Suche"])).firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 20), "Search tab missing \(context)")
            search.tap()
            let mapSegment = element("searchModeSegment_map")
            XCTAssertTrue(mapSegment.waitForExistence(timeout: 20), "the Map segment is missing \(context)")
            mapSegment.tap()
            assertTouchable("mapSettingsButton", "on the map \(context)", timeout: 25)
            sleep(2) // map tiles
            capture("map-\(name)")

            app.tabBars.buttons["Photos"].tap()
        }
    }

    /// AC-30: the timeline's own floating controls keep their identifiers.
    func test_AC_30_timelineControlsKeepIdentifiers() throws {
        XCUIDevice.shared.appearance = .light
        reachTimeline()
        assertTouchable("selectButton", "on the timeline")
        assertTouchable("filterMenu", "on the timeline")
        assertTouchable("syncStatusButton", "on the timeline")

        let toTop = element("timelineScrollToTopButton")
        for _ in 0..<6 where !toTop.exists {
            app.swipeUp()
        }
        XCTAssertTrue(toTop.waitForExistence(timeout: 10), "scrolling down never showed the scroll-to-top button")
        capture("timeline-light")
    }
}
