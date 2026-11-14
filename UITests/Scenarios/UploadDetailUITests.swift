import XCTest

/// End-to-end scenario for "Upload details" (gap G5) — the per-asset report of
/// the last backup run: what failed, with its size and a Retry that names that
/// one asset.
///
/// It drives the real app: onboarding → SSO → the "Me" hub → Backup → "Run now"
/// → a run the stub makes fail on ONE asset → "Upload details" → Retry. And it
/// asserts on the WIRE what each action asked for, which is the point of the
/// feature: the card's claim is not just "the screen lists an asset", it is
/// "retrying one asset launches ONE asset" — a screen that showed the right row
/// while re-scanning the whole library would look perfect and be worthless.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself). The
/// photos come from `--media`: a backup run has nothing to upload without a
/// Photos library, and `--erase` is what makes "one photo failed, one was
/// uploaded" reproducible on a device three scenarios share.
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/upload-detail.uitest.log \
///         UITests/stubs/immich_stub_upload_detail.py UploadDetailUITests/test_uploadDetail \
///         --erase --media /tmp/media-a.png --media /tmp/media-b.png
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// timeline, real PNG thumbnails) and adds the two routes a run needs
/// (`bulk-upload-check`, the upload itself); it refuses exactly one identifier
/// and answers `accept`/`created` for the rest — see its docstring.
final class UploadDetailUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// Every permission alert this scenario saw, as `label|label|…` — the
    /// buttons it was offered, verbatim. A prompt whose labels this scenario
    /// does not know is a fact to report, never to guess at: answering the
    /// wrong button gives a `denied` (or add-only) grant and the run silently
    /// does nothing.
    private var promptsSeen: [String] = []

    /// The two identifiers the wire named, read off `/__requests` after the run
    /// — never assumed: Photos assigns the `localIdentifier`s, and the stub
    /// picks which one it refuses from the set it was asked about. Everything
    /// below (the failure row, the retry button) is addressed with them.
    private var failedAssetId = ""
    private var healthyAssetId = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // XCUITest's own interruption handler answers the Photos prompt with
        // "add only", which `ensurePhotoAccess()` reads as a refusal and the run
        // never starts. A monitor registered here runs BEFORE that default, and
        // only claims the alert when it really offers full access — an alert it
        // does not know is left to the default handler.
        addUIInterruptionMonitor(withDescription: "Photos access") { [weak self] alert in
            let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
            self?.promptsSeen.append(labels.joined(separator: "|"))
            let fullAccess = alert.buttons.matching(Self.labelsContain(Self.fullAccessLabels))
            if fullAccess.firstMatch.exists {
                fullAccess.firstMatch.tap()
                return true
            }
            let allow = alert.buttons.matching(Self.labelsContain(Self.allowLabels))
            guard allow.firstMatch.exists else { return false }
            allow.firstMatch.tap()
            return true
        }
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
    // they are `private` there, and the shared file is frozen. The harness rule
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
        Self.labelsContain(labels)
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

    /// The button that grants full library access, in every language this
    /// harness can meet: the slots follow the host's language (French), the
    /// repo's own simulator is German, and the phrasing changed across iOS
    /// versions ("…l'accès à toutes les photos" → "…l'accès complet").
    private static let fullAccessLabels = [
        "Allow Full Access", "Allow Access to All Photos",
        "Autoriser l'accès complet", "Autoriser l'accès à toutes",
        "Accès complet", "Vollständiger Zugriff", "Vollen Zugriff",
        "Erlauben", "Permitir el acceso completo", "Consenti l'accesso completo",
    ]

    /// A plain "yes" — the notification prompt's button. Deliberately NOT the
    /// add-only one: `Ajout uniquement` / "Add Only" answers a `.readWrite`
    /// request with an add-only grant, which is exactly the state this
    /// scenario must not end in.
    private static let allowLabels = ["Allow", "Autoriser", "Erlauben", "Permitir", "Consenti"]

    /// `label CONTAINS` over several labels, with the labels BOUND as arguments.
    ///
    /// A function, never an inline `NSPredicate(format:)`: the same string with
    /// `%@` placeholders and no `argumentArray` resolves them against garbage
    /// and kills the RUNNER process (measured — SIGBUS inside
    /// `ResolvePredicateArgument`, from the monitor's first version).
    private static func labelsContain(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    /// Answers the permission prompts the app raises when a run starts.
    ///
    /// Two can be up: Photos access (`UploadViewModel.ensurePhotoAccess`) and
    /// notifications. The Photos one is rendered INSIDE the app's own
    /// accessibility tree on iOS 26 — looking at SpringBoard alone finds
    /// nothing, and the run then stalls on a question nobody answers (measured:
    /// the screen ended up with no run and no error, `engine.phase` still
    /// `.idle`). So both trees are searched, and the loop keeps answering until
    /// no prompt has appeared for a few seconds.
    ///
    /// Full access is preferred over "select photos": the run must see the
    /// seeded library, and a limited selection is an empty one.
    @discardableResult
    private func answerPermissionPrompts(window: TimeInterval = 30) -> [String] {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(window)
        var quietSince = Date()
        var journal: [String] = []
        while Date() < deadline {
            var tapped = false
            for alerts in [app.alerts, springboard.alerts] {
                let alert = alerts.firstMatch
                guard alert.exists else { continue }
                promptsSeen.append(alert.buttons.allElementsBoundByIndex
                    .map(\.label).joined(separator: "|"))
                let fullAccess = alert.buttons.matching(Self.labelsContain(Self.fullAccessLabels))
                let generic = alert.buttons.matching(Self.labelsContain(Self.allowLabels))
                guard let button = [fullAccess.firstMatch, generic.firstMatch].first(where: \.exists) else {
                    // A prompt whose buttons this scenario does not know: report
                    // them instead of guessing, and stop (tapping the wrong
                    // button would answer the question wrongly).
                    journal.append("unmatched: " + alert.buttons.allElementsBoundByIndex
                        .map(\.label).joined(separator: "|"))
                    shot("u06d-unknown-permission-prompt")
                    return journal
                }
                journal.append(button.label)
                shot("u06c-permission-prompt")
                button.tap()
                tapped = true
                break
            }
            if tapped {
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) > 5 {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return journal
    }

    /// Whether a label mentions a byte unit. `ByteCountFormatter` follows the
    /// simulator's locale ("203 bytes", "203 Bytes", "203 octets"), so the size
    /// assertion accepts the unit in the languages this repo ships.
    private func mentionsASize(_ label: String) -> Bool {
        ["bytes", "Bytes", "octets", "Octets", "KB", "Ko", "MB", "Mo"].contains { label.contains($0) }
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
            shot("u02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// A row of a pushed screen, by IDENTIFIER (its label is localized five
    /// ways). A `Form` only publishes what it rendered, so it is scrolled into
    /// view first: `up` walks down the list, `down` walks back up it.
    private func row(_ identifier: String, swiping direction: String = "up",
                     swipes: Int = 10) -> XCUIElement {
        let element = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            if direction == "down" { app.swipeDown() } else { app.swipeUp() }
            _ = element.waitForExistence(timeout: 1)
        }
        return element
    }

    /// Any element carrying `identifier`. A per-asset row is ONE combined
    /// accessibility element (never a container: its identifier would shadow the
    /// Retry button it holds), so it is looked up among all element types.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func failureRows() -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'uploadDetailFailureRow_'"))
    }

    /// Waits for a condition, failing with `what` if it never holds. Budgeted on
    /// purpose — the retry's second upload is a server round-trip the test
    /// cannot be told about, so it is polled, never slept through.
    private func waitUntil(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(what)")
    }

    /// Waits for a control to become enabled again — how this scenario knows a
    /// run the app owns has ENDED (the retry button is disabled while it runs).
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval, _ what: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "timed out after \(Int(timeout))s waiting for \(what)")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string; the other fields are what the feature's routes noted about their
    /// own payload (`req.note`), which is how the wire is asserted without
    /// re-parsing a multipart body here.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let deviceAssetId: String?
        let filename: String?
        let outcome: String?
        let ids: [String]?
    }

    private func stubRequests() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 12), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    /// Every `POST /api/assets` the app sent, in order — one per upload.
    private func uploads() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    private func uploadCount(_ deviceAssetId: String) -> Int {
        uploads().filter { $0.deviceAssetId == deviceAssetId }.count
    }

    /// Every dedup question the app asked, in order.
    private func checks() -> [StubRequest] {
        stubRequests().filter { $0.path == "/api/assets/bulk-upload-check" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) ids=\($0.ids ?? []) asset=\($0.deviceAssetId ?? "-") "
                + "file=\($0.filename ?? "-") outcome=\($0.outcome ?? "-")"
        }.joined(separator: "\n")
    }

    // MARK: - Scenario

    func test_uploadDetail() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's drop of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("u01-welcome")
            walkOnboardingToLogin()
            shot("u02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: it must go before anything is reached.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("u03-whats-new")
            whatsNewDone.tap()
        }

        // The shell's own timeline proves the app is talking to THIS stub.
        let firstTimelineTile = element("assetTile_aaaaaaaa-1111-4111-8111-000000000001")
        XCTAssertTrue(firstTimelineTile.waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("u04-timeline")

        // MARK: The "Me" hub → Backup

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does

        let backupRow = row("backupRow")
        if !backupRow.waitForExistence(timeout: 10) {
            shot("u05b-me-hub-without-backup-row")
            XCTFail("Backup row missing in the Me hub:\n\(app.debugDescription)")
        }
        shot("u05-me-hub")
        backupRow.tap()

        // MARK: Run a backup the stub makes fail on ONE asset

        shot("u06a-backup-top")
        let runNow = row("runBackupButton")
        if !runNow.waitForExistence(timeout: 20) {
            shot("u06b-backup-settings-without-run-cta")
            XCTFail("the Backup screen has no Run now button:\n\(app.debugDescription)")
        }
        shot("u06-backup-settings")
        runNow.tap()
        let prompts = answerPermissionPrompts()

        // MARK: The screen: the run ended, and it ended with a failure

        // Whether the engine ever entered the pipeline. `Run now` is replaced by
        // `Cancel` for the whole run, so seeing that button is the one
        // observation that separates "the run found nothing to do" from "the run
        // was refused before it started" — `UploadViewModel.runBackup` returns
        // silently when Photos access is missing, and this screen shows no error.
        let cancel = app.buttons.matching(identifier: "cancelBackupButton").firstMatch
        let sawRunning = cancel.waitForExistence(timeout: 30)
        let failuresButton = app.buttons.matching(identifier: "failuresButton").firstMatch
        if !failuresButton.waitForExistence(timeout: 240) {
            shot("u07b-run-never-finished")
            XCTFail("the run never reported a failure (running: \(sawRunning), cancel: \(cancel.exists),"
                    + " prompts answered: \(prompts), seen: \(promptsSeen))."
                    + "\nThe Backup screen reads:\n"
                    + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
                    + "\nWire reads:\n\(describe(stubRequests()))")
        }
        shot("u07-run-finished")

        // MARK: The wire: one refused upload, one stored, two identifiers

        // One POST per candidate the engine accepted — the stub answers
        // `accept` to every checksum it does not refuse, so both seeded photos
        // go up. `--erase` keeps that count honest.
        let firstRun = uploads()
        let refused = firstRun.filter { $0.outcome == "refused" }
        let stored = firstRun.filter { $0.outcome == "created" }
        XCTAssertEqual(refused.count, 1,
                       "the run must have exactly one refused asset — wire reads:\n\(describe(firstRun))")
        XCTAssertGreaterThanOrEqual(stored.count, 1,
                                    "the OTHER asset must have been uploaded normally — wire reads:\n\(describe(firstRun))")
        guard let refusedRequest = refused.first, let storedRequest = stored.first else {
            return XCTFail("no refused/stored upload pair to assert on — wire reads:\n\(describe(firstRun))")
        }
        failedAssetId = refusedRequest.deviceAssetId ?? ""
        healthyAssetId = storedRequest.deviceAssetId ?? ""
        XCTAssertFalse(failedAssetId.isEmpty, "the upload carried no deviceAssetId: \(refusedRequest)")
        XCTAssertNotEqual(failedAssetId, healthyAssetId, "the two outcomes must be two different assets")

        // Both candidates were asked about in ONE check — the run started by
        // asking the server, and the answer is what decided who was uploaded.
        guard let openingCheck = checks().first else {
            return XCTFail("the run never asked bulk-upload-check — wire reads:\n\(describe(firstRun))")
        }
        // Containment, never equality: an `--erase`d device carries the
        // simulator's own sample photos too, so the run has more candidates
        // than the two this scenario seeded — the wire's count is the truth.
        let asked = Set(openingCheck.ids ?? [])
        XCTAssertTrue(asked.isSuperset(of: [failedAssetId, healthyAssetId]),
                      "the dedup question must name the assets the run uploads — got \(openingCheck.ids ?? [])")

        // MARK: The ledger is cleared, so the retry below is the ONLY thing
        // that can keep a healthy asset out of the second run.
        //
        // Without this, the app's backup ledger — not the retry's targeting —
        // is what stops the uploaded photo from going up again, and the
        // assertion after the retry could not fail. That is the whole negative
        // control of this scenario: a retry that re-scanned the library would
        // re-upload this asset, and the wire would show it.

        let resetTracking = row("resetTrackingButton")
        XCTAssertTrue(resetTracking.waitForExistence(timeout: 10), "no Reset backup tracking button")
        resetTracking.tap()
        // An alert (not a sheet: on iOS 26 a confirmation dialog drops Cancel), its
        // Reset button reached by identifier — its label is localized. iOS 26
        // lists an identified alert button twice, hence `matching(…).firstMatch`.
        let confirmReset = app.alerts.firstMatch.buttons.matching(identifier: "resetTrackingConfirm").firstMatch
        if !confirmReset.waitForExistence(timeout: 10) {
            XCTFail("the confirmation alert never offered Reset tracking:\n\(app.debugDescription)")
        } else {
            confirmReset.tap()
        }
        shot("u08-tracking-reset")

        // MARK: Upload details — the per-asset report

        let detailRow = row("uploadDetailRow", swiping: "down")
        if !detailRow.waitForExistence(timeout: 10) {
            shot("u09b-no-upload-detail-row")
            XCTFail("Upload details row missing:\n\(app.debugDescription)")
        }
        // The badge is the engine's failure count (one refused upload), and the
        // row is reached by IDENTIFIER because its label is translated.
        let badge = String(stored.count - stored.count + 1) // the run failed exactly one asset
        let rowValue = (detailRow.value as? String) ?? ""
        XCTAssertTrue(detailRow.label.contains(badge) || rowValue.contains(badge),
                      "the Upload details row must carry the engine's failure count (\(badge)),"
                      + " label '\(detailRow.label)' value '\(rowValue)'")
        shot("u09-upload-detail-row")
        detailRow.tap()

        let failureRow = element("uploadDetailFailureRow_\(failedAssetId)")
        if !failureRow.waitForExistence(timeout: 20) {
            shot("u10b-no-failure-row")
            XCTFail("no failure row for \(failedAssetId); the screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        // The refusal the SERVER sent is what the row must show — not a generic
        // "failed": the engine's reason is `APIError.serverError(500, …)`.
        XCTAssertTrue(failureRow.label.contains("500"),
                      "the failure row must carry the server's refusal, reads '\(failureRow.label)'")
        // The name the row shows is the one the upload carried. `--media` files
        // are renamed on import (`media-a.png` → `IMG_0007.PNG`), so the name
        // is taken from the wire and never from the seeding path.
        let wireName = (refusedRequest.filename as NSString?)?.lastPathComponent ?? ""
        XCTAssertFalse(wireName.isEmpty, "the refused upload carried no filename: \(refusedRequest)")
        XCTAssertTrue(failureRow.label.contains(wireName),
                      "the failure row must name the asset (\(wireName)), reads '\(failureRow.label)'")
        // One refused upload, one row — the screen's count IS the engine's.
        XCTAssertEqual(failureRows().count, 1,
                       "the screen must list exactly the engine's one failure, got \(failureRows().count)")
        XCTAssertTrue(mentionsASize(failureRow.label),
                      "the failure row must carry the size the run measured, reads '\(failureRow.label)'")

        // The success the run also recorded, as the total the engine keeps.
        let uploadedValue = element("uploadDetailUploadedValue")
        XCTAssertTrue(uploadedValue.waitForExistence(timeout: 10),
                      "the screen must report what the run uploaded too:\n\(app.debugDescription)")
        // `LabeledContent` publishes label and value as ONE element ("Importés,
        // 7"), so the count is asserted as the value's tail — never pinned to a
        // language.
        let total = "\(stored.count)"
        XCTAssertTrue(uploadedValue.label.hasSuffix(total),
                      "the screen's total must be the run's own (\(total) uploaded), says '\(uploadedValue.label)'")

        let retry = app.buttons.matching(identifier: "uploadDetailRetryButton_\(failedAssetId)").firstMatch
        if !retry.waitForExistence(timeout: 10) {
            shot("u10c-no-retry-button")
            XCTFail("no Retry button for the failed asset:\n\(app.debugDescription)")
        }
        shot("u10-upload-details")

        // MARK: Retry — one asset in, one asset on the wire

        let beforeFailed = uploadCount(failedAssetId)
        let beforeHealthy = uploadCount(healthyAssetId)
        let checksBefore = checks().count
        retry.tap()
        waitUntil(90, "the retry to upload \(failedAssetId) again") {
            uploadCount(failedAssetId) > beforeFailed
        }
        waitUntilEnabled(retry, timeout: 120, "the retry run to end")

        let afterFailed = uploadCount(failedAssetId)
        let afterHealthy = uploadCount(healthyAssetId)
        XCTAssertEqual(afterFailed, beforeFailed + 1,
                       "the retry must upload the failed asset exactly once more — wire reads:\n\(describe(uploads()))")
        XCTAssertEqual(afterHealthy, beforeHealthy,
                       "the retry must not touch any other asset — wire reads:\n\(describe(uploads()))")

        // And WHICH assets it asked about: the dedup question of the retry names
        // the one asset, not the library. A full rescan with the ledger cleared
        // would have named both.
        let retryChecks = checks().dropFirst(checksBefore)
        guard let retryCheck = retryChecks.first else {
            return XCTFail("the retry never asked bulk-upload-check — wire reads:\n\(describe(uploads()))")
        }
        XCTAssertEqual(retryCheck.ids ?? [], [failedAssetId],
                       "the retry must run over exactly the asset it was asked to retry — got \(retryCheck.ids ?? [])")

        // The screen follows the second run: the same single failure, with the
        // server's refusal again, and no second row.
        XCTAssertTrue(element("uploadDetailFailureRow_\(failedAssetId)").waitForExistence(timeout: 20),
                      "the retried asset failed again, so its row must be back — the screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(failureRows().count, 1,
                       "the second run had one failure, but the screen lists \(failureRows().count) rows")
        shot("u11-after-retry")
    }
}
