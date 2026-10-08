import XCTest

/// End-to-end scenario for the Preferences screen (gap G22) — the one screen in
/// the wave whose subject is a value that never leaves the device.
///
/// What it proves, in order:
///
/// 1. a fresh install groups the timeline by day and asks the viewer for the
///    transcoded preview (`/api/assets/{id}/thumbnail?size=fullsize`) — the
///    behavior of the app before the feature, i.e. the additive default;
/// 2. two preferences changed on the real Preferences screen — the timeline
///    grouping (Day → Month) and the viewer's image quality (Load Full Quality)
///    — take effect in the SAME session: the timeline re-cuts its pinned header
///    with no relaunch, and the next photo opened comes from
///    `/api/assets/{id}/original` instead of the preview;
/// 3. they survive a relaunch (`terminate()` + `launch()`), which is the whole
///    point of a persisted preference and the reason the store exists;
/// 4. Reset puts every row back to its default, on screen and in the same
///    session;
/// 5. none of it — the change, the relaunch, the reset — puts a single writing
///    request on the wire: a preference is a device-local choice.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself). The
/// `--erase` is required: the assertions below read a fresh install's defaults
/// and then a persisted value, and a slot keeps its `UserDefaults` (and its
/// keychain) between runs — a leftover grouping would make this scenario pass
/// or fail depending on who ran before it.
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/settings-parity.uitest.log \
///         UITests/stubs/immich_stub_settings.py SettingsParityUITests/test_settingsParity \
///         --erase
///
/// The stub inherits `immich_stub_base` and adds one route; see its docstring
/// for why the original file it serves is a different colour from the preview.
final class SettingsParityUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The first tile of the shell's own timeline — the photo this scenario
    /// opens in the viewer, and the proof the app is talking to THIS stub.
    private let assetId = "aaaaaaaa-1111-4111-8111-000000000001"

    /// The five languages the catalog carries for the confirmation dialog's
    /// "Reset". Matched as a set, never as one literal: the repo's own simulator
    /// is German, a slot that has never launched the app is French and the
    /// shared devices have been both — a scenario pinned to one of them lies on
    /// the other. Everything else is asserted by IDENTIFIER, and the pickers'
    /// options are the enums' own verbatim words (see `pickerValue`).
    private let resetLabels = ["Reset", "Zurücksetzen", "Restablecer", "Réinitialiser", "Reimposta"]

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
            shot("p02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One element by IDENTIFIER, whatever its type: a preference row is a menu
    /// picker, a switch or a button depending on the control, and only the
    /// identifier is stable across those.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        element("assetTile_\(assetId)")
    }

    /// Bounded poll on a UI predicate, spelled out rather than left to
    /// `waitForExistence`: the caller's message can then say what was on screen
    /// when the budget ran out, and a NEGATIVE assertion gets a real budget
    /// instead of a bare sleep.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    /// A row of a `Form`, by IDENTIFIER (its label is localized: "Recently
    /// Taken" / "Récemment prises"). A `Form` only publishes what it rendered,
    /// so the row is scrolled into view first, letting each swipe settle — the
    /// hub's rows and the Preferences form's Reset row both sit below the fold.
    private func scrolledRow(_ identifier: String) -> XCUIElement {
        let row = element(identifier)
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// Back to the top of the open form: the rows asserted after a scroll down
    /// (Reset lives in the last section) were off screen, and a `Form` only
    /// publishes the rows it rendered.
    private func scrollFormToTop() {
        let deadline = Date().addingTimeInterval(10)
        while !element("preferencesGroupPicker").exists && Date() < deadline {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(element("preferencesGroupPicker").exists, "the Preferences form never scrolled back to its top")
    }

    // MARK: - Preferences screen

    /// Timeline → Me sheet → Preferences. Leaves the app on the Preferences form.
    private func openPreferences() {
        let avatar = element("profileAvatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "the timeline has no profile avatar")
        avatar.tap()
        let row = scrolledRow("preferencesRow")
        if !row.waitForExistence(timeout: 10) {
            shot("p06b-me-hub-without-preferences-row")
            XCTFail("Preferences row missing in the Me hub:\n\(app.debugDescription)")
        }
        row.tap()
        XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20),
                      "the Preferences form never appeared — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    /// Preferences → the hub → the timeline. The Me sheet has no Done button: it
    /// is dismissed the way a user dismisses it, by dragging it down from its
    /// navigation bar (a drag inside the form would scroll the form instead).
    /// The dismissal is VERIFIED, because the covered timeline stays in the
    /// accessibility tree — an unverified dismissal would leave every later
    /// timeline assertion reading the screen behind the sheet.
    private func leavePreferencesAndHub() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back from the Preferences screen")
        back.tap()

        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            // Dragged down from its chrome: the navigation bar first (a drag
            // inside the form scrolls the form), then the form itself — at the
            // top of its scroll view the sheet's own pan takes the gesture over.
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { !self.element("preferencesGroupPicker").exists }
        }
        XCTAssertTrue(dismissed,
                      "the Me sheet never dismissed: the timeline assertions below would read the covered timeline")
        XCTAssertTrue(tile(assetId).waitForExistence(timeout: 15), "not back on the timeline after the Me sheet")
    }

    /// Resolves a catalog key the way the app does, for the language the
    /// simulator runs in — an expectation written as `"Day"` would assert the
    /// English source and stop proving the localization, which is this
    /// feature's whole subject.
    ///
    /// Deliberately NOT a membership list of accepted labels (`latchedCopy` in
    /// `OcrTextUITests`): a set of several forms would still pass if the app
    /// drew the raw English literal. Reading the catalog keeps the assertion
    /// discriminating — on a `fr-FR` slot, expecting `Mois` fails the moment
    /// the picker reads `Month`.
    private func catalogLabel(_ key: String) -> String {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/" {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) {
                break
            }
            root.deleteLastPathComponent()
        }
        let catalog = root.appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: catalog),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = payload["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any] else {
            XCTFail("cannot read the catalog entry for '\(key)' in \(catalog.path)")
            return key
        }
        let language = String((Locale.preferredLanguages.first ?? "en").prefix { $0 != "-" })
        guard let localizations = entry["localizations"] as? [String: Any],
              let unit = localizations[language] as? [String: Any],
              let stringUnit = unit["stringUnit"] as? [String: Any],
              let value = stringUnit["value"] as? String, !value.isEmpty else {
            // Not shipped in this language: the app falls back to the key.
            return key
        }
        return value
    }

    /// The option a menu picker currently shows.
    ///
    /// Measured shape (this run): XCUITest exposes a `Form` picker as a **Button**
    /// whose label joins the row's name and the selected option's — `Grouper par,
    /// Jour` on the French slot — and whose `value` is EMPTY. Only the tail is
    /// compared: the row's own name (`Group By`) is not what this helper is
    /// about, the option is (and both now come from the catalog).
    private func pickerValue(_ identifier: String) -> String {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let parts = control.label.components(separatedBy: ", ")
        return parts.count > 1 ? parts[parts.count - 1] : control.label
    }

    private func assertPicker(_ identifier: String, is option: String, _ comment: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let actual = pickerValue(identifier)
        XCTAssertEqual(actual, option,
                       "\(identifier) reads '\(actual)' (full label '\(control.label)'), expected '\(option)' "
                       + "— \(comment)")
    }

    /// A switch's state as the accessibility API reports it ("1"/"0"). The row is
    /// a SwiftUI `Toggle`; the element it publishes is a `Switch`.
    private func assertSwitch(_ identifier: String, is expected: String, _ comment: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let actual = (control.value as? String) ?? ""
        XCTAssertEqual(actual, expected,
                       "\(identifier) reads '\(actual)', expected '\(expected)' — \(comment). "
                       + "Element: \(control.debugDescription)")
    }

    /// Opens a menu-style picker and clicks one of its options. The option is
    /// matched EXACTLY, on `catalogLabel`'s value for the running language: the
    /// menu item and the picker row show the same localized label.
    private func select(_ option: String, inPicker identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        control.tap()
        let predicate = NSPredicate(format: "label == %@", option)
        for candidate in [app.buttons.matching(predicate).firstMatch,
                          app.descendants(matching: .any).matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: 6) {
            candidate.tap()
            return
        }
        XCTFail("the \(identifier) menu never offered '\(option)' — buttons on screen: "
                + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    /// Flips a switch and waits for its value to move. The assertion is the
    /// VALUE, not the tap: the element's frame is the whole ROW (measured on the
    /// picker next door — same layout), so a centre tap lands on the label and
    /// switches nothing. The tap is therefore aimed at the trailing edge, where
    /// the control sits, and retried: the tap that follows a menu dismissal can
    /// land while the menu is still on its way out.
    private func flip(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let before = control.value as? String
        for _ in 0..<3 {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            if waitUntil(4) { (control.value as? String) != before } { return }
        }
        XCTFail("\(identifier) never flipped, even tapped on its own control (value stayed \(before ?? "nil"))")
    }

    /// The pinned header's shape, read by IDENTIFIER: a `.day` timeline pins the
    /// year + day pair, a `.month` timeline pins only the month banner, and a
    /// flat one pins nothing. The copy itself is localized, so an assertion on
    /// the text would tie this scenario to the device's language.
    private func pinnedHeaderShape() -> String {
        if element("timelinePinnedMonthHeader").exists { return "month" }
        if element("timelinePinnedDayHeader").exists { return "day" }
        return "none"
    }

    private func assertPinnedHeader(is shape: String, _ comment: String, timeout: TimeInterval = 20) {
        let reached = waitUntil(timeout) { self.pinnedHeaderShape() == shape }
        XCTAssertTrue(reached,
                      "the timeline never pinned the \(shape) header — \(comment). It currently pins "
                      + "'\(pinnedHeaderShape())', and the screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(pinnedHeaderShape(), shape, "the pinned header changed shape again — \(comment)")
    }

    // MARK: - Viewer

    private func openViewer() {
        let cell = tile(assetId)
        XCTAssertTrue(cell.waitForExistence(timeout: 20), "the first timeline tile is not on screen")
        cell.tap()
        XCTAssertTrue(app.buttons["viewerBackButton"].waitForExistence(timeout: 20),
                      "the photo viewer never opened on a tap of the tile")
    }

    private func closeViewer() {
        var closed = false
        for _ in 0..<4 where !closed {
            guard app.buttons["viewerBackButton"].exists else { break }
            let back = app.buttons["viewerBackButton"]
            if back.isHittable { back.tap() } else { app.swipeDown() }
            closed = waitUntil(6) { !self.app.buttons["viewerBackButton"].exists }
        }
        XCTAssertTrue(closed, "the photo viewer never dismissed — every later step would read the covered timeline")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string: an absent `size` is `nil`, an empty one is `""`.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
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

    private func describe(_ requests: [StubRequest]) -> String {
        requests.isEmpty ? "(nothing)" : requests.map { "\($0.method) \($0.path) params=\($0.params)" }
            .joined(separator: "\n")
    }

    /// Bounded poll on the stub's log. The media fetch a viewer starts is
    /// asynchronous, so a POSITIVE assertion waits for its own request instead
    /// of sleeping and hoping; the NEGATIVE ones (no original for the preview,
    /// no preference on the wire) are each paired with the positive proof that
    /// the client was talking to this stub at all.
    private func waitForWire(_ timeout: TimeInterval, _ condition: ([StubRequest]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition(stubRequests()) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return condition(stubRequests())
    }

    private func originalRequests() -> [StubRequest] {
        stubRequests().filter { $0.path.hasSuffix("/original") }
    }

    // MARK: - Scenario

    func test_settingsParity() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's drop of `skipped` only concerns the stub being absent.
        // `--erase` clears the keychain, so the walk is the normal path here.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("p01-welcome")
            walkOnboardingToLogin()
            shot("p02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the hub would never open under it. Its Done
        // button carries an identifier because its label is translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 8) {
            shot("p03-whats-new")
            whatsNewDone.tap()
        }

        XCTAssertTrue(tile(assetId).waitForExistence(timeout: 30),
                      "the timeline never rendered its first tile against \(stub)")

        // MARK: The defaults a fresh install opens on

        // Grouping by day is the behavior the app had before the feature: the
        // pinned header is the year + day pair, never the month banner.
        assertPinnedHeader(is: "day", "a fresh install must group the timeline by day")
        shot("p04-timeline-defaut-jour")

        // The wire is read at three points: the negative proof below, the
        // positive one after the change, and once at the end over the whole run.

        // MARK: Default quality: the viewer asks for the transcoded preview

        openViewer()
        let previewFetched = waitForWire(20) { log in
            log.contains { $0.path.hasSuffix("/thumbnail") && $0.params["size"] == "preview" }
        }
        XCTAssertTrue(previewFetched,
                      "the viewer never asked for its preview — got:\n\(describe(Array(stubRequests().suffix(12))))")
        // The positive proof above is what makes this negative one mean
        // something: a fetch DID happen, and the original was not part of it.
        XCTAssertTrue(originalRequests().isEmpty,
                      "with 'Load Full Quality' off the viewer must serve the transcoded preview, never the "
                      + "original — got:\n\(describe(originalRequests()))")
        shot("p05-viewer-preview-par-defaut")
        closeViewer()

        // MARK: Preferences — the two rows this scenario moves

        openPreferences()
        shot("p06-preferences-defauts")
        assertPicker("preferencesGroupPicker", is: catalogLabel("Day"),
                     "a fresh install must offer Day, the grouping the timeline had before the feature")
        assertSwitch("preferencesLoadOriginalToggle", is: "0",
                     "'Load Full Quality' must default to off: it is the behavior the viewer had before")

        // MARK: Change them on the real screen

        let beforeChange = stubRequests().count
        select(catalogLabel("Month"), inPicker: "preferencesGroupPicker")
        flip("preferencesLoadOriginalToggle")
        shot("p07-preferences-modifiees")
        XCTAssertEqual(stubRequests().dropFirst(beforeChange).filter { $0.method != "GET" }.count, 0,
                       "writing a preference must not send a request to the server")
        assertPicker("preferencesGroupPicker", is: catalogLabel("Month"),
                     "the picker must read back the option that was just chosen")
        assertSwitch("preferencesLoadOriginalToggle", is: "1",
                     "the toggle must read back the state that was just set")

        // MARK: …and the screens that own those axes follow, in this session

        leavePreferencesAndHub()
        assertPinnedHeader(is: "month", "changing the grouping must re-cut the timeline without a relaunch")
        shot("p08-timeline-mois-session")

        let beforeViewer = stubRequests().count
        openViewer()
        let originalFetched = waitForWire(20) { log in
            log.dropFirst(beforeViewer).contains { $0.path.hasSuffix("/original") }
        }
        XCTAssertTrue(originalFetched,
                      "with 'Load Full Quality' on the viewer must fetch "
                      + "/api/assets/\(assetId)/original — got:\n\(describe(Array(stubRequests().dropFirst(beforeViewer))))")
        shot("p09-viewer-original-session")
        closeViewer()

        // MARK: Relaunch — a persisted preference is the whole point of the screen

        app.terminate()
        app.launch()
        let relaunchDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if relaunchDone.waitForExistence(timeout: 8) {
            // Seen on the first launch: it must NOT come back, but a modal left
            // up would swallow the taps below, so it is dismissed either way.
            shot("p10-whats-new-apres-relance")
            relaunchDone.tap()
        }
        XCTAssertTrue(tile(assetId).waitForExistence(timeout: 40),
                      "the relaunch did not reach the timeline (session lost?)")

        assertPinnedHeader(is: "month", "the grouping must survive a relaunch — that is what persisting it means")
        shot("p11-apres-relance-timeline")

        openPreferences()
        assertPicker("preferencesGroupPicker", is: catalogLabel("Month"),
                     "the grouping chosen before the relaunch must still be the one on screen")
        assertSwitch("preferencesLoadOriginalToggle", is: "1",
                     "the image quality chosen before the relaunch must still be on")
        shot("p12-apres-relance-preferences")

        // MARK: Reset — back to the defaults, in the same session

        let reset = scrolledRow("preferencesResetButton")
        if !reset.waitForExistence(timeout: 10) {
            shot("p13b-reset-row-missing")
            XCTFail("the Preferences form has no Reset row:\n\(app.debugDescription)")
        }
        reset.tap()
        // Destructive and confirmed: the dialog is an action sheet, and its
        // buttons are in the app's own tree (the form's Reset row is still there
        // behind it, hence the dialog-scoped query).
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Reset did not raise a confirmation")
        let confirm = dialog.buttons.matching(labelPredicate(resetLabels)).firstMatch
        if !confirm.waitForExistence(timeout: 10) {
            shot("p13c-reset-sans-bouton")
            XCTFail("no Reset button in the confirmation dialog — its buttons are: "
                    + "\(dialog.buttons.allElementsBoundByIndex.map(\.label))")
        }
        confirm.tap()
        XCTAssertTrue(waitUntil(10) { !dialog.exists }, "the confirmation stayed up after Reset")
        shot("p13-reset-confirme")
        // The rows asserted below were off screen while the form was scrolled to
        // its last section.
        scrollFormToTop()
        let resetOnScreen = waitUntil(10) { (self.element("preferencesLoadOriginalToggle").value as? String) == "0" }
        XCTAssertTrue(resetOnScreen, "Reset left 'Load Full Quality' on — the store did not go back to its defaults")
        assertPicker("preferencesGroupPicker", is: catalogLabel("Day"), "Reset must bring the grouping back to Day")

        leavePreferencesAndHub()
        assertPinnedHeader(is: "day", "Reset must give the timeline its default grouping back, in the same session")
        shot("p14-timeline-apres-reset")

        // MARK: The wire — none of this ever travelled to the server

        // The only writes the whole run contains are the app's OWN session
        // handshakes: the two OAuth legs of the sign-in walk, and the token
        // validation a relaunch performs at boot (measured: it is the only
        // non-GET the relaunch sends, and it fires whether or not anyone opens
        // Preferences). Every other writing request this segment could have
        // carried — a preference pushed to `/api/users/me`, a settings sync, a
        // reset announced to the server — is outside that list, so it would fail
        // here by name.
        let handshakes = ["/api/oauth/authorize", "/api/oauth/callback", "/api/auth/validateToken"]
        let writes = stubRequests().filter { $0.method != "GET" && !handshakes.contains($0.path) }
        XCTAssertTrue(writes.isEmpty,
                      "a preference is a device-local choice: changing one, relaunching and resetting must put "
                      + "NO writing request on the wire — got:\n\(describe(writes))")
        // And the quality axis is still a real fetch, so the assertion above is
        // not passing on a client that stopped talking to the server entirely.
        XCTAssertFalse(originalRequests().isEmpty,
                       "the whole run never asked for a single original file, while 'Load Full Quality' was on")
    }
}
