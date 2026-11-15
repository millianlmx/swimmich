import XCTest

/// End-to-end scenario for the profile picture (gap G16): open the screen from
/// the "Me" hub with the initials showing, pick a photo in the SYSTEM picker,
/// frame the square, publish it (`POST /api/users/profile-image`, multipart),
/// watch the avatar switch to the photo the server just published, survive a
/// server refusal that must leave the previous photo alone — and finally remove
/// it (`DELETE /api/users/profile-image`) and fall back to the initials.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, refuses a scenario that skipped itself, and grants
/// Photos + seeds the library):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/profile-picture.uitest.log \
///         UITests/stubs/immich_stub_profile_picture.py ProfilePictureUITests/test_profilePicture \
///         --erase --media /tmp/profile-picture-640x480.png
///
/// `--erase` and `--media` are not decoration: the scenario asserts the crop
/// square opens at 75 % of the image width, which is only true for the 4:3 photo
/// it seeds, and a shared device would otherwise hand the picker a library full of
/// whatever the previous run (or a neighbour) left there. The seeded file has to
/// be generated, with four colours and an off-centre disc, so that a screenshot
/// can tell "the square moved" and "the avatar now shows the upload" apart.
///
/// What the WIRE proves, route by route (the stub parses the multipart part, it
/// does not merely count the request — see its docstring):
///
/// * `GET /api/users/me` — the screen reads the identity from the server.
/// * `POST /api/users/profile-image` — one part, field `file` (never
///   `assetData`), filename `profile.jpg`, part type `image/jpeg`, a real JFIF
///   JPEG inside, framed as a closed multipart body.
/// * `GET /api/users/{id}/profile-image?v=<stamp>` — the avatar fetched the photo
///   the upload just published; the cache-buster is what stops `ImageCache` from
///   reserving the previous (or absent) one.
/// * a refused second upload publishes nothing: two POSTs, one 201, and every
///   profile-image read still carries the FIRST stamp.
/// * `DELETE /api/users/profile-image` — exactly one, only after the confirmation
///   dialog, and no profile-image read follows it (the avatar has nothing left).
final class ProfilePictureUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private let userID = "11111111-1111-4111-8111-111111111111"
    /// The stamps the stub publishes, in order — see `STAMPS` in the stub. The
    /// second one must NEVER appear on the wire: the upload that would have
    /// published it is the one the stub refuses.
    private let firstStamp = "2026-09-15T10:00:00.000Z"
    private let secondStamp = "2026-09-15T11:00:00.000Z"
    /// `GET /api/users/{id}/profile-image` — the READ route, the one the app did
    /// not have before this feature.
    private var profileImagePath: String { "/api/users/\(userID)/profile-image" }

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
    // and the shared file is frozen (the committed scenarios are green against
    // its current text). Extracting them into a shared support file would be a
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

    /// Puts the stub back to its initial state (no photo published, counters at
    /// zero, no armed refusal) and empties its request log, so no assertion below
    /// can be satisfied by a previous run.
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

    /// Arms (or disarms) the stub's one-shot refusal of the next profile image
    /// upload, and checks the answer: a control route that answered `[]` because
    /// it is not registered would leave the failure step silently happy.
    private func armFailure(_ on: Bool) {
        let url = URL(string: "\(stub)/api/stub/fail-upload?on=\(on ? 1 : 0)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer its control route")
        XCTAssertEqual(body, "{\"failUpload\": \(on)}", "the refusal switch did not take")
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
            shot("p00b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized: "Profile
    /// Picture" / "Photo de profil"). A `Form` only publishes what it rendered,
    /// so the row is scrolled into view first, letting each swipe settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The initials the avatar publishes: `profilePictureAvatar`'s accessibility
    /// value ("SU" for the stub's "Stub User"), polled because the identity is
    /// loaded from the server. See the comment on the assertion that uses it —
    /// the circle's children are merged into the container, so there is no
    /// element of their own to look for.
    private func waitForInitials(_ avatar: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (avatar.value as? String) == "SU" { return true }
            usleep(300_000)
        }
        return (avatar.value as? String) == "SU"
    }

    /// Scrolls until the element is really tappable. The screen is a `ScrollView`
    /// taller than the phone: Save and Remove sit below the picked photo's crop
    /// block.
    ///
    /// NOT `app.swipeUp()`: a swipe is performed at the CENTRE of the app, and
    /// once a photo is pending the crop canvas sits there — its `DragGesture`
    /// claims the touch, the `ScrollView` never moves, and the save button is
    /// never reached (measured: the square just kept moving under eight swipes,
    /// while the button stayed off screen). The drag starts in the bottom band
    /// instead, where nothing claims the gesture, and its direction follows the
    /// element's own position.
    @discardableResult
    private func scrollIntoView(_ target: XCUIElement, drags: Int = 8) -> Bool {
        for _ in 0..<drags {
            if target.exists && target.isHittable { return true }
            guard target.exists else { return false }
            let below = target.frame.midY > app.frame.midY
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.93 : 0.82))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.5 : 0.95))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        return target.exists && target.isHittable
    }

    /// A compact inventory of what the screen actually publishes — the failure
    /// message of last resort, printed in full (the launcher truncates its own
    /// echo of an assertion, the log keeps this).
    private func elementDigest(limit: Int = 25) -> String {
        func digest(_ query: XCUIElementQuery, _ name: String) -> [String] {
            query.allElementsBoundByIndex.prefix(limit).map { "\(name)(id=\($0.identifier),label=\($0.label))" }
        }
        let parts = digest(app.buttons, "button") + digest(app.staticTexts, "text")
            + digest(app.cells, "cell") + digest(app.images, "image") + digest(app.otherElements, "other")
        let report = parts.joined(separator: " | ")
        print("DIGEST \(report)")
        return report
    }

    // MARK: - System picker

    /// Picks the first photo in the system picker.
    ///
    /// Measured on this OS (2026-09-15): tapping the chooser opens a real sheet
    /// whose own progress view reads "Chargement…" while it reads the library,
    /// and whose grid IS bridged into the app under test's tree. Enumerating it
    /// during that window fails the WHOLE test — the indices resolved a moment
    /// earlier stop existing and XCUITest raises "Failed to get matching
    /// snapshot: No matches found for Element at index 13". So the sheet is given
    /// time to settle before anything is enumerated.
    ///
    /// Only a HITTABLE element is tapped: the screen behind the sheet is in the
    /// same tree, and tapping one of those would look like a successful choice.
    ///
    /// The picker's own process is asked LAST, and only when it is actually
    /// running: `XCUIApplication(bundleIdentifier:)` on an app that is not
    /// running does not answer an empty query, it fails the test ("Failed to get
    /// matching snapshots: Application … is not running" — measured, cost one
    /// run). `.state` is a process question, not a snapshot, so it is safe to ask.
    ///
    /// Returns whether a selection gesture was SENT — the crop canvas the caller
    /// waits for next is what decides whether the picker actually answered.
    private func pickFirstPhoto(shot name: String, budget: TimeInterval = 40) -> Bool {
        // Photo tiles are labelled "Photo, <date>" in every language the picker
        // can be in; the comma matters, because the grid's own container is
        // labelled "Photos" and a `BEGINSWITH 'Photo'` matches it first — that tap
        // landed in the middle of the grid and picked a sample photo (measured).
        let photoLike = NSPredicate(format: "label BEGINSWITH 'Photo,' OR label BEGINSWITH 'Foto,'")
        let settled = waitForPickerReady(photoLike: photoLike, budget: budget)
        shot(name)
        let tiles = app.images.matching(photoLike)
        print("PICKER settled=\(settled) images=\(app.images.count) tiles=\(tiles.count)")

        if tapFirstTile(in: app, tiles: tiles) { return true }

        let service = XCUIApplication(bundleIdentifier: "com.apple.PhotosUIService")
        print("PICKER PhotosUIService state=\(service.state.rawValue)")
        if service.state != .notRunning,
           tapFirstTile(in: service, tiles: service.images.matching(photoLike)) { return true }

        // Last resort, and said out loud: no tile published a usable frame. Below
        // the sheet's bar and left of centre, where the first photo of a "Recents"
        // grid sits.
        print("PICKER no tile frame — falling back to a blind tap in the grid")
        shot("\(name)-no-tile-frame")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.42)).tap()
        confirmPickerIfStillUp()
        return true
    }

    /// Waits until the picker's library read is really over.
    ///
    /// The sheet renders a progress view ("Chargement…") while it reads, and its
    /// tree keeps changing after that: enumerating it too early raises "Failed to
    /// get matching snapshot: No matches found for Element at index 10", which
    /// fails the whole test rather than just this step (measured twice). Only
    /// COUNTS are read while waiting — a count is re-queried, never bound to an
    /// index — and four quiet polls (~3 s) are required, not one.
    private func waitForPickerReady(photoLike: NSPredicate, budget: TimeInterval) -> Bool {
        let busy = labelPredicate(["Chargement", "Loading", "Wird geladen"])
        var last = -1
        var quiet = 0
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            let count = app.images.matching(photoLike).count
            if count > 0, count == last, app.staticTexts.matching(busy).count == 0 {
                quiet += 1
                if quiet >= 4 { return true }
            } else {
                quiet = 0
            }
            last = count
            usleep(700_000)
        }
        return false
    }

    /// Taps the TOP-LEFT photo of the grid — the newest one, which is the photo
    /// the launcher seeded — BY COORDINATE.
    ///
    /// The tiles are not hittable in the sense XCUITest tests: the grid is a
    /// remote view and the hit test at a tile's centre resolves to an ancestor, so
    /// a tap computed on the tile never happens, while a tap on the container
    /// lands in the MIDDLE of the grid and picks a sample photo (both measured —
    /// the sample gave a 67 % crop square instead of the seeded file's 75 %). A
    /// coordinate tap at the tile's own frame is a real tap on that photo.
    private func tapFirstTile(in host: XCUIApplication, tiles: XCUIElementQuery) -> Bool {
        var best: CGRect?
        for index in 0..<min(tiles.count, 6) {
            let tile = tiles.element(boundBy: index)
            guard tile.exists else { continue }
            let frame = tile.frame
            // A tile, not a toolbar icon: the bars live in the top 60 pt.
            guard frame.width >= 44, frame.height >= 44, frame.minY >= 60 else { continue }
            if best == nil || (frame.minY, frame.minX) < (best!.minY, best!.minX) { best = frame }
        }
        guard let frame = best else { return false }
        print("PICKER tapping the top-left tile at \(frame)")
        host.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        confirmPickerIfStillUp()
        return true
    }

    /// A picker that stayed up wants its own confirmation ("Add"/"Ajouter");
    /// tapping it is harmless when the single-selection picker already dismissed
    /// itself, because the app has no such button.
    private func confirmPickerIfStillUp() {
        let confirm = app.buttons.matching(labelPredicate(["Add", "Ajouter", "Done", "Terminé"])).firstMatch
        if confirm.waitForExistence(timeout: 4) {
            print("PICKER confirming with \(confirm.label)")
            confirm.tap()
        }
    }

    // MARK: - Crop canvas

    /// The square's size as the screen publishes it ("Crop square, 75 percent of
    /// the image", localized — the DIGITS are what every language shares).
    private func cropPercent(_ canvas: XCUIElement) -> Int? {
        let digits = canvas.label.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
        return digits.first.flatMap(Int.init)
    }

    private func waitForCropPercent(_ canvas: XCUIElement, above floor: Int,
                                    timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let percent = cropPercent(canvas), percent > floor { return percent }
            usleep(300_000)
        }
        return cropPercent(canvas)
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query string;
    /// the rest are the fields the stub's route attached with `req.note(...)` —
    /// present only on the requests that route answered.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let field: String?
        let fields: [String]?
        let filename: String?
        let partType: String?
        let requestType: String?
        let jfif: Bool?
        let bytes: Int?
        let upload: Int?
        let refused: Bool?
        let deletes: Int?
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

    /// Polls the log until `predicate` holds, and hands back the whole log. No
    /// bare `sleep` for a server round-trip: the app's request is what is being
    /// waited for, and the budget is explicit.
    @discardableResult
    private func waitForWire(_ predicate: @escaping ([StubRequest]) -> Bool,
                             timeout: TimeInterval, label: String) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var log = stubRequests()
        while Date() < deadline {
            if predicate(log) { return log }
            usleep(500_000)
            log = stubRequests()
        }
        if !predicate(log) {
            XCTFail("\(label) — wire so far:\n\(describe(log))")
        }
        return log
    }

    private func posts(_ log: [StubRequest]) -> [StubRequest] {
        log.filter { $0.method == "POST" && $0.path == "/api/users/profile-image" }
    }

    private func reads(_ log: [StubRequest]) -> [StubRequest] {
        log.filter { $0.method == "GET" && $0.path == profileImagePath }
    }

    private func deletes(_ log: [StubRequest]) -> [StubRequest] {
        log.filter { $0.method == "DELETE" && $0.path == "/api/users/profile-image" }
    }

    private func describe(_ log: [StubRequest]) -> String {
        log.map { entry in
            var line = "\(entry.method) \(entry.path) params=\(entry.params)"
            if let field = entry.field { line += " field=\(field)" }
            if let fields = entry.fields { line += " fields=\(fields)" }
            if let filename = entry.filename { line += " filename=\(filename)" }
            if let type = entry.partType { line += " partType=\(type)" }
            if let bytes = entry.bytes { line += " bytes=\(bytes)" }
            if let jfif = entry.jfif { line += " jfif=\(jfif)" }
            if let refused = entry.refused { line += " refused=\(refused)" }
            if let deletes = entry.deletes { line += " deletes=\(deletes)" }
            return line
        }.joined(separator: "\n")
    }

    /// Dismisses the screen's error alert if the picker or a system surface left
    /// one up, so a tap below cannot be swallowed by it.
    private func dismissAlertIfPresent() {
        let alert = app.alerts.firstMatch
        if alert.exists { alert.buttons.firstMatch.tap() }
    }

    // MARK: - Scenario

    func test_profilePicture() throws {
        reset()
        setProvider("manual")
        armFailure(false)
        app.launch()

        // MARK: Onboarding → OAuth → the shell
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("p00-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install (the launcher's `--erase`) presents "What's New" over
        // the shell, and a modal swallows every tap: the hub would never open
        // under it. Its Done button carries an identifier because its label is
        // translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("p00b-whats-new")
            whatsNewDone.tap()
        }

        // MARK: The "Me" hub → the pushed screen
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()

        // Matched by IDENTIFIER, never by label: the row reads "Profile Picture"
        // here and "Photo de profil" on the repo's simulator.
        let row = hubRow("profilePictureRow")
        if !row.waitForExistence(timeout: 10) {
            shot("p01b-me-hub-without-profile-picture-row")
            XCTFail("Profile Picture row missing in the Me hub:\n\(elementDigest())")
        }
        shot("p01-me-hub")
        row.tap()

        let avatar = element("profilePictureAvatar")
        if !avatar.waitForExistence(timeout: 20) {
            shot("p02b-no-profile-picture-screen")
            XCTFail("the Profile Picture screen never opened:\n\(elementDigest())")
        }

        // The identity comes from the SERVER (`GET /api/users/me`), not from the
        // login payload: the whole screen is built on the row that carries
        // `profileImagePath`/`profileChangedAt`.
        XCTAssertTrue(waitForWire({ $0.contains { $0.method == "GET" && $0.path == "/api/users/me" } },
                                  timeout: 15, label: "the screen never read /api/users/me").count > 0,
                      "expected at least one GET /api/users/me")

        // MARK: Nothing published yet — the initials
        //
        // The initials are the avatar's accessibility VALUE, not an element:
        // SwiftUI merges the circle's children into the container (measured —
        // the tree only ever published `profilePictureAvatar`), and the view
        // publishes the initials it drew. The two fallbacks below both spell
        // "No profile picture", so this value is the only honest way to tell
        // "shows the user's initials" from "shows an empty disc".
        if !waitForInitials(avatar, timeout: 15) {
            shot("p02c-no-initials")
            XCTFail("the avatar does not show the user's initials (\"Stub User\") before any photo "
                    + "(value=\(avatar.value.map { "\($0)" } ?? "nil")):\n" + elementDigest())
        }
        XCTAssertTrue(element("profilePictureChooseButton").exists, "the chooser is missing")
        XCTAssertFalse(element("profilePictureRemoveButton").exists,
                       "a Remove button is offered while the server holds no photo")
        shot("p02-initials")

        // MARK: Choose a photo in the system picker
        let choose = element("profilePictureChooseButton")
        XCTAssertTrue(scrollIntoView(choose), "the chooser is not tappable:\n\(elementDigest())")
        choose.tap()
        // `false` = not even a selection gesture could be sent. `true` only means
        // one was sent: the crop canvas below is what decides whether the picker
        // actually answered.
        if !pickFirstPhoto(shot: "p03a-picker-open") {
            XCTFail("the system photo picker never yielded a photo — see the PICKER lines in the log")
        }

        // MARK: Frame the square
        let canvas = element("profilePictureCropCanvas")
        if !canvas.waitForExistence(timeout: 25) {
            shot("p03c-no-crop-canvas")
            XCTFail("the picked photo never produced a crop canvas:\n\(elementDigest())")
        }
        // The seeded photo is 4:3, so the largest square centred in it is 75 % of
        // its width: this one number proves the crop is computed from the photo
        // the picker returned, in normalized space, and published to VoiceOver.
        let opened = cropPercent(canvas)
        XCTAssertEqual(opened, 75,
                       "the seeded photo is 4:3, so its crop square is 75 % of the image width; "
                       + "got \(opened.map(String.init) ?? "nil") (67 % would be one of the device's own "
                       + "3:2 samples — the picker was not targeted) — canvas label: \"\(canvas.label)\"")
        shot("p03-crop")

        // Moving the square is a `DragGesture`: it must move it, not resize it.
        let centre = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.2, thenDragTo: centre.withOffset(CGVector(dx: 34, dy: -22)))
        XCTAssertEqual(cropPercent(canvas), opened,
                       "dragging the square must not resize it — canvas label: \"\(canvas.label)\"")
        shot("p03d-crop-moved")

        // Resizing is the pinch, and it is the one framing gesture the screen
        // publishes as a number: if the model never saw it, the value cannot move.
        canvas.pinch(withScale: 2.0, velocity: 3.0)
        let resized = waitForCropPercent(canvas, above: opened ?? 0, timeout: 12)
        XCTAssertTrue((resized ?? 0) > (opened ?? 0),
                      "pinching the canvas did not resize the square (it stayed at \(cropPercent(canvas).map(String.init) ?? "nil")) — the gesture never reached the model")
        shot("p03e-crop-resized")

        // MARK: Publish it — `POST /api/users/profile-image`, multipart
        let save = element("profilePictureSaveButton")
        XCTAssertTrue(scrollIntoView(save), "the Save button is not tappable:\n\(elementDigest())")
        save.tap()

        var log = waitForWire({ !self.posts($0).isEmpty }, timeout: 40,
                              label: "no POST /api/users/profile-image ever reached the stub")
        var uploads = posts(log)
        XCTAssertEqual(uploads.count, 1, "one Save must send one upload — wire:\n\(describe(log))")
        guard let part = uploads.first else { return XCTFail("no upload entry") }

        // The part, field by field — what `CreateProfileImageDto` asks for, and
        // what the asset upload's assembler must NOT leak into: the field is
        // `file` here, `assetData` there.
        XCTAssertEqual(part.requestType, "multipart/form-data",
                       "the upload is not a multipart request — got \(part.requestType ?? "nil")")
        XCTAssertEqual(part.field, "file",
                       "the upload must carry the `file` field; the request carried \(part.fields ?? []) — wire:\n\(describe(log))")
        XCTAssertEqual(part.filename, "profile.jpg", "unexpected filename in the part")
        XCTAssertEqual(part.partType, "image/jpeg", "unexpected part content type")
        XCTAssertEqual(part.jfif, true, "the part's body is not a JFIF JPEG — wire:\n\(describe(log))")
        XCTAssertGreaterThan(part.bytes ?? 0, 2000,
                             "the part holds \(part.bytes ?? 0) bytes — a 512-px JPEG is tens of KB")

        // MARK: The avatar switches to the photo the server just published
        log = waitForWire({ log in self.reads(log).contains { $0.params["v"] == self.firstStamp } },
                          timeout: 40,
                          label: "the avatar never fetched the profile image the upload published (?v=\(firstStamp))")
        XCTAssertTrue(reads(log).contains { $0.params["v"] == firstStamp },
                      "no profile-image read carried the stamp the upload published")
        XCTAssertTrue(app.buttons.matching(identifier: "profilePictureRemoveButton").firstMatch
            .waitForExistence(timeout: 25),
                      "after a 201 the screen must offer to remove the published photo:\n\(elementDigest())")
        XCTAssertNotEqual(avatar.value as? String, "SU",
                          "the avatar still shows the initials after the photo was published")
        // Evaluated ON the avatar element: the same words are also the pushed
        // screen's title, so an unqualified label search would pass either way.
        XCTAssertTrue(labelPredicate(["Profile picture", "Photo de profil", "Profilbild"])
            .evaluate(with: avatar),
                      "the avatar is not labelled as holding a photo: \"\(avatar.label)\"")
        shot("p04-published")

        // MARK: A refused upload leaves the published photo alone — and says so
        armFailure(true)
        let chooseAgain = element("profilePictureChooseButton")
        XCTAssertTrue(scrollIntoView(chooseAgain), "the chooser is not tappable on the second pass")
        chooseAgain.tap()
        XCTAssertTrue(pickFirstPhoto(shot: "p04b-picker-open-again"),
                      "the system photo picker never yielded a photo the second time")
        let saveAgain = element("profilePictureSaveButton")
        XCTAssertTrue(saveAgain.waitForExistence(timeout: 25), "the second pick produced no crop block")
        XCTAssertTrue(scrollIntoView(saveAgain), "the Save button is not tappable on the second pass")
        saveAgain.tap()

        let alert = app.alerts.firstMatch
        if !alert.waitForExistence(timeout: 40) {
            shot("p05b-no-error-alert")
            XCTFail("the screen said nothing after the server refused the upload:\n\(elementDigest())")
        }
        XCTAssertTrue(alert.label.isEmpty == false, "the error alert has no title")
        XCTAssertTrue(alert.staticTexts.matching(labelPredicate(["Could not update",
                                                                 "Impossible de mettre à jour",
                                                                 "konnte nicht aktualisiert"]))
            .firstMatch.exists,
                      "the alert is not the feature's own error — it reads: \"\(alert.label)\"")
        XCTAssertTrue(alert.staticTexts.count >= 2,
                      "the error alert carries no message — texts: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("p05-refused-upload-alert")

        log = stubRequests()
        uploads = posts(log)
        XCTAssertEqual(uploads.count, 2, "the second Save never reached the server — wire:\n\(describe(log))")
        XCTAssertEqual(uploads.last?.refused, true,
                       "the second POST was not the one the stub refused — wire:\n\(describe(log))")
        XCTAssertNil(reads(log).first { $0.params["v"] == secondStamp },
                     "the avatar fetched ?v=\(secondStamp): a refused upload published something — wire:\n\(describe(log))")
        XCTAssertEqual(reads(log).last?.params["v"], firstStamp,
                       "the avatar stopped reading the photo that was already published — wire:\n\(describe(log))")
        XCTAssertTrue(element("profilePictureRemoveButton").exists,
                      "a refused upload took the published photo off the screen")
        XCTAssertNotEqual(avatar.value as? String, "SU",
                          "the avatar fell back to the initials because an upload was refused")

        dismissAlertIfPresent()

        // MARK: Remove it — `DELETE /api/users/profile-image`, after the confirmation
        let remove = element("profilePictureRemoveButton")
        XCTAssertTrue(scrollIntoView(remove), "the Remove button is not tappable:\n\(elementDigest())")
        let readsBeforeDelete = reads(stubRequests()).count
        remove.tap()

        // The confirmation is not decorative: nothing may be destroyed before it
        // is answered.
        // The app's own Remove button carries the SAME words ("Remove Photo" /
        // "Retirer la photo" — the catalog translates it), so the query is scoped
        // to the confirmation alert (iOS 26 also lists an alert button twice:
        // `firstMatch` narrows it).
        let confirm = app.alerts.firstMatch.buttons.matching(labelPredicate(["Remove Photo", "Retirer la photo",
                                                                              "Supprimer la photo", "Foto entfernen"]))
            .matching(NSPredicate(format: "identifier != 'profilePictureRemoveButton'")).firstMatch
        if !confirm.waitForExistence(timeout: 15) {
            shot("p06b-no-confirmation")
            XCTFail("removing the photo is not confirmed by a dialog:\n\(elementDigest())")
        }
        shot("p06-confirmation")
        XCTAssertTrue(deletes(stubRequests()).isEmpty,
                      "the DELETE went out before the user confirmed it")
        confirm.tap()

        log = waitForWire({ !self.deletes($0).isEmpty }, timeout: 40,
                          label: "no DELETE /api/users/profile-image ever reached the stub")
        XCTAssertEqual(deletes(log).count, 1, "one confirmation must send one DELETE — wire:\n\(describe(log))")

        // MARK: Back to the initials
        if !waitForInitials(avatar, timeout: 25) {
            shot("p07b-no-initials-after-removal")
            XCTFail("after the DELETE the avatar must fall back to the initials "
                    + "(value=\(avatar.value.map { "\($0)" } ?? "nil")):\n" + elementDigest())
        }
        XCTAssertFalse(element("profilePictureRemoveButton").exists,
                       "the Remove button is still offered with no photo published")
        let afterDelete = reads(stubRequests())
        XCTAssertEqual(afterDelete.count, readsBeforeDelete,
                       "the avatar fetched the profile image again after the DELETE — wire:\n\(describe(log))")
        XCTAssertTrue(afterDelete.allSatisfy { $0.params["v"] == firstStamp },
                      "a read after the DELETE carries something else than the old stamp — wire:\n\(describe(log))")
        // Back to the top before the screenshot: reaching the Remove button
        // scrolled the avatar out of the window, and a step's picture has to show
        // the thing the step is about.
        scrollIntoView(avatar)
        shot("p07-initials-again")

        // The run's wire, in the log. Every line of it was asserted above; this is
        // what a reader of the report gets to read back without re-running.
        print("WIRE\n" + describe(stubRequests().filter {
            $0.path.hasPrefix("/api/users") || $0.path.hasPrefix("/api/stub")
        }))
    }
}
