import XCTest

/// End-to-end scenario for the two "recent" consult screens (gap G13) — and the
/// reference for the 24 scenarios that follow it: one `XCTestCase` per feature,
/// in its own file, against its own committed stub. 25 branches each adding a
/// method to `ImmichRenderScreenshots` would collide on every merge.
///
/// It drives the real app: onboarding → SSO → the Albums tab → "Recently Taken"
/// (grid + day band) → back → "Recently Added". And it asserts on the WIRE what
/// each screen asked for, which is the point of the feature: `GET
/// /api/timeline/buckets` is the only route that can sort by upload date
/// (`orderBy=createdAt`), so a screen that rendered without that parameter would
/// be showing the wrong days while looking perfectly fine.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/recently-taken.uitest.log \
///         UITests/stubs/immich_stub_recent.py RecentlyTakenUITests/test_recentlyTaken \
///         --erase
///
/// `--erase` is not decoration: the stub port is drawn at random per run, so the
/// session an earlier run persisted points at a port nothing serves — and
/// `restoreSession()` drops a session on a 401, never on an unreachable host. An
/// erased device is the only one that walks onboarding and types THIS run's URL.
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// ordinary timeline, real PNG thumbnails) and adds the three axes; see its
/// docstring. Its three days are what make the wire assertions load-bearing: no
/// `orderBy` → the shell's day, `takenAt` → the day the photos were taken,
/// `createdAt` → the day they were uploaded.
final class RecentlyTakenUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The day the scenario expects on each axis. Only the YEAR is asserted
    /// (below): a day band is a localized date ("Saturday, July 27, 2024" here,
    /// "Samstag, 27. Juli 2024" on the repo's German simulator), and digits are
    /// the one part of it that reads the same in every language.
    private let takenYear = "2024"
    private let addedYear = "2025"

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
            shot("r02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// The pinned day band. Only its YEAR is asserted — see `takenYear`.
    private func dayHeader(year: String, timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", year))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// A tile of the Albums tab's Library section, by IDENTIFIER (its label is
    /// localized: "Recently Taken" / "Récemment prises"). The Albums ScrollView
    /// is scrolled only when the tile is not hittable.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        _ = row.waitForExistence(timeout: 10)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string: an absent `orderBy` is `nil`, an empty one is `""`.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
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

    /// Every `/api/timeline/buckets` the app sent, in order — the one route the
    /// whole feature hangs on.
    private func bucketRequests() -> [StubRequest] {
        stubRequests().filter { $0.path == "/api/timeline/buckets" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    /// The first index of a request carrying `orderBy=axis`, or nil.
    private func index(ofAxis axis: String, in requests: [StubRequest]) -> Int? {
        requests.firstIndex { $0.params["orderBy"] == axis }
    }

    // MARK: - Scenario

    func test_recentlyTaken() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's drop of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("r01-welcome")
            walkOnboardingToLogin()
            shot("r02-login-sso")
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
            shot("r03-whats-new")
            whatsNewDone.tap()
        }

        // The ordinary timeline: the shell's own day, six photos. Its first tile
        // also proves the app is talking to THIS stub — a session persisted
        // against another slot's port would leave the grid empty.
        let firstTimelineTile = tile("aaaaaaaa-1111-4111-8111-000000000001")
        if !firstTimelineTile.waitForExistence(timeout: 30) {
            let tiles = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
                .allElementsBoundByIndex.map(\.identifier)
            XCTFail("the timeline never rendered \(tiles.count) tiles (\(tiles)) against \(stub); "
                    + "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }

        // MARK: On the wire — the plain timeline asks for no sort axis

        let atLaunch = bucketRequests()
        XCTAssertTrue(atLaunch.contains { $0.params["orderBy"] == nil },
                      "the ordinary timeline must not ask for a sort axis — got:\n\(describe(atLaunch))")
        XCTAssertNil(index(ofAxis: "takenAt", in: atLaunch),
                     "no 'recent' screen has been opened yet, nothing may carry orderBy=takenAt — got:\n\(describe(atLaunch))")
        XCTAssertNil(index(ofAxis: "createdAt", in: atLaunch),
                     "no 'recent' screen has been opened yet, nothing may carry orderBy=createdAt — got:\n\(describe(atLaunch))")
        shot("r04-timeline")

        // MARK: The Albums tab's Library section

        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15), "Albums tab missing")
        albums.tap()

        // MARK: Recently Taken — the capture axis

        // Matched by IDENTIFIER, never by label — "Recently Taken" reads
        // "Récemment prises" here, so a literal would follow the simulator's
        // locale.
        let takenRow = libraryRow("recentTakenRow")
        if !takenRow.waitForExistence(timeout: 10) {
            shot("r05b-albums-without-recent-row")
            XCTFail("Recently Taken tile missing in the Albums library:\n\(app.debugDescription)")
        }
        shot("r05-albums-library")
        takenRow.tap()

        let grid = app.descendants(matching: .any).matching(identifier: "recentGrid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "the Recently Taken screen never loaded")
        XCTAssertTrue(tile("bbbbbbbb-1111-4111-8111-000000000001").waitForExistence(timeout: 20),
                      "the day the stub announced for orderBy=takenAt is not in the grid")
        XCTAssertTrue(dayHeader(year: takenYear, timeout: 20),
                      "no day band on the Recently Taken grid — labels: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("r06-recently-taken")

        let afterTaken = bucketRequests()
        XCTAssertNotNil(index(ofAxis: "takenAt", in: afterTaken),
                        "opening 'Recently Taken' did not ask the server to sort by takenAt — got:\n\(describe(afterTaken))")
        XCTAssertNil(index(ofAxis: "createdAt", in: afterTaken),
                     "'Recently Taken' must not ask for the upload axis — got:\n\(describe(afterTaken))")

        // MARK: Recently Added — the upload axis, the one only this route has

        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from the recently screen")
        back.tap()
        sleep(2)

        let addedRow = libraryRow("recentAddedRow")
        if !addedRow.waitForExistence(timeout: 10) {
            shot("r07b-albums-without-added-row")
            XCTFail("Recently Added tile missing in the Albums library:\n\(app.debugDescription)")
        }
        addedRow.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recentGrid")
            .firstMatch.waitForExistence(timeout: 20), "the Recently Added screen never loaded")
        XCTAssertTrue(tile("cccccccc-1111-4111-8111-000000000001").waitForExistence(timeout: 20),
                      "the upload day the stub announced for orderBy=createdAt is not in the grid")
        XCTAssertTrue(dayHeader(year: addedYear, timeout: 20),
                      "no day band on the Recently Added grid — labels: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        shot("r07-recently-added")

        let afterAdded = bucketRequests()
        guard let takenIndex = index(ofAxis: "takenAt", in: afterAdded),
              let addedIndex = index(ofAxis: "createdAt", in: afterAdded) else {
            return XCTFail("the two axes were not both asked for — got:\n\(describe(afterAdded))")
        }
        // Order matters: each screen drove its OWN request, rather than one
        // screen having produced both.
        XCTAssertLessThan(takenIndex, addedIndex,
                          "orderBy=takenAt must precede orderBy=createdAt — got:\n\(describe(afterAdded))")
        // And the ordinary timeline is still sort-free in the same log.
        XCTAssertTrue(afterAdded.contains { $0.params["orderBy"] == nil },
                      "the ordinary timeline must keep asking for no sort axis — got:\n\(describe(afterAdded))")
    }
}
