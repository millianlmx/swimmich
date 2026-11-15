import XCTest

/// End-to-end scenario for "Free Up Space" (gap G1) — the batch's one
/// DESTRUCTIVE feature, and the only scenario here whose failure mode is losing
/// a photo rather than painting a wrong pixel.
///
/// The feature removes local originals that Immich already holds. Its safety
/// property is not "the screen shows a number": it is that the set of files it
/// offers is the intersection of
///
///   * what this device has (a `PHAsset` walk), and
///   * what the SERVER has CONFIRMED it has (`bulk-upload-check` → `reject`).
///
/// The ledger alone knows only what was uploaded once — an asset deleted
/// server-side stays in it — so a scan reading the ledger would offer an asset
/// whose only remaining copy is on the device, and deleting it would destroy the
/// last copy. That is the bug this scenario is built to catch, and the fixture
/// is built to make it reachable:
///
///   1. two photos are seeded into the slot's library (`--erase --media`, the
///      media dated 2020 so a past cutoff can reach them),
///   2. the app backs them up for real — both upload — so its ledger tracks two
///      assets with two checksums,
///   3. `GET /control/held` then tells the stub to hold only ONE of the two:
///      the other stands for "gone server-side since the backup",
///   4. the scan must therefore offer exactly one asset — the confirmed one —
///      and must refuse to offer the other, ever.
///
/// The library is NOT just the two seeded photos: an erased device ships its own
/// sample photos, which this run backs up as well (measured). Everything below
/// is therefore derived from the wire — which assets were uploaded, with which
/// creation dates — and never from an expected total.
///
/// Both halves are asserted: the screen (which asset the review lists, by its
/// own identifier) and the wire (which asset the server was asked about, and the
/// deletion that never goes to the server at all).
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/free-up-space.uitest.log \
///         UITests/stubs/immich_stub_free_up_space.py \
///         FreeUpSpaceUITests/test_freeUpSpace \
///         --erase --media /tmp/media-a.png --media /tmp/media-b.png
///
/// `--erase` is required, not a convenience: the scenario counts what is on the
/// device, and a shared slot keeps its Photos library, its defaults and its
/// ledger from every previous run.
final class FreeUpSpaceUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

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
    // `ImmichRenderScreenshots`) on purpose: those helpers are `private`, and
    // the shared file is frozen. Extracting them into a shared support file
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
            shot("f02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// The "Me" hub is a sheet presented from the avatar.
    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    /// A row of a `Form`, by IDENTIFIER and never by label (the label is
    /// localized; the hub's Management section is long, and a `Form` only
    /// publishes what it has rendered).
    private func row(_ identifier: String, swipes: Int = 12) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        // Existence is not enough: a row below the fold exists and still cannot
        // be tapped, and a `Form` only publishes what it has rendered.
        for _ in 0..<swipes {
            if element.exists && element.isHittable { break }
            app.swipeUp()
            usleep(600_000)
        }
        return element
    }

    private func back(_ reason: String) {
        let button = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), reason)
        button.tap()
        sleep(2)
    }

    /// Everything an element publishes, as one string — the raw material of
    /// `rowNumber`, and what a failing assertion prints so the run says what the
    /// screen actually showed instead of only what was expected.
    private func rowText(_ identifier: String) -> String {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.exists else { return "<\(identifier) is absent>" }
        // SwiftUI hands a `LabeledContent`'s value over in `value` on one OS
        // version, folds it into `label` ("To delete, 1") on another, and
        // publishes the two as separate `Text`s under a plain container on a
        // third: all three are read, so the assertion is about the number the
        // screen shows and not about how it was rendered.
        return ([(element.value as? String) ?? "", element.label]
            + element.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " ")
    }

    /// The first integer an element publishes — a count row's value.
    private func rowNumber(_ identifier: String) -> Int? {
        rowText(identifier)
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first { !$0.isEmpty }
            .flatMap { Int($0) }
    }

    /// Waits for `body` to produce a value. Never a bare `sleep`: every wait in
    /// this scenario is bounded and re-tried.
    private func poll<T>(_ timeout: TimeInterval = 60, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            usleep(500_000)
        }
        return body()
    }

    // MARK: - Wire

    /// The part of a `bulk-upload-check` body this scenario needs: which device
    /// assets the app asked the server about, in the app's own order.
    private struct BulkCheckBody: Decodable {
        struct Item: Decodable {
            let id: String
            let checksum: String
        }
        let assets: [Item]
    }

    /// One entry of the stub's request log. `body` is decoded leniently: an
    /// upload carries a multipart body the stub keeps as `{"raw": …}`, and a
    /// strict decode of the whole log would then throw and report "no requests"
    /// — a fixture bug that reads as a missing feature.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let body: BulkCheckBody?
        /// Lifted from an upload's multipart body by the stub (`req.note`): the
        /// two fields that name the media a run put on the server.
        let deviceAssetId: String?
        let fileCreatedAt: String?

        private enum CodingKeys: String, CodingKey {
            case method, path, params, body, deviceAssetId, fileCreatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            path = try container.decode(String.self, forKey: .path)
            params = (try? container.decode([String: String].self, forKey: .params)) ?? [:]
            body = try? container.decodeIfPresent(BulkCheckBody.self, forKey: .body)
            // Absent on every route but the upload — and `null` there when the
            // field was not in the body.
            deviceAssetId = try? container.decodeIfPresent(String.self, forKey: .deviceAssetId)
            fileCreatedAt = try? container.decodeIfPresent(String.self, forKey: .fileCreatedAt)
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

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    private func checks() -> [StubRequest] {
        stubRequests().filter { $0.path == "/api/assets/bulk-upload-check" }
    }

    private func uploads() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    /// Tells the stub which device assets this server still holds. Called after
    /// the backup and before the scan: the whole fixture of this scenario.
    private func declareHeld(_ ids: [String]) {
        var components = URLComponents(string: "\(stub)/control/held")!
        components.queryItems = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /control/held")
        XCTAssertTrue(body.contains(ids.first ?? "?"), "the stub did not record what it holds: \(body)")
    }

    // MARK: - Review cells

    /// One cell of the review grid, by the LOCAL IDENTIFIER the review was built
    /// from. The identity is what makes this scenario's central assertion
    /// possible: "the review lists exactly the asset the server confirmed" is a
    /// statement about *which* asset, and a count of thumbnails cannot say it.
    private func cell(_ localIdentifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "cleanupReviewCell_\(localIdentifier)")
            .firstMatch
    }

    private func reviewCellCount() -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'cleanupReviewCell_'"))
            .allElementsBoundByIndex.count
    }

    // MARK: - Scenario

    func test_freeUpSpace() throws {
        reset()
        setProvider("manual")
        app.launch()

        // MARK: Onboarding → OAuth (a persisted session skips the walk)

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("f01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install (this scenario erases the device) presents "What's
        // New" over the shell, and a modal swallows every tap.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }
        shot("f03-shell")

        // MARK: 1. Back the two seeded photos up, for real

        openHub()
        let backupRow = row("backupRow")
        if !backupRow.waitForExistence(timeout: 10) {
            shot("f04b-hub-without-backup-row")
            XCTFail("Backup row missing in the Me hub:\n\(app.debugDescription)")
        }
        shot("f04-me-hub")
        backupRow.tap()

        // The Backup screen reads the album list as it appears, which is the
        // app's first READ of the photo library: iOS asks for access here.
        allowPhotoAccessIfAsked()
        shot("f05-backup-screen")

        let runNow = row("runBackupButton")
        XCTAssertTrue(runNow.waitForExistence(timeout: 20),
                      "the Backup screen has no 'Run now' button:\n\(app.debugDescription)")
        runNow.tap()

        // The run is over when the screen says so. Polled rather than waited
        // once, because the two ways it can end are not the same claim: "Backup
        // complete" is the run happening, "Finished with errors" is a different
        // failure and has to be reported as one.
        let completed = ["Backup complete", "Sauvegarde terminée"]
        let errored = ["Finished with errors", "Terminé avec des erreurs"]
        let deadline = Date().addingTimeInterval(180)
        var failed = false
        while Date() < deadline {
            if waitForStaticText(completed, timeout: 2) { break }
            if waitForStaticText(errored, timeout: 1) { failed = true; break }
            allowPhotoAccessIfAsked(timeout: 0.5)
        }
        XCTAssertFalse(failed, "the backup run finished with errors — screen reads: "
                       + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))"
                       + "\nwire:\n\(describe(stubRequests()))")
        XCTAssertTrue(waitForStaticText(completed, timeout: 1),
                      "the backup run never completed — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))"
                      + "\nwire:\n\(describe(stubRequests()))")
        shot("f06-backup-complete")

        // The ledger this scenario scans is the one that run just wrote — and it
        // is bigger than the two photos the fixture seeded: an ERASED device is
        // not an empty library, it ships its own sample photos, and the run backs
        // those up too (measured). So nothing here may count 2. The seeded pair
        // is identified by the DATE it carries, the one thing `simctl addmedia`
        // preserves (it renames every file to IMG_000N in DCIM).
        let uploaded = uploads()
        let seeded = uploaded.filter { ($0.fileCreatedAt ?? "").hasPrefix("2020-01-") }
        guard let red = seeded.first(where: { ($0.fileCreatedAt ?? "").hasPrefix("2020-01-02") }),
              let blue = seeded.first(where: { ($0.fileCreatedAt ?? "").hasPrefix("2020-01-03") }),
              let confirmedID = red.deviceAssetId,
              let unconfirmedID = blue.deviceAssetId else {
            return XCTFail("the two seeded photos were not uploaded, so the ledger the scan reads does not mention them — uploads:\n\(describe(uploaded))")
        }
        XCTAssertNotEqual(confirmedID, unconfirmedID, "the two seeded photos share a local identifier")

        // Every entry the run wrote, whatever the library held: the scan
        // confronts all of them with the server, and the screen's "Already gone
        // from the server" is their count minus the one confirmed.
        let afterBackup = checks()
        guard let seeding = afterBackup.last, let items = seeding.body?.assets, !items.isEmpty else {
            return XCTFail("the backup never dedup-checked what it uploaded — got:\n\(describe(afterBackup))")
        }
        let ledgerIDs = Set(items.map(\.id))
        XCTAssertTrue(ledgerIDs.isSuperset(of: [confirmedID, unconfirmedID]),
                      "the seeded photos must be ledger entries — the check carries:\n\(describe(afterBackup))")

        // MARK: 2. The server admits it holds only ONE of the two

        // The other stands for an original deleted server-side since the backup:
        // the ledger still lists it, the device still has it, and the server
        // answers `accept` — "I do not have these bytes". Offering it would
        // delete the last copy in existence.
        declareHeld([confirmedID])

        back("no way back from the Backup screen")
        let freeRow = row("freeUpSpaceRow")
        if !freeRow.waitForExistence(timeout: 10) {
            shot("f07b-hub-without-free-row")
            XCTFail("Free Up Space row missing in the Me hub:\n\(app.debugDescription)")
        }
        freeRow.tap()

        // Same first-read prompt as the Backup screen: this screen lists albums
        // as it appears too.
        allowPhotoAccessIfAsked()

        // MARK: 3. Scan

        // "30 days" — the FIRST chip of the row, so it is on screen without
        // scrolling the horizontal picker sideways. Its cutoff is after the
        // seeded photos (2020) and the device's own sample photos (2011), which
        // is all the fixture needs: every preset the screen offers is in the
        // past, which is why the media carries an old date.
        let preset = row("cleanupCutoffPreset_30d", swipes: 2)
        XCTAssertTrue(preset.waitForExistence(timeout: 20),
                      "the cutoff presets are missing:\n\(app.debugDescription)")
        preset.tap()
        shot("f08-cutoff")

        let scan = row("cleanupScanButton")
        XCTAssertTrue(scan.waitForExistence(timeout: 20), "the Scan button is missing")
        scan.tap()

        let scannedRow = app.descendants(matching: .any).matching(identifier: "cleanupScannedValue").firstMatch
        XCTAssertTrue(scannedRow.waitForExistence(timeout: 90),
                      "the scan produced no result — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("f09-scan-result")

        // MARK: 4. The review lists the confirmed asset and only it
        //
        // Checked before the counters below on purpose: this is the claim that
        // matters (which files are about to leave the device), and a failing run
        // must state it first — the counters are the app's own summary and would
        // only describe the same bug second-hand.

        let reviewRow = row("cleanupReviewRow", swipes: 2)
        XCTAssertTrue(reviewRow.waitForExistence(timeout: 20),
                      "a candidate was found but the screen offers no review:\n\(app.debugDescription)")
        reviewRow.tap()

        XCTAssertTrue(cell(confirmedID).waitForExistence(timeout: 20),
                      "the review does not list \(confirmedID), the asset the server confirmed it holds — cells: \(reviewCellCount())")
        XCTAssertFalse(cell(unconfirmedID).exists,
                       "the review offers \(unconfirmedID): this server does NOT hold it, so the local original is the only copy left and deleting it destroys it. Cells: \(reviewCellCount())")
        XCTAssertEqual(reviewCellCount(), 1,
                       "the review must offer exactly the confirmed asset")
        // The grid asks Photos for each thumbnail; a shot taken in the same tick
        // catches placeholders instead of the photos themselves.
        sleep(3)
        shot("f10-review")

        back("no way back from the review")

        // MARK: 5. What the scan reports

        // One asset resolved on device (only the confirmed one may be), one
        // offered, and one tracked entry answered `accept` — the guard's own
        // count, which the screen shows as "Already gone from the server".
        XCTAssertEqual(rowNumber("cleanupScannedValue"), 1,
                       "the scan must resolve exactly the one asset this server confirmed — row reads: \(rowText("cleanupScannedValue"))")
        XCTAssertEqual(rowNumber("cleanupToDeleteValue"), 1,
                       "exactly one candidate is expected: this server confirmed one of the tracked entries — row reads: \(rowText("cleanupToDeleteValue"))")
        XCTAssertEqual(rowNumber("cleanupNotOnServerValue"), ledgerIDs.count - 1,
                       "every tracked entry but the confirmed one was answered `accept`, so the screen must say \(ledgerIDs.count - 1) — row reads: \(rowText("cleanupNotOnServerValue"))")
        shot("f11-scan-numbers")

        // MARK: 6. Delete — behind an explicit confirmation, and never on the wire

        let reviewAgain = row("cleanupReviewRow", swipes: 2)
        XCTAssertTrue(reviewAgain.waitForExistence(timeout: 20),
                      "the review is gone after coming back from it:\n\(app.debugDescription)")
        reviewAgain.tap()

        let freeButton = row("cleanupReviewFreeButton", swipes: 1)
        XCTAssertTrue(freeButton.waitForExistence(timeout: 10), "no destructive button on the review")
        freeButton.tap()

        // An alert: iOS 26 lists an identified alert button twice, so it is
        // queried inside the alert.
        let confirm = app.alerts.firstMatch.buttons.matching(identifier: "cleanupReviewConfirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the app did not ask for confirmation before deleting:\n\(app.debugDescription)")
        shot("f12-confirm-dialog")
        confirm.tap()

        // Photos asks its own question on top of the app's dialog, always: an
        // app that deleted without it would be deleting behind the user's back.
        allowSystemDeletion()

        let success = app.alerts.firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 30),
                      "no success alert after the deletion — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(success.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("1") },
                      "the alert does not report one deleted item: "
                      + "\(success.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("f13-deleted")
        let acknowledge = success.buttons.firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 10), "the success alert has no button")
        acknowledge.tap()

        // The deletion is local-only. Immich's own delete route (`DELETE
        // /api/assets`) would remove the copy the feature promises to keep, and
        // a single call to it is a data-loss bug no screen can show.
        let serverDeletes = stubRequests().filter { request in
            request.method == "DELETE" || request.path.hasPrefix("/api/assets/delete")
        }
        XCTAssertTrue(serverDeletes.isEmpty,
                      "Free Up Space must never delete anything server-side — got:\n\(describe(serverDeletes))")

        // MARK: 7. The original is gone from the library

        let scansBefore = checks().count
        let scanAgain = row("cleanupScanButton", swipes: 1)
        XCTAssertTrue(scanAgain.waitForExistence(timeout: 20), "the Scan button is missing after the deletion")
        scanAgain.tap()

        // Anchored on the wire, not on a timer: the second scan is over when it
        // has re-asked the server. And it still asks about BOTH entries — the
        // ledger is deliberately not purged (a restored original must not be
        // re-uploaded), so what makes the second scan empty can only be the
        // LIBRARY, never the ledger.
        let secondCheck = poll(60) { () -> StubRequest? in
            checks().count > scansBefore ? checks().last : nil
        }
        guard let secondCheck, let secondIDs = secondCheck.body?.assets.map(\.id) else {
            return XCTFail("the second scan never asked the server — log:\n\(describe(stubRequests()))")
        }
        XCTAssertEqual(Set(secondIDs), ledgerIDs,
                       "the second scan must still confront EVERY tracked entry with the server — a deletion does not purge the ledger, so what changed can only be the library")

        XCTAssertTrue(row("cleanupScanButton", swipes: 1).isEnabled,
                      "the second scan never finished")
        XCTAssertFalse(app.buttons.matching(identifier: "cleanupReviewRow").firstMatch.exists,
                       "the deleted original is still offered: the review survived the second scan")
        XCTAssertEqual(rowNumber("cleanupToDeleteValue"), nil,
                       "the second scan still finds something to delete, though the only confirmed original is gone from the device — row reads: \(rowText("cleanupToDeleteValue"))")
        shot("f14-second-scan")

        // MARK: 8. The OTHER seeded photo — still on the device, never offered

        // The mirror image of step 4, and the end state of the two media: the
        // server now admits it holds the one it denied, and the second seeded
        // photo — untouched by the deletion, because it was never a candidate —
        // becomes the candidate instead. The two steps together are what says
        // the deletion hit exactly one asset and not "whatever looked similar".
        declareHeld([unconfirmedID])

        let scansBeforeThird = checks().count
        let thirdScan = row("cleanupScanButton", swipes: 1)
        XCTAssertTrue(thirdScan.waitForExistence(timeout: 20), "the Scan button is missing")
        thirdScan.tap()
        XCTAssertNotNil(poll(60) { () -> StubRequest? in
            checks().count > scansBeforeThird ? checks().last : nil
        }, "the third scan never asked the server — log:\n\(describe(stubRequests()))")
        XCTAssertTrue(row("cleanupScanButton", swipes: 1).isEnabled, "the third scan never finished")

        let thirdReview = row("cleanupReviewRow", swipes: 2)
        XCTAssertTrue(thirdReview.waitForExistence(timeout: 20),
                      "the other seeded photo is not offered although the server now confirms it — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        thirdReview.tap()

        XCTAssertTrue(cell(unconfirmedID).waitForExistence(timeout: 20),
                      "the other seeded photo must still be on the device — cells: \(reviewCellCount())")
        XCTAssertFalse(cell(confirmedID).exists,
                       "the deleted original is offered again — cells: \(reviewCellCount())")
        XCTAssertEqual(reviewCellCount(), 1,
                       "one candidate: the seeded photo the server now confirms")
        sleep(3)
        shot("f15-third-review")
    }

    /// The Photos access question, the one alert that decides whether anything
    /// in this scenario can work at all. iOS asks it on the app's first READ of
    /// the library (here: `loadAlbums()` as the Backup screen appears), and its
    /// four buttons are not equivalent: "Add Only" authorises writes and leaves
    /// the library unreadable, so `ensurePhotoAccess()` refuses and the backup
    /// never starts — measured, the screen stays idle and every assertion below
    /// would be about an empty library. XCUITest's automatic alert handling
    /// dismisses an unexpected alert with its FIRST button ("Ajout uniquement"
    /// in this simulator), so the scenario answers the question itself, before
    /// any other query can hand it over.
    @discardableResult
    private func allowPhotoAccessIfAsked(timeout: TimeInterval = 2) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS 26's dialog has exactly three buttons — "Limiter l'accès…",
        // "Autoriser l'accès complet", "Ajout uniquement" — and only the middle
        // one grants READ access. "Ajout uniquement" is what XCUITest's own
        // interrupt handler presses, which leaves the library unreadable and the
        // backup refusing to start.
        //
        // Matched on a FRAGMENT, never on the full label: the system spells its
        // apostrophes as U+2019 ("l’accès"), so a literal copied with a straight
        // quote silently matches nothing — measured, and it cost a run whose
        // failure was the alert's own button list. "complet" is unique to the
        // full-access button; "Autoriser"/"Allow" cover the other wordings.
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
            shot("f00b-unanswerable-system-alert")
            XCTFail("a system alert asked something this scenario cannot answer: "
                    + "\(buttons.map(\.label))")
        }
        return false
    }

    /// The system's own "delete these items?" alert. Photos asks it on behalf of
    /// the app, and the app cannot answer it — the scenario has to, or the
    /// deletion never happens.
    private func allowSystemDeletion() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let destructive = ["Supprimer", "Delete", "Löschen", "Elimina"]
        var seen: [[String]] = []
        for alert in [app.alerts, springboard.alerts] {
            guard alert.firstMatch.waitForExistence(timeout: 8) else {
                seen.append([])
                continue
            }
            // The app's own dialog is not this question: Photos asks "Allow
            // deleting N items?" itself, and this scenario photographs it.
            shot("f12c-photos-delete-alert")
            for label in destructive {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return
                }
            }
            seen.append(alert.buttons.allElementsBoundByIndex.map(\.label))
        }
        shot("f12b-no-system-alert")
        XCTFail("Photos never asked to delete the items, or asked with words this scenario does not know. "
                + "Alert buttons seen (app, springboard): \(seen) — screen reads: "
                + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }
}
