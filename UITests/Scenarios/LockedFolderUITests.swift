import XCTest

/// End-to-end scenario for the locked folder (gap G12).
///
/// The whole feature rests on one claim: the PIN is the **server's** elevation,
/// not a decoration on a screen. `GET /api/auth/status.isElevated` decides which
/// of the three doors the user stands in front of, `POST /api/auth/session/unlock`
/// is the only thing that opens the grid, and `POST /api/auth/session/lock`
/// closes it again. Every step below therefore asserts the wire as much as the
/// screen — a folder that opened without those calls, or that kept showing tiles
/// after the server dropped the elevation, is a bug that a happy screenshot
/// cannot see.
///
/// The stub (`immich_stub_locked_folder.py`) is where that lives: it owns the
/// PIN, the elevation, and a locked day (`dddd…`, 2025-03-03) the ordinary
/// timeline never shows — so a grid that rendered those tiles can only have read
/// `visibility=locked`.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself), and
/// with `--erase`: the scenario asserts a FIRST launch (no PIN, no elevation, no
/// session in the slot's Keychain), and the device is shared between runs:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/locked-folder.uitest.log \
///         UITests/stubs/immich_stub_locked_folder.py LockedFolderUITests/test_lockedFolder --erase
final class LockedFolderUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The PIN the scenario creates, one the server must refuse, and the day the
    /// stub reserves for the locked filter.
    private let pin = "123456"
    private let wrongPin = "999999"
    private let lockedDay = "2025-03-03"
    private let lockedAsset = "dddddddd-1111-4111-8111-000000000001"

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
    // there, and the shared file is frozen (11 committed scenarios are green
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

    /// Puts the stub back to its initial state (no PIN, no elevation) and
    /// empties its request log, so no assertion below can be satisfied by a
    /// previous run.
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
            shot("lf02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: \(screenText())")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// Any element carrying an identifier — the doors' controls are buttons and
    /// secure fields, but a badge is neither, and the identifier is what tells
    /// them apart across five languages.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// What is on screen, for a failure message that can be acted on.
    private func screenText() -> String {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }
        return Array(labels.prefix(24)).joined(separator: " | ")
    }

    // MARK: - The three doors

    /// Which door the folder is showing, read from its CONTROLS rather than from
    /// a heading: "Create a PIN" and "Unlock" exist in five languages, and the
    /// identifiers are the contract.
    private enum Door: String {
        case needsSetup = "create"
        case locked = "pin"
        case unlocked = "grid"
    }

    private func doorIdentifier(_ door: Door) -> String {
        switch door {
        case .needsSetup: return "lockedFolderCreatePINButton"
        case .locked: return "lockedFolderUnlockButton"
        case .unlocked: return "lockNowButton"
        }
    }

    /// The door the screen is standing in front of right now.
    private func currentDoor() -> Door? {
        for door in [Door.unlocked, .needsSetup, .locked] where element(doorIdentifier(door)).exists {
            return door
        }
        return nil
    }

    /// Waits for a door, then re-reads the tree: a screen showing two doors at
    /// once (the grid *and* a PIN field) is a bug this must not let through.
    private func waitForDoor(_ door: Door, timeout: TimeInterval) -> Bool {
        guard element(doorIdentifier(door)).waitForExistence(timeout: timeout) else { return false }
        return currentDoor() == door
    }

    // MARK: - Navigating in and out of the folder

    /// The Albums tab → its Library section → Locked Folder. The tile is matched
    /// by IDENTIFIER, never by its localized label; it is a plain button, closed
    /// or not.
    private func openLockedFolder() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "Albums tab missing")
        albums.tap()
        let row = libraryRow("lockedFolderRow")
        if !row.waitForExistence(timeout: 10) {
            shot("lf05b-albums-without-locked-row")
            XCTFail("Locked Folder tile missing in the Albums library:\n\(app.debugDescription)")
        }
        row.tap()
    }

    /// A tile of the Albums tab's Library section, by IDENTIFIER (its label is
    /// localized). The Albums ScrollView is scrolled only when the tile is not
    /// hittable.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        _ = row.waitForExistence(timeout: 10)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// The leading button of the frontmost navigation bar — the pushed screen's
    /// back chevron. Found by geometry rather than by label: the previous
    /// screen's title is localized ("Me" / "Ich" / "Moi"), and a sheet may carry
    /// a trailing button that `firstMatch` could hand back instead.
    @discardableResult
    private func goBack() -> Bool {
        let bars = app.navigationBars
        for index in stride(from: bars.count - 1, through: 0, by: -1) {
            let button = bars.element(boundBy: index).buttons.element(boundBy: 0)
            if button.exists, button.isHittable, button.frame.minX < app.frame.width / 2 {
                button.tap()
                return true
            }
        }
        return false
    }

    /// The only way to make the screen ask the server again: `.task { await
    /// vm.refreshGate() }` runs when the view is pushed. If the app trusted a
    /// local "already unlocked" flag, the grid would still be there afterwards —
    /// which is exactly what the elevation-expiry step below refuses to accept.
    private func leaveAndReopenFolder() {
        XCTAssertTrue(goBack(), "no back button on the locked folder's navigation bar")
        let row = libraryRow("lockedFolderRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "the Locked Folder tile is gone from the Albums library: \(screenText())")
        row.tap()
    }

    // MARK: - Typing a PIN

    /// The bullets a `SecureField` answers as its `value` (empty when the field
    /// holds nothing — the placeholder is not bullets, so it cannot be confused
    /// with six typed digits).
    private func typedDigits(_ field: XCUIElement) -> Int {
        ((field.value as? String) ?? "").filter { $0 == "•" }.count
    }

    /// Replaces a PIN field's content. The existing characters are removed one
    /// by one: select-all + delete is flaky on a `SecureField` (measured by the
    /// shared harness on the shared-link password field).
    private func typePIN(_ text: String, into fieldID: String) {
        let field = app.secureTextFields[fieldID]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "PIN field \(fieldID) missing: \(screenText())")
        field.tap()
        let existing = typedDigits(field)
        if existing > 0 {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing))
        }
        field.typeText(text)
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `submittedPIN`, `contentType` and
    /// `contentLength` are what the stub's own routes noted about the request
    /// (`req.note(...)`) — the raw body is not decoded here on purpose: half the
    /// routes of this app send arrays and booleans, and one such entry would
    /// make the whole log undecodable.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let submittedPIN: String?
        let contentType: String?
        let contentLength: String?
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
        do {
            return try JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))
        } catch {
            // Never `?? []`: an undecodable log would silently satisfy every
            // "nothing was sent" assertion below.
            XCTFail("could not decode /__requests (\(error)) — head: \(body.prefix(300))")
            return []
        }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) params=\($0.params) pin=\($0.submittedPIN ?? "-") "
                + "ctype=\($0.contentType ?? "-") clen=\($0.contentLength ?? "-")"
        }.joined(separator: "\n")
    }

    /// A read of the folder itself: the two bucket routes, scoped to the locked
    /// filter. The point of the feature is that these exist only while elevated.
    private func isLockedRead(_ request: StubRequest) -> Bool {
        (request.path == "/api/timeline/buckets" || request.path == "/api/timeline/bucket")
            && request.params["visibility"] == "locked"
    }

    private func createPinCalls(_ requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/auth/pin-code" }
    }

    private func unlockCalls(_ requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/auth/session/unlock" }
    }

    private func lockCalls(_ requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/auth/session/lock" }
    }

    private func statusReads(_ requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "GET" && $0.path == "/api/auth/status" }
    }

    /// Plays the other client: the scenario itself drops the session's elevation
    /// server-side — the 15-minute TTL, or a lock from another device. The app
    /// is told nothing; its screen still shows the grid. The `reason` is what
    /// tells this call apart from the app's own (bodyless) one in the log.
    private func expireElevationElsewhere() {
        var request = URLRequest(url: URL(string: "\(stub)/api/auth/session/lock")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"reason":"expired-elsewhere"}"#.utf8)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var code = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer the lock")
        XCTAssertEqual(code, 204, "the stub refused the other client's lock")
    }

    // MARK: - Scenario

    func test_lockedFolder() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("lf01-welcome")
            walkOnboardingToLogin()
            shot("lf02-login-sso")
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
            shot("lf03-whats-new")
            whatsNewDone.tap()
        }

        // The ordinary timeline proves the app is talking to THIS stub before the
        // folder is opened: a session left over from another slot's port would
        // draw an empty grid.
        XCTAssertTrue(tile("aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); screen reads: \(screenText())")
        shot("lf04-timeline")

        // MARK: Door 1 — the server has no PIN for this account

        openLockedFolder()
        XCTAssertTrue(waitForDoor(.needsSetup, timeout: 25),
                      "a session with no PIN and no elevation must be asked to CREATE one — the screen is "
                        + "at the \(currentDoor()?.rawValue ?? "unknown") door. Screen: \(screenText())")
        XCTAssertTrue(app.secureTextFields["lockedFolderConfirmPINField"].exists,
                      "the create door must ask for the PIN twice")
        shot("lf06-create-door")

        let atCreateDoor = stubRequests()
        XCTAssertFalse(statusReads(atCreateDoor).isEmpty,
                       "the door must be the SERVER's verdict (GET /api/auth/status), not a local one — "
                        + "got:\n\(describe(atCreateDoor))")
        XCTAssertTrue(atCreateDoor.filter(isLockedRead).isEmpty,
                      "the locked folder must not be read before the session is elevated — got:\n"
                        + describe(atCreateDoor.filter(isLockedRead)))

        // MARK: The creation guards, and the PIN the server is given

        let createButton = element("lockedFolderCreatePINButton")
        XCTAssertTrue(createButton.waitForExistence(timeout: 10), "no create button on the first door")
        typePIN(pin, into: "lockedFolderPINField")
        typePIN("12345", into: "lockedFolderConfirmPINField")
        shot("lf07-mismatch-guard")
        XCTAssertFalse(createButton.isEnabled,
                       "six digits against a five-digit confirmation must not be submittable")
        XCTAssertTrue(createPinCalls(stubRequests()).isEmpty,
                      "the app sent a PIN the local guard had already refused")

        typePIN(pin, into: "lockedFolderConfirmPINField")
        XCTAssertTrue(createButton.isEnabled,
                      "the create button must enable once both fields hold the same six digits — "
                        + "fields read \((app.secureTextFields["lockedFolderPINField"].value as? String) ?? "nil") / "
                        + "\((app.secureTextFields["lockedFolderConfirmPINField"].value as? String) ?? "nil")")
        createButton.tap()

        XCTAssertTrue(waitForDoor(.unlocked, timeout: 30),
                      "a created PIN must open the folder — the screen is at the "
                        + "\(currentDoor()?.rawValue ?? "unknown") door. Wire:\n\(describe(stubRequests()))")

        // MARK: What opened it, on the wire

        let afterUnlock = stubRequests()
        let lockedReads = afterUnlock.filter(isLockedRead)
        XCTAssertEqual(createPinCalls(afterUnlock).count, 1,
                       "exactly one PIN creation — got:\n\(describe(createPinCalls(afterUnlock)))")
        XCTAssertEqual(createPinCalls(afterUnlock).last?.submittedPIN, pin,
                       "the PIN the user typed is not the one the server was given — got:\n"
                        + describe(createPinCalls(afterUnlock)))
        XCTAssertEqual(unlockCalls(afterUnlock).last?.submittedPIN, pin,
                       "the elevation must be requested with the PIN just created — got:\n"
                        + describe(unlockCalls(afterUnlock)))
        XCTAssertFalse(lockedReads.isEmpty,
                       "the grid's tiles can only have come from visibility=locked reads — got:\n"
                        + describe(afterUnlock))
        XCTAssertTrue(lockedReads.contains { $0.path == "/api/timeline/buckets" },
                      "the folder's bucket list must carry the locked filter — got:\n\(describe(lockedReads))")
        XCTAssertEqual(lockedReads.last(where: { $0.path == "/api/timeline/bucket" })?.params["timeBucket"],
                       lockedDay,
                       "the day the stub announced for the locked filter is not the one that was read — got:\n"
                        + describe(lockedReads))
        guard let createIndex = afterUnlock.firstIndex(where: { $0.path == "/api/auth/pin-code" }),
              let unlockIndex = afterUnlock.firstIndex(where: { $0.path == "/api/auth/session/unlock" }),
              let readIndex = afterUnlock.firstIndex(where: isLockedRead) else {
            return XCTFail("the create → unlock → read sequence is incomplete — got:\n\(describe(afterUnlock))")
        }
        XCTAssertLessThan(createIndex, unlockIndex, "the PIN must exist before the session is elevated with it")
        XCTAssertLessThan(unlockIndex, readIndex, "the folder may only be read AFTER the elevation")

        // The grid itself: the locked day's tiles, and the banner that says the
        // folder is open.
        XCTAssertTrue(tile(lockedAsset).waitForExistence(timeout: 20),
                      "the locked day the stub served (\(lockedDay)) is not in the grid — screen reads: \(screenText())")
        XCTAssertTrue(element("lockedFolderStatusBadge").exists,
                      "the open folder must say so — screen: \(screenText())")
        shot("lf08-unlocked")

        // MARK: The elevation is the server's — drop it behind the app's back

        let beforeRevoke = stubRequests()
        expireElevationElsewhere()
        XCTAssertTrue(element("lockNowButton").exists,
                      "a server-side expiry must not repaint the screen by itself (the app has not asked yet)")
        leaveAndReopenFolder()
        XCTAssertTrue(waitForDoor(.locked, timeout: 25),
                      "the elevation was dropped server-side, so re-entering the folder must ask for the PIN — "
                        + "the screen is at the \(currentDoor()?.rawValue ?? "unknown") door. Screen: \(screenText())")
        XCTAssertFalse(tile(lockedAsset).exists, "the locked tiles must not survive an expired elevation")
        let afterReopen = Array(stubRequests().dropFirst(beforeRevoke.count))
        XCTAssertFalse(statusReads(afterReopen).isEmpty,
                       "re-entering the folder must re-ask the server rather than trust a local flag — got:\n"
                        + describe(afterReopen))
        XCTAssertTrue(afterReopen.filter(isLockedRead).isEmpty,
                      "an unelevated session must not read the folder — got:\n\(describe(afterReopen))")
        shot("lf09-expired-elevation")

        // MARK: A refused PIN neither opens the door nor reads anything

        let beforeRefusal = stubRequests()
        typePIN(wrongPin, into: "lockedFolderPINField")
        element("lockedFolderUnlockButton").tap()
        XCTAssertTrue(waitForStaticText(["Wrong PIN", "Code PIN incorrect", "Falscher PIN", "PIN incorrecto",
                                         "PIN errato"], timeout: 20)
                        || element("lockedFolderErrorText").waitForExistence(timeout: 2),
                      "a refused PIN must be reported on the screen — screen: \(screenText())")
        XCTAssertTrue(waitForDoor(.locked, timeout: 10),
                      "a refused PIN must not change the door — the screen is at the "
                        + "\(currentDoor()?.rawValue ?? "unknown") door")
        XCTAssertFalse(element("lockNowButton").exists, "a refused PIN must not open the folder")
        shot("lf10-refused-pin")

        let refusalWindow = Array(stubRequests().dropFirst(beforeRefusal.count))
        XCTAssertEqual(unlockCalls(refusalWindow).count, 1,
                       "one unlock attempt, not a burst — got:\n\(describe(refusalWindow))")
        XCTAssertEqual(unlockCalls(refusalWindow).last?.submittedPIN, wrongPin,
                       "the refusal must have been asked for with the refused PIN")
        XCTAssertTrue(refusalWindow.filter(isLockedRead).isEmpty,
                      "a refused PIN must not read the folder — got:\n\(describe(refusalWindow))")

        // MARK: The right PIN opens it again

        typePIN(pin, into: "lockedFolderPINField")
        element("lockedFolderUnlockButton").tap()
        XCTAssertTrue(waitForDoor(.unlocked, timeout: 30),
                      "the right PIN must open the folder — the screen is at the "
                        + "\(currentDoor()?.rawValue ?? "unknown") door. Wire:\n\(describe(stubRequests()))")
        XCTAssertTrue(tile(lockedAsset).waitForExistence(timeout: 20),
                      "the folder came back without its tiles — screen reads: \(screenText())")
        shot("lf11-unlocked-again")

        let afterSecondUnlock = stubRequests()
        XCTAssertEqual(unlockCalls(afterSecondUnlock).map { $0.submittedPIN ?? "-" }, [pin, wrongPin, pin],
                       "the three attempts, in order: create, refused, accepted — got:\n"
                        + describe(unlockCalls(afterSecondUnlock)))
        XCTAssertGreaterThan(afterSecondUnlock.filter(isLockedRead).count, lockedReads.count,
                             "the second elevation must have re-read the folder — got:\n"
                                + describe(afterSecondUnlock.filter(isLockedRead)))

        // MARK: "Lock now" masks the folder at once — and says so on the wire

        let beforeLock = stubRequests()
        element("lockNowButton").tap()
        XCTAssertTrue(waitForDoor(.locked, timeout: 5),
                      "« Lock now » must mask the folder immediately — the screen is at the "
                        + "\(currentDoor()?.rawValue ?? "unknown") door")
        XCTAssertFalse(tile(lockedAsset).exists, "the locked tiles must be gone the moment the folder is locked")
        shot("lf12-locked-now")

        let lockWindow = Array(stubRequests().dropFirst(beforeLock.count))
        let appLocks = lockCalls(lockWindow)
        XCTAssertEqual(appLocks.count, 1, "one POST /api/auth/session/lock — got:\n\(describe(lockWindow))")
        XCTAssertNil(appLocks.last?.contentType,
                     "the lock route takes no body, so the app must not send a JSON one — content-type was "
                        + "\(appLocks.last?.contentType ?? "nil")")
        let length = appLocks.last?.contentLength
        XCTAssertTrue(length == nil || length == "0",
                      "a bodyless lock request carries no payload — content-length was \(length ?? "nil")")

        // MARK: …and the server really lost the elevation, not just the screen

        leaveAndReopenFolder()
        XCTAssertTrue(waitForDoor(.locked, timeout: 25),
                      "the folder reopened unlocked after « Lock now » — the lock did not drop the server's "
                        + "elevation. The screen is at the \(currentDoor()?.rawValue ?? "unknown") door")
        shot("lf13-still-locked-after-reentry")

        let final = stubRequests()
        XCTAssertEqual(lockCalls(final).filter { $0.contentType != nil }.count, 1,
                       "only this scenario's own lock may carry a JSON body (it is what tells the two "
                        + "calls apart) — got:\n\(describe(lockCalls(final)))")
        XCTAssertTrue(lockCalls(final).contains { $0.contentType == nil },
                      "the app's own bodyless lock is missing from the log — got:\n\(describe(lockCalls(final)))")
        XCTAssertEqual(createPinCalls(final).count, 1, "the PIN was created once and never re-created")
    }
}
