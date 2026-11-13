import XCTest

/// End-to-end scenario for L-22 "Also back up edits" — the setting, and what the
/// backup engine does with a photo edited in place in Photos.
///
/// It drives the real app (onboarding → SSO → Me > Backup) against a Photos
/// library seeded by the launcher with one PNG (`--media`). The photo is then
/// REALLY edited, in place, through PhotoKit by the app itself
/// (`-uiTestEditAssetNamed <file name>`, DEBUG builds): colour inversion plus
/// adjustment data, so Photos reports `hasAdjustments` and a moved modification
/// date. Photos asks its own system alert before it lets the app do that, and the
/// scenario answers it (`allowSystemModification`). What each test proves:
///
/// * `test_AC_41_editStackedOnOriginal` — with the setting ON, a first backup
///   uploads the original (no stack yet); after the photo is edited in place, the
///   second backup uploads the EDITED rendering as a new asset (a checksum the
///   server did not hold) and then asks the server, once, to stack it:
///   `POST /api/stacks` with the edit FIRST (the head) and the original beneath.
///   The timeline confirms it from the server's own point of view: the edit's tile
///   exists and carries the stack badge, the original's tile is no longer a tile
///   of its own.
/// * `test_AC_41_settingOffSendsNothing` — the same story with the setting left
///   OFF (its default): after the edit, the second backup adds no upload and no
///   stack to the journal. An edit is not a reason to talk to the server unless
///   the user asked for it.
/// * `test_AC_200_settingOffByDefaultAndPersisted` — the toggle exists, reads off
///   on a fresh install, and the choice survives the app being killed and
///   relaunched.
///
/// The journal is the stub's `/__requests`. An "upload" is a `POST` whose path is
/// exactly `/api/assets`, a "stack" a `POST` whose path is exactly `/api/stacks`
/// (`bulk-upload-check` is neither, and always allowed). Identifiers only, never
/// localized text.
///
/// Identification of the assets is done from the wire, not from names: an erased
/// simulator also ships its own sample photos, and the first backup uploads them
/// too, so "the original" is the asset the stack names beneath the edit.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/edit-stacks.uitest.log \
///         UITests/stubs/immich_stub_edit_stacks.py EditStacksUITests/test_AC_41_editStackedOnOriginal \
///         --erase --media L22-edit-on.png
final class EditStacksUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private static let allowFullAccess = ["Allow Full Access", "Allow Access to All Photos", "Allow All Photos",
                                          "Full Access", "accès complet", "accès à toutes les photos",
                                          "Vollen Zugriff"]
    /// Fragments of Photos' "Allow … to modify this photo?" button: Modify,
    /// Modifier, Modifica, Modificar, Ändern. Fragments, never whole labels — the
    /// system spells its apostrophes U+2019.
    private static let modifyFragments = ["Modif", "Ändern"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
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

    // MARK: - Helpers (copied from LocalLibraryUITests / FreeUpSpaceUITests on purpose: one file per feature)

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenReads() -> String {
        "\(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))"
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

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seededURL = (field.value as? String) ?? ""
        if !seededURL.isEmpty && seededURL != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seededURL.count))
        }
        if (field.value as? String) != stub {
            field.typeText(stub)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        // The CTA sits under the keyboard the URL raised: scrolling dismisses it.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("es900-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: \(screenReads())")
        }
    }

    /// Answers the Photos library prompt with FULL access: XCUITest's own handler
    /// would press its default button ("Add only"), leaving the app without read
    /// access. See `LocalLibraryUITests.installPhotoPromptHandler`.
    private func installPhotoPromptHandler() {
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            let button = alert.buttons.matching(self.labelPredicate(Self.allowFullAccess)).firstMatch
            guard button.exists else { return false }
            button.tap()
            return true
        }
    }

    /// The Photos library prompt, when the Backup screen's first read raises it.
    @discardableResult
    private func allowPhotoAccessIfAsked(timeout: TimeInterval = 2) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fullAccessTokens = ["complet", "Full Access", "Autoriser", "Allow"]
        for host in [springboard.alerts, app.alerts] {
            guard host.firstMatch.waitForExistence(timeout: timeout) else { continue }
            let buttons = host.buttons.allElementsBoundByIndex
            for token in fullAccessTokens {
                if let button = buttons.first(where: { $0.label.contains(token) }) {
                    button.tap()
                    return true
                }
            }
            shot("es00b-unanswerable-system-alert")
            XCTFail("a system alert asked something this scenario cannot answer: \(buttons.map(\.label))")
        }
        return false
    }

    /// Photos' own "Allow … to modify this photo?" alert. The app asks PhotoKit to
    /// change the photo, Photos asks the user, and the app cannot answer: the
    /// scenario has to, or the edit never happens. No alert within the delay is
    /// not a failure (the edit may already have been approved); an alert whose
    /// buttons match nothing is.
    private func allowSystemModification() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var seen: [[String]] = []
        for alerts in [springboard.alerts, app.alerts] {
            guard alerts.firstMatch.waitForExistence(timeout: 8) else { continue }
            let buttons = alerts.firstMatch.buttons.allElementsBoundByIndex
            shot("es10-photos-modify-alert")
            for fragment in Self.modifyFragments {
                if let button = buttons.first(where: { $0.label.contains(fragment) }) {
                    button.tap()
                    return
                }
            }
            seen.append(buttons.map(\.label))
        }
        guard !seen.isEmpty else { return }
        shot("es11-unanswerable-modify-alert")
        XCTFail("Photos asked something with words this scenario does not know. "
                + "Alert buttons seen (springboard, app): \(seen)")
    }

    private func signIn() {
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("es01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        waitForShell()
    }

    private func waitForShell() {
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        dismissWhatsNewIfPresent()
    }

    private func dismissWhatsNewIfPresent() {
        let done = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        guard done.waitForExistence(timeout: 5) else { return }
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !done.exists }, "What's New never closed")
    }

    /// A row of a `Form`, by IDENTIFIER, scrolled into reach.
    private func row(_ identifier: String, swipes: Int = 12) -> XCUIElement {
        let target = element(identifier)
        for _ in 0..<swipes {
            if target.exists && target.isHittable { break }
            app.swipeUp()
            usleep(600_000)
        }
        return target
    }

    /// The "Me" hub, then its Backup row.
    private func openBackup() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "Profile avatar missing")
        hub.tap()
        sleep(4)
        let backupRow = row("backupRow")
        if !backupRow.waitForExistence(timeout: 10) {
            shot("es02b-hub-without-backup-row")
            XCTFail("Backup row missing in the Me hub — screen reads: \(screenReads())")
        }
        backupRow.tap()
        // The Backup screen reads the album list as it appears: iOS may ask for access here.
        allowPhotoAccessIfAsked()
        XCTAssertTrue(element("autoBackupToggle").waitForExistence(timeout: 25),
                      "the Backup screen never loaded — screen reads: \(screenReads())")
    }

    private func backupEditsToggle() -> XCUIElement {
        let toggle = row("backupEditsToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "the 'Also back up edits' toggle is missing — screen reads: \(screenReads())")
        return toggle
    }

    private func enableBackupEdits() {
        let toggle = backupEditsToggle()
        for _ in 0..<3 where (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(toggle.value as? String, "1", "the 'Also back up edits' toggle did not turn on")
    }

    /// The two ways a run can end, as the Backup screen's completion summary
    /// says them (`UploadViewModel.completionSummary`).
    private static let runCompleted = ["Backup complete", "Sauvegarde terminée"]
    private static let runErrored = ["Finished with errors", "Terminé avec des erreurs"]

    /// A manual run asks for the notification permission (the run's outcome is
    /// posted as a local alert). That alert belongs to SpringBoard: left up, it
    /// swallows every swipe the wait below needs to bring "Run now" back into
    /// reach. Copied from `SyncBadgeUITests`.
    private func dismissNotificationsAlertIfPresent(wait: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: wait) else { return }
        for label in ["Allow", "Autoriser", "Erlauben", "Consentir"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    /// Everything a failed wait has to say: which pass, what the progress
    /// section shows, what SpringBoard still holds up, and what reached the stub.
    /// `isEnabled` is only read on a button that exists (XCUITest throws otherwise).
    private func runState(pass: String) -> String {
        let run = element("runBackupButton")
        let cancel = element("cancelBackupButton")
        let runExists = run.exists
        let runEnabled = runExists ? "\(run.isEnabled)" : "n/a"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let alertButtons = alert.exists ? alert.buttons.allElementsBoundByIndex.map(\.label) : []
        return "pass=\(pass) cancelBackupButton.exists=\(cancel.exists) "
            + "runBackupButton.exists=\(runExists) runBackupButton.isEnabled=\(runEnabled) "
            + "springboardAlertButtons=\(alertButtons)"
            + "\nscreen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
            + "\nwire:\n\(describe(stubRequests()))"
    }

    /// Taps "Run now" and waits for the run to end. The end is what the screen
    /// says — "Backup complete" is the run happening, "Finished with errors" is a
    /// failure of its own — not the swap of `cancelBackupButton` back to
    /// `runBackupButton`: that swap can sit below the fold once the completion
    /// summary is drawn, and a SpringBoard alert left up blocks the swipe that
    /// would reach it. Every turn of the wait answers the system alerts a manual
    /// run raises (notifications, Photos). `pass` names the call in failures.
    private func runBackup(pass: String) {
        let run = row("runBackupButton")
        XCTAssertTrue(run.waitForExistence(timeout: 20),
                      "[\(pass)] the Backup screen has no 'Run now' button — screen reads: \(screenReads())")
        XCTAssertTrue(waitUntil(timeout: 20) { run.exists && run.isEnabled },
                      "[\(pass)] 'Run now' is disabled before the run")
        let cancel = element("cancelBackupButton")
        // Every pass follows a fresh launch, so no outcome should be on screen
        // yet. If one is, it belongs to an earlier run: only a run seen going
        // (Cancel up, which replaces the summary) may then be judged by the text.
        let staleOutcome = waitForStaticText(Self.runCompleted + Self.runErrored, timeout: 0.5)
        run.tap()
        if staleOutcome { _ = waitUntil(timeout: 8) { cancel.exists } }

        var completed: Bool?
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            dismissNotificationsAlertIfPresent(wait: 0.5)
            allowPhotoAccessIfAsked(timeout: 0.5)
            // Errors first: the French "Sauvegarde terminée avec des erreurs"
            // (the completion notification) also contains the success phrase.
            if waitForStaticText(Self.runErrored, timeout: 1) { completed = false; break }
            if waitForStaticText(Self.runCompleted, timeout: 2) { completed = true; break }
        }
        guard let completed else {
            shot("es-run-never-ended-\(pass)")
            return XCTFail("the backup run never ended — \(runState(pass: pass))")
        }
        guard completed else {
            shot("es-run-finished-with-errors-\(pass)")
            return XCTFail("the backup run finished with errors — \(runState(pass: pass))")
        }

        // The summary is up, so the engine is idle: "Run now" is back, maybe
        // below the taller summary.
        let back = waitUntil(timeout: 30) {
            self.dismissNotificationsAlertIfPresent(wait: 0.2)
            if cancel.exists { return false }
            if !run.exists { _ = self.row("runBackupButton", swipes: 2) }
            return run.exists && run.isEnabled
        }
        if !back {
            shot("es-run-button-never-back-\(pass)")
            XCTFail("the run reported its outcome but 'Run now' never came back — \(runState(pass: pass))")
        }
        allowPhotoAccessIfAsked(timeout: 0.5)
    }

    // MARK: - Wire

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let checksum: String?
        let filename: String?
        let deviceAssetId: String?
        let assetId: String?
        let assetIds: [String]?
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

    private func uploads() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    private func stacks() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/stacks" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) checksum=\($0.checksum ?? "-") filename=\($0.filename ?? "-") "
                + "assetId=\($0.assetId ?? "-") assetIds=\($0.assetIds ?? [])"
        }.joined(separator: "\n")
    }

    // MARK: - Scenario steps

    /// Sign in, enable the setting when asked, back up once. Returns the uploads
    /// of that first pass.
    private func firstBackup(enablingEdits: Bool) -> [StubRequest] {
        reset()
        setProvider("manual")
        installPhotoPromptHandler()
        app.launch()
        signIn()
        openBackup()
        if enablingEdits { enableBackupEdits() }
        shot("es03-backup-screen")
        runBackup(pass: "first")
        let first = uploads()
        XCTAssertGreaterThanOrEqual(first.count, 1,
                                    "the first backup uploaded nothing — wire:\n\(describe(stubRequests()))")
        XCTAssertTrue(first.allSatisfy { !($0.checksum ?? "").isEmpty && $0.assetId != nil },
                      "an upload carries no checksum or got no id — wire:\n\(describe(first))")
        XCTAssertEqual(stacks().count, 0, "a stack was requested before any edit existed")
        return first
    }

    /// Kills the app, relaunches it with the edit hook, answers Photos' alert, and
    /// waits for the edit to be applied.
    private func editPhotoInPlace(named media: String) {
        app.terminate()
        app.launchArguments = ["-uiTestEditAssetNamed", media]
        app.launch()
        allowSystemModification()
        let applied = element("uiTestEditApplied")
        let failed = element("uiTestEditFailed")
        var outcome = waitUntil(timeout: 30) { applied.exists || failed.exists }
        if !outcome {
            // The alert can come later than the first wait.
            allowSystemModification()
            outcome = waitUntil(timeout: 30) { applied.exists || failed.exists }
        }
        if failed.exists {
            shot("es12-edit-failed")
            XCTFail("the test hook could not edit \(media): \(failed.label)")
        }
        if !applied.exists {
            shot("es13-edit-never-applied")
            XCTFail("the edit of \(media) was never reported applied — screen reads: \(screenReads())")
        }
        shot("es04-edit-applied")
        // The edit must not run again on a later launch of this scenario.
        app.terminate()
        app.launchArguments = []
        app.launch()
        waitForShell()
    }

    // MARK: - AC-41: the edit is backed up, stacked on its original

    func test_AC_41_editStackedOnOriginal() throws {
        let first = firstBackup(enablingEdits: true)
        let knownChecksums = Set(first.compactMap(\.checksum))
        let knownIds = Set(first.compactMap(\.assetId))

        editPhotoInPlace(named: "L22-edit-on.png")
        openBackup()
        XCTAssertEqual((backupEditsToggle().value as? String), "1", "the setting did not survive the relaunch")
        runBackup(pass: "second")

        // One more upload (the edited rendering, a checksum the server never saw)
        // and one stack, edit first.
        XCTAssertTrue(waitUntil(timeout: 60) { self.uploads().count > first.count && self.stacks().count >= 1 },
                      "the second backup did not upload the edit and stack it — wire:\n\(describe(stubRequests()))")
        let all = uploads()
        XCTAssertEqual(all.count, first.count + 1,
                       "the second backup must upload exactly the edit — wire:\n\(describe(all))")
        let edit = all[first.count]
        let editId = try XCTUnwrap(edit.assetId, "the edit's upload got no id")
        XCTAssertFalse(knownChecksums.contains(edit.checksum ?? ""),
                       "the 'edit' carries the original's checksum — wire:\n\(describe(all))")

        let made = stacks()
        XCTAssertEqual(made.count, 1, "expected exactly one POST /api/stacks — wire:\n\(describe(stubRequests()))")
        let ids = try XCTUnwrap(made.first?.assetIds, "the stack request carries no assetIds")
        XCTAssertGreaterThanOrEqual(ids.count, 2, "a stack needs two assets: \(ids)")
        XCTAssertEqual(ids.first, editId, "the edit must head the stack — assetIds: \(ids), edit: \(editId)")
        let originals = ids.dropFirst()
        XCTAssertTrue(originals.allSatisfy { knownIds.contains($0) },
                      "the stack's other assets are not ones the first backup uploaded — assetIds: \(ids), "
                      + "first backup: \(knownIds.sorted())")
        let originalId = try XCTUnwrap(originals.first)

        // The timeline, as the server now builds it: the edit is the tile (with the
        // badge), the original sits beneath it.
        app.terminate()
        app.launchArguments = []
        app.launch()
        waitForShell()
        let photos = app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch
        photos.tap()
        let editTile = element("assetTile_\(editId)")
        if !editTile.waitForExistence(timeout: 40) {
            shot("es901-edit-tile-missing")
            XCTFail("the edit has no tile on the timeline — screen reads: \(screenReads())")
        }
        shot("es05-timeline")
        let badge = element("stackBadge")
        XCTAssertTrue(waitUntil(timeout: 10) { badge.exists }, "the stack head carries no stackBadge")
        XCTAssertTrue(editTile.frame.insetBy(dx: -1, dy: -1).contains(badge.frame),
                      "the stackBadge \(badge.frame) is not on the edit's tile \(editTile.frame)")
        XCTAssertFalse(element("assetTile_\(originalId)").exists,
                       "the original still has a tile of its own beside the stack")
    }

    // MARK: - AC-41: setting off sends nothing

    func test_AC_41_settingOffSendsNothing() throws {
        let first = firstBackup(enablingEdits: false)

        editPhotoInPlace(named: "L22-edit-off.png")
        openBackup()
        XCTAssertEqual((backupEditsToggle().value as? String), "0", "the setting is not off by default")
        runBackup(pass: "second")
        // Absence needs a settle delay: a late upload would land after the run ended.
        Thread.sleep(forTimeInterval: 4)

        XCTAssertEqual(uploads().count, first.count,
                       "an edit was uploaded with the setting off — wire:\n\(describe(stubRequests()))")
        XCTAssertEqual(stacks().count, 0,
                       "a stack was requested with the setting off — wire:\n\(describe(stubRequests()))")
    }

    // MARK: - AC-200: off by default, persisted

    func test_AC_200_settingOffByDefaultAndPersisted() throws {
        reset()
        setProvider("manual")
        installPhotoPromptHandler()
        app.launch()
        signIn()
        openBackup()

        let toggle = backupEditsToggle()
        XCTAssertEqual(toggle.value as? String, "0", "'Also back up edits' must be off by default")
        enableBackupEdits()
        shot("es06-toggle-on")
        // Let the setting reach its store before the kill.
        Thread.sleep(forTimeInterval: 2)

        app.terminate()
        app.launch()
        waitForShell()
        openBackup()
        XCTAssertEqual(backupEditsToggle().value as? String, "1",
                       "the setting did not survive a relaunch")
    }
}
