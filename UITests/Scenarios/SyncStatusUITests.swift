import XCTest

/// End-to-end scenario for the "Sync Status" screen (gap G4) — the one screen
/// that reports what the backup run actually did.
///
/// It drives the real app: onboarding → SSO → the sync-status button in the
/// bar → "Sync Status" (empty, nothing recorded yet) → a real backup run
/// against this stub, seeded
/// with two photos → the counters → "Check server" → a fresh open of the same
/// screen. Every figure on that screen is a projection of the ledger, of the
/// run and of the offline index: the scenario therefore asserts on the WIRE what
/// the run and the screen's own action said (`/__requests`: the dedup check, the
/// multipart uploads, the reconciliation), because a screen that showed
/// plausible counters while the ledger was never written would look perfect.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, seeds the photo library and refuses a scenario
/// that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/immich-orchestration/sync-status.uitest.log \
///         UITests/stubs/immich_stub_sync_status.py SyncStatusUITests/test_syncStatus \
///         --erase --media /tmp/immich-sync-status/media/photo-a.png \
///         --media /tmp/immich-sync-status/media/photo-b.png
///
/// `--erase` is not optional: the scenario counts photos AND asserts the screen
/// is empty before any run, so nothing may be left on the shared device by a
/// neighbour (leftover media would add candidates, a leftover ledger would fill
/// the counters before the run).
///
/// The seeded photos are recognised on the wire by the ORIGINAL file name the
/// multipart carries (`filename=photo-a.png`), not by the DCIM name Photos
/// gives them and not by their creation date: `simctl addmedia` dates an
/// imported asset from the file's **birth** time (`stat -f %SB`) and a plain
/// `touch` does not move it, so a date-based check silently expires overnight —
/// measured on 2026-09-16, when the run uploaded both seeded files and a
/// "created today" assertion failed on `createdAt=2026-09-15`. Anything that
/// only needs the library to be non-empty works; the files just have to be real
/// images.
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// ordinary timeline, real PNG thumbnails) and adds the two routes a run needs;
/// see its docstring. It remembers the checksums it was given, so the same
/// `POST /api/assets/bulk-upload-check` answers `accept` during the run and
/// `reject` during "Check server" — the answer a real server gives, and what
/// makes the reconciliation assertion load-bearing.
final class SyncStatusUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The files `uitest.sh --media` seeds into the slot's photo library. Photos
    /// imports them under its own DCIM name, but the app uploads the resource's
    /// ORIGINAL name in the multipart's `filename` field, so the wire keeps the
    /// identity the launcher gave them.
    private let seededFiles = ["photo-a.png", "photo-b.png"]

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
    // Copied from `RecentlyTakenUITests` on purpose: these are `private` there,
    // and the shared `ImmichRenderScreenshots` file is frozen (11 committed
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

    /// The app's copy is localized (issue #21) and the repo's own simulator is
    /// in German while the slots run in French: a walk accepts several
    /// languages, never one hard-coded one. Every *interactive* element below is
    /// matched by identifier for the same reason.
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

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    // MARK: - Screen helpers

    /// A `StatTile`, by the identity `SyncStatusView` gives it. The tile is one
    /// combined accessibility element ("Tracked, 2" / "Suivis, 2"), which is why
    /// every assertion below reads its TEXT and never its title: the title is
    /// translated, the number is not.
    private func statTile(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls until `element` can be tapped. The screen is a `ScrollView` (not
    /// a lazy `Form`), so its elements exist even below the fold — but a tap
    /// needs the element on screen, and the actions sit under eight tiles once a
    /// run has filled the counters.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, swipes: Int = 5) -> XCUIElement {
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            app.swipeUp()
            sleep(1)
        }
        return element
    }

    /// Everything a tile says. SwiftUI merges the tile's title and its value
    /// into the combined element's label; a `LabeledContent` (the two dates)
    /// publishes its value separately. Both are read so no assertion depends on
    /// which of the two carries the text.
    private func tileText(_ identifier: String) -> String {
        let element = statTile(identifier)
        guard element.exists else { return "" }
        let value = (element.value as? String) ?? ""
        return value.isEmpty ? element.label : "\(element.label) \(value)"
    }

    /// The NUMBER a counter tile renders — its last numeric token. `nil` when
    /// the tile is not on screen, which is what the empty state looks like.
    private func statValue(_ identifier: String) -> String? {
        tileText(identifier).split(whereSeparator: { !$0.isNumber }).last.map(String.init)
    }

    /// The eight counters and the two dates, with what they currently read: the
    /// failure message of any assertion below, so a wrong screen is diagnosable
    /// from the log alone.
    private func counters() -> String {
        (["syncStatusTrackedValue", "syncStatusPendingValue", "syncStatusStagedValue",
          "syncStatusUploadedValue", "syncStatusAlreadyOnServerValue", "syncStatusFailedValue",
          "syncStatusOfflineValue", "syncStatusOfflineBytesValue", "syncStatusLastRunValue",
          "syncStatusLastServerCheckValue"] + ["syncStatusEmptyState"])
            .map { "\($0)=\(tileText($0).isEmpty ? "<absent>" : tileText($0))" }
            .joined(separator: "\n")
    }

    /// The screen's empty state: matched by identifier or by its title — a
    /// `ContentUnavailableView` does not reliably keep an identifier put on the
    /// container (measured in `test_09_offlineDownload`).
    private func emptyStateShown() -> Bool {
        if statTile("syncStatusEmptyState").exists { return true }
        return app.staticTexts.matching(labelPredicate(["Nothing to sync yet", "Rien à synchroniser"]))
            .firstMatch.exists
    }

    /// Waits, by polling the accessibility tree, until `condition` holds. The
    /// run finishes on the main actor and the screen re-renders as it goes, so a
    /// fixed sleep would either lie or cost seconds; `RunLoop.run(until:)` keeps
    /// the queries live instead of blocking the process.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string; the rest are the fields the stub's own routes noted about the
    /// payload they received (`checkIds`/`verdicts` for the dedup gate,
    /// `deviceAssetId`/`fileName` for an upload).
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let checkIds: [String]?
        let checksums: [String]?
        let verdicts: [String]?
        let deviceAssetId: String?
        let fileName: String?
        let fileCreatedAt: String?
        let serverAssetId: String?
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

    /// Polls the wire until `take` has something to show, answering the system
    /// prompts a run raises on the way. A manual run asks for two things the
    /// moment it starts: Photos access (`ensurePhotoAccess`, its first act) and
    /// notification permission (the outcome is posted as a local alert). Both
    /// belong to SpringBoard, and an unanswered one is a run that never leaves
    /// the device — with nothing on the wire to say why.
    private func waitForWire(timeout: TimeInterval = 90, _ take: () -> [StubRequest]) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var found = take()
        while found.isEmpty && Date() < deadline {
            answerSystemPromptOnce()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            found = take()
        }
        return found
    }

    /// The run's uploads, once it has uploaded `count` of them.
    private func waitForUploads(from mark: Int, count: Int, timeout: TimeInterval = 120) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var uploads = uploadLog(from: mark)
        while uploads.count < count && Date() < deadline {
            answerSystemPromptOnce()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            uploads = uploadLog(from: mark)
        }
        return uploads
    }

    /// Answers one system prompt if one is up. `BEGINSWITH`, never `CONTAINS`:
    /// "Don't Allow" contains "Allow" and is the opposite answer.
    @discardableResult
    private func answerSystemPromptOnce() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return false }
        let consent = alert.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Allow' OR label BEGINSWITH 'Autoriser' "
                + "OR label BEGINSWITH 'Erlauben' OR label BEGINSWITH 'Zugriff'")).firstMatch
        guard consent.exists else { return false }
        consent.tap()
        return true
    }

    /// Everything the screen currently says. The failure message of any wire
    /// assertion: "no request" has no other explanation on the wire, and an
    /// error badge or a stale tile says which it was.
    private func screenDump() -> String {
        "counters:\n\(counters())\nstatic texts:\n"
            + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) ids=\($0.checkIds ?? []) checksums=\($0.checksums ?? []) "
                + "verdicts=\($0.verdicts ?? []) deviceAssetId=\($0.deviceAssetId ?? "-") "
                + "file=\($0.fileName ?? "-") createdAt=\($0.fileCreatedAt ?? "-") "
                + "serverAssetId=\($0.serverAssetId ?? "-")"
        }.joined(separator: "\n")
    }

    /// Uploads and dedup checks of the log, from `mark` on.
    private func uploadLog(from mark: Int) -> [StubRequest] {
        Array(stubRequests().dropFirst(mark)).filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    private func checkLog(from mark: Int) -> [StubRequest] {
        Array(stubRequests().dropFirst(mark))
            .filter { $0.method == "POST" && $0.path == "/api/assets/bulk-upload-check" }
    }

    /// The requests this screen's own opening produced. The realtime socket
    /// (`RealtimeService`, connected since the OAuth handshake) retries its
    /// WebSocket handshake against `/api/socket.io` in the background whatever
    /// screen is open, so it is named and excluded — the claim is about what the
    /// SCREEN asks for, and the failure message prints everything it did ask.
    private func screenRequests(from mark: Int) -> [StubRequest] {
        Array(stubRequests().dropFirst(mark)).filter { !$0.path.hasPrefix("/api/socket.io") }
    }

    // MARK: - Scenario

    func test_syncStatus() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; with
        // `--erase` the walk always runs.
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
        // modal swallows every tap: the hub would never open under it. Its Done
        // button carries an identifier because its label is translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("s03-whats-new")
            whatsNewDone.tap()
        }

        // The ordinary timeline: the shell's own day, six photos. Its first tile
        // also proves the app is talking to THIS stub — a session persisted
        // against another slot's port would leave the grid empty.
        XCTAssertTrue(tile("aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("s04-timeline")

        // MARK: The bar's sync button → Sync Status, BEFORE any run

        // The entry point is a sibling of the avatar in the bar, not a row of
        // the Me hub: that hub already carries Backup, and a read-out of the
        // ledger sitting under the screen that feeds it read as the same
        // feature stated twice.
        let syncButton = app.buttons.matching(identifier: "syncStatusButton").firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 15), "Sync Status button missing from the bar")
        shot("s04b-sync-button")

        let beforeOpen = stubRequests().count
        syncButton.tap()
        sleep(4) // the sheet animates in; the screen is not hittable before it does

        // Nothing has ever been recorded: the screen says so instead of showing
        // a grid of zeros that would read as a finished, empty library.
        XCTAssertTrue(waitUntil(25, emptyStateShown),
                      "the Sync Status screen must show its empty state before any run — it reads:\n\(counters())")
        XCTAssertNil(statValue("syncStatusTrackedValue"),
                     "no run has happened, no counter may be drawn yet:\n\(counters())")
        shot("s06-sync-status-empty")

        // MARK: On the wire — opening the screen asks the server nothing

        // The figures come from the ledger, the engine and the offline index; a
        // screen that fetched them would be the very bug this card forbids.
        let opened = screenRequests(from: beforeOpen)
        XCTAssertTrue(opened.isEmpty,
                      "opening Sync Status must not produce a request — it reads local state; got:\n\(describe(opened))")

        // MARK: A real backup, run from this screen, against this stub

        let runButton = scrollTo(app.buttons.matching(identifier: "syncStatusRunNow").firstMatch)
        XCTAssertTrue(runButton.waitForExistence(timeout: 15),
                      "no Run now action on the screen:\n\(counters())")
        let beforeRun = stubRequests().count
        runButton.tap()

        // The run's own dedup check is the first thing it puts on the wire, and
        // it is the reference for everything below: the slot's Photos library is
        // not ours alone (a freshly erased simulator ships sample photos of its
        // own), so no expectation here is a hard-coded count.
        let checks = waitForWire(timeout: 120) { self.checkLog(from: beforeRun) }
        XCTAssertEqual(checks.count, 1,
                       "the run must ask the dedup gate once — no request at all means it never started (a system prompt left up, or Photos access refused); screen reads:\n\(screenDump())")
        let checked = checks.first?.checkIds ?? []
        XCTAssertGreaterThanOrEqual(checked.count, seededFiles.count,
                      "the run must check the photos the launcher seeded (plus the device's own) — it checked \(checked.count); screen reads:\n\(screenDump())")
        XCTAssertEqual(Set(checks.first?.verdicts ?? []), ["accept"],
                       "the stub has nothing yet: every checked asset must be uploaded, not skipped — got:\n\(describe(checks))")

        let uploads = waitForUploads(from: beforeRun, count: checked.count)
        XCTAssertEqual(uploads.count, checked.count,
                       "every accepted asset must be uploaded — got:\n\(describe(checks + uploads))\nscreen reads:\n\(screenDump())")
        // The seeded photos are the ones the launcher handed to `simctl
        // addmedia`, and the run names them on the wire: the multipart's
        // `filename` field carries the ORIGINAL name (`photo-a.png`) even though
        // Photos itself imports them under a DCIM name (`IMG_0007.PNG`) — the
        // run publishes the identity the launcher gave them.
        //
        // By name, not by date: a date-based check ("the only photos created
        // today") fails on media born the previous day, and it failed exactly
        // that way on 2026-09-16 while both files had been uploaded — `simctl
        // addmedia` takes the creation date from the file's birth time, not its
        // mtime, so `touch` cannot even repair it.
        let seeded = uploads.filter { seededFiles.contains($0.fileName ?? "") }
        XCTAssertEqual(Set(seeded.compactMap(\.fileName)), Set(seededFiles),
                      "the photos the launcher seeded must be among the uploads — got:\n\(describe(uploads))")
        XCTAssertEqual(Set(uploads.compactMap(\.deviceAssetId)), Set(checked),
                       "the run must upload exactly the assets it checked — got:\n\(describe(checks + uploads))")
        XCTAssertEqual(Set(uploads.compactMap(\.serverAssetId)).count, checked.count,
                       "every upload must become its own server asset — got:\n\(describe(uploads))")
        // On the record: the log keeps what the run really sent, so the report
        // can quote it rather than describe the screen.
        print("WIRE run: \(checks.count) dedup check(s), \(uploads.count) upload(s)")
        for entry in uploads {
            print("WIRE upload: deviceAssetId=\(entry.deviceAssetId ?? "-") file=\(entry.fileName ?? "-") "
                  + "createdAt=\(entry.fileCreatedAt ?? "-") serverAssetId=\(entry.serverAssetId ?? "-")")
        }

        // MARK: The counters mirror the run that just finished

        // The ledger is committed on the main actor as the run settles, so the
        // tile is polled rather than read once.
        let expected = "\(uploads.count)"
        XCTAssertTrue(waitUntil(45) { self.statValue("syncStatusTrackedValue") == expected },
                      "Tracked must count what the ledger recorded — the wire says \(uploads.count) uploads; screen reads:\n\(screenDump())")
        XCTAssertEqual(statValue("syncStatusUploadedValue"), expected,
                       "Uploaded must count this run's uploads:\n\(counters())")
        XCTAssertEqual(statValue("syncStatusAlreadyOnServerValue"), "0",
                       "the stub had none of these photos: nothing may be counted as already there:\n\(counters())")
        XCTAssertEqual(statValue("syncStatusFailedValue"), "0",
                       "no upload failed, so no failure may be shown:\n\(screenDump())")
        XCTAssertEqual(statValue("syncStatusPendingValue"), "0",
                       "the run is over: nothing may still be pending (the run's denominator minus what is settled):\n\(counters())")
        XCTAssertEqual(statValue("syncStatusStagedValue"), "0",
                       "the run is over: nothing may still be waiting in the upload queue:\n\(counters())")
        XCTAssertEqual(statValue("syncStatusOfflineValue"), "0",
                       "this scenario downloaded nothing: the offline index must read empty:\n\(counters())")
        XCTAssertFalse(emptyStateShown(),
                       "with a run recorded the empty state must give way to the counters:\n\(counters())")

        // The run's date, not "Never": the year is the one part of a formatted
        // date that reads the same in every language.
        let year = "\(Calendar.current.component(.year, from: Date()))"
        XCTAssertTrue(tileText("syncStatusLastRunValue").contains(year),
                      "Last run must show the run that just finished (\(year)):\n\(counters())")
        XCTAssertTrue(tileText("syncStatusLastServerCheckValue").contains(year),
                      "the run confronts the ledger with the server before scanning, so the check has a date too:\n\(counters())")
        shot("s07-sync-status-after-run")

        // MARK: "Check server" — the screen's own action, with the ledger's record

        let checkButton = scrollTo(app.buttons.matching(identifier: "syncStatusReconcile").firstMatch)
        XCTAssertTrue(checkButton.waitForExistence(timeout: 15), "no Check server action:\n\(counters())")
        let beforeCheck = stubRequests().count
        checkButton.tap()

        let reconcile = waitForWire(timeout: 90) { self.checkLog(from: beforeCheck) }
        XCTAssertEqual(reconcile.count, 1, "Check server must ask once — got:\n\(describe(reconcile))")
        XCTAssertEqual(Set(reconcile.first?.checkIds ?? []), Set(uploads.compactMap(\.deviceAssetId)),
                       "Check server must re-check exactly the assets the run uploaded:\n\(describe(reconcile))")
        XCTAssertEqual(Set(reconcile.first?.checksums ?? []), Set(checks.first?.checksums ?? []),
                       "the ledger must have kept each asset's checksum: the server recognises an asset by it, and without it every tracked photo would be re-uploaded:\n\(describe(reconcile))")
        XCTAssertEqual(Set(reconcile.first?.verdicts ?? []), ["reject"],
                       "the stub still holds every photo: the check must keep them, not forget them:\n\(describe(reconcile))")
        // A `reject` keeps the entry: the counters must not move. The check is
        // asynchronous — the answer lands after the request — so "it did not
        // move" is only observable by holding the line for a few seconds.
        var trackedHeld = true
        let heldUntil = Date().addingTimeInterval(10)
        while Date() < heldUntil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if statValue("syncStatusTrackedValue") != expected { trackedHeld = false; break }
        }
        XCTAssertTrue(trackedHeld,
                      "a photo the server still has stays tracked: 'Check server' must not forget a reject; screen reads:\n\(counters())")
        shot("s08-sync-status-server-check")

        // MARK: A fresh open — the counters survive a re-render

        let done = app.buttons.matching(identifier: "syncStatusDone").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no way out of the Sync Status sheet")
        done.tap()
        sleep(2)

        let openedAgain = app.buttons.matching(identifier: "syncStatusButton").firstMatch
        XCTAssertTrue(openedAgain.waitForExistence(timeout: 10),
                      "Sync Status button missing from the bar again")
        openedAgain.tap()
        sleep(4) // the sheet animates in again
        XCTAssertTrue(waitUntil(25) { self.statValue("syncStatusTrackedValue") == expected },
                      "a fresh open must show the same counters — it reads:\n\(counters())")
        XCTAssertEqual(statValue("syncStatusUploadedValue"), expected,
                       "a fresh open must show the same run:\n\(counters())")
        XCTAssertTrue(tileText("syncStatusLastRunValue").contains(year),
                      "a fresh open must still date the run:\n\(counters())")
        shot("s09-sync-status-reopened")
    }
}
