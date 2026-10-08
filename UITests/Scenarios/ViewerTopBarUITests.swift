import UIKit
import XCTest

/// End-to-end proof of the viewer's top bar on device (BR-2): the badge is
/// never squeezed (AC-1), trailing actions collapse behind "⋯" only when the
/// width asks for it and every collapsed action stays reachable (AC-2), the
/// row keeps every action live when the width allows (AC-3), a badge that
/// cannot fit two lines falls back to one truncated line (AC-4), and a bar that
/// was never squeezed — the trash's, three actions — is unchanged (AC-5).
///
/// The four methods drive the same photo through four places. The place is the
/// only input the badge width depends on (see the stub), so the scenario can
/// reach each layout state at the iPhone 17 width (402 pt) without a device
/// rotation or a second size class.
///
/// Run one method at a time with the launcher, never by hand (it owns the
/// slot's simulator, DerivedData and stub port, and refuses a skipped scenario):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/viewer-topbar-<méthode>.log \
///         UITests/stubs/immich_stub_viewer_top_bar.py ViewerTopBarUITests/<méthode> --erase
final class ViewerTopBarUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The shell's first timeline asset: the viewer opens on it with no route
    /// of the scenario's own.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

    // MARK: - Fixtures the stub serves (see immich_stub_viewer_top_bar.py)

    /// Narrow place: two lines fit at 402 pt, the collapsed row with it too.
    private let shortPlace = "Ogre"
    /// Long place: even the "⋯ seul" row cannot fit it on two lines (SP-4).
    private let longPlace = "Göreme Belediyesi Karayolları Müdürlüğü"
    /// The date the stub stamps on every asset, in the app's French locale.
    private let date = "2 mai 2025"

    // MARK: - Label families (fr-FR is pinned in setUp; the families keep the
    // scenario honest if the catalog answers in another language)

    /// Details' label, on the pill and in the "⋯" menu.
    private let detailsLabels = ["Détails", "Details"]
    /// Cast's label, disconnected family, on the pill and in the "⋯" menu.
    private let castLabels = ["Cast", "Diffuser", "Übertragen", "Transmitir", "Trasmetti"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Pinned on EVERY launch: the badge's width depends on the locale, and
        // the expected strings above are French.
        app.launchArguments += ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        // Skip-vs-run only, so a full-scheme run without a stub stays green.
        // `uitest.sh` starts the stub first and treats a skip as a failure.
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
    // Copied from `ChromecastUITests` on purpose: they are `private` there, and
    // one file per feature (helpers included) is the harness rule.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects.
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

    /// Arms the place the next launch shows, then relaunches: the timeline (and
    /// with it every asset's `city`) is fetched at launch, not on demand.
    private func armPlace(_ place: String) {
        var request = URLRequest(url: URL(string: "\(stub)/control/place")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["place": place])
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /control/place")
        XCTAssertTrue(body.contains("\"armed\": true"), "the place was not armed: \(body)")
        if app.state != .notRunning { app.terminate() }
        app.launch()
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

    /// The provider page lives in `SafariViewService`, a separate process.
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
        // A warm slot seeds the PREVIOUS run's URL, and `typeText` APPENDS: it is
        // cleared before typing rather than trusted.
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
        // The keyboard sits over the CTA: scrolling dismisses it, with a bounded
        // retry for the frame the keyboard was still animating over.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("vt02-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: \(screenLabels())")
        }
    }

    /// Any element carrying `identifier`, whatever its type.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Everything on screen, for a failure message that says what the app showed.
    private func screenLabels() -> String {
        app.descendants(matching: .any).allElementsBoundByIndex
            .filter { !$0.label.isEmpty }
            .map { "\($0.identifier.isEmpty ? "-" : $0.identifier)=\($0.label)" }
            .joined(separator: " | ")
    }

    /// A top-bar button that is on the row: a live pill, by identifier.
    private func livePill(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    /// An item of the "⋯" menu: by identifier, else by label. A menu item may
    /// publish as `.menuItem` or `.button`, so the search is `.any`.
    private func menuItem(id: String, labels: [String]) -> XCUIElement {
        let anyElement = app.descendants(matching: .any)
        let byId = anyElement.matching(identifier: id).firstMatch
        if byId.waitForExistence(timeout: 5) { return byId }
        return anyElement.matching(labelPredicate(labels)).firstMatch
    }

    /// The width a label takes in the badge's font, unrounded (Doc-4). A device
    /// frame lands a fraction of a point off the exact width ("Ogre" measured
    /// 35.14, frame 35.33), so a frame must be at least this wide less 1 pt —
    /// a squeeze to the 10 pt defect is far outside that. `ceil` would demand
    /// a width the text never gets (measured 2026-10-08: 35.33 < 36).
    private func textWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width - 1
    }

    /// Walks onboarding if it shows, then clears the "What's New" sheet that a
    /// fresh install presents over the shell. Leaves the app on the shell.
    private func reachShell() {
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }
    }

    /// Opens the photo in the viewer and waits for its top bar to be up.
    private func openTimelineViewer() {
        let tile = element("assetTile_\(photo)")
        XCTAssertTrue(tile.waitForExistence(timeout: 30),
                      "the timeline never rendered \(photo) against \(stub) — screen reads: \(screenLabels())")
        tile.tap()
        let chrome = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        if !chrome.waitForExistence(timeout: 20) {
            shot("vt-no-viewer-chrome")
            XCTFail("the viewer never showed its top bar — screen reads: \(screenLabels())")
        }
    }

    /// The badge's two lines, asserted once for both the readable and the
    /// trash methods: each line whole, and the date under the place.
    private func assertBadgeWhole(place: String) {
        let placeLine = element("viewerBadgePlace")
        let dateLine = element("viewerBadgeDate")
        XCTAssertTrue(placeLine.waitForExistence(timeout: 10),
                      "the badge has no place line — screen reads: \(screenLabels())")
        XCTAssertTrue(dateLine.waitForExistence(timeout: 10),
                      "the badge has no date line — screen reads: \(screenLabels())")
        XCTAssertEqual(placeLine.label, place)
        XCTAssertEqual(dateLine.label, date)
        XCTAssertGreaterThanOrEqual(placeLine.frame.width, textWidth(place, size: 15, weight: .semibold),
                                    "the place line is squeezed: frame=\(placeLine.frame)")
        XCTAssertGreaterThanOrEqual(dateLine.frame.width, textWidth(date, size: 13, weight: .regular),
                                    "the date line is squeezed: frame=\(dateLine.frame)")
        XCTAssertGreaterThanOrEqual(dateLine.frame.minY, placeLine.frame.maxY - 1,
                                    "the date is not under the place: place=\(placeLine.frame) date=\(dateLine.frame)")
    }

    // MARK: - Scenarios

    /// AC-1 (B-1), AC-4a (B-3): at 402 pt the place and date are shown whole,
    /// on two lines, and neither is squeezed below its own measured width.
    func test_viewerTopBarBadgeIsReadable() throws {
        reset()
        setProvider("manual")
        armPlace(shortPlace)
        reachShell()
        openTimelineViewer()
        shot("vt01-viewer-badge")
        assertBadgeWhole(place: shortPlace)
    }

    /// AC-2 (B-2): with the badge and four actions wider than 402 pt, the row
    /// keeps what fits and gathers the last two behind "⋯"; each collapsed
    /// action is reachable from the menu, and the menu's Details opens the panel.
    func test_viewerTopBarCollapsesTrailingActions() throws {
        reset()
        setProvider("manual")
        armPlace(shortPlace)
        reachShell()
        openTimelineViewer()

        XCTAssertTrue(livePill("viewerSlideshowButton").exists, "Slideshow must stay on the row")
        XCTAssertTrue(livePill("viewerOcrToggle").exists, "Detected text must stay on the row")
        XCTAssertFalse(livePill("viewerCastButton").exists, "Cast must be collapsed at 402 pt")
        XCTAssertFalse(livePill("viewerDetailsButton").exists, "Details must be collapsed at 402 pt")

        let overflow = livePill("viewerOverflowMenu")
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), "the ⋯ pill is missing — screen reads: \(screenLabels())")
        XCTAssertTrue(overflow.isHittable, "the ⋯ pill cannot be tapped")
        overflow.tap()
        shot("vt02-overflow-open")

        let cast = menuItem(id: "viewerMenuCast", labels: castLabels)
        XCTAssertTrue(cast.exists, "Cast is not in the ⋯ menu — screen reads: \(screenLabels())")
        let details = menuItem(id: "viewerMenuDetails", labels: detailsLabels)
        XCTAssertTrue(details.exists, "Details is not in the ⋯ menu — screen reads: \(screenLabels())")
        details.tap()

        let infoClose = element("viewerInfoClose")
        XCTAssertTrue(infoClose.waitForExistence(timeout: 20),
                      "the menu's Details did not open the info panel — screen reads: \(screenLabels())")
        shot("vt03-details-from-menu")
    }

    /// AC-4b (B-3): a place too long for two lines, even with every action
    /// collapsed, becomes one truncated line that carries both place and date.
    func test_viewerTopBarKeepsTheSingleLineFallback() throws {
        reset()
        setProvider("manual")
        armPlace(longPlace)
        reachShell()
        openTimelineViewer()

        let single = element("viewerBadgeSingleLine")
        XCTAssertTrue(single.waitForExistence(timeout: 10),
                      "the badge did not fall back to one line — screen reads: \(screenLabels())")
        XCTAssertTrue(single.label.contains(longPlace), "the one line lost the place: \(single.label)")
        XCTAssertTrue(single.label.contains(date), "the one line lost the date: \(single.label)")
        XCTAssertLessThanOrEqual(single.frame.width, 230, "the one line takes more than the row leaves it: \(single.frame)")
        XCTAssertLessThan(single.frame.height, 30, "the one line grew into two: \(single.frame)")
        XCTAssertFalse(element("viewerBadgePlace").exists, "the two-line place must not exist in the fallback")
        shot("vt04-single-line")
    }

    /// AC-3 (B-2), AC-5 (B-4): the trash viewer has three actions and no Cast.
    /// At 402 pt they all stay live — no "⋯" — and the badge keeps its two lines
    /// at the same measured width: the bar that was never squeezed is unchanged.
    func test_trashViewerKeepsEveryAction() throws {
        reset()
        setProvider("manual")
        armPlace(shortPlace)
        reachShell()

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "Profile avatar missing")
        hub.tap()
        let trash = app.descendants(matching: .any).matching(identifier: "trashRow").firstMatch
        for _ in 0..<6 where !trash.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(trash.waitForExistence(timeout: 15), "the trash row is missing from the Me hub")
        trash.tap()

        let firstTrashed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'")).firstMatch
        XCTAssertTrue(firstTrashed.waitForExistence(timeout: 30),
                      "the trash never rendered an asset — screen reads: \(screenLabels())")
        firstTrashed.tap()
        let chrome = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(chrome.waitForExistence(timeout: 20), "the trash viewer never showed its top bar")
        shot("vt05-trash-viewer")

        XCTAssertFalse(livePill("viewerOverflowMenu").exists,
                       "the trash viewer collapsed an action — it has three, all of which fit at 402 pt")
        XCTAssertTrue(livePill("viewerSlideshowButton").exists, "Slideshow must be live in the trash")
        XCTAssertTrue(livePill("viewerOcrToggle").exists, "Detected text must be live in the trash")
        XCTAssertTrue(livePill("viewerDetailsButton").exists, "Details must be live in the trash")
        XCTAssertFalse(livePill("viewerCastButton").exists, "the trash has no Cast")

        assertBadgeWhole(place: shortPlace)
    }
}
