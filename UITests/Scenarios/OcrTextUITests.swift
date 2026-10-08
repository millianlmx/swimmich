import XCTest

/// End-to-end scenario for the detected-text feature (gap G8, `ocr-text`): the
/// recognized-text layer over the photo in the viewer, and the search that
/// restricts the grid to photos whose *detected text* matches.
///
/// It drives the real app — onboarding → SSO → the timeline → the viewer →
/// Search — and it asserts **both** halves of each claim: what the screen shows
/// (`viewerOcrText_0`, the chrome capsule, the result tile) and what the app
/// sent (`GET /api/assets/{id}/ocr`, `filter.ocr.matches`). An overlay that
/// appeared without the route, or a search that looked right while carrying the
/// deprecated scalar `ocr` instead of the structured filter, would both be bugs
/// the screen alone could not tell.
///
/// The stub (`immich_stub_ocr_text.py`) owns the three facts this hangs on: a
/// **tilted quadrilateral** per box (four corners, never a bbox), an asset whose
/// box array is **empty**, and an OCR-active version number — the structured
/// filter only exists on a v3.2.0 server, and the shell's own `1.119.0` would
/// leave the search toggle disabled. See its docstring.
///
/// The search half's criterion is typed into the **Filters sheet's "Detected
/// text" field**, which is the writer a scenario can reach: the toolbar toggle
/// rewrites the *typed query* as the filter (`toggleCarriesCriterion`), but iOS
/// 26 hands a `role: .search` tab a bottom search field whose presentation takes
/// the app toolbar — filter button included — out of the accessibility tree, and
/// leaving that presentation clears the query (both measured). The toggle is
/// therefore asserted as a control (present, gated on the v3.2.0 shape the stub
/// answers, able to latch) while the WIRE contract the card pins — the criterion
/// as `filter.ocr.matches`, never as the deprecated scalar `ocr` — is read off
/// the request the sheet's Done dispatches.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/ocr-text.uitest.log \
///         UITests/stubs/immich_stub_ocr_text.py OcrTextUITests/test_ocrText --erase
final class OcrTextUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's cast (`immich_stub_ocr_text.py`). The first two are the shell's
    // own timeline photos; `searchAsset` is deliberately NOT on the timeline, so
    // a tile carrying that id can only have come from a search response — the
    // Photos grid stays in the accessibility tree behind the Search tab.
    private let textAsset = "aaaaaaaa-1111-4111-8111-000000000001"
    private let blankAsset = "aaaaaaaa-1111-4111-8111-000000000002"
    private let searchAsset = "dddddddd-1111-4111-8111-000000000042"

    /// The text the stub's OCR payload carries and the scenario types: the only
    /// needle its detected-text filter answers.
    private let needle = "Rechnung"

    /// `No text found` in the five languages of the catalogue: the slots run in
    /// English, the repo's own simulator is German, and the app's language is a
    /// persisted setting, so a literal would follow the machine.
    private let noTextCopy = ["No text found", "Aucun texte détecté", "Kein Text gefunden",
                              "No se encontró texto", "Nessun testo trovato"]

    /// The value both detected-text toggles publish while latched — the same
    /// hazard as `noTextCopy`, one level down: the VoiceOver value is a catalog
    /// key (`on`, shipped in five languages), so it follows the machine.
    private let latchedCopy = ["on", "Activé", "Ein", "Activado", "Attivato"]

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
    // Copied from `ImmichRenderScreenshots` on purpose: these are `private`
    // there, and the shared file is frozen (its committed scenarios are green
    // against its current text). Extracting them into a shared support file
    // would be a second convention next to the existing one — the harness rule
    // is one file per feature, helpers included.

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

    /// The provider page lives in `SafariViewService`, a separate process, so
    /// its "Authorize" link is not in the app's own accessibility tree.
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
            shot("b02-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One grid cell, by the identity every grid gives it (Photos timeline and
    /// search results alike).
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// Closes the viewer and proves it closed: a tap that misses leaves the
    /// cover up, and every later assertion would then read the grid behind it.
    private func dismissViewer() {
        let back = app.buttons["viewerBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way out of the viewer")
        for _ in 0..<4 where app.buttons["viewerBackButton"].exists {
            let candidate = app.buttons["viewerBackButton"]
            if candidate.isHittable { candidate.tap() } else { app.swipeDown() }
            sleep(2)
        }
        XCTAssertFalse(app.buttons["viewerBackButton"].exists,
                       "the photo viewer never dismissed — every later step would read the covered screen")
    }

    /// Waits for an element's `accessibilityValue` to become one of `accepted`.
    /// A tap and the SwiftUI re-render that publishes the new value are two
    /// events: asserting immediately reads the old one (measured). The list is
    /// `labelPredicate`'s twin one level down — a localized value is accepted in
    /// every language it ships in, never in one.
    private func waitForValue(_ element: XCUIElement, _ accepted: [String],
                              timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: accepted.map { _ in "value == %@" }.joined(separator: " OR "),
                                    argumentArray: accepted)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// A viewer top-bar action (SP-6): its pill when the row carries it, else
    /// the "⋯" menu's item — by identifier, then by label, because a menu item
    /// may publish as `.menuItem` or `.button`. Taps what it returns. The
    /// caller reads `live` BEFORE calling: only a live pill publishes the
    /// latched `value`; a menu item carries none.
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
                        + "\(app.descendants(matching: .any).allElementsBoundByIndex.map(\.label))")
        item.tap()
        return item
    }

    /// One recognized-text element of the viewer's accessibility stand-in. The
    /// layer is `allowsHitTesting(false)` and drawn in a `Canvas`, so
    /// `accessibilityRepresentation` is the only thing that publishes these.
    private func ocrBox(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "viewerOcrText_\(index)").firstMatch
    }

    /// How many detected-text elements the screen publishes — the whole
    /// question of the empty-array case is whether this is ZERO.
    private func ocrBoxCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'viewerOcrText_'")).count
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string; the rest are the fields THIS stub recorded with `req.note()` —
    /// which is how a body assertion is possible without decoding arbitrary
    /// JSON (see the stub's `metadata_search`).
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let ocrAsset: String?
        let ocrMatches: String?
        let query: String?
        let scalarOcr: String?

        enum CodingKeys: String, CodingKey {
            case method, path, params, query
            case ocrAsset = "ocr_asset"
            case ocrMatches = "ocr_matches"
            case scalarOcr = "scalar_ocr"
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

    /// Every request the app sent to one exact path, in order.
    private func requests(to path: String) -> [StubRequest] {
        stubRequests().filter { $0.path == path }
    }

    /// Every metadata search, in order — the route the detected-text criterion
    /// travels on.
    private func metadataRequests() -> [StubRequest] {
        requests(to: "/api/search/metadata")
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) query=\($0.query ?? "-") "
                + "filter.ocr.matches=\($0.ocrMatches ?? "-") scalar_ocr=\($0.scalarOcr ?? "-")"
        }.joined(separator: "\n")
    }

    private func screenCopy() -> [String] {
        app.staticTexts.allElementsBoundByIndex.map(\.label)
    }

    // MARK: - Scenario

    func test_ocrText() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("01-welcome")
            walkOnboardingToLogin()
            shot("02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the viewer would never open under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("03-whats-new")
            whatsNewDone.tap()
        }

        // MARK: - The viewer: a photo whose detected text the server knows

        let firstPhoto = tile(textAsset)
        if !firstPhoto.waitForExistence(timeout: 30) {
            shot("04b-no-timeline")
            XCTFail("the timeline never rendered \(textAsset) against \(stub); screen reads: \(screenCopy())")
        }
        shot("04-timeline")
        firstPhoto.tap()

        let chrome = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        if !chrome.waitForExistence(timeout: 25) {
            shot("05b-viewer-without-chrome")
            XCTFail("the viewer never showed its top bar; screen reads: \(screenCopy())")
        }
        shot("05-viewer")
        // Live or behind ⋯ depending on the width (BR-3 step 4): the latch is
        // read from the pill only; a menu item publishes no `value`, so the
        // collapsed case is proven by the layer's boxes just below.
        let ocrLive = app.buttons.matching(identifier: "viewerOcrToggle").firstMatch.exists
        let ocrToggle = viewerAction(id: "viewerOcrToggle", menu: "viewerMenuOcr",
                                     labels: ["Texte détecté", "Detected text"])
        if ocrLive {
            XCTAssertTrue(waitForValue(ocrToggle, latchedCopy),
                          "the detected-text button did not latch — it reads '\(ocrToggle.value ?? "nil")'")
        }

        // The layer announces its boxes: two confident ones, in reading order,
        // and NOT the faint third (drawn, but under the display threshold).
        if !ocrBox(0).waitForExistence(timeout: 25) {
            shot("06b-no-detected-text-overlay")
            XCTFail("the viewer fetched the boxes but published no detected text"
                    + " — the accessibility stand-in is what makes them reachable at all."
                    + " On screen: \(screenCopy())\nStub log:\n"
                    + describe(requests(to: "/api/assets/\(textAsset)/ocr")))
        }
        XCTAssertEqual(ocrBox(0).label, needle,
                       "the boxes must be announced most-confident-first, not in the server's array order"
                       + " (which is Entwurf, Total, Rechnung) — box 0 reads '\(ocrBox(0).label)'")
        XCTAssertTrue(ocrBox(1).waitForExistence(timeout: 10),
                      "only one of the two confident boxes reached the accessibility tree")
        XCTAssertEqual(ocrBox(1).label, "Total 42,00 €",
                       "box 1 reads '\(ocrBox(1).label)'")
        XCTAssertFalse(ocrBox(2).exists,
                       "a box below the confidence threshold is DRAWN but must not be announced"
                       + " — the threshold is a display cut-off, not a data filter")
        shot("06-detected-text-overlay")

        let ocrLog = requests(to: "/api/assets/\(textAsset)/ocr")
        XCTAssertEqual(ocrLog.count, 1,
                       "the layer must load the boxes ONCE per asset (`didLoad`) — got:\n\(describe(ocrLog))")

        dismissViewer()

        // MARK: - A photo with an EMPTY box array: a message, not an overlay

        let secondPhoto = tile(blankAsset)
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 25),
                      "the timeline lost its second photo — screen reads: \(screenCopy())")
        secondPhoto.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 25),
                      "the viewer did not open on the second photo")
        let secondLive = app.buttons.matching(identifier: "viewerOcrToggle").firstMatch.exists
        let secondToggle = viewerAction(id: "viewerOcrToggle", menu: "viewerMenuOcr",
                                        labels: ["Texte détecté", "Detected text"])
        if secondLive {
            XCTAssertTrue(waitForValue(secondToggle, latchedCopy),
                          "the detected-text button did not latch on the second photo")
        }

        let status = app.descendants(matching: .any).matching(identifier: "viewerOcrStatusText").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 25),
                      "a photo the server knows nothing about said nothing — screen reads: \(screenCopy())")
        // The fetch must have SETTLED: the capsule shows a spinner while it is
        // in flight, so its absence is what tells "empty" from "still asking".
        let spinner = app.descendants(matching: .any)
            .matching(identifier: "viewerOcrLoadingIndicator").firstMatch
        let settled = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                            object: spinner)],
            timeout: 25)
        XCTAssertEqual(settled, .completed, "the detected-text fetch never settled")
        XCTAssertEqual(ocrBoxCount(), 0,
                       "an empty box array must not draw an overlay — the chrome carries the state")
        XCTAssertTrue(noTextCopy.contains { status.label.contains($0) },
                      "'no text' and 'unchanged/unavailable' are TWO states: the capsule reads"
                      + " '\(status.label)', none of \(noTextCopy)")
        shot("07-detected-text-empty")

        let blankLog = requests(to: "/api/assets/\(blankAsset)/ocr")
        XCTAssertEqual(blankLog.count, 1,
                       "the second photo must be fetched for its OWN id — got:\n\(describe(blankLog))")

        dismissViewer()

        // MARK: - The Search tab: the criterion UI

        let searchTab = app.tabBars.buttons
            .matching(labelPredicate(["Search", "Rechercher", "Suche"])).firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 25),
                      "no Search tab — tab bar reads: \(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        searchTab.tap()
        sleep(3)

        // The detected-text toggle is a mode of the METADATA search, and it is
        // off the table on a server without the structured filter: the stub
        // answers 3.2.0, so a disabled toggle here is a real failure.
        let modeMenu = app.buttons
            .matching(labelPredicate(["Search mode", "Mode de recherche", "Suchmodus"])).firstMatch
        if !modeMenu.waitForExistence(timeout: 25) {
            shot("08b-no-search-toolbar")
            XCTFail("no search-mode menu in the toolbar — buttons read: "
                    + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
        }
        shot("08-search")
        modeMenu.tap()
        XCTAssertTrue(tapAnyButton(["Metadata", "Métadonnées", "Metadaten"], timeout: 15),
                      "the mode menu offers no Metadata option — buttons read: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")

        let ocrFilter = app.buttons.matching(identifier: "searchOcrFilterToggle").firstMatch
        XCTAssertTrue(ocrFilter.waitForExistence(timeout: 25),
                      "no detected-text toggle in the search toolbar — buttons read: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
        let enabled = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                            object: ocrFilter)],
            timeout: 25)
        XCTAssertEqual(enabled, .completed,
                       "the detected-text toggle stayed disabled: either the mode is not Metadata"
                       + " or the server never answered 3.2.0 (the stub does)")
        ocrFilter.tap()
        XCTAssertTrue(waitForValue(ocrFilter, latchedCopy),
                      "the detected-text toggle did not latch — it reads '\(ocrFilter.value ?? "nil")'")

        // MARK: - Search: the criterion travels as a structured filter

        // The Filters sheet's "Detected text" field is the criterion's only
        // writer a scenario can reach. The toolbar toggle rewrites the QUERY as
        // the filter (`SearchViewModel.toggleCarriesCriterion`), but that query
        // cannot survive to a dispatch: iOS 26 hands a `role: .search` tab a
        // bottom search field whose presentation takes the app toolbar — filter
        // button included — out of the accessibility tree, and leaving the
        // presentation clears the query (both measured). What the card pins is
        // the WIRE contract, and it is what is asserted here: the criterion as
        // `filter.ocr.matches`, never as the deprecated scalar `ocr`. The
        // toggle is proven as a control — present, gated on the v3.2.0 shape
        // the stub answers, and able to latch.
        XCTAssertFalse(tile(searchAsset).exists,
                       "the photo whose detected text matches is on screen before any search was sent")
        let filtersButton = app.buttons["searchFilterButton"]
        XCTAssertTrue(filtersButton.waitForExistence(timeout: 25),
                      "no Filters button in the search toolbar — buttons read: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
        filtersButton.tap()
        XCTAssertTrue(app.buttons["searchFilterDone"].waitForExistence(timeout: 25),
                      "the Filters sheet never opened — buttons read: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
        shot("09-search-filters-sheet")

        let criterion = app.textFields["searchFilterOCR"]
        if !criterion.waitForExistence(timeout: 20) {
            shot("09b-no-detected-text-field")
            XCTFail("no detected-text field in the Filters sheet — text fields read: "
                    + "\(app.textFields.allElementsBoundByIndex.map(\.identifier))")
        }
        if !criterion.isHittable {
            app.swipeUp()
        }
        criterion.tap()
        criterion.typeText(needle)
        XCTAssertTrue(waitForValue(criterion, [needle]),
                      "the detected-text field did not take the query — it reads '\(criterion.value ?? "nil")'")

        app.buttons["searchFilterDone"].tap()

        // The screen: the photo whose detected text matches — the stub answers a
        // detected-text filter with exactly the assets whose OCR carries the
        // needle, and `searchAsset` is on no timeline, so that tile can only
        // come from this response.
        if !tile(searchAsset).waitForExistence(timeout: 30) {
            shot("10b-no-detected-text-result")
            XCTFail("the detected-text search did not put its photo on screen — screen reads: \(screenCopy())\n"
                    + describe(metadataRequests()))
        }
        shot("10-search-detected-text")

        // MARK: On the wire — the criterion travels as a structured filter

        let log = metadataRequests()
        guard let structured = log.last(where: { $0.ocrMatches == needle }) else {
            return XCTFail("no metadata search carried the criterion as `filter.ocr.matches` — got:\n"
                           + describe(log.isEmpty ? stubRequests() : log))
        }
        XCTAssertEqual(structured.ocrMatches, needle,
                       "the detected-text criterion must travel as `filter.ocr.matches` — got:\n\(describe(log))")
        XCTAssertTrue((structured.query ?? "").isEmpty,
                      "the criterion is not free text: nothing may travel in `query` next to it"
                      + " — got:\n\(describe(log))")
        XCTAssertTrue(log.allSatisfy { $0.scalarOcr == nil },
                      "the deprecated scalar `ocr` of `MetadataSearchDto` must never be sent"
                      + " — its replacement is `filter.ocr`:\n\(describe(log))")
    }
}
