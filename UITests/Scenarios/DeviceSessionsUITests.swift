import XCTest

/// End-to-end scenario for "Connected Devices" (gap G19) — the account's
/// sessions, and the **elevation probe** that landed on 2026-09-15.
///
/// What it drives, and what each step is there to prove:
///
/// 1. The list comes from `GET /api/sessions`, and the session in your hand is
///    the marked one — the rows are asserted to carry the stub's own device
///    strings, and exactly one of them carries the "This device" badge.
/// 2. One device, revoked in the app: `DELETE /api/sessions/{id}` **then**
///    `GET /api/auth/status`. The order is the whole point — the second request
///    can only exist because the mutation finished, so a screen that guessed
///    what its own call had done would leave it out. The stub flips its
///    elevation between the two revocations, and the lock control is asserted to
///    follow the SERVER's answer both ways (nothing local elevated anything).
/// 3. The bulk revoke is recorded as `DELETE /api/sessions` — the path of the
///    route that spares the calling session, not the per-id one.
/// 4. The unlock: `POST /api/auth/session/unlock` is accepted with the account
///    PIN (the stub 401s anything else) and the probe **contradicts** it
///    (`isElevated: false`). The screen must not claim an elevation the server
///    denies — and its control must not be left holding a stale value either.
///
/// Run it with the launcher, never by hand: it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself.
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/device-sessions.uitest.log \\
///         UITests/stubs/immich_stub_device_sessions.py \\
///         DeviceSessionsUITests/test_deviceSessions --erase
///
/// `--erase` because the walk below is a first launch: the device is shared
/// with the other scenarios of the wave, and a session left in its keychain by
/// a neighbour's port would take the app straight to an empty shell.
final class DeviceSessionsUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's fixtures — the ids the rows must be drawn from, and the PIN its
    // unlock route really checks.
    private let selfID = "dddddddd-1111-4111-8111-000000000001"
    private let iphoneID = "dddddddd-1111-4111-8111-000000000002"
    private let chromeID = "dddddddd-1111-4111-8111-000000000003"
    private let pin = "246813"

    // Every state below is recognised through ALL the spellings the catalogue
    // holds (`Resources/Localizable.xcstrings`): the app's accessibility labels
    // are `LocalizedStringKey`s, the repo's own simulator is German and the
    // slots are English, so no control may be identified by one literal.
    private let currentBadge = ["This device", "Cet appareil", "Dieses Gerät",
                                "Este dispositivo", "Questo dispositivo"]
    private let notElevated = ["Unlock", "Déverrouiller", "Entsperren", "Desbloquear", "Sblocca"]
    private let elevated = ["Lock session", "Verrouiller la session", "Sitzung sperren",
                            "Bloquear la sesión", "Blocca la sessione"]
    private let staleElevation = ["Unknown", "Inconnu", "Unbekannt", "Desconocido", "Sconosciuto"]
    private let logOut = ["Log Out", "Se déconnecter", "Abmelden", "Cerrar sesión", "Esci"]
    private let revokeOthers = ["Log out other devices", "Déconnecter les autres appareils",
                                "Andere Geräte abmelden", "Cerrar sesión en otros dispositivos",
                                "Disconnetti gli altri dispositivi"]

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
    // Copied from `RecentlyTakenUITests` on purpose: they are `private` there,
    // the shared file is frozen (11 committed scenarios are green against its
    // current text), and extracting them into a shared support file would be a
    // second convention next to the existing one — the harness rule is one file
    // per feature, helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// One GET against the stub. Every control route below is a GET with its
    /// argument in the query, so the whole harness side is this one call.
    @discardableResult
    private func stubGet(_ path: String, timeout: TimeInterval = 10) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + timeout + 2), .success, "Stub did not answer \(path)")
        return body
    }

    /// Puts the stub back to its initial state and empties its request log, so
    /// no assertion below can be satisfied by a previous run.
    private func reset() {
        stubGet("/__reset")
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks, like `test_01` of the shared class.
    private func setProvider(_ mode: String) {
        let body = stubGet("/__provider?mode=\(mode)")
        XCTAssertEqual(body, "{\"provider\": \"\(mode)\"}")
    }

    /// The server's elevation, held by the scenario — see the stub's docstring.
    /// Both directions are needed: the screen must follow it up (proving it read
    /// the answer) and down (proving a successful unlock did not become one).
    private func setElevation(_ isElevated: Bool) {
        let body = stubGet("/control/elevation?isElevated=\(isElevated ? 1 : 0)")
        XCTAssertEqual(body, "{\"isElevated\": \(isElevated)}", "the stub did not take the elevation")
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
            shot("ds02b-not-on-login-screen")
            XCTFail("Login screen not reached — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized: "Connected
    /// Devices" / "Appareils connectés"). A `Form` only publishes what it
    /// rendered, so the row is scrolled into view first, letting each swipe
    /// settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<8 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    // MARK: - Screen helpers

    /// An element by IDENTIFIER, wherever it sits in the tree. Rows are
    /// `.accessibilityElement(children: .combine)`d, so they do not show up as
    /// `cells` or `buttons`: the identifier's element type is not asserted.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sessionRow(_ id: String) -> XCUIElement {
        element("deviceSessionRow_\(id)")
    }

    private func lockButton() -> XCUIElement {
        element("deviceSessionsLockButton")
    }

    /// Every element carrying a `deviceSessionRow_` identifier — the failure
    /// message of a missing row has to say what the screen actually rendered.
    private func describeRows() -> String {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'deviceSessionRow_'"))
            .allElementsBoundByIndex
        return "rows: " + rows.map { "\($0.identifier) → '\($0.label)'" }.joined(separator: " | ")
    }

    /// Waits until the lock control's label is one of `labels`. The label is the
    /// elevation the SERVER reported, and it arrives one round trip after the
    /// action, so it is waited on and never sampled once.
    private func waitForLockLabel(_ labels: [String], timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(
            format: labels.map { _ in "label == %@" }.joined(separator: " OR "),
            argumentArray: labels)
        return XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: lockButton())],
            timeout: timeout) == .completed
    }

    /// The action of the confirmation alert the app raised — found by
    /// IDENTIFIER first, always inside the alert.
    ///
    /// The confirmation and the swipe that raised it carry the SAME label ("Log
    /// Out" on both), so a label query that is not scoped can reach the swipe
    /// action instead, which only re-arms the confirmation. And iOS 26 lists an
    /// identified alert button twice in the tree, so an unscoped identifier query
    /// fails with "Multiple matching elements". The query is scoped to the alert
    /// and narrowed to its first match; the label query stays as a fallback.
    private func confirmButton(_ identifier: String, _ labels: [String],
                               timeout: TimeInterval = 10) -> XCUIElement? {
        let alert = app.alerts.firstMatch
        let byIdentifier = alert.buttons.matching(identifier: identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: timeout) { return byIdentifier }
        let labelClause = labels.map { _ in "label == %@" }.joined(separator: " OR ")
        let byLabel = alert.buttons.matching(NSPredicate(format: labelClause, argumentArray: labels)).firstMatch
        return byLabel.waitForExistence(timeout: timeout) ? byLabel : nil
    }

    /// The confirmation of the bulk revoke is labelled with the number of
    /// devices it would remove, and that number is the one the SERVER just
    /// served — a count read anywhere else would be a different string.
    private func logoutDevicesLabels(_ count: Int) -> [String] {
        ["Log out \(count) devices", "Déconnecter \(count) appareils", "\(count) Geräte abmelden",
         "Cerrar sesión en \(count) dispositivos", "Disconnetti \(count) dispositivi"]
    }

    /// Types the PIN in the unlock alert's field. The number pad is a software
    /// keyboard: with the hardware keyboard attached `typeText` can be
    /// swallowed, so the keys are tapped as a fallback. The wire assertion
    /// (the stub echoes the PIN it decoded and 401s anything else) is what
    /// actually proves the entry, not this bookkeeping.
    private func enterPIN(_ digits: String, in field: XCUIElement) {
        field.tap()
        field.typeText(digits)
        if !((field.value as? String) ?? "").contains(digits) {
            for digit in digits {
                let key = app.keyboards.firstMatch.keys[String(digit)]
                if key.waitForExistence(timeout: 2) { key.tap() }
            }
        }
        XCTAssertTrue(((field.value as? String) ?? "").contains(digits),
                      "the PIN never landed in the alert's field (it reads '\((field.value as? String) ?? "")')")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. Decoded by hand rather than through
    /// `Codable`: the log carries the fields a route `note()`d, whose types vary
    /// (a string, a list), and one non-decoding field would make a
    /// `try?`-decoded array collapse to `[]` — a scenario asserting on an empty
    /// log reads every "must exist" as a screen bug.
    private struct StubRequest {
        let method: String
        let path: String
        let params: [String: String]
        /// The route's own `note()`d fields (`session`, `pinCode`, `accepted`).
        let fields: [String: String]

        init?(_ raw: Any) {
            guard let object = raw as? [String: Any],
                  let method = object["method"] as? String,
                  let path = object["path"] as? String else { return nil }
            self.method = method
            self.path = path
            self.params = (object["params"] as? [String: String]) ?? [:]
            // Only what the route itself `note()`d: the entry's own keys would
            // otherwise show up as "fields" in every failure message.
            let envelope: Set<String> = ["method", "path", "params", "body"]
            self.fields = object.compactMapValues { $0 as? String }
                .filter { !envelope.contains($0.key) }
        }
    }

    private func stubRequests() -> [StubRequest] {
        let body = stubGet("/__requests", timeout: 6)
        let raw = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [Any] ?? []
        return raw.compactMap(StubRequest.init)
    }

    /// The app's own traffic. The scenario's control routes are logged by the
    /// shell like any other request; filtering on `/api/` keeps them out of the
    /// index arithmetic below.
    private func apiRequests() -> [StubRequest] {
        stubRequests().filter { $0.path.hasPrefix("/api/") }
    }

    private func index(of method: String, _ path: String, in requests: [StubRequest]) -> Int? {
        requests.firstIndex { $0.method == method && $0.path == path }
    }

    /// Waits until the log holds `count` instances of a request, then returns it.
    ///
    /// The app sends its mutations from a `Task`, so reading the log the instant
    /// a control is tapped RACES the app: a screen that did the right thing can
    /// still look silent for a few hundred milliseconds. The mutation is
    /// therefore given a bounded window, and its absence is only a failure once
    /// that window has passed.
    private func waitForRequests(_ method: String, _ path: String, count: Int,
                                 timeout: TimeInterval = 20) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var requests = apiRequests()
        func matches() -> Int {
            requests.filter { $0.method == method && $0.path == path }.count
        }
        while Date() < deadline && matches() < count {
            usleep(300_000)
            requests = apiRequests()
        }
        return requests
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params) fields=\($0.fields)" }
            .joined(separator: "\n")
    }

    private func contains(_ text: String, in labels: [String]) -> Bool {
        labels.contains { text.contains($0) }
    }

    // MARK: - Scenario

    func test_deviceSessions() throws {
        reset()
        setProvider("manual")
        setElevation(false)
        app.launch()

        // MARK: Onboarding → OAuth → the authenticated shell

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("ds01-welcome")
            walkOnboardingToLogin()
            shot("ds02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the hub would never open under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("ds03-whats-new")
            whatsNewDone.tap()
        }

        // The ordinary timeline: the shell's own day. Its first tile also proves
        // the app is talking to THIS stub — a session persisted against another
        // slot's port would leave the grid empty.
        XCTAssertTrue(tile("aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("ds04-timeline")

        // MARK: The "Me" hub → Connected Devices

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does

        let row = hubRow("deviceSessionsRow")
        if !row.waitForExistence(timeout: 10) {
            shot("ds05b-me-hub-without-device-row")
            XCTFail("Connected Devices row missing in the Me hub:\n\(app.debugDescription)")
        }
        shot("ds05-me-hub")
        row.tap()

        XCTAssertTrue(element("deviceSessionsList").waitForExistence(timeout: 20),
                      "the Connected Devices screen never loaded — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")

        let selfRow = sessionRow(selfID)
        XCTAssertTrue(selfRow.waitForExistence(timeout: 20),
                      "the current session is not in the list — \(describeRows())")
        XCTAssertTrue(sessionRow(iphoneID).waitForExistence(timeout: 10),
                      "a session the server served is missing — \(describeRows())")
        XCTAssertTrue(sessionRow(chromeID).exists,
                      "a session the server served is missing — \(describeRows())")
        shot("ds06-device-sessions")

        // The list comes from `GET /api/sessions`, and nothing invents a row: the
        // device strings are the stub's, and the marked session is the one the
        // payload flags `current` — not merely the first one.
        XCTAssertTrue(sessionRow(chromeID).label.contains("Chrome OS"),
                      "the Chrome row is not drawn from the served payload: '\(sessionRow(chromeID).label)'")
        XCTAssertTrue(sessionRow(iphoneID).label.contains("iPhone"),
                      "the iPhone row is not drawn from the served payload: '\(sessionRow(iphoneID).label)'")
        XCTAssertTrue(contains(selfRow.label, in: currentBadge),
                      "the current session carries no badge — \(describeRows())")
        XCTAssertFalse(contains(sessionRow(iphoneID).label, in: currentBadge),
                       "an other session is presented as this device — \(describeRows())")
        XCTAssertFalse(contains(sessionRow(chromeID).label, in: currentBadge),
                       "an other session is presented as this device — \(describeRows())")

        // On the wire: one list read, and no elevation probe yet.
        let onOpen = apiRequests()
        XCTAssertEqual(onOpen.filter { $0.method == "GET" && $0.path == "/api/sessions" }.count, 1,
                       "the list must come from exactly one GET /api/sessions — got:\n\(describe(onOpen))")
        XCTAssertNil(index(of: "GET", "/api/auth/status", in: onOpen),
                     "nothing has been mutated yet: no probe may have run — got:\n\(describe(onOpen))")
        XCTAssertTrue(waitForLockLabel(notElevated, timeout: 10),
                      "the screen opened claiming an elevation the server never gave it — reads '\(lockButton().label)'")

        // MARK: One device revoked — the probe follows the mutation

        // The server now says the session IS elevated, so the only thing that
        // can move the lock control is the answer to the probe the revocation
        // triggers. An optimistic screen stays where it was.
        setElevation(true)

        sessionRow(iphoneID).swipeLeft()
        let swipeRevoke = element("deviceSessionRevokeButton_\(iphoneID)")
        if !swipeRevoke.waitForExistence(timeout: 10) {
            shot("ds07b-swipe-did-not-reveal")
            XCTFail("the swipe revealed no revoke action — \(describeRows())")
        }
        shot("ds07-swipe-reveal")
        // `allowsFullSwipe: false` (AC-5196): the swipe above is a FULL swipe,
        // and a full swipe must not sign a device out silently.
        XCTAssertNil(index(of: "DELETE", "/api/sessions/\(iphoneID)", in: apiRequests()),
                     "a full swipe revoked a device — the confirmation was skipped:\n\(describe(apiRequests()))")

        swipeRevoke.tap()
        guard let confirmOne = confirmButton("deviceSessionRevokeConfirm", logOut) else {
            shot("ds08b-no-single-confirmation")
            XCTFail("tapping the revoke action raised no confirmation — labels: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            return
        }
        shot("ds08-confirm-single")
        XCTAssertNil(index(of: "DELETE", "/api/sessions/\(iphoneID)", in: apiRequests()),
                     "the device was revoked before the confirmation was accepted:\n\(describe(apiRequests()))")
        confirmOne.tap()

        // MARK: On the wire — DELETE, then the probe. The order IS the proof.

        // The confirmation is waited on, not raced: the mutation leaves the app
        // in a `Task`, and the probe follows it.
        let revoked = waitForRequests("GET", "/api/auth/status", count: 1)
        guard let deleteIndex = index(of: "DELETE", "/api/sessions/\(iphoneID)", in: revoked) else {
            shot("ds09b-no-single-delete")
            XCTFail("the accepted confirmation sent no DELETE for the row it named — got:\n\(describe(revoked))")
            return
        }
        let probes = revoked.enumerated().filter {
            $0.element.method == "GET" && $0.element.path == "/api/auth/status"
        }
        guard let firstProbe = probes.first else {
            shot("ds09c-no-probe-after-revoke")
            XCTFail("the mutation was not followed by the elevation probe (GET /api/auth/status) — got:\n"
                    + "\(describe(revoked))")
            return
        }
        XCTAssertLessThan(deleteIndex, firstProbe.offset,
                          "the elevation was read BEFORE the mutation it is supposed to reflect:\n"
                          + "\(describe(revoked))")
        XCTAssertEqual(probes.count, 1,
                       "one mutation, one probe — got:\n\(describe(revoked))")
        // The list is re-read before the probe (`mutate` reloads, then probes):
        // the row disappearing below is the consequence of that second read.
        guard let reload = revoked.enumerated().last(where: {
            $0.element.method == "GET" && $0.element.path == "/api/sessions"
        }) else {
            XCTFail("the revocation never re-read the list — got:\n\(describe(revoked))")
            return
        }
        XCTAssertLessThan(reload.offset, firstProbe.offset,
                          "the elevation was probed before the list was re-read:\n\(describe(revoked))")

        // The screen re-read the list (the row is gone because the STUB no
        // longer serves it — the deletion really happened) …
        XCTAssertTrue(sessionRow(iphoneID).waitForNonExistence(timeout: 20),
                      "the revoked session is still listed — \(describeRows())")
        XCTAssertTrue(sessionRow(chromeID).exists,
                      "the untouched session disappeared from the list — \(describeRows())")
        // … and it holds the elevation the server just reported, not the one it
        // had: nothing local elevated this session.
        XCTAssertTrue(waitForLockLabel(elevated, timeout: 20),
                      "the server answered isElevated=true to the probe that followed the revocation, "
                      + "so the lock control must read 'Lock session' — it reads '\(lockButton().label)'")
        shot("ds09-after-single-revoke")

        // MARK: Every other device revoked — `DELETE /api/sessions`

        // Back down: the probe is what says so, and it must take the screen with
        // it.
        setElevation(false)

        let menu = element("deviceSessionsMenuButton")
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no toolbar menu on the devices screen")
        menu.tap()
        // A `Menu`'s items do not exist in the accessibility tree until it is
        // open, and they carry their own identifier only when the system keeps
        // it: the item is recognised by its label, which names the route's
        // meaning ("other devices", never "this device").
        XCTAssertTrue(tapAnyButton(revokeOthers, timeout: 10),
                      "the toolbar menu offered no 'log out other devices' action — labels: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")

        // One other device is left: the confirmation is labelled with the count
        // the server served, which is the only place that number can come from.
        guard let confirmAll = confirmButton("deviceSessionsRevokeAllConfirm", logoutDevicesLabels(1)) else {
            shot("ds10c-no-bulk-confirmation")
            XCTFail("no confirmation for the bulk revocation — labels: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            return
        }
        XCTAssertTrue(logoutDevicesLabels(1).contains(confirmAll.label),
                      "the bulk confirmation does not name the number of devices the server served — it reads "
                      + "'\(confirmAll.label)'")
        shot("ds10-confirm-bulk")
        confirmAll.tap()

        let bulk = waitForRequests("GET", "/api/auth/status", count: 2)
        guard let bulkIndex = index(of: "DELETE", "/api/sessions", in: bulk) else {
            shot("ds11b-no-bulk-delete")
            XCTFail("the bulk revocation did not use the collection route (DELETE /api/sessions) — got:\n"
                    + "\(describe(bulk))")
            return
        }
        let bulkProbes = bulk.enumerated().filter {
            $0.element.method == "GET" && $0.element.path == "/api/auth/status"
        }
        guard let bulkProbe = bulkProbes.last else {
            XCTFail("the bulk mutation was not followed by the elevation probe — got:\n\(describe(bulk))")
            return
        }
        XCTAssertLessThan(bulkIndex, bulkProbe.offset,
                          "the elevation was not re-read after the bulk revocation:\n\(describe(bulk))")
        XCTAssertEqual(bulkProbes.count, 2, "two mutations, two probes — got:\n\(describe(bulk))")

        XCTAssertTrue(sessionRow(chromeID).waitForNonExistence(timeout: 20),
                      "a revoked session is still listed — \(describeRows())")
        XCTAssertTrue(sessionRow(selfID).exists,
                      "the bulk route never touches the calling session, and the screen must keep it — \(describeRows())")
        XCTAssertTrue(waitForLockLabel(notElevated, timeout: 20),
                      "the server answered isElevated=false to the probe, so the lock control must read 'Unlock' "
                      + "— it reads '\(lockButton().label)'")
        shot("ds11-after-bulk-revoke")

        // MARK: Unlock — the server keeps the last word

        XCTAssertTrue(lockButton().waitForExistence(timeout: 10), "the lock control vanished")
        lockButton().tap()
        let pinField = element("deviceSessionsUnlockField")
        let alertField = app.alerts.firstMatch.textFields.firstMatch
        let field = pinField.waitForExistence(timeout: 10) ? pinField : alertField
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the lock control raised no PIN alert — labels: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("ds12-unlock-alert")
        enterPIN(pin, in: field)
        let confirmUnlock = app.alerts.firstMatch.buttons
            .matching(identifier: "deviceSessionsUnlockConfirm").firstMatch
        XCTAssertTrue(confirmUnlock.waitForExistence(timeout: 10),
                      "the unlock alert has no confirmation — labels: "
                      + "\(app.alerts.firstMatch.buttons.allElementsBoundByIndex.map(\.label))")
        confirmUnlock.tap()

        let unlocked = waitForRequests("GET", "/api/auth/status", count: 3)
        guard let unlockIndex = index(of: "POST", "/api/auth/session/unlock", in: unlocked) else {
            shot("ds13b-no-unlock-call")
            XCTFail("the confirmation sent no POST /api/auth/session/unlock — got:\n\(describe(unlocked))")
            return
        }
        // The unlock SUCCEEDED on the wire: the stub echoes the PIN it decoded
        // and 401s anything else, so 'accepted' is the server's own word.
        XCTAssertEqual(unlocked[unlockIndex].fields["accepted"], "yes",
                       "the stub refused the unlock — got:\n\(describe(Array(unlocked.dropFirst(unlockIndex))))")
        XCTAssertEqual(unlocked[unlockIndex].fields["pinCode"], pin,
                       "the PIN that left the app is not the account's — got:\n\(describe(Array(unlocked.dropFirst(unlockIndex))))")
        let unlockProbes = unlocked.enumerated().filter {
            $0.element.method == "GET" && $0.element.path == "/api/auth/status"
        }
        guard let unlockProbe = unlockProbes.last else {
            XCTFail("a successful unlock was not followed by the elevation probe — got:\n\(describe(unlocked))")
            return
        }
        XCTAssertLessThan(unlockIndex, unlockProbe.offset,
                          "the elevation was not re-read after the unlock:\n\(describe(unlocked))")
        XCTAssertEqual(unlockProbes.count, 3, "three mutations, three probes — got:\n\(describe(unlocked))")

        // And the screen does NOT claim what the mutation looked like it did:
        // the server answered `isElevated: false`, so the control stays on
        // "Unlock" — the value it must read from that answer and not from the 204.
        XCTAssertTrue(waitForLockLabel(notElevated, timeout: 15),
                      "the unlock was accepted but the server still denies the elevation: the screen must not "
                      + "claim it — the control reads '\(lockButton().label)'")
        // …and the value it holds is a CONFIRMED one: a probe that failed would
        // leave `Unknown` on the control, which would make the line above pass
        // for the wrong reason.
        let held = (lockButton().value as? String) ?? ""
        XCTAssertFalse(staleElevation.contains(held),
                       "the elevation control is marked '\(held)': the probe did not read an answer, so the "
                       + "unlock's outcome was never confirmed")
        shot("ds13-after-unlock")
    }
}
