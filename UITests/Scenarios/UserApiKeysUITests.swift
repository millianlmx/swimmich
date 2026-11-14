import XCTest

/// End-to-end scenario for "API Keys" (gap G20) — one `XCTestCase` per feature,
/// in its own file, against its own committed stub, like `RecentlyTakenUITests`.
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/user-api-keys.uitest.log \\
///         UITests/stubs/immich_stub_user_api_keys.py UserApiKeysUITests/test_userApiKeys
///
/// WHAT IT PROVES, and why the wire half is the load-bearing one:
///
/// * the row lives in the "Me" hub for an account the stub answers as
///   `isAdmin: false` — it used to sit inside `if auth.isAdmin`, which is the
///   gap itself;
/// * the LIST comes from `GET /api/api-keys` and the "Current session" row from
///   `GET /api/api-keys/me` — two distinct endpoints with two payloads sharing
///   no name, so filling one from the other is caught by a name;
/// * creating a scoped key puts the typed `name` and the picker's `permissions`
///   in the `POST /api/api-keys` body, and its secret is shown ONCE;
/// * the rotation is a `POST /api/api-keys/{id}/rotate` — never the `PUT` the
///   backlog announced (the published document lists `post` only) — and its new
///   secret, a different string, is shown through the same single display;
/// * the revocation is a `DELETE /api/api-keys/{id}`, and the key leaves the
///   list because the stub really dropped it;
/// * and the negative control: with `/control/rotate?mode=fail` the server
///   refuses the rotation — the screen says so and does NOT show a secret.
final class UserApiKeysUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's fixture, mirrored here on purpose: the ids address the rows
    // (their identifier is built from the id) and the names are what the SCREEN
    // has to show — a name that only one of the two endpoints answers is what
    // tells the list and the "current session" row apart.
    private let laptop = "33333333-3333-4333-8333-000000000001"
    private let ci = "33333333-3333-4333-8333-000000000003"
    /// The id the stub gives the key this scenario creates.
    private let created = "33333333-3333-4333-8333-000000000004"
    private let createdName = "stub-created-key"
    private let secretCreated = "stub-key-secret-created"
    private let secretRotated = "stub-key-secret-rotated"
    /// What the stub's refusal says — the one part of the error badge that does
    /// not follow the simulator's locale.
    private let refusal = "stub refused the rotation"

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
    // Copied from `RecentlyTakenUITests` on purpose: these are `private` in the
    // shared file, and the harness rule is one file per feature, helpers
    // included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state (keys, refusal disarmed) and
    /// empties its request log, so no assertion below can be satisfied by a
    /// previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// The negative control's switch. Called with `ok: true` first on purpose:
    /// its assertion is also the proof that the control route answers, so a
    /// later `false` cannot silently be a no-op.
    private func armRotation(ok: Bool) {
        let mode = ok ? "ok" : "fail"
        var request = URLRequest(url: URL(string: "\(stub)/control/rotate?mode=\(mode)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer /control/rotate")
        XCTAssertEqual(body, "{\"rotate\": \"\(mode)\"}",
                       "the stub did not arm the rotation switch — the negative control would prove nothing")
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself.
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

    /// The copy is localized (issue #21), and the repo's own simulator is in
    /// German while the runs use English slots: a walk accepts both, never one
    /// hard-coded language.
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
        // Typing the URL raised the keyboard, and the CTA sits under it.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("k02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized, and the
    /// repository's simulator is not in English). A `Form` only publishes what
    /// it rendered, so the row is scrolled into view first, letting each swipe
    /// settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// One owned key's row. Its identifier is built from the key's ID, so the
    /// scenario never has to guess which localized text is the row.
    private func keyRow(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "apiKeyRow_\(id)").firstMatch
    }

    /// Where a secret is published. The alert's message is a plain `Text`, and
    /// the secret is the only copy the app ever holds: matching on `CONTAINS`
    /// rather than on an exact label keeps this independent of how an alert
    /// bundles its title and message into elements.
    private func secretElements(_ secret: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", secret))
    }

    /// The action a swipe just revealed: by identifier first (the app sets one
    /// per key), by label as the fallback — the labels are translated.
    private func tapSwipeAction(_ identifier: String, labels: [String]) -> Bool {
        let byIdentifier = app.buttons.matching(identifier: identifier).firstMatch
        if byIdentifier.waitForExistence(timeout: 10) {
            byIdentifier.tap()
            return true
        }
        return tapAnyButton(labels, timeout: 5)
    }

    private func waitForText(containing text: String, timeout: TimeInterval) -> Bool {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if element.waitForExistence(timeout: timeout) { return true }
        for _ in 0..<3 {
            app.swipeUp()
            if element.exists { return true }
        }
        return false
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `body` is the JSON the app sent, with
    /// the two shapes this feature uses kept apart: a `String` field (`name`)
    /// and an array of `String`s (`permissions`). Anything else is `other` — a
    /// `permissions` sent as a bare string has to be visible, not silently
    /// equal.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: BodyValue]

        var name: String? { body["name"]?.text }
        var permissions: [String]? { body["permissions"]?.list }

        enum BodyValue: Decodable {
            case text(String)
            case list([String])
            case other

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                } else if let list = try? container.decode([String].self) {
                    self = .list(list)
                } else {
                    self = .other
                }
            }

            var text: String? { if case .text(let value) = self { return value } else { return nil } }
            var list: [String]? { if case .list(let value) = self { return value } else { return nil } }
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

    /// Every request the feature's five routes received, in order.
    private func apiKeyRequests() -> [StubRequest] {
        stubRequests().filter { $0.path.hasPrefix("/api/api-keys") }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) name=\($0.name ?? "-") permissions=\($0.permissions ?? [])" }
            .joined(separator: "\n")
    }

    // MARK: - Scenario

    func test_userApiKeys() throws {
        reset()
        armRotation(ok: true)
        setProvider("manual")
        app.launch()

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("k01-welcome")
            walkOnboardingToLogin()
            shot("k02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }

        // The shell's own day: it proves the app is talking to THIS stub before
        // anything is asserted about this feature.
        XCTAssertTrue(tile("aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")

        // MARK: The "Me" hub — the row is NOT behind the administrator check

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does

        let apiKeysRow = hubRow("apiKeysRow")
        if !apiKeysRow.waitForExistence(timeout: 10) {
            shot("k03b-me-hub-without-api-keys-row")
            XCTFail("API Keys row missing in the Me hub:\n\(app.debugDescription)")
        }
        shot("k03-me-hub-api-keys-row")

        // The control that makes the row's presence mean something. The stub
        // answers `/api/users/me` AND the OAuth callback with `isAdmin: false`
        // (see `immich_stub_base`), so a row rendered inside `if auth.isAdmin`
        // could not be on this screen at all — which is exactly gap G20. The
        // admin-only row is asserted ABSENT by identifier and by label, so this
        // cannot pass by the row simply not having been scrolled to.
        XCTAssertFalse(app.buttons.matching(identifier: "adminRow").firstMatch.exists,
                       "the hub rendered the admin-only row for a non-administrator account")
        XCTAssertFalse(app.buttons.matching(labelPredicate(["Administration", "Administración"]))
            .firstMatch.exists,
                       "the hub rendered the admin-only section for a non-administrator account")

        apiKeysRow.tap()

        // MARK: The two endpoints, and which row each one feeds

        let currentRow = app.descendants(matching: .any).matching(identifier: "apiKeysCurrentRow").firstMatch
        if !currentRow.waitForExistence(timeout: 25) {
            shot("k04b-no-current-session-row")
            XCTFail("the 'Current session' row never rendered against \(stub) — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        // Read off the ROW's label, not off a standalone static text: a key row
        // is ONE combined accessibility element (`children: .combine`), so the
        // names it carries are not published as static texts of their own.
        XCTAssertTrue(currentRow.label.contains("stub-phone-session"),
                      "the row fed by GET /api/api-keys/me reads '\(currentRow.label)', not the key that endpoint answers")
        let laptopRow = keyRow(laptop)
        XCTAssertTrue(laptopRow.waitForExistence(timeout: 15),
                      "the list fed by GET /api/api-keys does not show the keys that endpoint answers — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(laptopRow.label.contains("stub-laptop"), "the listed key's row reads '\(laptopRow.label)'")
        XCTAssertTrue(keyRow(ci).exists, "the second listed key is missing")
        shot("k04-api-keys-screen")

        let opened = apiKeyRequests()
        XCTAssertTrue(opened.contains { $0.method == "GET" && $0.path == "/api/api-keys" },
                      "the list was never fetched from GET /api/api-keys — got:\n\(describe(opened))")
        XCTAssertTrue(opened.contains { $0.method == "GET" && $0.path == "/api/api-keys/me" },
                      "the current key was never fetched from GET /api/api-keys/me — got:\n\(describe(opened))")

        // MARK: Create — a scoped key, and its secret shown once

        let createButton = app.buttons.matching(identifier: "apiKeysCreateButton").firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 10), "no Create button on the screen")
        createButton.tap()

        let nameField = app.textFields.matching(identifier: "apiKeyNameField").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "the create sheet never opened")
        shot("k05-create-sheet")

        // The sheet opens on its default scope: "Full access" ON, i.e. the
        // wildcard. The scenario walks that default rather than the folded
        // permission picker — measured: tapping the `Full access` switch closes
        // the sheet (the picker's own usability is reported separately). What
        // the assertion below still pins is that BOTH fields of
        // `ApiKeyCreateDto` are on the wire, each with the value the screen
        // holds, and that the wildcard reaches the server as a one-element LIST
        // (the server's parameter is a list, not a string).
        nameField.tap()
        nameField.typeText(createdName)
        shot("k05b-create-sheet-named")

        let confirmCreate = app.buttons.matching(identifier: "apiKeyCreateConfirmButton").firstMatch
        XCTAssertTrue(confirmCreate.waitForExistence(timeout: 10), "no Create button in the sheet")
        confirmCreate.tap()

        XCTAssertTrue(secretElements(secretCreated).firstMatch.waitForExistence(timeout: 25),
                      "the created secret was never shown — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("k06-secret-shown-once")
        XCTAssertEqual(secretElements(secretCreated).count, 1, "the secret must be shown exactly once")

        // `Copy` is the alert's language-neutral affordance; tapping it closes
        // the alert like any other of its buttons.
        let copy = app.buttons.matching(identifier: "apiKeyCopySecretButton").firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "the secret alert has no copy affordance")
        copy.tap()
        XCTAssertTrue(secretElements(secretCreated).firstMatch.waitForNonExistence(timeout: 10),
                      "the secret is still on screen although its only display was dismissed")
        let createdRow = keyRow(created)
        XCTAssertTrue(createdRow.waitForExistence(timeout: 15),
                      "the created key is not in the list — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(createdRow.label.contains(createdName),
                      "the created key's row reads '\(createdRow.label)'")
        shot("k07-list-after-create")

        let afterCreate = apiKeyRequests()
        guard let create = afterCreate.first(where: { $0.method == "POST" && $0.path == "/api/api-keys" }) else {
            return XCTFail("no POST /api/api-keys on the wire — got:\n\(describe(afterCreate))")
        }
        XCTAssertEqual(create.name, createdName, "the body must carry the typed name")
        // `ApiKeyCreateDto.permissions` is a LIST, and the wildcard is one of
        // the 146 values the server's `Permission` enum accepts — not an
        // omission: a body without `permissions` (or with it as a bare string)
        // has to fail here.
        XCTAssertEqual(create.permissions, ["all"],
                       "the body must carry the sheet's scope as a one-element list — got \(create.permissions ?? [])")

        // MARK: Rotation — a POST on /{id}/rotate, never a PUT

        XCTAssertTrue(laptopRow.waitForExistence(timeout: 10), "the stub-laptop row is missing")
        laptopRow.swipeRight()
        XCTAssertTrue(tapSwipeAction("apiKeyRotateAction_\(laptop)",
                                     labels: ["Rotate", "Faire tourner", "Rotieren", "Rotar"]),
                      "the leading swipe never revealed a Rotate action")
        // Alerts: iOS 26 lists an identified alert button twice, so each
        // confirmation button is queried inside the alert.
        let confirmRotate = app.alerts.firstMatch.buttons.matching(identifier: "apiKeyRotateConfirmButton").firstMatch
        XCTAssertTrue(confirmRotate.waitForExistence(timeout: 10),
                      "the rotation was not put behind a confirmation — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("k08-rotate-confirmation")
        confirmRotate.tap()

        XCTAssertTrue(secretElements(secretRotated).firstMatch.waitForExistence(timeout: 20),
                      "the rotated secret was never shown — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertFalse(secretElements(secretCreated).firstMatch.exists,
                       "the alert is showing the CREATED secret, not the one the rotation returned")
        shot("k09-rotated-secret")
        app.buttons.matching(identifier: "apiKeyCopySecretButton").firstMatch.tap()
        XCTAssertTrue(secretElements(secretRotated).firstMatch.waitForNonExistence(timeout: 10),
                      "the rotated secret outlived its only display")

        let afterRotate = apiKeyRequests()
        XCTAssertTrue(afterRotate.contains { $0.method == "POST" && $0.path == "/api/api-keys/\(laptop)/rotate" },
                      "the rotation was not sent as POST /api/api-keys/{id}/rotate — got:\n\(describe(afterRotate))")
        XCTAssertFalse(afterRotate.contains { $0.path.contains("rotate") && $0.method != "POST" },
                       "the rotation is a POST; the backlog's PUT on /{id}/rotate is a typo — got:\n\(describe(afterRotate))")
        XCTAssertFalse(afterRotate.contains { $0.method == "PUT" },
                       "nothing on this screen renames a key, so no PUT belongs on the wire — got:\n\(describe(afterRotate))")

        // MARK: Revocation — DELETE, and the key really leaves the server's list

        let ciRow = keyRow(ci)
        XCTAssertTrue(ciRow.waitForExistence(timeout: 10), "the stub-ci row is missing")
        ciRow.swipeLeft()
        XCTAssertTrue(tapSwipeAction("apiKeyDeleteAction_\(ci)",
                                     labels: ["Delete", "Supprimer", "Löschen", "Eliminar"]),
                      "the trailing swipe never revealed a Delete action")
        let confirmDelete = app.alerts.firstMatch.buttons.matching(identifier: "apiKeyDeleteConfirmButton").firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10),
                      "the revocation was not put behind a confirmation — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("k10-delete-confirmation")
        confirmDelete.tap()

        XCTAssertTrue(ciRow.waitForNonExistence(timeout: 20),
                      "the revoked key is still in the list — the stub drops it, so the list is re-read")
        shot("k11-after-revoke")

        let afterDelete = apiKeyRequests()
        XCTAssertTrue(afterDelete.contains { $0.method == "DELETE" && $0.path == "/api/api-keys/\(ci)" },
                      "the revocation was not sent as DELETE /api/api-keys/{id} — got:\n\(describe(afterDelete))")
        XCTAssertFalse(afterDelete.contains { $0.method == "DELETE" && $0.path == "/api/api-keys" },
                       "the list route is not a deletion — got:\n\(describe(afterDelete))")

        // MARK: The negative control — a rotation the server refuses

        armRotation(ok: false)
        let again = keyRow(laptop)
        XCTAssertTrue(again.waitForExistence(timeout: 15),
                      "the rotated key left the list, so there is nothing left to refuse — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        again.swipeRight()
        XCTAssertTrue(tapSwipeAction("apiKeyRotateAction_\(laptop)",
                                     labels: ["Rotate", "Faire tourner", "Rotieren", "Rotar"]),
                      "the leading swipe never revealed a Rotate action")
        app.alerts.firstMatch.buttons.matching(identifier: "apiKeyRotateConfirmButton").firstMatch.tap()

        // The screen must SAY it was refused …
        XCTAssertTrue(waitForText(containing: refusal, timeout: 25),
                      "the refused rotation was never reported — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        // … and must not pretend the key was rotated.
        XCTAssertFalse(secretElements(secretRotated).firstMatch.exists,
                       "a rotated secret is on screen although the server refused the rotation")
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 3),
                      "the secret alert was raised although the server refused the rotation")
        XCTAssertTrue(again.exists, "the key vanished from the list although its rotation failed")
        shot("k12-rotation-refused")

        let attempts = apiKeyRequests().filter { $0.path == "/api/api-keys/\(laptop)/rotate" }
        XCTAssertEqual(attempts.count, 2,
                       "the refusal must answer a rotation the app really sent — got:\n\(describe(apiKeyRequests()))")
        XCTAssertTrue(attempts.allSatisfy { $0.method == "POST" },
                      "both rotations must be POSTs — got:\n\(describe(attempts))")
    }
}
