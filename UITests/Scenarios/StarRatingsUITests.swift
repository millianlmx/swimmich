import XCTest

/// End-to-end scenario for the star rating (gap G7): the photo viewer's info
/// panel writes the asset's rating, and shows the SERVER's answer rather than
/// what the tap wrote.
///
/// One `XCTestCase` per feature, in its own file, against its own committed
/// stub — 24 branches each adding a method to `ImmichRenderScreenshots` would
/// collide on every merge. The helpers below are copied from that class (they
/// are `private` there and its eleven scenarios are green against its current
/// text) and from the reference `RecentlyTakenUITests`.
///
/// It drives the real app: onboarding → SSO → the Photos timeline → a photo →
/// the viewer's Details button → the info panel's rating bar. And it asserts on
/// the WIRE, because two of the three claims are invisible on screen:
///
/// 1. `PATCH /api/assets/:id` (not the bulk `PUT`, not a `POST`) carries
///    `rating: 4` — the screen looks identical for any verb.
/// 2. Clearing sends the `rating` KEY with a null value. An omitted key is the
///    failure this card exists for: the server has no `0` since v3, so `{}`
///    reads as "no change" and the star stays on the server while the bar reads
///    empty. `{}` and `{"rating":null}` decode alike, hence the stub records the
///    key's presence separately.
/// 3. The panel adopts the server's answer: the stub is armed to answer 3 to a
///    tap of 4, and the panel must show 3. Without it, `rating = sent` and
///    `rating = response.exifInfo?.rating` look exactly alike.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/star-ratings.uitest.log \
///         UITests/stubs/immich_stub_star_ratings.py StarRatingsUITests/test_starRatings
final class StarRatingsUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The shell's first timeline asset — the photo this scenario rates.
    private let rated = "aaaaaaaa-1111-4111-8111-000000000001"

    /// `PVRatingBar` names the star that IS the current rating "Remove rating"
    /// (the VoiceOver name of the re-tap-to-clear gesture) and the others
    /// "Rate N stars". Those strings are translated, and the label follows the
    /// SIMULATOR's language — English on the launcher's slots, German on this
    /// repo's own device — so every comparison below matches all five.
    private let removeRatingLabels = ["Remove rating", "Retirer la note", "Bewertung entfernen",
                                      "Quitar la valoración", "Rimuovi la valutazione"]

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

    // MARK: - Rating surface

    private func star(_ value: Int) -> XCUIElement {
        app.buttons["assetRatingStar_\(value)"]
    }

    /// True when the star IS the current rating — a state only the bar shows:
    /// the filled stars are a tint, invisible to the accessibility tree, while
    /// the current star is the one labelled "Remove rating".
    private func isRated(_ value: Int) -> Bool {
        removeRatingLabels.contains(star(value).label)
    }

    private func starLabels() -> [String] {
        (1...5).map { "\($0)=\(star($0).label)" }
    }

    /// Waits (budgeted — this re-queries on a timer until the timeout, it never
    /// sleeps a fixed amount) for `element`'s label to become one of `labels`.
    private func waitForLabel(_ element: XCUIElement, isOneOf labels: [String],
                              timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return labels.contains(element.label)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. The two trailing fields are what the
    /// stub's `req.note` adds about its own payload — the key's presence cannot
    /// be recovered from `body`, where `{"rating": null}` and `{}` look alike.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let ratingKeyPresent: Bool?
        let ratingSent: Int?
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

    /// Every write this feature makes: `PATCH /api/assets/<the photo>`. The
    /// panel's other traffic is reads (`/api/assets/<id>`, thumbnails), which is
    /// why the filter pins the verb as well as the path.
    private func ratingWrites() -> [StubRequest] {
        stubRequests().filter { $0.method == "PATCH" && $0.path == "/api/assets/\(rated)" }
    }

    /// The rating writes the stub has logged so far, re-read until there are
    /// `count` of them. A fixed sleep would either be too short or paid on every
    /// run; this polls a bounded number of times and then reports what it saw.
    private func waitForRatingWrites(_ count: Int, timeout: TimeInterval = 20) -> [StubRequest] {
        var found = ratingWrites()
        let deadline = Date().addingTimeInterval(timeout)
        while found.count < count, Date() < deadline {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "stub poll")], timeout: 0.5)
            found = ratingWrites()
        }
        return found
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params) "
            + "ratingKeyPresent=\(String(describing: $0.ratingKeyPresent)) "
            + "ratingSent=\(String(describing: $0.ratingSent))" }
            .joined(separator: "\n")
    }

    /// Arms the stub's NEXT rating write to be answered with `rating`, whatever
    /// the app sent. Returns false if the stub did not acknowledge the arm — an
    /// unarmed run must not be reported as a passed adoption.
    @discardableResult
    private func armRatingResponse(_ rating: Int) -> Bool {
        var request = URLRequest(url: URL(string: "\(stub)/control/rating-response")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"rating\": \(rating)}".utf8)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 6) == .success else { return false }
        return body.contains("\"armed\": true")
    }

    // MARK: - Scenario

    func test_starRatings() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's refusal of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("s01-welcome")
            walkOnboardingToLogin()
            shot("s02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the timeline would never open under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("s03-whats-new")
            whatsNewDone.tap()
        }

        // MARK: The viewer, then its info panel

        tapTile(rated)
        let chrome = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        if !chrome.waitForExistence(timeout: 20) {
            shot("s04b-viewer-without-chrome")
            XCTFail("the viewer never showed its chrome — buttons: "
                    + "\(app.buttons.allElementsBoundByIndex.map(\.identifier))")
        }
        shot("s04-viewer")
        // Details sits on the row or behind "⋯", by the badge width (SP-3). The
        // tap is the same action either way.
        _ = viewerAction(id: "viewerDetailsButton", menu: "viewerMenuDetails", labels: ["Détails", "Details"])

        let star4 = star(4)
        if !star4.waitForExistence(timeout: 20) {
            shot("s05b-info-panel-without-rating-bar")
            XCTFail("the info panel never rendered the rating bar — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        // The stub's fixture is unrated: five empty stars and no explicit clear.
        XCTAssertFalse(isRated(4), "the asset starts unrated — labels: \(starLabels())")
        XCTAssertFalse(app.buttons["assetRatingClearButton"].exists,
                       "an unrated asset must not offer `Clear rating`")
        shot("s05-info-panel-unrated")
        // Opening the panel is a READ. If it wrote, every assertion below would
        // be reading whatever that write left behind.
        XCTAssertEqual(ratingWrites().count, 0,
                       "opening the info panel wrote a rating — got:\n\(describe(stubRequests()))")

        // MARK: Rate — the wire carries 4, the panel shows the server's 3

        // The stub answers the NEXT write with 3 whatever the tap sends. Without
        // this arm, `rating = response.exifInfo?.rating` and `rating = sent` are
        // indistinguishable: the panel would look right while showing the tap.
        XCTAssertTrue(armRatingResponse(3), "the stub refused to arm its answer")

        star4.tap()
        if !waitForLabel(star(3), isOneOf: removeRatingLabels) {
            shot("s06b-rating-not-adopted")
            XCTFail("the panel never adopted the server's answer (3, for a tap of 4); it reads "
                    + "\(starLabels()) and the wire got:\n\(describe(stubRequests()))")
        }
        shot("s06-rated-by-server")

        let writes = waitForRatingWrites(1)
        guard writes.count == 1 else {
            return XCTFail("expected exactly 1 rating write on the wire, saw \(writes.count):\n"
                           + describe(stubRequests()))
        }
        XCTAssertEqual(writes[0].method, "PATCH",
                       "the rating is written by PATCH /api/assets/:id — got:\n\(describe(writes))")
        XCTAssertEqual(writes[0].path, "/api/assets/\(rated)", "wrong asset targeted")
        XCTAssertEqual(writes[0].ratingKeyPresent, true,
                       "the write's body must carry the `rating` key — got:\n\(describe(writes))")
        XCTAssertEqual(writes[0].ratingSent, 4, "the tapped star is what must be sent")
        // The screen, not the wire: the panel adopted 3 and dropped the tap's 4.
        XCTAssertTrue(isRated(3), "the panel must show the server's 3 — labels: \(starLabels())")
        XCTAssertFalse(isRated(4), "the tapped 4 must NOT survive the server's answer — labels: \(starLabels())")
        let clear = app.buttons["assetRatingClearButton"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10),
                      "a rated asset must offer an explicit `Clear rating`")

        // MARK: Clear — the key must be PRESENT and null

        clear.tap()
        let cleared = waitForRatingWrites(2)
        guard cleared.count == 2 else {
            shot("s07b-clear-not-sent")
            return XCTFail("the clear never reached the stub (\(cleared.count) rating write(s)):\n"
                           + describe(stubRequests()))
        }
        // The card's invariant, and the reason this scenario exists: `{"rating":
        // null}` is a clear, `{}` is "no change" — the server would keep the
        // star while the bar reads empty.
        XCTAssertEqual(cleared[1].ratingKeyPresent, true,
                       "clearing must send the `rating` KEY with a null value; an omitted key is `{}`, "
                       + "which the server reads as 'no change' — got:\n\(describe(cleared))")
        XCTAssertNil(cleared[1].ratingSent,
                     "the clear's value must be null (never 0: the server rejects it since v3)")
        XCTAssertTrue(app.buttons["assetRatingClearButton"].waitForNonExistence(timeout: 10),
                      "the clear must take the `Clear rating` affordance away")
        XCTAssertFalse(isRated(3), "the clear must leave the bar on 'not rated' — labels: \(starLabels())")
        shot("s07-cleared-unrated")
    }
}
