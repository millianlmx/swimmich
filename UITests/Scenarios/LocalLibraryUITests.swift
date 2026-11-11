import XCTest

/// End-to-end scenario for "On this device" (gap G3) — the local library, and the
/// one question it asks the server.
///
/// It drives the real app: onboarding → SSO → the "Me" hub → "On this device",
/// against three media seeded into the slot's Photos library by the launcher.
/// What it proves is the *screen and the wire together*:
///
/// * the three seeded media are listed, and the summary counts them (3) while the
///   second column shows the server's own totals — two different sources, so a
///   screen reading the wrong one is visible;
/// * "not on the server" comes from `POST /api/assets/bulk-upload-check`: the stub
///   rejects exactly one asset and accepts the others, and the chip must follow
///   THAT answer per asset (the rejected id is read off the wire, never guessed);
/// * before the check, no tile carries the chip — "no answer" must not read as
///   "already saved";
/// * checking sends nothing but the check itself;
/// * Upload sends exactly the assets the server reported missing, one
///   `POST /api/assets` each, none of the saved one;
/// * and a refused Photos library shows the access state with no tile, never an
///   empty grid (`test_localLibraryAccessDenied`).
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, seeds the media, grants Photos, and refuses a
/// scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/local-library.uitest.log \
///         UITests/stubs/immich_stub_local_library.py LocalLibraryUITests/test_localLibrary \
///         --erase --media /tmp/ll-a.png --media /tmp/ll-b.png --media /tmp/ll-c.png
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/access-denied.uitest.log \
///         UITests/stubs/immich_stub_local_library.py LocalLibraryUITests/test_localLibraryAccessDenied \
///         --erase --no-photos-grant
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// server statistics, ordinary timeline, real PNG thumbnails) and adds the two
/// routes the feature owns; see its docstring.
final class LocalLibraryUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// How many media the run seeds into the slot's Photos library
    /// (`--media …` three times, on a device `--erase` wiped first). Declared,
    /// not assumed: the summary and the grid are both asserted against it.
    private let seeded = 3

    // The copy the screen uses. The repo's own simulator is German and the slots
    // are English, and every one of these strings is in the catalogue — so a
    // scenario that hard-codes one language is a scenario that fails on the other
    // machine. Matched by phrase, never by an exact sentence.
    private static let notOnServer = ["Not on the server", "Absent du serveur", "Nicht auf dem Server"]
    private static let onServer = ["On the server", "Sur le serveur", "Auf dem Server"]
    private static let selectedWords = ["Selected", "Sélectionné", "Ausgewählt"]
    private static let accessOff = ["Photo library access is off",
                                    "L'accès à la photothèque est désactivé",
                                    "Zugriff auf die Mediathek ist deaktiviert"]
    private static let emptyLibrary = ["Nothing here yet", "Rien pour l'instant", "Noch nichts hier"]
    private static let allowAccess = ["Allow access", "Autoriser l'accès", "Zugriff erlauben"]
    private static let openSettings = ["Open Settings", "Ouvrir les réglages", "Einstellungen öffnen"]
    private static let denyLabels = ["Don't Allow", "Do Not Allow", "Ne pas autoriser", "Nicht erlauben"]
    /// "Full access" — what a library screen needs, and what a slot is never
    /// answered for by itself: iOS words it per version and per language (the slots
    /// run French), and its French labels carry a TYPOGRAPHIC apostrophe
    /// ("Autoriser l’accès complet"), so a phrase with a straight one matches
    /// nothing — measured, and it cost a run: the alert fell through to XCUITest's
    /// default handler, which answers it with its default button, "Ajout uniquement"
    /// ("add only"), leaving the app without read access. Hence fragments that
    /// contain no apostrophe at all.
    private static let allowFullAccess = ["Allow Full Access", "Allow Access to All Photos", "Allow All Photos",
                                          "Full Access", "accès complet", "accès à toutes les photos",
                                          "Vollen Zugriff"]

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
    // Copied from `RecentlyTakenUITests` (itself copied from
    // `ImmichRenderScreenshots`) on purpose: the shared file is frozen and its
    // helpers are `private`, and extracting them would be a second convention
    // next to the existing one — the harness rule is one file per feature,
    // helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log, so no
    /// assertion below can be satisfied by a previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks.
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

    /// The onboarding copy is localized (issue #21), and the repo's own simulator
    /// is in German while the runs use English slots: a walk accepts both, never
    /// one hard-coded language.
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

    /// A bounded poll. `sleep` alone is not an expectation; this one has a
    /// deadline and a failing assertion behind it.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
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

    /// The provider page lives in `SafariViewService`, a separate process, so its
    /// "Authorize" link is not in the app's own accessibility tree.
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
            shot("ll900-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// Chooses the answer this scenario needs on the Photos alert.
    ///
    /// Not optional: XCUITest's OWN interruption handler dismisses that alert by
    /// its DEFAULT button — "Ajout uniquement" ("add only") — which grants no read
    /// access, and it gets there before an explicit `alert.buttons[...].tap()`
    /// ever sees the alert (measured: the app stayed unauthorised, the grid stayed
    /// empty, and the scenario's later tap found no alert at all). A registered
    /// monitor is consulted first, so this one answers instead.
    private func installPhotoPromptHandler(allowing: Bool) {
        let phrases = allowing ? Self.allowFullAccess : Self.denyLabels
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            // The alert's own buttons are printed on every outcome: a phrase list
            // that stops matching (a reworded iOS alert) must be visible in the log
            // rather than silent — the fallback is XCUITest's default handler, which
            // answers with a button this scenario does not want.
            let offered = alert.buttons.allElementsBoundByIndex.map { $0.label }
            let button = alert.buttons.matching(self.labelPredicate(phrases)).firstMatch
            guard button.exists else {
                print("PHOTOS-PROMPT unmatched (allowing: \(allowing)) — offered: \(offered)")
                return false
            }
            print("PHOTOS-PROMPT answering “\(button.label)” (allowing: \(allowing)) — offered: \(offered)")
            button.tap()
            return true
        }
    }

    /// Onboarding → OAuth → the authenticated shell. A persisted Keychain session
    /// skips the walk instead of failing, so re-running on a warm slot stays
    /// useful; the launcher's refusal of `skipped` only concerns the stub being
    /// absent.
    private func signIn() {
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("ll01-welcome")
            walkOnboardingToLogin()
            shot("ll02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    private func screenReads() -> String {
        "\(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))"
    }

    /// The shell, with nothing on top of it. A fresh install presents "What's New"
    /// (gap G23) OVER the shell, and a modal swallows every tap — the hub then
    /// never opens and the failure reads as a missing row. The first timeline tile
    /// is what proves the shell is really up (and that the app is talking to THIS
    /// stub, not to a session persisted against another run's port).
    private func settleOnShell() {
        if !tile("aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40) {
            shot("ll901-timeline-never-rendered")
            XCTFail("the timeline never rendered — screen reads: \(screenReads())")
        }
        shot("ll03-timeline")
        dismissWhatsNewIfPresent()
    }

    private var whatsNewDone: XCUIElement {
        app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
    }

    /// A modal on top of the shell eats every tap, so it is dismissed before the
    /// hub is reached for. Its Done button carries an identifier because its label
    /// is translated.
    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        shot("ll04-whats-new")
        whatsNewDone.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.whatsNewDone.exists }, "What's New never closed")
    }

    /// The "Me" hub, then "On this device". A `Form` only publishes what it
    /// rendered, and Management sits far below the fold, so the row is scrolled
    /// into view — by IDENTIFIER, never by label ("On this device" reads
    /// "Sur cet appareil" on a French slot, "Auf diesem Gerät" on the repo's own
    /// simulator).
    ///
    /// Two bounded attempts on purpose: on a first launch the "What's New" sheet
    /// can land between the timeline and the avatar tap, and the tap then lands on
    /// the modal instead of the hub (measured — this is what failed the first run
    /// of this scenario, with the hub's row assertion reading as "no hub").
    private func openLocalLibrary() {
        let row = app.buttons.matching(identifier: "localLibraryRow").firstMatch
        for _ in 0..<2 {
            dismissWhatsNewIfPresent()
            let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
            XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
            hub.tap()
            // The sheet animates in and its Form is not published before it does.
            Thread.sleep(forTimeInterval: 4)
            if whatsNewDone.exists { continue }

            var swipes = 0
            while !row.isHittable && swipes < 24 {
                app.swipeUp()
                swipes += 1
                Thread.sleep(forTimeInterval: 0.8)
            }
            if row.isHittable {
                shot("ll05-me-hub")
                row.tap()
                XCTAssertTrue(app.staticTexts.matching(identifier: "localAssetGrid").firstMatch
                    .waitForExistence(timeout: 30),
                              "the On this device screen never loaded — screen reads: \(screenReads())")
                return
            }
        }
        shot("ll902-hub-without-local-library-row")
        XCTFail("the On this device row is not reachable in the Me hub — screen reads: \(screenReads()) — "
                + "hub buttons: \(app.buttons.allElementsBoundByIndex.prefix(60).map(\.identifier))")
    }

    // MARK: - The local tiles

    private enum Verdict: String {
        /// No answer yet: the tile must show NO chip.
        case none
        /// The server reported it already holds the file.
        case saved
        /// The server reported it does not have the file.
        case localOnly
    }

    private struct Cell {
        /// What the grid names the tile: `localAssetCell_<PHAsset id>`.
        let identifier: String
        /// The PHAsset localIdentifier itself — the id the API receives, and the one
        /// the stub's answers name. Assertions compare THIS with the wire.
        let id: String
        /// The cell combines its children into one element, so the chip (an
        /// `Image` inside) is only readable here or in a screenshot.
        let label: String

        var isSelected: Bool {
            LocalLibraryUITests.selectedWords.contains { label.contains($0) }
        }

        var verdict: Verdict {
            for phrase in LocalLibraryUITests.notOnServer where label.contains(phrase) { return .localOnly }
            for phrase in LocalLibraryUITests.onServer where label.contains(phrase) { return .saved }
            return .none
        }
    }

    private static let cellPrefix = "localAssetCell_"

    private func localCells() -> [Cell] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", Self.cellPrefix)
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            .map { element in
                Cell(identifier: element.identifier,
                     id: String(element.identifier.dropFirst(Self.cellPrefix.count)),
                     label: element.label)
            }
    }

    private func cellElement(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.cellPrefix + id).firstMatch
    }

    private func labels(of cells: [Cell]) -> String {
        cells.map { "\($0.identifier) → “\($0.label)”" }.joined(separator: "\n")
    }

    /// The leading integer of a count label ("2 not on server" / "12 absents du
    /// serveur"). The sentence around it is localized; the number is not.
    private func count(in label: String) -> Int? {
        Int(label.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log, including the fields the feature stub
    /// attached with `req.note(...)`.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let checked: [String]?
        let checksums: [String]?
        let rejected: [String]?
        let accepted: [String]?
        let deviceAssetId: String?
        let fileCreatedAt: String?
        let filename: String?
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

    /// The uploads the app sent — one `POST /api/assets` per asset.
    private func uploadRequests() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params) deviceAssetId=\($0.deviceAssetId ?? "-")" }
            .joined(separator: "\n")
    }

    /// The account's own counts, read from the stub by the scenario rather than
    /// hard-coded: the second column of the screen must show exactly what
    /// `/api/assets/statistics` answered — `images + videos`, never `total`
    /// (which also counts audio and other media).
    private func stubStatisticsTotal() -> Int? {
        guard let url = URL(string: "\(stub)/api/assets/statistics") else { return nil }
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 6) == .success,
              let stats = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let photos = stats["images"] as? Int, let videos = stats["videos"] as? Int
        else { return nil }
        return photos + videos
    }

    // MARK: - Scenario: the library, the verdict, the upload

    func test_localLibrary() throws {
        reset()
        setProvider("manual")
        installPhotoPromptHandler(allowing: true)
        app.launch()
        signIn()
        settleOnShell()
        openLocalLibrary()

        // MARK: The screen reads the DEVICE

        // The run declares the slot's Photos permission (`uitest.sh` grants it), but
        // a device this run just erased has never been asked for it. The screen
        // must then offer the request rather than draw an empty grid — and this is
        // where a user answers it, on the system alert.
        allowPhotosIfAsked()

        let deviceColumn = app.staticTexts.matching(identifier: "localLibrarySummary").firstMatch
        XCTAssertTrue(deviceColumn.waitForExistence(timeout: 20), "no device column on the summary card")
        XCTAssertTrue(waitUntil(timeout: 30) {
            self.localCells().count >= self.seeded
        }, "the device library lists \(localCells().count) tiles, the run seeded \(seeded) — "
           + "access refused: \(waitForStaticText(Self.accessOff, timeout: 1)), "
           + "empty library: \(waitForStaticText(Self.emptyLibrary, timeout: 1)) — screen reads: \(screenReads())"
           + "\n\(labels(of: localCells()))")
        let listed = localCells()
        XCTAssertEqual(count(in: deviceColumn.label), listed.count,
                       "the device column reads “\(deviceColumn.label)” while the grid lists \(listed.count) tiles")

        // MARK: The screen reads the SERVER, through the route the Profile storage
        // section reads (the account's own counts) — a second source, so a wrong one shows.

        let remoteColumn = app.staticTexts.matching(identifier: "localLibraryRemoteSummary").firstMatch
        XCTAssertTrue(remoteColumn.waitForExistence(timeout: 15), "no server column on the summary card")
        guard let expectedRemote = stubStatisticsTotal() else {
            return XCTFail("the stub did not answer /api/assets/statistics")
        }
        XCTAssertTrue(waitUntil(timeout: 20) {
            remoteColumn.label == "\(expectedRemote)"
        }, "the server column reads “\(remoteColumn.label)”, the API answered \(expectedRemote)")

        // Before the server is asked, NO tile may carry the chip: "no answer" and
        // "already saved" are exactly the two things this screen exists to keep
        // apart.
        XCTAssertTrue(localCells().allSatisfy { $0.verdict == .none },
                      "a tile showed a verdict before the server was asked:\n\(labels(of: localCells()))")
        shot("ll06-on-this-device")

        // MARK: Selecting the three

        // The three NEWEST tiles are the three the run seeded: `fetchAssets()`
        // sorts by creation date descending, and the media were imported when the
        // run started while the simulator's own samples are years old. What is
        // asserted below never depends on this order — every verdict is read per
        // asset id, and those ids come from the wire.
        let ids = Array(localCells().prefix(seeded).map(\.id))
        XCTAssertEqual(ids.count, seeded, "the grid lists fewer tiles than the run seeded")
        for id in ids {
            cellElement(id).tap()
            XCTAssertTrue(waitUntil(timeout: 5) {
                self.localCells().first { $0.id == id }?.isSelected == true
            }, "tapping tile \(id) did not select it:\n\(labels(of: localCells()))")
        }
        XCTAssertTrue(ids.allSatisfy { id in localCells().first { $0.id == id }?.isSelected == true },
                      "not every selected tile reads as selected:\n\(labels(of: localCells()))")
        shot("ll07-three-selected")

        // MARK: The check — the verdict comes from the server, per asset

        let check = app.buttons.matching(identifier: "checkSelectionButton").firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 15), "the selection bar's Check button is missing")
        check.tap()

        let localOnlyValue = app.staticTexts.matching(identifier: "localOnlyValue").firstMatch
        XCTAssertTrue(localOnlyValue.waitForExistence(timeout: 90),
                      "the check never produced a verdict on screen")
        let savedValue = app.staticTexts.matching(identifier: "savedValue").firstMatch
        XCTAssertTrue(savedValue.waitForExistence(timeout: 15), "the bar shows no saved count")
        shot("ll08-checked")

        // The check itself: one request for the whole batch, and nothing else.
        let checks = stubRequests().filter { $0.method == "POST" && $0.path == "/api/assets/bulk-upload-check" }
        XCTAssertEqual(checks.count, 1,
                       "the three picked assets must travel in ONE check — got:\n\(describe(checks))")
        XCTAssertTrue(uploadRequests().isEmpty,
                      "checking must not send anything — got:\n\(describe(uploadRequests()))")
        guard let checked = checks.first,
              let checkedIDs = checked.checked,
              let rejected = checked.rejected,
              let accepted = checked.accepted else {
            return XCTFail("the check request carries no item list — got: \(describe(checks))")
        }
        print("WIRE-CHECK checked=\(checkedIDs) rejected=\(rejected) accepted=\(accepted) checksums=\(checked.checksums ?? [])")
        XCTAssertEqual(checkedIDs.count, seeded, "the check must carry all \(seeded) picked assets — got \(checkedIDs)")
        XCTAssertEqual(Set(checkedIDs), Set(ids), "the check must carry the assets the grid shows")
        XCTAssertEqual(rejected.count, 1, "this stub rejects exactly one asset — got \(rejected)")
        XCTAssertEqual(accepted.count, seeded - 1, "the stub accepts the rest — got \(accepted)")
        if let sums = checked.checksums {
            XCTAssertEqual(sums.count, seeded, "one checksum per checked asset — got \(sums)")
            XCTAssertEqual(Set(sums).count, seeded,
                           "three different originals must hash to three different checksums — got \(sums)")
            XCTAssertTrue(sums.allSatisfy { $0.count >= 20 },
                          "the server dedups on these; an empty one asks it to dedup on nothing — got \(sums)")
        }

        // The chip follows the SERVER'S ANSWER, asset by asset. The rejected id is
        // taken from the wire, never guessed from the grid's order.
        XCTAssertEqual(count(in: localOnlyValue.label), accepted.count,
                       "the bar reads “\(localOnlyValue.label)”, the server accepted \(accepted.count)")
        XCTAssertEqual(count(in: savedValue.label), rejected.count,
                       "the bar reads “\(savedValue.label)”, the server rejected \(rejected.count)")
        for id in rejected {
            XCTAssertEqual(localCells().first { $0.id == id }?.verdict, .saved,
                           "the asset the server already holds must read as ON it — \(id):\n\(labels(of: localCells()))")
        }
        for id in accepted {
            XCTAssertEqual(localCells().first { $0.id == id }?.verdict, .localOnly,
                           "the asset the server lacks must carry “not on the server” — \(id):\n\(labels(of: localCells()))")
        }
        XCTAssertEqual(localCells().filter { $0.verdict == .localOnly }.count, accepted.count,
                      "exactly the assets the server lacks may carry the chip:\n\(labels(of: localCells()))")

        // MARK: Upload — only what the server said it lacks

        let upload = app.buttons.matching(identifier: "uploadSelectionButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15), "the selection bar's Upload button is missing")
        XCTAssertTrue(upload.isEnabled, "Upload must be offered once the check found assets to send")
        upload.tap()

        XCTAssertTrue(waitUntil(timeout: 120) {
            self.count(in: localOnlyValue.label) == 0
        }, "after the upload the bar still reads “\(localOnlyValue.label)”")
        XCTAssertEqual(count(in: savedValue.label), seeded,
                       "after the upload every asset is on the server — bar reads “\(savedValue.label)”")
        XCTAssertTrue(localCells().allSatisfy { $0.verdict == .saved },
                      "a tile still reads as missing from the server:\n\(labels(of: localCells()))")
        shot("ll09-uploaded")

        let uploads = uploadRequests()
        let sentIDs = uploads.compactMap(\.deviceAssetId)
        print("WIRE-UPLOAD \(uploads.map { "\($0.deviceAssetId ?? "-") ← \($0.filename ?? "-") @ \($0.fileCreatedAt ?? "-")" })")
        XCTAssertEqual(sentIDs.count, accepted.count,
                       "exactly the assets the server lacks may be sent — sent \(sentIDs)\n\(describe(uploads))")
        XCTAssertEqual(Set(sentIDs), Set(accepted),
                       "the uploaded set is not the accepted set — sent \(sentIDs), accepted \(accepted)")
        XCTAssertFalse(sentIDs.contains { rejected.contains($0) },
                       "the asset the server already held was sent AGAIN: \(sentIDs) vs rejected \(rejected)")
        XCTAssertTrue(uploads.allSatisfy { ($0.filename ?? "").isEmpty == false },
                      "an upload arrived without a file name — the multipart body is malformed:\n\(describe(uploads))")

        // Identity of the media, taken from the one field that carries it: the run
        // seeded its media minutes ago, so their creation year is this one, while
        // the device's OWN sample photos — six of them, present even on a device
        // the run erased — are dated 2009-2018. And a name proves nothing here:
        // `simctl addmedia` renames the files on import (`ll-a.png` lands in DCIM as
        // `IMG_0007.PNG`). So the two sent assets must be today's files.
        let year = String(Calendar.current.component(.year, from: Date()))
        for upload in uploads {
            XCTAssertEqual(upload.fileCreatedAt?.prefix(4), Substring(year),
                           "the asset sent to the server is not one of the media this run seeded — "
                           + "its creation date is \(upload.fileCreatedAt ?? "missing"):\n\(describe(uploads))")
        }
    }

    // MARK: - Scenario: the library that cannot be read

    /// The run declares its device: `--no-photos-grant --erase` leaves the slot
    /// with Photos never granted, so the screen must say so. Depending on what the
    /// TCC row looks like when the app asks, iOS either prompts (never asked) or
    /// reports the refusal straight away — both are covered here, and both must
    /// end on the same screen: the access state, a way to Settings, and NO tile.
    func test_localLibraryAccessDenied() throws {
        reset()
        setProvider("manual")
        installPhotoPromptHandler(allowing: false)
        app.launch()
        signIn()
        settleOnShell()
        openLocalLibrary()

        XCTAssertTrue(waitForStaticText(Self.accessOff, timeout: 30),
                      "a library without Photos access must say so — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("ll10-access-required")

        // The counts must not claim a library it cannot see, and no tile may be
        // rendered: "no permission" and "no photos" are otherwise the same picture.
        let deviceColumn = app.staticTexts.matching(identifier: "localLibrarySummary").firstMatch
        XCTAssertTrue(deviceColumn.waitForExistence(timeout: 15), "no device column on the summary card")
        XCTAssertEqual(deviceColumn.label, "0", "an unreadable library must not be counted")
        XCTAssertEqual(localCells().count, 0, "tiles were listed without Photos access:\n\(labels(of: localCells()))")

        // Never asked: the screen offers the request, and the refusal is answered
        // on the system alert (it belongs to SpringBoard, not to the app). Already
        // refused: iOS will not ask twice, so Settings is the only way forward.
        let allow = app.buttons.matching(labelPredicate(Self.allowAccess)).firstMatch
        if allow.waitForExistence(timeout: 8) {
            allow.tap()
            answerPhotosPrompt(allowing: false, timeout: 15)
            shot("ll11-photos-prompt")
        }
        let settings = app.buttons.matching(labelPredicate(Self.openSettings)).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30),
                      "a refused library must offer Settings — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertEqual(localCells().count, 0, "a tile appeared after the refusal:\n\(labels(of: localCells()))")
        shot("ll12-access-refused")
    }

    /// Answers the Photos permission alert IF it is there. It is a system alert
    /// (`SpringBoard`) and its buttons are worded per iOS version, so the answer is
    /// matched by phrase and the alert's own buttons are quoted when none matches.
    ///
    /// No alert is the normal case — the launcher grants Photos to the installed app
    /// before the run — and it is NOT a failure: what these scenarios assert is the
    /// outcome (the library lists the media, or the screen offers Settings), never
    /// the alert. A monitor that never fires must not fail a run.
    @discardableResult
    private func answerPhotosPrompt(allowing: Bool, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let hosts: [XCUIApplication] = [springboard, app]
        for host in hosts {
            let alert = host.alerts.firstMatch
            guard alert.waitForExistence(timeout: timeout) else { continue }
            let phrases = allowing ? Self.allowFullAccess : Self.denyLabels
            let button = alert.buttons.matching(labelPredicate(phrases)).firstMatch
            guard button.exists else {
                let offered = alert.buttons.allElementsBoundByIndex.map { $0.label }
                XCTFail("the Photos alert offers no \(allowing ? "allowance" : "refusal") button — "
                        + "it offers: \(offered)")
                return false
            }
            print("PHOTOS-PROMPT answering “\(button.label)” from the test (allowing: \(allowing))")
            button.tap()
            return true
        }
        return false
    }

    /// The screen's request, answered when it is offered. A device whose Photos
    /// library was never granted starts `.notDetermined`, and the screen is the one
    /// that asks — so the scenario follows the user's path instead of depending on
    /// the launcher's standing grant.
    private func allowPhotosIfAsked() {
        let allow = app.buttons.matching(labelPredicate(Self.allowAccess)).firstMatch
        guard allow.waitForExistence(timeout: 8) else { return }
        shot("ll06b-photos-request")
        allow.tap()
        answerPhotosPrompt(allowing: true, timeout: 8)
        shot("ll06c-after-the-photos-request")
    }
}
