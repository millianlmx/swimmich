import XCTest

/// End-to-end scenario for the adjust-location sheet (L-25, B-29.1): typed
/// latitude/longitude, the pin that follows them, validation, and adding a
/// location to a photo that has none. Drives the real app (onboarding → SSO →
/// timeline → viewer → info panel → sheet) against
/// `UITests/stubs/immich_stub_adjust_location.py`, and asserts on the WIRE
/// (`PUT /api/assets/:id` bodies read from `/__requests`).
///
/// Every touch goes through accessibility identifiers, never localized text.
/// The minus sign is typed by tapping the "-" key of the keyboard the field
/// raises (the signed keyboard is part of the contract); the save button is
/// always touched with the keyboard still open and no Return pressed.
///
/// One `XCTestCase` per feature, helpers copied from `StarRatingsUITests`
/// (private there, and the shared file stays frozen). Run it with the launcher:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/adjust-location.uitest.log \\
///         UITests/stubs/immich_stub_adjust_location.py AdjustLocationUITests
final class AdjustLocationUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The shell's first and second timeline assets: the stub gives the first
    /// one coordinates (45.5 / 6.8) and leaves the second without.
    private let located = "aaaaaaaa-1111-4111-8111-000000000001"
    private let unlocated = "aaaaaaaa-1111-4111-8111-000000000002"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip-vs-run only, so a full-scheme run without a stub stays green.
        // `uitest.sh` starts the stub first and treats a skip as a failure, so
        // this never masks anything under the launcher.
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

    // MARK: - Helpers
    //
    // Copied from `RecentlyTakenUITests` / `ImmichRenderScreenshots` on purpose:
    // these are `private` there, and the shared file is frozen (its scenarios
    // are green against its current text). Extracting them into a shared support
    // file would be a second convention next to the existing one — the harness
    // rule is one file per feature, helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log, so
    /// no assertion below can be satisfied by a previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks, like `test_01` of the shared class.
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

    /// A viewer top-bar action (SP-6): its pill when the row carries it, else
    /// the "⋯" menu's item — by identifier, then by label, because a menu item
    /// may publish as `.menuItem` or `.button`. Taps what it returns.
    private func viewerAction(id: String, menu: String, labels: [String]) -> XCUIElement {
        let pill = app.buttons.matching(identifier: id).firstMatch
        if pill.exists {
            pill.tap()
            return pill
        }
        let overflow = app.buttons.matching(identifier: "viewerOverflowMenu").firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 15),
                      "\(id) is neither on the viewer's row nor behind ⋯")
        overflow.tap()
        let anyElement = app.descendants(matching: .any)
        var item = anyElement.matching(identifier: menu).firstMatch
        if !item.waitForExistence(timeout: 5) {
            item = anyElement.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "⋯ holds neither \(menu) nor \(labels) — screen reads: "
                        + "\(anyElement.allElementsBoundByIndex.map(\.label))")
        item.tap()
        return item
    }

    /// Waits for any button whose label contains `text` and taps it. Case
    /// sensitive on purpose: the keyboard's return key is labelled "continuer"
    /// in lowercase and would shadow the "Continuer" CTA.
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

    /// The onboarding copy is localized (issue #21), and the repo's own
    /// simulator is in German while the runs use English slots: a walk accepts
    /// both, never one hard-coded language.
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

    /// The provider page loads in another process (`SafariViewService`), slowly on a
    /// loaded Mac, and the system's sign-in consent can show late: while the
    /// "Authorize" link is awaited, the consent is accepted whenever it is up.
    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 60) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
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

    /// Welcome → server URL → login. Leaves the app on the login screen.
    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        // The field can hold the PREVIOUS run's URL — a warm slot seeds it — and
        // `typeText` APPENDS. With a random stub port per run that value is
        // always stale, so it is cleared before typing rather than trusted.
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
        // Typing the URL raised the keyboard, and the CTA sits under it: a tap
        // computed from the button's frame then lands on the keyboard and the
        // flow never leaves this screen (measured — it cost one run in two).
        // Scrolling dismisses the keyboard (`.scrollDismissesKeyboard(.immediately)`),
        // so the CTA is really hittable when it is tapped, and a bounded retry
        // covers the frame the keyboard was still animating over.
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

    /// Opens the photo viewer on a timeline tile. The identifier sits on the
    /// image LAYER inside the cell (never on the cell's container, which would
    /// erase it), so the element is not always reported as hittable; the tap is
    /// then sent to its centre by coordinate, which is the same point.
    private func tapTile(_ assetId: String, file: StaticString = #filePath, line: UInt = #line) {
        let tile = app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
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

    // MARK: - Wire helpers

    /// One entry of the stub's request log; the two coordinates are what the
    /// stub's `req.note` recorded from the body of a write.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let latitudeSent: Double?
        let longitudeSent: Double?
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

    private func locationWrites(_ id: String) -> [StubRequest] {
        stubRequests().filter { $0.method == "PUT" && $0.path == "/api/assets/\(id)" }
    }

    private func waitForLocationWrites(_ id: String, count: Int, timeout: TimeInterval = 20) -> [StubRequest] {
        var found = locationWrites(id)
        let deadline = Date().addingTimeInterval(timeout)
        while found.count < count, Date() < deadline {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "stub poll")], timeout: 0.5)
            found = locationWrites(id)
        }
        return found
    }

    // MARK: - Screen helpers

    private func signIn() {
        reset()
        setProvider("manual")
        app.launchArguments += locationArguments
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
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
    }

    private func openInfoPanel(_ id: String) {
        tapTile(id)
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the viewer never showed its chrome")
        _ = viewerAction(id: "viewerDetailsButton", menu: "viewerMenuDetails", labels: ["Détails", "Details"])
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Scrolls the info panel (bounded) until `id` is on screen, then returns it.
    @discardableResult
    private func reveal(_ id: String) -> XCUIElement {
        let target = element(id)
        for _ in 0..<6 {
            if target.waitForExistence(timeout: 3), target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.exists, "\(id) never appeared in the info panel")
        return target
    }

    private func waitForValue(_ target: XCUIElement, _ expected: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)],
                                timeout: timeout) == .completed
    }

    private func waitForGone(_ target: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)],
                                timeout: timeout) == .completed
    }

    private var latitudeField: XCUIElement { app.textFields["adjustLocationLatitudeField"] }
    private var longitudeField: XCUIElement { app.textFields["adjustLocationLongitudeField"] }
    private var saveButton: XCUIElement { app.buttons["adjustLocationSaveButton"] }

    private func clear(_ field: XCUIElement) {
        field.tap()
        let current = (field.value as? String) ?? ""
        // An empty field reports its prompt as its value.
        if !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
    }

    /// Clears `field` and types `text`. A leading "-" is typed by touching the
    /// "-" key of the keyboard the field shows; no Return is ever pressed.
    private func enter(_ text: String, in field: XCUIElement) {
        clear(field)
        var rest = Substring(text)
        if rest.first == "-" {
            let minus = app.keyboards.keys["-"]
            XCTAssertTrue(minus.waitForExistence(timeout: 5), "the field's keyboard has no \"-\" key")
            minus.tap()
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { field.typeText(String(rest)) }
    }

    /// Touches Save with the keyboard still open.
    private func save() {
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard must still be open when Save is touched")
        XCTAssertTrue(saveButton.isHittable, "Save is not reachable with the keyboard open")
        saveButton.tap()
    }

    private func openAdjustSheet(of id: String, entry: String) {
        openInfoPanel(id)
        reveal(entry).tap()
        XCTAssertTrue(latitudeField.waitForExistence(timeout: 15), "the adjust-location sheet did not open")
    }

    // MARK: - My Location helpers (B-29.2, B-29.3)

    /// Launch arguments of the scripted device position
    /// (`ScriptedDeviceLocationService`): the permission, the answers to the two
    /// system prompts and the fix. The system prompts themselves cannot be
    /// driven reliably from here, and the map's position dot is drawn by MapKit
    /// from the real sensor, so the app exposes what it was asked to do as the
    /// `mapMyLocationProbe` element.
    private var locationArguments: [String] = []

    private func script(_ status: String, fix: String = "48.8584,2.2945", prompt: String = "allow", precise: String = "grant") {
        locationArguments = [
            "-uiTestLocationStatus", status, "-uiTestLocationFix", fix,
            "-uiTestLocationPrompt", prompt, "-uiTestLocationPrecise", precise,
        ]
    }

    private func openMap() {
        let searchTab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherche", "Suche"])).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "Search tab missing")
        searchTab.tap()
        let segment = app.buttons.matching(NSPredicate(format: "label IN %@", ["Map", "Carte", "Karte"])).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 20), "the Map segment of the search bar is missing")
        segment.tap()
        XCTAssertTrue(element("mapMyLocationButton").waitForExistence(timeout: 25), "the map never drew My Location")
    }

    private func probe() -> String { (element("mapMyLocationProbe").value as? String) ?? "<no probe>" }

    private func waitForProbe(containing part: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", part)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element("mapMyLocationProbe"))],
                                timeout: timeout) == .completed
    }

    /// The alert "My Location" raises when it cannot move anything.
    private var locationAlert: XCUIElement { app.alerts.firstMatch }

    /// Taps one of the alert's buttons by its label (never by position: the
    /// system orders the two buttons of an alert as it pleases).
    private func tapLocationAlertButton(_ labels: [String]) {
        XCTAssertTrue(locationAlert.waitForExistence(timeout: 15), "no alert explained the refusal")
        let button = locationAlert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        XCTAssertTrue(button.exists, "the alert has no button among \(labels)")
        button.tap()
    }

    private let cancelLabels = ["Cancel", "Annuler", "Abbrechen", "Cancelar", "Annulla", "OK"]
    private let openSettingsLabels = [
        "Open Settings", "Ouvrir les réglages", "Einstellungen öffnen", "Abrir ajustes", "Apri impostazioni",
    ]

    /// Taps Cancel (or OK when the alert has no other button) and waits for the alert to go.
    private func dismissLocationAlert() {
        tapLocationAlertButton(cancelLabels)
        XCTAssertTrue(waitForGone(locationAlert), "the alert did not close")
    }

    // MARK: - Scenarios

    func test_AC_228() throws {
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        XCTAssertEqual(latitudeField.value as? String, "45.5")
        XCTAssertEqual(longitudeField.value as? String, "6.8")
        let pin = element("adjustLocationPin")
        XCTAssertTrue(pin.waitForExistence(timeout: 15), "no pin on a located photo")
        XCTAssertTrue(waitForValue(pin, "45.5, 6.8"))

        // Dragging the pin rewrites both fields.
        let from = pin.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.6, thenDragTo: from.withOffset(CGVector(dx: 60, dy: 40)))
        let moved = NSPredicate(format: "value != %@", "45.5")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: latitudeField)],
                                        timeout: 15), .completed, "dragging the pin left the latitude field alone")
        let lat = (latitudeField.value as? String) ?? ""
        let lon = (longitudeField.value as? String) ?? ""
        XCTAssertTrue(waitForValue(element("adjustLocationPin"), "\(lat), \(lon)"))

        // Typed values move the pin before anything is saved.
        enter("-33,8688", in: latitudeField)
        enter("151.2093", in: longitudeField)
        XCTAssertTrue(waitForValue(element("adjustLocationPin"), "-33.8688, 151.2093"))
        XCTAssertEqual(locationWrites(located).count, 0, "typing alone must not write")

        save()
        let writes = waitForLocationWrites(located, count: 1)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.latitudeSent ?? 0, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(writes.first?.longitudeSent ?? 0, 151.2093, accuracy: 1e-9)
        XCTAssertTrue(waitForGone(saveButton), "the sheet stayed open after a successful save")
    }

    func test_AC_47() throws {
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        enter("48,8584", in: latitudeField)
        enter("2.2945", in: longitudeField)
        save()
        let writes = waitForLocationWrites(located, count: 1)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.latitudeSent ?? 0, 48.8584, accuracy: 1e-9)
        XCTAssertEqual(writes.first?.longitudeSent ?? 0, 2.2945, accuracy: 1e-9)
        XCTAssertTrue(waitForGone(saveButton))

        reveal("adjustLocationButton").tap()
        XCTAssertTrue(latitudeField.waitForExistence(timeout: 15))
        enter("95", in: latitudeField)
        save()
        XCTAssertTrue(element("adjustLocationLatitudeError").waitForExistence(timeout: 10),
                      "latitude 95 was not refused with a message")
        XCTAssertEqual(locationWrites(located).count, 1, "a refused latitude must not send a request")
        XCTAssertTrue(saveButton.exists, "the sheet must stay open")
    }

    func test_AC_229() throws {
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        // A prefix that reads is followed by the pin; the final invalid value is not.
        enter("180", in: longitudeField)
        longitudeField.typeText(".")
        XCTAssertTrue(waitForValue(element("adjustLocationPin"), "45.5, 180"))
        let held = (element("adjustLocationPin").value as? String) ?? ""
        longitudeField.typeText("5")
        XCTAssertEqual(longitudeField.value as? String, "180.5")
        XCTAssertEqual(element("adjustLocationPin").value as? String, held, "the pin followed an invalid longitude")
        save()
        XCTAssertTrue(element("adjustLocationLongitudeError").waitForExistence(timeout: 10))
        XCTAssertEqual(element("adjustLocationPin").value as? String, held)
        XCTAssertEqual(locationWrites(located).count, 0)

        enter("179", in: longitudeField)
        XCTAssertTrue(waitForGone(element("adjustLocationLongitudeError")), "the message outlived the fix")

        enter("abc", in: latitudeField)
        save()
        XCTAssertTrue(element("adjustLocationLatitudeError").waitForExistence(timeout: 10))

        clear(latitudeField)
        save()
        XCTAssertTrue(element("adjustLocationLatitudeError").waitForExistence(timeout: 10))
        XCTAssertEqual(locationWrites(located).count, 0)

        enter("90", in: latitudeField)
        enter("-180", in: longitudeField)
        save()
        let writes = waitForLocationWrites(located, count: 1)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.latitudeSent ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(writes.first?.longitudeSent ?? 0, -180, accuracy: 1e-9)
    }

    func test_AC_233() throws {
        signIn()
        openInfoPanel(unlocated)
        let add = reveal("addLocationButton")
        XCTAssertFalse(element("adjustLocationButton").exists, "a photo without a location offers Add, not Adjust")
        add.tap()
        XCTAssertTrue(latitudeField.waitForExistence(timeout: 15))
        XCTAssertFalse(element("adjustLocationPin").exists, "no pin before a valid pair")
        for field in [latitudeField, longitudeField] {
            let value = (field.value as? String) ?? ""
            XCTAssertTrue(value.isEmpty || value == field.placeholderValue, "field not empty: \(value)")
        }

        latitudeField.tap()
        save()
        XCTAssertTrue(element("adjustLocationLatitudeError").waitForExistence(timeout: 10))
        XCTAssertTrue(element("adjustLocationLongitudeError").exists)
        XCTAssertEqual(locationWrites(unlocated).count, 0)

        enter("48,8584", in: latitudeField)
        enter("2.2945", in: longitudeField)
        XCTAssertTrue(waitForValue(element("adjustLocationPin"), "48.8584, 2.2945"))
        save()
        let writes = waitForLocationWrites(unlocated, count: 1)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.latitudeSent ?? 0, 48.8584, accuracy: 1e-9)
        XCTAssertEqual(writes.first?.longitudeSent ?? 0, 2.2945, accuracy: 1e-9)
        XCTAssertTrue(waitForGone(saveButton))

        XCTAssertTrue(element("locationMapPreviewButton").waitForExistence(timeout: 15),
                      "the panel did not show the map after the location was added")
        reveal("adjustLocationButton")
        XCTAssertFalse(element("addLocationButton").exists)
    }

    // MARK: - My Location scenarios

    func test_AC_48() throws {
        script("authorizedFull")
        signIn()
        openMap()
        XCTAssertTrue(waitForProbe(containing: "center=none"))
        element("mapMyLocationButton").tap()
        XCTAssertTrue(waitForProbe(containing: "center=48.8584,2.2945"), "the map was not centered: \(probe())")
    }

    func test_AC_48_refusedExplainsAndTheMapStays() throws {
        script("denied")
        signIn()
        openMap()
        element("mapMyLocationButton").tap()
        XCTAssertTrue(locationAlert.waitForExistence(timeout: 15), "a refusal must be explained")
        XCTAssertTrue(probe().contains("center=none"), "the map moved: \(probe())")
    }

    func test_AC_230() throws {
        script("notDetermined")
        signIn()
        openMap()
        XCTAssertTrue(waitForProbe(containing: "dot=hidden"))
        XCTAssertTrue(probe().contains("prompts=0"), "opening the map must not ask: \(probe())")
        element("mapMyLocationButton").tap()
        XCTAssertTrue(waitForProbe(containing: "center=48.8584,2.2945"), probe())
        XCTAssertTrue(probe().contains("dot=shown"), probe())
        XCTAssertTrue(probe().contains("prompts=1"), probe())
    }

    func test_AC_230_alreadyAllowedShowsTheDotWithoutAsking() throws {
        script("authorizedFull")
        signIn()
        openMap()
        XCTAssertTrue(waitForProbe(containing: "dot=shown"), probe())
        XCTAssertTrue(probe().contains("prompts=0"), probe())
    }

    func test_AC_230_servicesOffExplainsAndTheMapStays() throws {
        script("servicesDisabled")
        signIn()
        openMap()
        element("mapMyLocationButton").tap()
        dismissLocationAlert()
        XCTAssertTrue(probe().contains("center=none"), probe())
    }

    func test_AC_230_noFixExplainsAndTheMapStays() throws {
        script("authorizedFull", fix: "none")
        signIn()
        openMap()
        element("mapMyLocationButton").tap()
        dismissLocationAlert()
        XCTAssertTrue(probe().contains("center=none"), probe())
    }

    func test_AC_231() throws {
        script("denied")
        signIn()
        openMap()
        element("mapMyLocationButton").tap()
        XCTAssertTrue(locationAlert.waitForExistence(timeout: 15))
        XCTAssertEqual(locationAlert.buttons.count, 2, "Open Settings and Cancel")
        // Cancel closes it and changes nothing.
        dismissLocationAlert()
        XCTAssertTrue(probe().contains("center=none"), probe())
        XCTAssertTrue(probe().contains("prompts=0"), probe())

        // Open Settings goes to the Settings app.
        element("mapMyLocationButton").tap()
        XCTAssertTrue(locationAlert.waitForExistence(timeout: 15))
        tapLocationAlertButton(openSettingsLabels)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 20), "the Settings app did not open")
    }

    func test_AC_232() throws {
        script("authorizedFull")
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        element("adjustLocationMyLocationButton").tap()
        XCTAssertTrue(waitForValue(latitudeField, "48.8584"), "the latitude field did not take the position")
        XCTAssertTrue(waitForValue(longitudeField, "2.2945"))
        XCTAssertTrue(waitForValue(element("adjustLocationPin"), "48.8584, 2.2945"))
        XCTAssertEqual(locationWrites(located).count, 0, "My Location alone must not write")
        saveButton.tap()
        let writes = waitForLocationWrites(located, count: 1)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.latitudeSent ?? 0, 48.8584, accuracy: 1e-9)
        XCTAssertEqual(writes.first?.longitudeSent ?? 0, 2.2945, accuracy: 1e-9)
    }

    func test_AC_232_refusedKeepsThePinAndExplains() throws {
        script("denied")
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        element("adjustLocationMyLocationButton").tap()
        dismissLocationAlert()
        XCTAssertEqual(latitudeField.value as? String, "45.5")
        XCTAssertEqual(longitudeField.value as? String, "6.8")
        XCTAssertEqual(locationWrites(located).count, 0)
    }

    func test_AC_234() throws {
        script("authorizedReduced", precise: "refuse")
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        element("adjustLocationMyLocationButton").tap()
        dismissLocationAlert()
        XCTAssertEqual(latitudeField.value as? String, "45.5", "an approximate position must not move the pin")
        XCTAssertEqual(longitudeField.value as? String, "6.8")
        XCTAssertEqual(locationWrites(located).count, 0)
    }

    func test_AC_234_preciseGrantedMovesThePin() throws {
        script("authorizedReduced", precise: "grant")
        signIn()
        openAdjustSheet(of: located, entry: "adjustLocationButton")
        element("adjustLocationMyLocationButton").tap()
        XCTAssertTrue(waitForValue(latitudeField, "48.8584"), "the precise position was not used")
        XCTAssertTrue(waitForValue(longitudeField, "2.2945"))
    }

    func test_AC_234_theMapCentersOnReducedAccuracyWithoutAskingForMore() throws {
        script("authorizedReduced", precise: "refuse")
        signIn()
        openMap()
        element("mapMyLocationButton").tap()
        XCTAssertTrue(waitForProbe(containing: "center=48.8584,2.2945"), probe())
        XCTAssertTrue(probe().contains("precise=0"), "the map must not ask for the precise position: \(probe())")
    }
}
