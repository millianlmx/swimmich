import XCTest

/// End-to-end scenario for the duration shown on a video tile. One `XCTestCase`
/// per feature, in its own file, against its own committed stub — the pattern
/// `RecentlyTakenUITests` set for the suite.
///
/// It drives the real app (onboarding → SSO → the Photos grid) and asserts what
/// the tiles actually read. Immich v3 sends `duration` in MILLISECONDS; a
/// surface that forgets it renders 7173 ms as "119:33" — a plausible-looking
/// label, on a screen that is otherwise perfectly healthy. The stub therefore
/// serves a 7-second clip, a 5-minute clip and a 2-hour clip, and the scenario
/// pins all three labels — including the badge compaction past the hour
/// ("2:00", never the unbounded-minutes "120:00" nor the raw-cell
/// "120000:00") — in the same run.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/video-duration.uitest.log \
///         UITests/stubs/immich_stub_video_duration.py VideoDurationUITests/test_videoDuration \
///         --erase
///
/// `--erase` is not decoration: the stub port is drawn at random per run, and a
/// session persisted against a dead port is only dropped on a 401 — an erased
/// device is the one that walks onboarding and types THIS run's URL.
final class VideoDurationUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The video tiles, in the stub's own order: 7173 ms, 300000 ms, 7200000 ms.
    private let sevenSecondClip = "aaaaaaaa-1111-4111-8111-000000000001"
    private let fiveMinuteClip = "aaaaaaaa-1111-4111-8111-000000000003"
    private let twoHourClip = "aaaaaaaa-1111-4111-8111-000000000004"

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
    // Copied from `RecentlyTakenUITests` on purpose: these are `private` there
    // and each scenario owns its copy — extracting them into a shared support
    // file would be a second convention next to the existing one.

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
        // Scrolling dismisses the keyboard, so the CTA is really hittable when
        // it is tapped, and a bounded retry covers the animating frame.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("v02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// Every label on screen (the badge is a plain `Text` inside the cell, so it
    /// surfaces as a static text of its own — the cell never folds its
    /// descendants into one element).
    private func screenLabels() -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex.map(\.label)
    }

    // MARK: - Scenario

    func test_videoDuration() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's drop of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("v01-welcome")
            walkOnboardingToLogin()
            shot("v02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" over the shell, and a modal
        // swallows every tap: the tiles would never be reachable under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("v03-whats-new")
            whatsNewDone.tap()
        }

        // All three videos of the stub are on screen — their ids are what the
        // badge assertions below are about.
        XCTAssertTrue(tile(sevenSecondClip).waitForExistence(timeout: 30),
                      "the 7-second clip never rendered — screen reads: \(screenLabels())")
        XCTAssertTrue(tile(fiveMinuteClip).waitForExistence(timeout: 20),
                      "the 5-minute clip never rendered — screen reads: \(screenLabels())")
        XCTAssertTrue(tile(twoHourClip).waitForExistence(timeout: 20),
                      "the 2-hour clip never rendered — screen reads: \(screenLabels())")
        shot("v04-video-duration-timeline")

        // AC-1/AC-2: the 7173 ms clip reads "0:07" (never "119:33"), the
        // 300000 ms clip reads "5:00" (never "3000:00"), the 7200000 ms clip
        // compacts to "2:00" past the hour, and those three are the ONLY
        // durations on screen — the photos carry `duration: nil` and draw no
        // badge at all.
        let durationLabels = screenLabels().filter { $0.range(of: #"^\d+:\d{2}$"#, options: .regularExpression) != nil }
        XCTAssertEqual(durationLabels.sorted(), ["0:07", "2:00", "5:00"],
                       "the grid shows the raw millisecond cell on a video tile — screen reads: \(screenLabels())")

        // The same claim as an explicit absence, so a regression names itself
        // even if the live labels above move around. "120:00" is the
        // unbounded-minutes render this badge used to have; "120000:00" is the
        // raw cell read as seconds.
        for wrong in ["119:33", "3000:00", "120:00", "120000:00"] {
            XCTAssertFalse(screenLabels().contains { $0.contains(wrong) },
                           "a surface renders the wrong duration (\(wrong))")
        }
    }
}
