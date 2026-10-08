import XCTest

/// End-to-end scenario for the viewer's AirPlay output (gap G9), in the one
/// state a simulator can really produce: **no route at all**.
///
/// Route discovery belongs to iOS, not to this app — `AVRouteDetector` publishes
/// a single boolean, `AVRoutePickerView` *is* the device list. A simulator has
/// no Apple TV on the Wi-Fi and no external screen, so `isAvailable` is false
/// and the card's pill is present, DISABLED, and reads "Cast" (never "Casting")
/// because nothing carries the stream. That is what this scenario proves: the
/// viewer's chrome states "no screen" instead of offering a control that would
/// do nothing, tapping that control opens nothing, and the app never creates a
/// server-side cast session — the phone stays the HTTP client of the Immich
/// server over AirPlay.
///
/// WHAT A SIMULATOR CANNOT PROVE, and this scenario therefore does not claim:
/// `CastSheet` itself (measured: `isEnabled=false` on the pill, which is the
/// only entry to the sheet, so the sheet is not reachable here; XCUITest has no
/// accessibility-activate API to press a disabled control with) and a stream
/// that actually leaves the device — a real route, and the video the external
/// playback engine would hand to it. The card assumes both (`chromecast.specs`:
/// "le simulateur ne signale aucune route").
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/immich-orchestration/chromecast.uitest.log \
///         UITests/stubs/immich_stub_chromecast.py ChromecastUITests/test_chromecast --erase
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// one day of timeline, real PNG thumbnails) and adds the ONE route this feature
/// must never call: `POST /api/sessions`, the server session a cast *receiver*
/// would need to download the media itself. Serving it is what makes the absence
/// assertion below falsifiable instead of vacuous.
final class ChromecastUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The photo the scenario opens: the shell's first timeline asset, so the
    /// scenario needs no route of its own to reach the viewer.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

    // MARK: - Label families
    //
    // Every string below is a catalog key, and the same scenario runs on a fresh
    // slot (French, the host language) and on the repository's German simulator.
    // A single literal would make it pass or fail with the machine (measured on
    // the P2 wave), so each state is searched as a FAMILY — never one language.

    /// The pill's `accessibilityLabel` when nothing is casting.
    private let pillDisconnected = ["Cast", "Diffuser", "Übertragen", "Transmitir", "Trasmetti"]
    /// ...and when a route carries the stream. The negative below is what makes
    /// the first assertion mean something: "Cast" is a prefix of "Casting".
    private let pillConnected = ["Casting", "Diffusion en cours", "Übertragung läuft",
                                 "Transmitiendo", "Trasmettendo"]

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
    // Copied from `ImmichRenderScreenshots`/`RecentlyTakenUITests` on purpose:
    // they are `private` there, the shared file is frozen, and one file per
    // feature (helpers included) is the harness rule — a shared support file
    // would be a second convention beside the existing one.

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
    /// itself. This scenario clicks, like the reference.
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
        // flow never leaves this screen (measured). Scrolling dismisses the
        // keyboard (`.scrollDismissesKeyboard(.immediately)`), so the CTA is
        // really hittable when it is tapped, with a bounded retry for the frame
        // the keyboard was still animating over.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("c02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: \(screenLabels())")
        }
    }

    /// Any element carrying `identifier`, whatever its type: the cast surfaces
    /// are a combined group, a UIKit control and a `Label`, so asking for
    /// `.buttons` or `.staticTexts` would be guessing a type the card never
    /// promised.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A viewer top-bar action (SP-6): its pill when the row carries it, else
    /// the "⋯" menu's item — by identifier, then by label. Taps what it returns.
    /// A disabled item is tapped too: the caller's inertness checks read it.
    private func viewerAction(id: String, menu: String, labels: [String]) -> XCUIElement {
        let pill = app.buttons.matching(identifier: id).firstMatch
        if pill.exists {
            pill.tap()
            return pill
        }
        let overflow = app.buttons.matching(identifier: "viewerOverflowMenu").firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 15),
                      "\(id) is neither on the viewer's row nor behind ⋯ — screen reads: \(screenLabels())")
        overflow.tap()
        let anyElement = app.descendants(matching: .any)
        var item = anyElement.matching(identifier: menu).firstMatch
        if !item.waitForExistence(timeout: 5) {
            item = anyElement.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "⋯ holds neither \(menu) nor \(labels) — screen reads: \(screenLabels())")
        item.tap()
        return item
    }

    /// Everything on screen, for a failure message that says what the app
    /// actually showed instead of only what was expected.
    private func screenLabels() -> String {
        app.descendants(matching: .any).allElementsBoundByIndex
            .filter { !$0.label.isEmpty }
            .map { "\($0.identifier.isEmpty ? "-" : $0.identifier)=\($0.label)" }
            .joined(separator: " | ")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string; `deviceOS`/`deviceType` are what a session POST had to confess.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let deviceOS: String?
        let deviceType: String?
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

    // MARK: - Scenario

    func test_chromecast() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's refusal of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("c01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("c02-whats-new")
            whatsNewDone.tap()
        }

        // MARK: The photo, opened in the viewer

        let tile = element("assetTile_\(photo)")
        if !tile.waitForExistence(timeout: 30) {
            shot("c03b-no-timeline")
            XCTFail("the timeline never rendered \(photo) against \(stub) — screen reads: \(screenLabels())")
        }
        shot("c03-timeline")
        tile.tap()

        let chrome = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        if !chrome.waitForExistence(timeout: 20) {
            shot("c04b-no-viewer-chrome")
            XCTFail("the viewer never showed its top bar — screen reads: \(screenLabels())")
        }
        shot("c04-viewer-chrome")
        // Cast is on the row or behind "⋯" by the badge width (SP-3). The
        // helper taps it once — that tap is the one the inertness check below reads.
        let cast = viewerAction(id: "viewerCastButton", menu: "viewerMenuCast", labels: pillDisconnected)

        // MARK: The pill states the route it actually has — none

        // The label is exact, not `CONTAINS`: "Cast" is a prefix of "Casting",
        // so a screen that claimed a running session would satisfy a substring
        // search. The connected family is asserted absent as well, so the
        // failure message names the lie it found.
        XCTAssertTrue(pillDisconnected.contains(cast.label),
                      "the cast pill does not read as 'no screen': label=\(cast.label) "
                        + "(expected exactly one of \(pillDisconnected))")
        XCTAssertFalse(pillConnected.contains(cast.label),
                       "the cast pill claims a stream is running: label=\(cast.label)")

        // MARK: On the wire — the viewer really loaded THIS stub's photo
        //
        // Load-bearing twice over: it proves the viewer is showing an asset
        // served by this stub (a session persisted against another slot's port
        // would leave an empty viewer), and it proves the request log is live —
        // which is what gives the "no session" assertion below its meaning.

        let opened = stubRequests()
        XCTAssertTrue(opened.contains {
            $0.method == "GET" && $0.path == "/api/assets/\(photo)/thumbnail"
        }, "the viewer did not fetch \(photo) from this stub — got:\n\(describe(opened))")

        // MARK: The pill is the only way into the sheet, and it is inert

        // Tapping it must present NOTHING while no screen is reachable: this is
        // the assertion that catches a pill wired to `showCastSheet = true`
        // independently of the route state — a control that promises a screen
        // the system cannot deliver. It is also where the cost of the simulator
        // shows up: with `isEnabled=false` there is no way to reach `CastSheet`
        // at all (XCTest has no accessibility-activate API, only synthesized
        // gestures, and SwiftUI's `.disabled` ignores those), so the sheet's own
        // surfaces are not provable here — see the class comment.
        // (The tap itself was made by `viewerAction` above — exactly one.)
        let statusRow = element("castStatusRow")
        let sheetAppeared = statusRow.waitForExistence(timeout: 8)
        shot("c05-after-tapping-the-pill")
        XCTAssertFalse(sheetAppeared,
                       "tapping a disabled cast pill opened the sheet anyway (the route state is not what "
                        + "gates the entry) — enabled=\(cast.isEnabled); screen reads: \(screenLabels())")

        // MARK: ...and why nothing opened: no route ⇒ the control is DISABLED
        //
        // AC-5087 writes `.disabled(!castService.isAvailable)`. This is the
        // app's own answer to "is there anything to send to?", and it is the
        // whole of what a simulator can produce: there is no Apple TV on its
        // Wi-Fi, so `AVRouteDetector.multipleRoutesDetected` is false. Measured
        // on the slot device: `enabled=false hittable=true` — hittable, and
        // still inert above, which is what makes the two assertions a pair.
        XCTAssertFalse(cast.isEnabled,
                       "the pill is enabled, so iOS reported a reachable screen — a simulator has none: "
                        + "label=\(cast.label) hittable=\(cast.isHittable); screen reads: \(screenLabels())")
        print("CASTDIAG pill exists=\(cast.exists) enabled=\(cast.isEnabled) hittable=\(cast.isHittable) "
                + "label=\(cast.label)")

        // MARK: On the wire — no cast session, ever

        let all = stubRequests()
        let sessions = all.filter { $0.path == "/api/sessions" }
        XCTAssertTrue(sessions.isEmpty,
                      "the app created a server-side cast session (\(sessions.count)× `/api/sessions`): over "
                        + "AirPlay the PHONE stays the HTTP client and the route receives the stream, so a "
                        + "session means a receiver was asked to download the media itself. Got:\n\(describe(sessions))")
        // The scan above is only meaningful on a live log: the viewer's own
        // fetches must still be there.
        XCTAssertGreaterThan(all.filter { $0.path.hasSuffix("/thumbnail") }.count, 0,
                             "the request log lost the viewer's own fetches — the session absence above would "
                               + "be vacuous:\n\(describe(all))")
    }
}
