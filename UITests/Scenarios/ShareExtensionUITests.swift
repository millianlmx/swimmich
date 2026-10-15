import XCTest

/// End-to-end scenario for the share extension (gap G21).
///
/// It drives the REAL system share sheet, from a real Photos library, into the
/// extension's own process — the only place where the feature is a feature:
/// another process reads the app's session out of the shared keychain, stages
/// the attachment the host app handed it, uploads it to `POST /api/assets` and
/// files it in the chosen album.
///
/// Three things make this scenario worth its runtime, and each of them is an
/// assertion below:
///
/// 1. THE SESSION CROSSES THE PROCESS BOUNDARY. The app signs in against the
///    stub (that is what `AuthViewModel.publishWidgetSession()` mirrors into the
///    shared keychain group), the extension then shows `Stub User · 127.0.0.1`
///    — a label only the keychain item can produce. A share sheet that read
///    nothing would show its signed-out screen instead.
/// 2. THE WIRE CARRIES THE UPLOAD, FROM THE EXTENSION. The app is TERMINATED
///    before Photos is opened, and every request asserted here is dated after
///    that point: the baseline index into the stub's log is what turns "a POST
///    arrived" into "the extension sent it".
/// 3. THE BODY IS THE REAL MULTIPART. The stub parses the parts it received and
///    answers them in `/__requests`: a sheet that sent an empty body, the wrong
///    part name or no Bearer would still paint a green row while uploading
///    nothing a real server could store.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator, stub
/// port and DerivedData, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/share-extension.uitest.log \
///         UITests/stubs/immich_stub_share_extension.py \
///         ShareExtensionUITests/test_shareExtension \
///         --erase --media /tmp/media-share.png
///
/// `--erase` and `--media` are not decoration: an erased device is what makes
/// the run's login a fresh Keychain write, and the seeded file is the one the
/// sheet must show, by name and by byte count, in the row assertion.
final class ShareExtensionUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// Served by `immich_stub_share_extension.py`; the picker's menu must offer
    /// it, and the filing step must name its id.
    private let albumName = "Stub Album"
    private let albumId = "11111111-2222-4333-8444-555555555555"
    /// The id the stub answers to `POST /api/assets`: what the extension must
    /// file, which proves it filed the asset the SERVER named, not its own uuid.
    private let uploadedAssetId = "dddddddd-1111-4111-8111-000000000001"
    /// The token the stub's OAuth handshake hands the app, hence the session the
    /// extension reads: an upload carrying it cannot come from anywhere else.
    private let stubToken = "stub-access-token"
    /// The file `--media` seeded. `simctl addmedia` may rename its extension,
    /// so the stem is what is matched.
    private let seededStem = "media-share"
    /// The seeded PNG's exact size, as the sheet's row must show it.
    private let seededBytes = "178"

    /// Stub requests already logged when the app was terminated. Everything
    /// past it can only have been sent by the extension's own process.
    private var baseline = 0

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

    /// The onboarding copy is localized (issue #21), and the slot devices carry
    /// the host's language (French here, measured): a walk accepts both, never
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

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string; the rest is what `req.note(…)` attached about that request's own
    /// payload — for the upload, the multipart parts the stub really received.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let parts: [String]?
        let filename: String?
        let checksum: String?
        let authorization: String?
        let deviceId: String?
        let deviceAssetId: String?
        let contentType: String?
        let albumId: String?
        let ids: [String]?

        private enum CodingKeys: String, CodingKey {
            case method, path, params, parts, filename, checksum, authorization, ids
            case deviceId = "device_id"
            case deviceAssetId = "device_asset_id"
            case contentType = "content_type"
            case albumId = "album_id"
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
        requests.enumerated().map { index, request in
            var line = "#\(index) \(request.method) \(request.path)"
            if !request.params.isEmpty { line += " params=\(request.params)" }
            if let parts = request.parts { line += " parts=\(parts) filename=\(request.filename ?? "nil")" }
            if let checksum = request.checksum { line += " checksum=\(checksum)" }
            if let authorization = request.authorization { line += " auth=\(authorization)" }
            if let sent = request.deviceId { line += " deviceId=\(sent)" }
            if let ids = request.ids { line += " ids=\(ids)" }
            if let albumId = request.albumId { line += " album=\(albumId)" }
            return line
        }.joined(separator: "\n")
    }

    /// Polls the stub's log until a request matches, or `timeout` elapses. The
    /// extension's upload is asynchronous from the test's point of view, so
    /// every wire expectation is a bounded wait rather than a read after a
    /// fixed sleep.
    private func waitForRequest(timeout: TimeInterval = 30,
                                where matches: (StubRequest) -> Bool) -> StubRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = stubRequests().first(where: matches) { return match }
            usleep(700_000)
        }
        return nil
    }

    /// Everything the extension sent, i.e. everything logged after the app was
    /// terminated.
    private func extensionRequests() -> [StubRequest] {
        Array(stubRequests().dropFirst(baseline))
    }

    // MARK: - The system surfaces of Photos

    /// The alert-less parts of Photos the scenario has to walk. Two of them are
    /// measured, not guessed (iOS 26.3, French device):
    ///
    /// * the library grid publishes no `cells` — each tile is an
    ///   `PXGGridLayout-Info` element whose label is "Photo, <date>", and the
    ///   newest asset is the last one;
    /// * the detail view's share button is
    ///   `PUOneUpBarButtonItemIdentifierShare`, and the sheet's activity for
    ///   this extension is a cell identified `shareCell` labelled "Swimmich"
    ///   (its `CFBundleDisplayName`, renamed from "Immich" on 2026-09-16).
    ///
    /// A grid tile answers `isHittable == false` even when it is plainly on
    /// screen, so it is tapped at its own centre.
    private func photosTiles(_ photos: XCUIApplication) -> XCUIElementQuery {
        photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
    }

    /// Photos' own first-launch sheet ("Nouveautés de Photos" on this device).
    private func dismissPhotosOnboarding(_ photos: XCUIApplication) {
        for label in ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"] {
            let button = photos.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                sleep(2)
            }
        }
    }

    /// Photos' activity for this extension, scrolled into reach if the app row
    /// is full. Matched by LABEL, never by cell identifier: `shareCell` is the
    /// identifier every app's activity carries — and the label is the
    /// extension's `CFBundleDisplayName` (`Swimmich`, renamed from `Immich` on
    /// 2026-09-16).
    private func shareActivity(_ photos: XCUIApplication, _ springboard: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == 'Swimmich'")
        for attempt in 0..<3 {
            for root in [photos as XCUIElement, springboard as XCUIElement] {
                let match = root.descendants(matching: .any).matching(predicate).firstMatch
                if match.exists { return match }
            }
            if attempt < 2 {
                let row = photos.collectionViews.firstMatch
                if row.exists { row.swipeLeft() } else { photos.swipeLeft() }
                sleep(2)
            }
        }
        return nil
    }

    private func screenLabels(_ root: XCUIElement) -> String {
        root.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    // MARK: - Scenario

    func test_shareExtension() throws {
        reset()
        setProvider("manual")
        app.launch()

        // MARK: 1. The app signs in — which is what mirrors the session

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
        // modal swallows every tap: Photos would never open under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("s03-whats-new")
            whatsNewDone.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "assetTile_aaaaaaaa-1111-4111-8111-000000000001")
            .firstMatch.waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub); the session this run creates "
                      + "would be the wrong one")

        // The keychain write happens on the login path; give it a beat before
        // the app is torn down, then cut the wire so anything later is provably
        // the extension's.
        sleep(3)
        app.terminate()
        sleep(3)
        baseline = stubRequests().count
        XCTAssertFalse(stubRequests().contains { $0.path == "/api/assets" },
                       "the app uploaded something on its own — every /api/assets below is then "
                       + "ambiguous:\n\(describe(stubRequests()))")

        // MARK: 2. Photos, and the share sheet

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.launch()
        XCTAssertTrue(photos.state == .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        dismissPhotosOnboarding(photos)
        shot("s04-photos-library")

        let tiles = photosTiles(photos)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20),
                      "the Photos library never published a tile (library reads: "
                      + "\(screenLabels(photos)))")
        // The newest asset is the one `--media` seeded: the samples the erased
        // device ships with are dated 2009…2018, and this file carries the run's
        // own date.
        let newest = tiles.element(boundBy: tiles.count - 1)
        print("MAP sharing tile: \(newest.label)")
        newest.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let shareButton = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 25),
                      "the photo viewer never offered its share button (screen: "
                      + "\(screenLabels(photos)))")
        shot("s05-photo-viewer")
        shareButton.tap()

        guard let activity = shareActivity(photos, springboard) else {
            shot("s06b-no-swimmich-activity")
            XCTFail("the share sheet has no Swimmich activity — the extension is not registered, or "
                    + "its row is out of reach (sheet reads: \(screenLabels(photos)))")
            return
        }
        shot("s06-share-sheet")
        activity.tap()

        // MARK: 3. The extension's own screen

        let serverLabel = photos.staticTexts.matching(identifier: "shareExtensionServerLabel").firstMatch
        XCTAssertTrue(serverLabel.waitForExistence(timeout: 40),
                      "the Swimmich share sheet never presented itself after the activity was tapped "
                      + "(screen: \(screenLabels(photos)))")
        shot("s07-extension")
        // The app half, proven from the other process: this label is built from
        // the keychain session the app wrote on login.
        XCTAssertTrue(serverLabel.label.contains("Stub User") && serverLabel.label.contains("127.0.0.1"),
                      "the sheet is not showing the session the app published — it reads "
                      + "\"\(serverLabel.label)\"")

        let row = photos.buttons.matching(identifier: "shareExtensionItemRow_0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the sheet listed no attachment")
        XCTAssertTrue(row.label.contains(seededStem) && row.label.contains(seededBytes),
                      "the sheet is not showing the file Photos was asked to share — row reads "
                      + "\"\(row.label)\", expected the \(seededBytes)-byte \(seededStem).PNG")

        // The album list is a request the extension makes on its own, with the
        // app's token: it is the first proof on this side of the keychain.
        guard let albums = waitForRequest(timeout: 20, where: { $0.path == "/api/albums" }) else {
            XCTFail("the sheet never asked for the album list — the session it read is not "
                    + "usable:\n\(describe(extensionRequests()))")
            return
        }
        XCTAssertEqual(albums.authorization, "Bearer \(stubToken)",
                       "the album list must carry the session's token")

        // MARK: 4. Album, upload, filing

        let picker = photos.buttons.matching(identifier: "shareExtensionAlbumPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "the sheet has no album picker")
        picker.tap()
        let option = photos.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", albumName)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 15),
                      "the album the stub served is not in the picker's menu (screen: "
                      + "\(screenLabels(photos)))")
        option.tap()
        shot("s08-album-chosen")

        let upload = photos.buttons.matching(identifier: "shareExtensionUploadButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15), "the sheet has no upload button")
        upload.tap()

        guard let sent = waitForRequest(timeout: 60, where: { $0.method == "POST" && $0.path == "/api/assets" }) else {
            XCTFail("no upload reached the stub after the sheet was told to send:\n"
                    + describe(extensionRequests()))
            return
        }
        print("WIRE everything the extension sent:\n\(describe(extensionRequests()))")
        // The parts are what a real server stores the file and its metadata
        // from; a body of the wrong shape paints the same green row.
        let parts = sent.parts ?? []
        for required in ["assetData", "fileCreatedAt", "deviceAssetId", "deviceId"] {
            XCTAssertTrue(parts.contains(required),
                          "the multipart body has no \(required) part — parts=\(parts):\n\(describe(extensionRequests()))")
        }
        XCTAssertEqual(sent.contentType, "multipart/form-data",
                       "the upload was not sent as a multipart body")
        XCTAssertEqual(sent.authorization, "Bearer \(stubToken)",
                       "the upload must carry the session's token")
        XCTAssertEqual(sent.checksum?.isEmpty, false,
                       "the upload carries no x-immich-checksum: the server cannot deduplicate it")
        XCTAssertEqual(sent.deviceAssetId?.hasPrefix("share/"), true,
                       "deviceAssetId is not the share's own id: \(sent.deviceAssetId ?? "nil")")
        XCTAssertEqual(sent.deviceId?.count, 36,
                       "deviceId is not the installation id the session carries: \(sent.deviceId ?? "nil")")

        // The filing happens only after the uploads answered, and with the id
        // the SERVER named.
        guard let filed = waitForRequest(timeout: 30, where: { $0.method == "PUT" && $0.albumId != nil }) else {
            XCTFail("the asset was uploaded but never filed in \(albumName):\n\(describe(extensionRequests()))")
            return
        }
        XCTAssertEqual(filed.albumId, albumId, "the filing named the wrong album")
        XCTAssertEqual(filed.ids, [uploadedAssetId],
                       "the filing sent the wrong ids — got \(filed.ids ?? [])")

        // MARK: 5. The sheet's own screen, and the exit an extension has

        let done = photos.buttons.matching(identifier: "shareExtensionDoneButton").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30),
                      "the sheet never turned into its finished state — screen: \(screenLabels(photos))")
        shot("s09-uploaded")
        done.tap()

        // `completeRequest` is the only exit that dismisses the sheet: if the
        // request were merely abandoned, the extension's UI would stay up.
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: serverLabel, handler: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed,
                       "the sheet never dismissed after Done — the request was not completed")
    }
}
