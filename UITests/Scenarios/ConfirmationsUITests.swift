import XCTest

/// End-to-end scenarios of lot L-31 (AC-62, AC-64, AC-805, AC-806, AC-807, AC-809):
/// the confirmations that became alerts (with a Cancel that changes nothing), the
/// Backup screen's single navigation bar, and the haptic feedbacks, read through
/// the app's UI-test probe.
///
/// The probe: launched with `-uiTestHapticProbe YES`, every gated haptic
/// publishes a one-point element `hapticProbe.<name>` whose accessibility value
/// reads "<last played> calls=<n>" ("none calls=0" at the start; "none" as the
/// last one when the Haptic Feedback setting silenced it).
///
/// Everything is targeted by identifier, never by localized text; the few labels
/// that have no identifier ("Shared Links" in an album's menu) are matched in
/// English, the language the scenario launches with. What the stub saw is read
/// from `<IMMICH_STUB_URL>/__requests` (`immich_stub_confirmations.py`).
///
/// Run one test with the launcher, on an erased device (the backup tests also
/// seed a photo into Photos):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/confirmations.uitest.log \
///         UITests/stubs/immich_stub_confirmations.py ConfirmationsUITests/<test> --erase
final class ConfirmationsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"
    private let album = "22222222-2222-4222-8222-000000000002"
    private let photosLink = "99999999-9999-4999-8999-000000000001"
    private let albumLink = "99999999-9999-4999-8999-000000000002"
    private let partner = "bbbbbbbb-2222-4222-8222-000000000002"

    /// A pass that outlasts the whole test: the upload answer is held that long.
    private let longUploadSeconds = 120

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - Stub helpers

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

    private func stubCall(_ path: String, method: String = "GET") -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 6
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 8), .success, "Stub did not answer \(method) \(path)")
        return body
    }

    private func setProvider(_ mode: String) {
        _ = stubCall("/__provider?mode=\(mode)")
    }

    /// `POST /api/__confirmations/fail` — arms ONE error answer for the route's
    /// next request (a control route under `/api/`: the base answers every `/__`
    /// path itself).
    private func armFailure(route: String, status: Int) {
        _ = stubCall("/api/__confirmations/fail?route=\(route)&status=\(status)", method: "POST")
    }

    private func setUploadDelay(seconds: Int) {
        _ = stubCall("/api/__confirmations/upload-delay?seconds=\(seconds)", method: "POST")
    }

    /// One entry of the stub's request log.
    private struct StubRequest {
        let method: String
        let path: String
        let params: [String: String]
    }

    private func journal() -> [StubRequest] {
        let body = stubCall("/__requests")
        let raw = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [Any] ?? []
        return raw.compactMap { entry in
            guard let object = entry as? [String: Any],
                  let method = object["method"] as? String,
                  let path = object["path"] as? String else { return nil }
            return StubRequest(method: method, path: path, params: (object["params"] as? [String: String]) ?? [:])
        }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    private func requests(_ method: String, pathPrefix: String) -> [StubRequest] {
        journal().filter { $0.method == method && $0.path.hasPrefix(pathPrefix) }
    }

    /// Whether the app ever asked to delete (or trash) a photo.
    private func photoDeletions() -> [StubRequest] {
        journal().filter {
            ($0.method == "DELETE" && $0.path.hasPrefix("/api/assets"))
                || $0.path.hasPrefix("/api/trash")
        }
    }

    // MARK: - Element helpers

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

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    private func screenText() -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    /// Scrolls (up first, then down) until `identifier` is published by its
    /// scroll view: a `Form` only publishes what it rendered.
    @discardableResult
    private func scrollTo(_ identifier: String, upSwipes: Int = 8, downSwipes: Int = 8) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<upSwipes where !(target.exists && target.isHittable) {
            app.swipeUp()
            _ = target.waitForExistence(timeout: 1)
        }
        for _ in 0..<downSwipes where !target.exists {
            app.swipeDown()
            _ = target.waitForExistence(timeout: 1)
        }
        return target
    }

    /// A row of the "Me" hub (a `Form`), by identifier, scrolled into view. The
    /// row is waited on before each swipe: a swipe sent while the sheet still
    /// animates in lands on the timeline beneath it.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<8 where !row.waitForExistence(timeout: 2) {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(row.exists, "the Me hub has no \(identifier) row — \(screenText())")
        return row
    }

    /// A tile of the Albums tab's Library section, by identifier; the Albums
    /// scroll view is scrolled only when the tile is not hittable.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        _ = row.waitForExistence(timeout: 15)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// The leading button of the frontmost navigation bar (the pushed screen's
    /// back chevron), found by geometry rather than by label.
    @discardableResult
    private func goBack() -> Bool {
        let bars = app.navigationBars
        for index in stride(from: bars.count - 1, through: 0, by: -1) {
            let button = bars.element(boundBy: index).buttons.element(boundBy: 0)
            if button.exists, button.isHittable, button.frame.minX < app.frame.width / 2 {
                button.tap()
                sleep(1)
                return true
            }
        }
        return false
    }

    private func hasBackButton() -> Bool {
        let bars = app.navigationBars
        for index in 0..<bars.count {
            let button = bars.element(boundBy: index).buttons.element(boundBy: 0)
            if button.exists, button.isHittable, button.frame.minX < app.frame.width / 2 { return true }
        }
        return false
    }

    // MARK: - Navigation

    private let fullAccessLabels = ["Allow Full Access", "Allow Access to All Photos", "Full Access",
                                    "accès complet", "Zugriff auf alle Fotos", "Voller Zugriff"]
    private let allowLabels = ["Allow", "Autoriser", "Erlauben", "Permitir", "Consenti"]

    /// Answers the permission prompts a backup raises (Photos access,
    /// notifications) with full access / "Allow", until none has appeared for a
    /// few seconds. "Add Only" and "Limit Access" are never tapped: a limited or
    /// add-only grant would make the pass an empty one.
    private func answerPermissionPrompts(window: TimeInterval = 20) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(window)
        var quietSince = Date()
        let fullAccess = labelPredicate(fullAccessLabels)
        let generic = NSPredicate(format: "label IN %@", allowLabels)
        while Date() < deadline {
            var tapped = false
            for alerts in [app.alerts, springboard.alerts] {
                let alert = alerts.firstMatch
                guard alert.exists else { continue }
                // Full access first; the generic "Allow" only by an EXACT label
                // ("Don't Allow" contains it).
                let button = [alert.buttons.matching(fullAccess).firstMatch,
                              alert.buttons.matching(generic).firstMatch].first(where: \.exists)
                if let button {
                    button.tap()
                    tapped = true
                    break
                }
            }
            if tapped {
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) > 4 {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Waits for the OAuth provider's "Authorize" link and taps it, answering on
    /// the way every system alert that can stand in front of it: the sign-in
    /// question ("Continue"), and the Photos access and notification prompts a
    /// freshly erased device raises while the app starts (full access, or an
    /// EXACT "Allow"). A fixed wait for each, in a fixed order, missed a late
    /// alert and left the Safari sheet unreachable (CI, 1f2f95b).
    private func tapAuthorizeInProvider(timeout: TimeInterval) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let authorize = NSPredicate(format: "label CONTAINS 'Authorize'")
        let signInQuestion = NSPredicate(format: "label IN %@", ["Continue", "Continuer"])
        let fullAccess = labelPredicate(fullAccessLabels)
        let allow = NSPredicate(format: "label IN %@", allowLabels)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in [safari.links.matching(authorize).firstMatch, safari.buttons.matching(authorize).firstMatch]
            where candidate.exists {
                candidate.tap()
                return true
            }
            for alerts in [springboard.alerts, app.alerts] {
                let alert = alerts.firstMatch
                guard alert.exists else { continue }
                let answer = [alert.buttons.matching(signInQuestion).firstMatch,
                              alert.buttons.matching(fullAccess).firstMatch,
                              alert.buttons.matching(allow).firstMatch].first(where: \.exists)
                if let answer {
                    answer.tap()
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Onboarding → SSO → "Authorize". The first system sign-in of a freshly
    /// erased simulator is slow (the alert, then a cold `SafariViewService`): a
    /// stuck attempt is restarted from the onboarding, never failed on the first
    /// miss (the pattern of `ShareAndCachesUITests.signIn`).
    private func signIn() {
        for attempt in 0..<3 {
            if attempt > 0 {
                app.terminate()
                setProvider("manual")
                app.launch()
                XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                              "the onboarding did not come back for a new sign-in attempt")
            }
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            if tapAuthorizeInProvider(timeout: 45) { return }
        }
        XCTFail("Authorize link not reachable in the auth sheet after 3 attempts")
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

    /// Reset the stub, (optionally) arm the upload delay, launch with the haptic
    /// probe on, walk onboarding if the device is fresh, land on the timeline.
    private func launchSignedIn(uploadDelay: Int = 0) {
        _ = stubCall("/__reset")
        setProvider("manual")
        if uploadDelay > 0 { setUploadDelay(seconds: uploadDelay) }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestHapticProbe", "YES"]
        app.launch()
        // A signed-in device lands on the timeline without the onboarding: wait
        // for whichever comes first, never the full onboarding timeout (the
        // teardowns relaunch a signed-in app; 30 s lost there broke the budget).
        let onboarding = app.staticTexts.matching(labelPredicate(["Your photo library", "Votre photothèque"])).firstMatch
        let photosTab = app.tabBars.buttons["Photos"]
        _ = waitUntil(30) { onboarding.exists || photosTab.exists }
        if onboarding.exists, !photosTab.exists {
            signIn()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub)")
    }

    private func openHub() {
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "Profile avatar missing")
        avatar.tap()
        sleep(4) // the sheet animates in; its Form is not hittable before it does
    }

    /// Back `levels` times inside the hub, then the hub's sheet dragged down from
    /// its navigation bar: the timeline's own controls are reachable again.
    private func leaveHub(back levels: Int) {
        for _ in 0..<levels { goBack() }
        let photosTab = app.tabBars.buttons["Photos"]
        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { photosTab.exists && photosTab.isHittable }
        }
        XCTAssertTrue(dismissed, "the Me sheet never dismissed")
    }

    /// Me hub → Preferences, on the model of the Backup row: the row is waited
    /// on until it is hittable, then tapped; while the Preferences screen does
    /// not show, the app and SpringBoard alerts are answered (a banner or a
    /// permission prompt can stand over the hub's first row) and the row is
    /// tapped again — at most 3 attempts. The screen is recognised by its first
    /// section (the Haptic Feedback toggle sits at the bottom of the form and is
    /// only published once scrolled to).
    private func openPreferences() {
        openHub()
        let row = hubRow("preferencesRow")
        let opened = { () -> Bool in
            ["preferencesHapticsToggle", "preferencesGroupPicker", "preferencesSmoothScrubbingToggle"]
                .contains { self.element($0).exists }
        }
        for attempt in 0..<3 where !opened() {
            if attempt > 0 { answerPermissionPrompts(window: 4) }
            if opened() { break }
            let ready = waitUntil(10) { row.exists && row.isHittable }
            XCTAssertTrue(ready || opened(),
                          "the Preferences row is not hittable in the Me hub (attempt \(attempt + 1)) — \(screenText())")
            if ready { row.tap() }
            _ = waitUntil(10) { opened() }
        }
        XCTAssertTrue(opened(), "the Preferences screen never opened after 3 attempts — \(screenText())")
    }

    private func openBackup() {
        openHub()
        let row = hubRow("backupRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Backup row missing in the Me hub — \(screenText())")
        row.tap()
        // The screen's first act reads the photo library: the access question comes now.
        answerPermissionPrompts(window: 8)
        XCTAssertTrue(element("runBackupButton").waitForExistence(timeout: 25)
                      || element("autoBackupToggle").waitForExistence(timeout: 5),
                      "the Backup screen never loaded — \(screenText())")
    }

    /// The backup tests leave a signed-in device with Photos access and
    /// notifications granted; the next scenario on the same simulator is not
    /// erased. Their teardown relaunches the app (the held pass dies with it)
    /// and turns "Auto backup" off, so no pass — and no "Backup complete"
    /// notification banner over the Me hub — starts when the next test launches.
    private func turnAutoBackupOffAtTeardown() {
        addTeardownBlock { [self] in
            app.terminate()
            launchSignedIn()
            openBackup()
            let toggle = scrollTo("autoBackupToggle")
            XCTAssertTrue(waitUntil(15) { toggle.exists && toggle.isHittable },
                          "the Auto backup toggle is missing — \(screenText())")
            for _ in 0..<3 where (toggle.value as? String) != "0" {
                // The element is the whole row: its own control sits at the trailing edge.
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                _ = waitUntil(4) { (toggle.value as? String) == "0" }
            }
            XCTAssertEqual(toggle.value as? String, "0", "Auto backup never turned off — \(screenText())")
            app.terminate()
        }
    }

    private func openPartners() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "Albums tab missing")
        albums.tap()
        let row = libraryRow("partnersRow")
        XCTAssertTrue(row.exists, "Partners tile missing in the Albums library — \(screenText())")
        row.tap()
        XCTAssertTrue(element("partnersScreen").waitForExistence(timeout: 20)
                      || element("invitePartner").waitForExistence(timeout: 5),
                      "the Partners screen never opened")
    }

    private func openSharedTab() {
        for label in ["Shared", "Partagé"] {
            let tab = app.tabBars.buttons[label].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.tap()
                return
            }
        }
        app.tabBars.buttons.element(boundBy: 3).tap()
    }

    // MARK: - Alerts

    /// A button of the frontmost alert, by identifier. iOS 26 lists an
    /// identified alert button twice in the tree (`alert.buttons[id]` and
    /// `app.buttons[id]` then fail with "Multiple matching elements"), so it is
    /// always queried inside the alert and narrowed to its first match.
    private func alertButton(_ identifier: String) -> XCUIElement {
        app.alerts.firstMatch.buttons.matching(identifier: identifier).firstMatch
    }

    /// The alert a destructive button raised, with its two buttons.
    @discardableResult
    private func alertWithButtons(_ confirm: String, _ cancel: String, _ what: String) -> XCUIElement {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "\(what): no alert was presented — \(screenText())")
        XCTAssertTrue(alertButton(confirm).waitForExistence(timeout: 5), "\(what): the alert has no \(confirm) button")
        XCTAssertTrue(alertButton(cancel).exists, "\(what): the alert has no \(cancel) button")
        return alert
    }

    private func waitUntilNoAlert(_ what: String) {
        XCTAssertTrue(waitUntil(10) { !self.app.alerts.firstMatch.exists }, "\(what): the alert stayed up")
    }

    // MARK: - Haptic probe

    private func probeValue(_ name: String) -> String {
        (element("hapticProbe.\(name)").value as? String) ?? "<missing>"
    }

    /// The probe reads `expected` (waited on: the feedback fires after the
    /// action's own round trip).
    private func assertProbe(_ name: String, _ expected: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(element("hapticProbe.\(name)").waitForExistence(timeout: 20),
                      "hapticProbe.\(name) is not on screen")
        XCTAssertTrue(waitUntil(timeout) { self.probeValue(name) == expected },
                      "hapticProbe.\(name) reads '\(probeValue(name))', expected '\(expected)'")
    }

    /// The probe still reads `expected` after a settling pause: nothing played.
    private func assertProbeUnchanged(_ name: String, _ expected: String) {
        sleep(2)
        XCTAssertEqual(probeValue(name), expected, "hapticProbe.\(name) moved — a feedback played")
    }

    // MARK: - Counters

    /// The trailing integer of an element's value, else of its label ("Tracked
    /// photos, 3", "Tracked, 3").
    private func trailingCount(_ identifier: String) -> Int? {
        let target = element(identifier)
        guard target.exists else { return nil }
        let value = ((target.value as? String) ?? "").trimmingCharacters(in: .whitespaces)
        if let number = Int(value) { return number }
        let digits = target.label.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        return digits.last.flatMap(Int.init)
    }

    /// The counter, scrolling to it when it is not published yet.
    private func count(_ identifier: String) -> Int? {
        if element(identifier).exists { return trailingCount(identifier) }
        scrollTo(identifier)
        return trailingCount(identifier)
    }

    // MARK: - Shared links

    /// Swipes a link's row and presents the revoke alert (a full swipe may raise
    /// it on its own; a partial one reveals the button, which is tapped).
    private func startRevoke(_ linkId: String) {
        let row = element("sharedLinkRow_\(linkId)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no row for link \(linkId) — \(screenText())")
        _ = waitUntil(8) { row.isHittable }
        row.swipeLeft()
        let revoke = element("sharedLinkRevoke-\(linkId)")
        let alert = app.alerts.firstMatch
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !alert.exists {
            if revoke.exists && revoke.isHittable {
                revoke.tap()
                break
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        alertWithButtons("sharedLinkRevokeConfirm", "sharedLinkRevokeCancel", "revoking \(linkId)")
    }

    private func revokeLink(_ linkId: String, confirm: Bool) {
        startRevoke(linkId)
        alertButton(confirm ? "sharedLinkRevokeConfirm" : "sharedLinkRevokeCancel").tap()
    }

    /// The server refused the revocation: an error alert (no revoke button) is up.
    private func dismissErrorAlert() {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(waitUntil(20) { alert.exists && !self.alertButton("sharedLinkRevokeConfirm").exists },
                      "the refused revocation showed no error alert — \(screenText())")
        alert.buttons.firstMatch.tap()
        waitUntilNoAlert("error alert")
    }

    // MARK: - AC-62

    /// AC-62: the Preferences reset is an alert; Cancel leaves the preference,
    /// Reset brings the default back.
    func test_AC_62_preferencesReset() throws {
        launchSignedIn()
        openPreferences()

        let toggle = element("preferencesSmoothScrubbingToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Smooth Scrubbing toggle is missing")
        let initial = (toggle.value as? String) ?? ""
        XCTAssertTrue(initial == "0" || initial == "1", "unreadable toggle value '\(initial)'")
        let changed = initial == "1" ? "0" : "1"
        for _ in 0..<3 where (toggle.value as? String) != changed {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = waitUntil(4) { (toggle.value as? String) == changed }
        }
        XCTAssertEqual(toggle.value as? String, changed, "the preference never changed")

        let reset = scrollTo("preferencesResetButton")
        XCTAssertTrue(reset.exists, "the Preferences form has no Reset button")
        reset.tap()
        alertWithButtons("preferencesResetConfirm", "preferencesResetCancel", "Preferences reset")
        alertButton("preferencesResetCancel").tap()
        waitUntilNoAlert("Preferences reset (Cancel)")
        scrollTo("preferencesSmoothScrubbingToggle")
        XCTAssertEqual(toggle.value as? String, changed, "Cancel changed the preference")

        scrollTo("preferencesResetButton").tap()
        alertWithButtons("preferencesResetConfirm", "preferencesResetCancel", "Preferences reset")
        alertButton("preferencesResetConfirm").tap()
        waitUntilNoAlert("Preferences reset (Reset)")
        scrollTo("preferencesSmoothScrubbingToggle")
        XCTAssertTrue(waitUntil(10) { (toggle.value as? String) == initial },
                      "Reset did not bring the default back (reads '\(toggle.value as? String ?? "")')")
    }

    /// AC-62, AC-806: stopping a share is an alert; Cancel keeps the partner,
    /// sends nothing and plays no haptic; confirming removes the partner, sends
    /// the DELETE and plays one warning.
    func test_AC_62_partnerStopSharing() throws {
        launchSignedIn()
        openPartners()

        let remove = element("partnerRemove-\(partner)")
        XCTAssertTrue(remove.waitForExistence(timeout: 20), "the partner is not listed — \(screenText())")
        assertProbe("partnerStopSharing", "none calls=0")

        remove.tap()
        alertWithButtons("confirmStopSharing", "cancelStopSharing", "stopping a share")
        alertButton("cancelStopSharing").tap()
        waitUntilNoAlert("stopping a share (Cancel)")
        XCTAssertTrue(element("partnerRemove-\(partner)").exists, "Cancel removed the partner")
        XCTAssertTrue(requests("DELETE", pathPrefix: "/api/partners/").isEmpty,
                      "Cancel sent a DELETE — journal:\n\(describe(journal()))")
        assertProbeUnchanged("partnerStopSharing", "none calls=0")

        remove.tap()
        alertWithButtons("confirmStopSharing", "cancelStopSharing", "stopping a share")
        alertButton("confirmStopSharing").tap()
        XCTAssertTrue(waitUntil(20) { !self.element("partnerRemove-\(self.partner)").exists },
                      "the partner is still listed after Stop sharing")
        XCTAssertEqual(requests("DELETE", pathPrefix: "/api/partners/\(partner)").count, 1,
                       "confirming must send one DELETE — journal:\n\(describe(journal()))")
        assertProbe("partnerStopSharing", "warning calls=1")
    }

    /// AC-62: resetting the backup tracking, on the Backup screen and on the sync
    /// status sheet, is an alert; Cancel leaves the tracked count untouched, only
    /// the confirmation zeroes it.
    func test_AC_62_backupResetTracking() throws {
        launchSignedIn()
        turnAutoBackupOffAtTeardown()
        openBackup()

        scrollTo("runBackupButton").tap()
        answerPermissionPrompts(window: 20)
        XCTAssertTrue(waitUntil(180) { (self.count("backupTrackedPhotos") ?? 0) >= 1 },
                      "the pass never tracked a photo — Tracked reads \(String(describing: count("backupTrackedPhotos")))")
        XCTAssertTrue(waitUntil(120) { !self.element("cancelBackupButton").exists },
                      "the pass never ended")
        let tracked = try XCTUnwrap(count("backupTrackedPhotos"), "no tracked counter on the Backup screen")
        XCTAssertGreaterThanOrEqual(tracked, 1)

        scrollTo("resetTrackingButton").tap()
        alertWithButtons("resetTrackingConfirm", "resetTrackingCancel", "resetting the tracking")
        alertButton("resetTrackingCancel").tap()
        waitUntilNoAlert("resetting the tracking (Cancel)")
        XCTAssertEqual(count("backupTrackedPhotos"), tracked, "Cancel changed the tracked count (Backup screen)")

        leaveHub(back: 1)
        let syncButton = app.buttons.matching(identifier: "syncStatusButton").firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 15), "the sync status button is missing from the timeline")
        syncButton.tap()
        sleep(3)
        scrollTo("syncStatusTrackedValue")
        XCTAssertEqual(count("syncStatusTrackedValue"), tracked, "the sync status sheet disagrees with the Backup screen")

        scrollTo("syncStatusResetLedger").tap()
        alertWithButtons("syncStatusResetLedgerConfirm", "syncStatusResetLedgerCancel", "resetting the ledger")
        alertButton("syncStatusResetLedgerCancel").tap()
        waitUntilNoAlert("resetting the ledger (Cancel)")
        XCTAssertEqual(count("syncStatusTrackedValue"), tracked, "Cancel changed the tracked count (sync status)")

        scrollTo("syncStatusResetLedger").tap()
        alertWithButtons("syncStatusResetLedgerConfirm", "syncStatusResetLedgerCancel", "resetting the ledger")
        alertButton("syncStatusResetLedgerConfirm").tap()
        waitUntilNoAlert("resetting the ledger (confirm)")
        // At zero the sheet may swap its counters for its empty state.
        XCTAssertTrue(waitUntil(15) {
            self.element("syncStatusEmptyState").exists || self.trailingCount("syncStatusTrackedValue") == 0
        }, "the confirmation did not zero the tracking (reads \(String(describing: trailingCount("syncStatusTrackedValue"))))")
    }

    /// AC-62: deleting from the viewer is an alert; Cancel keeps the photo on
    /// screen and sends no deletion.
    func test_AC_62_viewerDelete() throws {
        launchSignedIn()
        element("assetTile_\(photo)").tap()
        let delete = element("viewerDeleteButton")
        XCTAssertTrue(delete.waitForExistence(timeout: 20), "the viewer has no Delete button — \(screenText())")
        delete.tap()
        alertWithButtons("viewerDeleteConfirm", "viewerDeleteCancel", "deleting from the viewer")
        alertButton("viewerDeleteCancel").tap()
        waitUntilNoAlert("deleting from the viewer (Cancel)")
        XCTAssertTrue(element("viewerDeleteButton").waitForExistence(timeout: 10), "the viewer closed after Cancel")
        XCTAssertTrue(element("viewerBackButton").exists, "the photo is no longer displayed after Cancel")
        sleep(1)
        XCTAssertTrue(photoDeletions().isEmpty,
                      "Cancel sent a deletion — journal:\n\(describe(photoDeletions()))")
    }

    // MARK: - AC-64, AC-805

    /// AC-64, AC-805: the Backup screen opened from Me has no navigation bar of
    /// its own — one bar, with the way back — and neither do the screens it pushes;
    /// two backs from the upload details return to the hub.
    ///
    /// The album picker is reached by the "Mirror into albums" row
    /// (`backupMirrorAlbumsRow`): the same `AlbumPickerView` push as "Albums to
    /// back up", without the scope menu that only reveals the latter.
    func test_AC_64_backupFromMeHasOneBar() throws {
        launchSignedIn()
        openHub()
        _ = hubRow("backupRow")
        let hubBars = app.navigationBars.count
        XCTAssertGreaterThanOrEqual(hubBars, 1, "no navigation bar on the Me hub")

        let backupRow = hubRow("backupRow")
        XCTAssertTrue(backupRow.waitForExistence(timeout: 10), "Backup row missing")
        backupRow.tap()
        answerPermissionPrompts(window: 8)
        XCTAssertTrue(element("autoBackupToggle").waitForExistence(timeout: 25)
                      || element("runBackupButton").waitForExistence(timeout: 5),
                      "the Backup screen never loaded — \(screenText())")
        sleep(1)
        XCTAssertEqual(app.navigationBars.count, hubBars,
                       "the Backup screen added a navigation bar: \(app.navigationBars.allElementsBoundByIndex.map(\.identifier))")
        XCTAssertTrue(hasBackButton(), "the Backup screen's bar has no back button")

        // Upload details → back.
        let detailRow = scrollTo("uploadDetailRow")
        XCTAssertTrue(detailRow.exists, "no Upload details row")
        detailRow.tap()
        XCTAssertTrue(element("uploadDetailEmptyState").waitForExistence(timeout: 20)
                      || element("uploadDetailUploadedValue").waitForExistence(timeout: 5),
                      "the upload details never opened — \(screenText())")
        sleep(1)
        XCTAssertEqual(app.navigationBars.count, hubBars, "the upload details added a navigation bar")
        XCTAssertTrue(goBack(), "no way back from the upload details")
        sleep(1)
        XCTAssertEqual(app.navigationBars.count, hubBars, "back from the upload details changed the bars")

        // Album picker → back.
        let mirrorRow = scrollTo("backupMirrorAlbumsRow")
        XCTAssertTrue(mirrorRow.exists, "no album picker row")
        mirrorRow.tap()
        XCTAssertTrue(waitUntil(15) { !self.element("backupMirrorAlbumsRow").isHittable },
                      "the album picker never opened")
        sleep(1)
        XCTAssertEqual(app.navigationBars.count, hubBars, "the album picker added a navigation bar")
        XCTAssertTrue(goBack(), "no way back from the album picker")
        sleep(1)
        XCTAssertEqual(app.navigationBars.count, hubBars, "back from the album picker changed the bars")

        // Two backs from the upload details land on the hub.
        let detailAgain = scrollTo("uploadDetailRow")
        XCTAssertTrue(detailAgain.exists, "no Upload details row (second time)")
        detailAgain.tap()
        XCTAssertTrue(element("uploadDetailEmptyState").waitForExistence(timeout: 20)
                      || element("uploadDetailUploadedValue").waitForExistence(timeout: 5),
                      "the upload details never reopened")
        XCTAssertTrue(goBack(), "first back from the upload details failed")
        XCTAssertTrue(goBack(), "second back (Backup → Me) failed")
        let hubBackupRow = app.buttons.matching(identifier: "backupRow").firstMatch
        XCTAssertTrue(waitUntil(10) { hubBackupRow.exists && hubBackupRow.isHittable },
                      "two backs did not return to the Me hub — \(screenText())")
        XCTAssertEqual(app.navigationBars.count, hubBars, "the hub's bars changed after two backs")
    }

    // MARK: - AC-806

    /// AC-806, AC-64: revoking a shared link is an alert; Cancel and a refused
    /// revocation play nothing; a successful one plays one warning — from the
    /// Shared tab and from an album's "Shared Links" sheet.
    func test_AC_806_sharedLinkRevoke() throws {
        launchSignedIn()
        openSharedTab()
        assertProbe("sharedLinkRevoke", "none calls=0")

        // Cancel: nothing plays, the row stays.
        revokeLink(photosLink, confirm: false)
        waitUntilNoAlert("revoking (Cancel)")
        XCTAssertTrue(element("sharedLinkRow_\(photosLink)").waitForExistence(timeout: 10), "Cancel removed the row")
        XCTAssertTrue(requests("DELETE", pathPrefix: "/api/shared-links/").isEmpty,
                      "Cancel sent a DELETE — journal:\n\(describe(journal()))")
        assertProbeUnchanged("sharedLinkRevoke", "none calls=0")

        // Confirm: the row goes, one warning plays.
        revokeLink(photosLink, confirm: true)
        XCTAssertTrue(waitUntil(20) { !self.element("sharedLinkRow_\(self.photosLink)").exists },
                      "the revoked link is still listed")
        assertProbe("sharedLinkRevoke", "warning calls=1")

        // The server refuses the next revocation: an error, nothing more plays.
        armFailure(route: "revoke", status: 500)
        revokeLink(albumLink, confirm: true)
        dismissErrorAlert()
        XCTAssertTrue(element("sharedLinkRow_\(albumLink)").waitForExistence(timeout: 10),
                      "the refused revocation removed the row")
        assertProbeUnchanged("sharedLinkRevoke", "warning calls=1")

        // The album's own "Shared Links" sheet.
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "Albums tab missing")
        albums.tap()
        let card = element("albumCard_\(album)")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the album is not listed — \(screenText())")
        card.tap()
        let menu = element("albumActionsMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "the album has no actions menu — \(screenText())")
        menu.tap()
        XCTAssertTrue(tapAnyButton(["Shared Links"], timeout: 10), "the album menu has no Shared Links item")
        assertProbe("albumSharedLinkRevoke", "none calls=0")

        revokeLink(albumLink, confirm: false)
        waitUntilNoAlert("revoking from the album (Cancel)")
        XCTAssertTrue(element("sharedLinkRow_\(albumLink)").waitForExistence(timeout: 10),
                      "Cancel removed the album's link")
        assertProbeUnchanged("albumSharedLinkRevoke", "none calls=0")

        revokeLink(albumLink, confirm: true)
        XCTAssertTrue(waitUntil(20) { !self.element("sharedLinkRow_\(self.albumLink)").exists },
                      "the revoked album link is still listed")
        assertProbe("albumSharedLinkRevoke", "warning calls=1")
    }

    /// Signs in with the Haptic Feedback setting off. The setting survives the
    /// test on a device that is not erased between runs: the teardown turns it
    /// back on.
    private func launchSignedInWithHapticsOff() {
        launchSignedIn()
        addTeardownBlock { [self] in
            app.terminate()
            launchSignedIn()
            setHaptics(on: true)
        }
        setHaptics(on: false)
    }

    /// AC-806: with the Haptic Feedback setting off, revoking a link plays
    /// nothing (the probe still counts the call, as "none"). One action per test:
    /// both in one test ran past the 180 s CI budget.
    func test_AC_806_hapticsOffRevokePlaysNothing() throws {
        launchSignedInWithHapticsOff()

        openSharedTab()
        assertProbe("sharedLinkRevoke", "none calls=0")
        revokeLink(photosLink, confirm: true)
        XCTAssertTrue(waitUntil(20) { !self.element("sharedLinkRow_\(self.photosLink)").exists },
                      "the revoked link is still listed")
        assertProbe("sharedLinkRevoke", "none calls=1")
    }

    /// AC-806: with the Haptic Feedback setting off, stopping a share plays
    /// nothing (the probe still counts the call, as "none").
    func test_AC_806_hapticsOffStopSharingPlaysNothing() throws {
        launchSignedInWithHapticsOff()

        openPartners()
        assertProbe("partnerStopSharing", "none calls=0")
        let remove = element("partnerRemove-\(partner)")
        XCTAssertTrue(remove.waitForExistence(timeout: 20), "the partner is not listed — \(screenText())")
        remove.tap()
        alertWithButtons("confirmStopSharing", "cancelStopSharing", "stopping a share")
        alertButton("confirmStopSharing").tap()
        XCTAssertTrue(waitUntil(20) { !self.element("partnerRemove-\(self.partner)").exists },
                      "the partner is still listed after Stop sharing")
        assertProbe("partnerStopSharing", "none calls=1")
    }

    /// The Me hub → Preferences → "Haptic Feedback" set to `on`, then back to the
    /// timeline. The toggle is the form's last control: scrolled to before use.
    private func setHaptics(on: Bool) {
        openPreferences()
        let toggle = scrollTo("preferencesHapticsToggle")
        XCTAssertTrue(waitUntil(15) { toggle.exists && toggle.isHittable },
                      "the Haptic Feedback toggle is missing — \(screenText())")
        let wanted = on ? "1" : "0"
        for _ in 0..<3 where (toggle.value as? String) != wanted {
            // The element is the whole row: its own control sits at the trailing edge.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = waitUntil(4) { (toggle.value as? String) == wanted }
        }
        XCTAssertEqual(toggle.value as? String, wanted, "Haptic Feedback never reached \(wanted)")
        leaveHub(back: 1)
    }

    // MARK: - AC-807

    private func openLockedFolder() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "Albums tab missing")
        albums.tap()
        let row = libraryRow("lockedFolderRow")
        XCTAssertTrue(row.exists, "Locked Folder tile missing in the Albums library — \(screenText())")
        row.tap()
        XCTAssertTrue(element("lockedFolderUnlockButton").waitForExistence(timeout: 20),
                      "the locked folder did not stand at its PIN door — \(screenText())")
    }

    private func typeLockedFolderPIN(_ digits: String) {
        let field = app.secureTextFields["lockedFolderPINField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the PIN field is missing — \(screenText())")
        field.tap()
        let existing = ((field.value as? String) ?? "").filter { $0 == "•" }.count
        if existing > 0 {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing))
        }
        field.typeText(digits)
    }

    /// AC-807: every PIN the server refuses plays one error; the accepted PIN plays none.
    func test_AC_807_lockedFolderWrongPIN() throws {
        launchSignedIn()
        openLockedFolder()
        assertProbe("lockedFolderPINRefused", "none calls=0")

        typeLockedFolderPIN("111111")
        element("lockedFolderUnlockButton").tap()
        assertProbe("lockedFolderPINRefused", "error calls=1")

        typeLockedFolderPIN("222222")
        element("lockedFolderUnlockButton").tap()
        assertProbe("lockedFolderPINRefused", "error calls=2")

        typeLockedFolderPIN("123456")
        element("lockedFolderUnlockButton").tap()
        XCTAssertTrue(element("lockNowButton").waitForExistence(timeout: 30),
                      "the right PIN did not open the folder — \(screenText())")
        assertProbeUnchanged("lockedFolderPINRefused", "error calls=2")
    }

    /// Types the PIN in the session-unlock alert's field (the number pad is a
    /// software keyboard: the keys are tapped when `typeText` is swallowed).
    private func enterSessionPIN(_ digits: String) {
        let field = app.textFields["deviceSessionsUnlockField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the unlock alert has no PIN field")
        field.tap()
        field.typeText(digits)
        if !((field.value as? String) ?? "").contains(digits) {
            for digit in digits {
                let key = app.keyboards.firstMatch.keys[String(digit)]
                if key.waitForExistence(timeout: 2) { key.tap() }
            }
        }
    }

    /// AC-807: a PIN the server refuses plays one error; one that is too short is
    /// refused on the spot, without a feedback.
    func test_AC_807_sessionElevationWrongPIN() throws {
        launchSignedIn()
        openHub()
        let row = hubRow("deviceSessionsRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Connected Devices row missing — \(screenText())")
        row.tap()
        XCTAssertTrue(element("deviceSessionsList").waitForExistence(timeout: 20), "Connected Devices never loaded")
        assertProbe("sessionPINRefused", "none calls=0")

        element("deviceSessionsLockButton").tap()
        enterSessionPIN("111111")
        app.alerts.firstMatch.buttons["deviceSessionsUnlockConfirm"].tap()
        assertProbe("sessionPINRefused", "error calls=1")
        waitUntilNoAlert("session unlock")

        element("deviceSessionsLockButton").tap()
        enterSessionPIN("123")
        app.alerts.firstMatch.buttons["deviceSessionsUnlockConfirm"].tap()
        let message = element("deviceSessionsActionError")
        XCTAssertTrue(waitUntil(15) { message.exists && message.label.contains("Enter 6 digits") },
                      "a 3-digit PIN did not show 'Enter 6 digits' — \(screenText())")
        assertProbeUnchanged("sessionPINRefused", "error calls=1")
    }

    // MARK: - AC-809

    /// AC-809: "Run now" plays a start as soon as the pass runs, "Cancel" a stop,
    /// "Resume last backup" a start again, and the upload details' "Stop" a stop.
    func test_AC_809_backupScreenStartStop() throws {
        launchSignedIn(uploadDelay: longUploadSeconds)
        turnAutoBackupOffAtTeardown()
        openBackup()
        assertProbe("backupStart.settings", "none calls=0")
        assertProbe("backupStop.settings", "none calls=0")

        scrollTo("runBackupButton").tap()
        answerPermissionPrompts(window: 20)
        assertProbe("backupStart.settings", "start calls=1", timeout: 30)
        XCTAssertTrue(element("cancelBackupButton").waitForExistence(timeout: 30),
                      "no pass is running after Run now — \(screenText())")

        element("cancelBackupButton").tap()
        assertProbe("backupStop.settings", "stop calls=1")

        let resume = scrollTo("resumeBackupButton")
        XCTAssertTrue(resume.waitForExistence(timeout: 60), "no Resume last backup after the cancel — \(screenText())")
        resume.tap()
        assertProbe("backupStart.settings", "start calls=2", timeout: 30)

        // The resumed pass runs: the stub holds every upload (`longUploadSeconds`,
        // cut at the client's 60 s request timeout, for each of the seeded photo
        // and the device's six sample photos), so it lasts minutes.
        XCTAssertTrue(element("cancelBackupButton").waitForExistence(timeout: 30),
                      "the resumed pass is not running on the Backup screen — \(screenText())")

        // Upload details, reached from the TOP of the Backup screen. Scrolled back
        // up from the Progress section, the row only got published at the edge of
        // the bar and the tap pushed nothing (CI, 1f2f95b). Leaving for the hub and
        // coming back opens the screen at its top, where test_AC_64 taps the row.
        XCTAssertTrue(goBack(), "no way back from the Backup screen to the hub")
        let backupRow = hubRow("backupRow")
        XCTAssertTrue(waitUntil(10) { backupRow.exists && backupRow.isHittable },
                      "the Me hub did not come back — \(screenText())")
        backupRow.tap()
        let detailRow = element("uploadDetailRow")
        XCTAssertTrue(waitUntil(20) { detailRow.exists && detailRow.isHittable },
                      "no hittable Upload details row at the top of the Backup screen — \(screenText())")
        detailRow.tap()
        // The details follow the same engine: a running pass shows its progress bar.
        XCTAssertTrue(element("uploadDetailProgress").waitForExistence(timeout: 20),
                      "the upload details did not open on a running pass — \(screenText())")
        let stop = element("uploadDetailCancelButton")
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the upload details offer no Stop — \(screenText())")
        stop.tap()
        assertProbe("backupStop.uploadDetail", "stop calls=1")
    }

    /// AC-809: the sync status sheet's "Run now" plays a start, its "Stop" a stop.
    func test_AC_809_syncStatusStartStop() throws {
        launchSignedIn(uploadDelay: longUploadSeconds)
        turnAutoBackupOffAtTeardown()
        let syncButton = app.buttons.matching(identifier: "syncStatusButton").firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 15), "the sync status button is missing from the timeline")
        syncButton.tap()
        sleep(3)
        assertProbe("backupStart.syncStatus", "none calls=0")

        scrollTo("syncStatusRunNow").tap()
        answerPermissionPrompts(window: 20)
        assertProbe("backupStart.syncStatus", "start calls=1", timeout: 30)

        let stop = scrollTo("syncStatusCancel")
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "no Stop while the pass runs — \(screenText())")
        stop.tap()
        assertProbe("backupStop.syncStatus", "stop calls=1")
    }
}
