import XCTest

/// End-to-end scenario for the map settings sheet (gap G14b) — the time range
/// of the map filter, and the map reachable from the photo viewer.
///
/// It drives the real app: onboarding → SSO → the Photos timeline → the Search
/// tab → the Map segment → the settings sheet → the viewer's info panel. And it
/// asserts on the WIRE what each state asked for, which is the point of the
/// card: the time range of the map travels on `GET /api/map/markers` ALONE
/// (`fileCreatedAfter` … `fileCreatedBefore`) — the timeline's
/// `/api/timeline/buckets` takes no date parameter, and `takenAfter`/`takenBefore`
/// live on the metadata *search* route, which answers assets, not markers. A map
/// that looks right while asking the wrong question is the bug this catches.
///
/// Three claims are load-bearing:
///
/// 1. **A custom range reaches the query.** After the sheet's "Use custom date
///    range" is applied, the next marker request carries BOTH bounds — a preset
///    would carry `fileCreatedAfter` only, so the second bound is what proves a
///    custom window was posed.
/// 2. **An inverted range never reaches the network.** "After" set later than
///    "Before" shows `mapSettingsRangeError`, leaves Done disabled, and the
///    marker-request count does not move — the sheet refuses the filter instead
///    of writing an empty answer under a legitimate-looking cache key.
/// 3. **Changing the filter re-asks.** Favourites on top of the range produces a
///    SECOND request with a different query, and the stub answers it with a
///    different city (`Favtown`): the marker cache gained a per-filter variant,
///    so the previous filter's payload is neither replayed nor reused.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself). The
/// slot device is shared and the app caches markers on disk per filter variant,
/// so the run MUST start from a wiped device — otherwise a previous run's
/// `markers.json` serves the first map and claim 1 has no request to read:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/map-settings.uitest.log \
///         UITests/stubs/immich_stub_map_settings.py MapSettingsUITests/test_mapSettings --erase
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// ordinary timeline, real PNG thumbnails) and adds the two routes the feature
/// owns; see its docstring. Its one payload per filter shape is what makes the
/// SCREEN prove which question was asked.
final class MapSettingsUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The one asset the stub gives EXIF coordinates to: the viewer's info panel
    /// only draws its mini-map (and the tappable preview) when it has them.
    private let locatedAsset = "aaaaaaaa-1111-4111-8111-000000000001"
    /// The city each payload advertises, per filter shape. Reading them on
    /// screen is how the scenario tells "a new request was answered" from "the
    /// first payload is still on the map".
    private let plainCity = "Stubtown"
    private let rangedCity = "Rangetown"
    private let favoritesCity = "Favtown"

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
    // Copied from `ImmichRenderScreenshots` / `RecentlyTakenUITests` on purpose:
    // these are `private` there, and the shared file is frozen (the committed
    // scenarios are green against its current text). Extracting them into a
    // shared support file would be a second convention next to the existing one
    // — the harness rule is one file per feature, helpers included.

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

    /// A button whose label is EXACTLY one of `labels`. The map's own settings
    /// button is labelled "Map settings", so `CONTAINS "Map"` would tap it
    /// instead of the Map segment of the search bar.
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
            shot("m02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// Any element carrying an accessibility identifier — a Button, a switch,
    /// a Map. Never matched by label: the slots follow the host's language (fr
    /// after an `--erase`) and the repo's simulator is in German, so a control's
    /// label follows the locale and an identifier does not.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: - Inside the settings sheet
    //
    // The sheet is a `Form` shown at a medium detent: its `CollectionView` is
    // 451 pt tall while the content is taller, so a row below the fold is
    // reported by `exists` long before it can be tapped (measured: the whole
    // "Date range" section sat under the sheet's bottom edge and the
    // custom-range tap changed nothing). Everything inside it is therefore
    // scrolled into reach first.

    /// Swipes inside the sheet. `app.swipeUp()` would start the gesture on the
    /// map above it (the sheet only covers the lower half), so the gesture is
    /// anchored on the sheet's own collection view.
    private func swipeSheet(down: Bool = false) {
        let sheet = app.collectionViews.firstMatch
        if !sheet.exists {
            app.swipeUp()
            return
        }
        if down { sheet.swipeDown() } else { sheet.swipeUp() }
    }

    /// On screen and reachable: hittable, or at least entirely inside the
    /// window. A row of the settings `Form` is not always hittable — a
    /// `DatePicker` row carries no hit area of its own — while a row below the
    /// fold is always outside the window, which is what the scrolling is for.
    private func reachable(_ target: XCUIElement) -> Bool {
        guard target.exists else { return false }
        if target.isHittable { return true }
        return app.frame.insetBy(dx: 0, dy: 4).contains(target.frame)
    }

    /// Scrolls the sheet until `identifier` is reachable; false when it never
    /// became so. Both directions, because a `Form` scrolls both ways: flipping
    /// the custom range appends two bound rows BELOW the toggle, and the row
    /// just scrolled to is then above the next target.
    ///
    /// With `fully`, the element's MIDPOINT must sit inside the sheet, above its
    /// own bottom bar: that midpoint is exactly where a coordinate tap lands, and
    /// the strip below the bar belongs to the presentation — a tap there closes
    /// the sheet instead of hitting the control (measured twice: the custom-range
    /// tap dismissed the sheet, and the run went on swiping a `Form` that was no
    /// longer there).
    private func scrollSheet(to identifier: String, maxSwipes: Int = 6, fully: Bool = false) -> Bool {
        let target = element(identifier)
        func settled() -> Bool {
            guard target.exists, target.frame.height > 0 else { return false }
            if !fully { return reachable(target) }
            let midpoint = target.frame.midY
            return midpoint > app.frame.minY + 8 && midpoint < settingsFloor()
        }
        for _ in 0..<maxSwipes {
            if settled() { return true }
            // Not rendered at all: it is most likely further down. Rendered but
            // out of reach: drag towards the half of the sheet it sits in.
            if target.exists, target.frame.midY < app.frame.midY {
                swipeSheet(down: true)
            } else {
                swipeSheet()
            }
        }
        return settled()
    }

    /// The lowest point of the settings sheet a row can be read at: the
    /// window's bottom edge (the sheet has no bottom bar of its own).
    private func settingsFloor() -> CGFloat {
        app.frame.maxY - 12
    }

    /// Same as `scrollSheet(fully: true)`, spelled for the call sites.
    private func scrollSheetFully(to identifier: String, maxSwipes: Int = 8) -> Bool {
        scrollSheet(to: identifier, maxSwipes: maxSwipes, fully: true)
    }

    /// Best effort: pull the settings sheet up to its large detent, where the
    /// whole `Form` fits and nothing hangs off the bottom edge. The scroll
    /// helpers cope with either detent, so failing to expand is not an error.
    private func expandSettingsSheet() {
        guard element("mapSettingsRangePicker").exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
    }

    /// What the sheet currently renders — put in the failure message, because
    /// "the row is not there" and "the row is there but unreachable" look the
    /// same from a bare XCTAssertTrue. The identifiers live on the controls
    /// inside the cells, never on the cells themselves.
    private func sheetDiagnosis() -> String {
        let identifiers = app.collectionViews.firstMatch.descendants(matching: .any)
            .allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty }
        return "sheet controls: " + (identifiers.isEmpty ? "none" : identifiers.joined(separator: ", "))
    }

    /// A switch's state, or nil when its row is not currently rendered: a `Form`
    /// drops the rows that scrolled out of its window, and reading `.value` of a
    /// query with no match RAISES instead of answering.
    private func switchValue(_ identifier: String) -> String? {
        let row = app.switches.matching(identifier: identifier).firstMatch
        return row.exists ? (row.value as? String) : nil
    }

    /// Flips a `Form` toggle until it really moved.
    ///
    /// A row publishes the WHOLE cell as its switch element, and only the
    /// trailing control toggles it: a tap at the element's centre lands on the
    /// label and changes nothing. So the trailing edge — and the row is scrolled
    /// fully into the sheet first, re-scrolled between attempts, and read back
    /// after each one, because flipping it can push it out of the `Form`'s
    /// render window (the custom range appends two bound rows) and a readback
    /// that never happened would fake a pass.
    private func setToggle(_ identifier: String, on: Bool) {
        XCTAssertTrue(scrollSheetFully(to: identifier),
                      "the toggle \(identifier) never came fully into the sheet — \(sheetDiagnosis())")
        if (switchValue(identifier) == "1") == on { return }
        for offset in [0.93, 0.90, 0.96] {
            // Re-scrolled before EVERY attempt and before every read: after a
            // flip the row can leave the `Form`'s render window, where both a
            // tap and a value readback are answered by nothing (a readback of
            // `nil` is not "off", and tapping on it would flip the toggle right
            // back).
            guard scrollSheetFully(to: identifier) else { break }
            element(identifier).coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)).tap()
            _ = scrollSheetFully(to: identifier)
            if (switchValue(identifier) == "1") == on { return }
        }
        if (switchValue(identifier) == "1") != on {
            // Kept as evidence, not decoration: this is the state a tap that did
            // not land leaves behind, and the screenshot is what says whether the
            // row was clipped, off screen, or simply not the switch.
            shot("m90-\(identifier)-stuck")
        }
        XCTAssertEqual(switchValue(identifier) == "1", on,
                       "\(identifier) did not switch to \(on) — \(sheetDiagnosis())")
    }

    /// Taps a control of the settings sheet, scrolled fully into the sheet
    /// first (see `scrollSheetFully`: a clipped row swallows taps).
    private func tapInSheet(_ identifier: String) {
        XCTAssertTrue(scrollSheetFully(to: identifier),
                      "\(identifier) never became reachable — \(sheetDiagnosis())")
        element(identifier).tap()
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    private func tab(_ labels: [String]) -> XCUIElement {
        app.tabBars.buttons.matching(labelPredicate(labels)).firstMatch
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string: an absent parameter is `nil`, an empty one is `""`. `variant`,
    /// `served` and `located` are the fields the stub's own handlers attached
    /// with `req.note(...)` — kept here so a failure prints which payload
    /// answered which query.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let variant: String?
        let served: Int?
        let located: Bool?
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

    /// Every `/api/map/markers` the app sent, in order — the one route the
    /// whole card hangs on.
    private func markerRequests() -> [StubRequest] {
        stubRequests().filter { $0.path == "/api/map/markers" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params) served=\($0.served ?? -1) variant=\($0.variant ?? "-")" }
            .joined(separator: "\n")
    }

    /// Polls the stub until it has seen `count` marker requests. A read of the
    /// app's own UI cannot say whether the network call happened, so the wait
    /// is on the wire (bounded, never a bare `sleep`).
    @discardableResult
    private func waitForMarkerRequests(_ count: Int, timeout: TimeInterval = 25) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var found = markerRequests()
        while found.count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            found = markerRequests()
        }
        return found
    }

    /// Waits for a route to appear in the stub's log — the synchronization a
    /// screen cannot give: a panel that has not fetched yet and one that fetched
    /// nothing look the same.
    private func waitForRequest(path: String, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stubRequests().contains(where: { $0.path == path }) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// Scrolls the viewer's info panel. A coordinate drag rather than
    /// `app.swipeUp()`: the panel covers the lower 70 % of the window and the
    /// viewer's pager sits behind it, so a gesture anchored on the wrong view
    /// pages to the NEXT photo — which would drop the coordinates this step is
    /// about.
    private func swipeInfoPanel() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
    }

    /// Brings the map's photo sheet down. It is presented ABOVE the tab view,
    /// so it covers the tab bar; the drag starts inside it, since a gesture at
    /// the app's centre would start on the map.
    private func dismissMapPhotoSheet() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
    }

    /// `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, GMT — the app's own wire format
    /// (`ISO8601.immichFormatter`), so a bound can be read back and compared
    /// instead of matched as a string.
    private let wireStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private func date(_ stamp: String?) -> Date? {
        guard let stamp else { return nil }
        return wireStamp.date(from: stamp)
    }

    // MARK: - Map helpers

    /// Taps the map segment of the Search tab and waits for the map's settings
    /// button (the map segment is the only screen that carries it).
    private func openMapSegment() {
        let searchTab = tab(["Search", "Recherche", "Suche"])
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20),
                      "Search tab missing — tabs: \(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        searchTab.tap()
        XCTAssertTrue(tapButton(exactlyOneOf: ["Map", "Carte", "Karte"], timeout: 20),
                      "the Map segment of the search bar is missing")
        XCTAssertTrue(element("mapSettingsButton").waitForExistence(timeout: 25),
                      "the map segment never drew its settings button")
    }

    /// Opens the settings sheet, with one bounded retry: the app takes the photo
    /// sheet down in the same breath as it presents this one (one host
    /// controller, one presentation at a time), and a dismissal still animating
    /// can swallow the first presentation.
    /// Closes the settings sheet the only way it closes — a drag down from its
    /// top edge (there is no Done button: closing applies). Repeated, because
    /// from the large detent the first drag may only lower it. Returns whether
    /// the sheet is gone.
    @discardableResult
    private func closeSettingsSheet() -> Bool {
        let sheetMarker = element("mapSettingsRangePicker")
        for _ in 0..<3 where sheetMarker.exists {
            let sheet = app.collectionViews.firstMatch
            let start = sheet.exists
                ? sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                    .withOffset(CGVector(dx: 0, dy: -8))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99)))
            _ = waitUntilGone(sheetMarker, timeout: 3)
        }
        return !sheetMarker.exists
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func openSettingsSheet() {
        let sheetMarker = element("mapSettingsRangePicker")
        element("mapSettingsButton").tap()
        if !sheetMarker.waitForExistence(timeout: 12) {
            element("mapSettingsButton").tap()
        }
        XCTAssertTrue(sheetMarker.waitForExistence(timeout: 12),
                      "the settings sheet never opened — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        expandSettingsSheet()
    }

    // MARK: - Scenario

    func test_mapSettings() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing; the launcher's drop of `skipped` only concerns the
        // stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("m01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap. Its Done button carries an identifier
        // because its label is translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("m02-whats-new")
            whatsNewDone.tap()
        }

        // The ordinary timeline proves the app is talking to THIS stub (a
        // session persisted against another slot's port would leave it empty).
        XCTAssertTrue(tile(locatedAsset).waitForExistence(timeout: 30),
                      "the timeline never rendered its tiles against \(stub)")
        shot("m03-timeline")

        // MARK: - The map segment asks for every marker, unconstrained

        openMapSegment()
        let onEntry = waitForMarkerRequests(1)
        XCTAssertFalse(onEntry.isEmpty,
                       "the Map segment never asked for markers — screen reads: "
                       + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        let plain = onEntry[0]
        XCTAssertTrue(plain.params.isEmpty,
                      "the untouched map must ask for every marker — got:\n\(describe(onEntry))")
        // The map's own payload, on screen: the city only the unfiltered answer
        // carries. A map that renders while pointing at another stub's server
        // would show nothing here.
        XCTAssertTrue(waitForStaticText([plainCity], timeout: 25),
                      "the plain marker payload is not on screen — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("m04-map")

        // MARK: - The settings sheet opens from the map

        openSettingsSheet()
        XCTAssertTrue(element("mapSettingsRangePicker").exists, "the date-range picker is missing")
        XCTAssertTrue(element("mapSettingsFavoritesToggle").exists, "the favourites toggle is missing")
        XCTAssertTrue(element("mapSettingsArchivedToggle").exists, "the archived toggle is missing")
        XCTAssertTrue(element("mapSettingsPartnersToggle").exists, "the partners toggle is missing")
        XCTAssertTrue(element("mapSettingsThemePicker").exists, "the theme picker is missing")
        shot("m05-settings-sheet")

        // A custom range: the toggle pre-fills both bounds from the preset
        // window (0 days = "All" here, so the sheet's own default of 30 days).
        setToggle("mapSettingsCustomRangeButton", on: true)
        XCTAssertTrue(scrollSheet(to: "mapSettingsFromDate"),
                      "the custom range never revealed its start bound — \(sheetDiagnosis())")
        XCTAssertTrue(scrollSheet(to: "mapSettingsToDate"),
                      "the custom range never revealed its end bound — \(sheetDiagnosis())")
        shot("m06-custom-range")

        // MARK: - An inverted range is refused BEFORE the network

        // "After" is cleared and re-set to *now*, while "Before" still holds the
        // start of today: start > end, which `MapMarkerFilter.isValid` refuses.
        tapInSheet("mapSettingsClearFrom")
        XCTAssertTrue(scrollSheet(to: "mapSettingsFromDate"),
                      "clearing the start bound must leave an 'Add' affordance — \(sheetDiagnosis())")
        tapInSheet("mapSettingsFromDate")
        // The custom-range toggle sits BELOW the error badge, so reaching it
        // proves the badge's region of the Form is rendered — an `exists` on the
        // badge alone could otherwise be answered from a dropped row.
        XCTAssertTrue(scrollSheet(to: "mapSettingsCustomRangeButton"),
                      "the sheet lost its custom-range toggle — \(sheetDiagnosis())")
        XCTAssertTrue(element("mapSettingsRangeError").exists,
                      "an inverted range must be reported in the sheet — \(sheetDiagnosis())")
        shot("m07-inverted-range")

        // No Done button: the sheet closes by a swipe down, which an inverted
        // range blocks — otherwise the empty answer would be cached under a
        // valid-looking key.
        XCTAssertFalse(app.buttons.matching(identifier: "mapSettingsDoneButton").firstMatch.exists,
                       "the sheet must not carry a Done button — closing it applies")
        let beforeRefusal = markerRequests().count
        XCTAssertFalse(closeSettingsSheet(),
                       "the sheet closed on an inverted range — it must stay up until the range is valid")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(markerRequests().count, beforeRefusal,
                       "the inverted range reached the network — got:\n\(describe(markerRequests()))")
        XCTAssertTrue(element("mapSettingsRangeError").exists,
                      "the sheet closed on a filter it refused to apply")

        // Back to a valid custom range: toggling the custom range off clears
        // both bounds, toggling it on again re-fills them from the preset.
        setToggle("mapSettingsCustomRangeButton", on: false)
        XCTAssertFalse(element("mapSettingsRangeError").exists,
                       "the error must clear once the range is valid — \(sheetDiagnosis())")
        setToggle("mapSettingsCustomRangeButton", on: true)
        XCTAssertTrue(scrollSheet(to: "mapSettingsToDate"),
                      "the custom range never came back — \(sheetDiagnosis())")
        // MARK: - Closing the sheet applies it: BOTH bounds on the wire

        XCTAssertTrue(closeSettingsSheet(), "the sheet did not close once the range was valid — \(sheetDiagnosis())")
        let afterApply = waitForMarkerRequests(2)
        XCTAssertEqual(afterApply.count, 2,
                       "applying the range did not reach the server exactly once — got:\n\(describe(afterApply))")
        let ranged = afterApply[1]
        let after = date(ranged.params["fileCreatedAfter"])
        let before = date(ranged.params["fileCreatedBefore"])
        XCTAssertNotNil(after, "the custom range must send its start bound — got:\n\(describe(afterApply))")
        XCTAssertNotNil(before, "the custom range must send its end bound — a preset sends none — got:\n\(describe(afterApply))")
        if let after, let before {
            let span = before.timeIntervalSince(after)
            XCTAssertGreaterThan(span, 0, "the range is inverted on the wire — got:\n\(describe(afterApply))")
            XCTAssertGreaterThan(span, 86_400 * 20,
                                 "the range is not the custom window the sheet pre-filled — got:\n\(describe(afterApply))")
        }
        XCTAssertNil(ranged.params["isFavorite"],
                     "no favourites filter was posed — got:\n\(describe(afterApply))")

        // The answer to THAT query is what the map now shows — and the active
        // filter reads on the map without reopening the sheet.
        XCTAssertTrue(waitForStaticText([rangedCity], timeout: 25),
                      "the ranged marker payload is not on screen — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        let badge = element("mapFilterActiveBadge")
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the active filter carried no badge on the map")
        // Its label is `MapViewModel.activeFilterSummary` — the two days of the
        // range, locale-formatted, so the YEAR is the part that reads the same
        // in every language. The end bound is today, hence the current year is
        // always in there.
        let currentYear = String(Calendar.current.component(.year, from: Date()))
        XCTAssertTrue(badge.label.contains(currentYear),
                      "the badge does not name the range that was applied — it reads «\(badge.label)»")
        shot("m08-range-applied")

        // MARK: - A second filter asks a SECOND question (the cache has variants)

        openSettingsSheet()
        setToggle("mapSettingsFavoritesToggle", on: true)
        XCTAssertTrue(closeSettingsSheet(), "the settings sheet did not close — \(sheetDiagnosis())")
        let afterFavorites = waitForMarkerRequests(3)
        XCTAssertEqual(afterFavorites.count, 3,
                       "the favourites filter reused the previous answer instead of re-asking — got:\n\(describe(afterFavorites))")
        let favorites = afterFavorites[2]
        XCTAssertEqual(favorites.params["isFavorite"], "true",
                       "the favourites filter did not reach the query — got:\n\(describe(afterFavorites))")
        // The range survives the second toggle, and both requests stay distinct:
        // one marker cache file per filter is what makes this second request
        // possible at all — a single `markers.json` would have served the ranged
        // payload back and never asked.
        XCTAssertEqual(favorites.params["fileCreatedAfter"], ranged.params["fileCreatedAfter"],
                       "the range was lost when the favourites toggle was applied — got:\n\(describe(afterFavorites))")
        XCTAssertEqual(favorites.params["fileCreatedBefore"], ranged.params["fileCreatedBefore"],
                       "the range was lost when the favourites toggle was applied — got:\n\(describe(afterFavorites))")
        XCTAssertTrue(waitForStaticText([favoritesCity], timeout: 25),
                      "the favourites payload is not on screen — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("m09-favorites-applied")

        // MARK: - The location map, from the photo viewer

        // The map's photo sheet is presented ABOVE the tab view, so it covers
        // the tab bar and swallows a tap meant for another tab (measured: the
        // app stayed on the map and the timeline never appeared). The drag
        // starts INSIDE the sheet — `app.swipeDown()` would start on the map —
        // and is repeated, because the sheet's two detents mean the first drag
        // may only collapse it.
        let photosTab = tab(["Photos", "Fotos"])
        dismissMapPhotoSheet()
        for _ in 0..<2 where !photosTab.isHittable { dismissMapPhotoSheet() }
        XCTAssertTrue(photosTab.isHittable,
                      "the map's photo sheet never came down off the tab bar — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        photosTab.tap()
        let locatedTile = tile(locatedAsset)
        XCTAssertTrue(locatedTile.waitForExistence(timeout: 25), "the located asset is not in the timeline")
        locatedTile.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 25),
                      "the viewer never opened on the located asset")
        XCTAssertTrue(tapAnyButton(["Details", "Détails"], timeout: 20), "the viewer has no Details button")
        // The panel draws the mini-map and the tappable preview from the EXIF
        // coordinates this stub serves for ONE asset, so the read is waited on
        // the wire rather than on the screen: a panel that rendered without
        // those coordinates would simply show no map at all, and the wait would
        // be a guess about which card came first.
        XCTAssertTrue(waitForRequest(path: "/api/assets/\(locatedAsset)"),
                      "the info panel never read the located asset from the stub — got:\n\(describe(stubRequests()))")
        // The Where card sits below the fold of a panel that opens at 70 % of
        // the window.
        let preview = element("locationMapPreviewButton")
        var previewReachable = false
        for _ in 0..<6 where !previewReachable {
            previewReachable = reachable(preview)
            if !previewReachable { swipeInfoPanel() }
        }
        XCTAssertTrue(previewReachable,
                      "the info panel never offered a tappable location preview — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("m10-viewer-info")

        // Tapped by coordinate: the preview is a transparent layer over the
        // mini-map (a `Button` there swallows the map's taps), and what matters
        // is that the APP opens the sheet, not that the harness finds a hit area
        // in a transparent view.
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The location map is a sheet of the VIEWER — exactly like the info
        // panel — and SwiftUI presents ONE sheet per presenter: while the panel
        // is up the viewer's second sheet is queued, not shown (measured: the tap
        // left the panel untouched and no map appeared for 20 s). Closing the
        // panel lets the queued sheet take its place, which is what proves the
        // tap was received, the request built and the sheet mounted.
        if !element("assetLocationMap").waitForExistence(timeout: 5) {
            XCTAssertTrue(element("chevron.down").waitForExistence(timeout: 5),
                          "the info panel has no way to close it — labels: "
                          + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            element("chevron.down").tap()
        }
        XCTAssertTrue(element("assetLocationMap").waitForExistence(timeout: 20),
                      "the full-screen location map never opened — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(element("assetLocationMapDoneButton").exists,
                      "the full-screen location map has no way out")
        shot("m11-location-map")
    }
}
