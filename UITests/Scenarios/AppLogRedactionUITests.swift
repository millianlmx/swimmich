import UIKit
import XCTest

/// End-to-end proof of need B-15 on a real failure: what the App Logs screen
/// lists, what its detail screen displays and what "Copy" puts on the clipboard
/// carry no part of the server's address.
///
/// The app is pointed at `<stub>/immich` — an installation served under a
/// sub-path, the one part of a server's address a real request writes into a
/// log line's `path` and `message`. The stub notes the raw paths it received, so
/// the scenario first asserts that the raw request DID carry `/immich`: without
/// that, "the log has no `/immich`" could be true for lack of anything to hide.
/// The host and the token that a transport error may quote are proved by the
/// unit tests (`AppLogRedactionTests`), on the production buffer; a lost
/// connection, the failure this stub provokes, names neither.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/app-log.uitest.log \
///         UITests/stubs/immich_stub_app_log.py \
///         AppLogRedactionUITests/test_AC_130_listDetailAndClipboardCarryNoAddressNorToken --erase
///
/// `--erase` is required: a first onboarding and an empty log are what the
/// assertions read.
final class AppLogRedactionUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    /// The access token `immich_stub_app_log.py` hands the app. Both files own
    /// this literal; change them together.
    private let token = "stub-applog-token-5c1e7a20"
    /// The character `AppLogEntry.message` puts between a call and its outcome.
    private let arrow = "\u{2192}"
    private let statisticsPath = "/api/assets/statistics"

    private var app: XCUIApplication!

    /// What the app is told to talk to: the stub, under the sub-path.
    private var serverAddress: String { stub + "/immich" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(serverAddress)/api/server/ping") else { return false }
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

    // MARK: - Stub controls

    private func get(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer \(path)")
        return body
    }

    private func setProvider(_ mode: String) {
        XCTAssertEqual(get("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    private func setDropping(_ dropping: Bool) {
        let body = get("/control/drop?on=\(dropping ? 1 : 0)")
        XCTAssertTrue(body.contains(dropping ? "true" : "false"), "the stub did not arm/disarm the drop: \(body)")
    }

    private func rawPaths() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(get("/control/raw-paths").utf8))) ?? []
    }

    // MARK: - Helpers (copied from `AppUtilitiesUITests`, one file per feature)

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
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

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let direct = app.buttons.matching(predicate).firstMatch
        let contained = app.buttons.containing(predicate).firstMatch
        for candidate in [direct, contained] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    /// Welcome → server URL (the stub, under `/immich`) → login.
    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != serverAddress {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != serverAddress {
            field.typeText(serverAddress)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<14 where !row.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
        }
        return row
    }

    private func goBack(_ titles: [String]) {
        let titled = app.navigationBars.matching(labelPredicate(titles)).firstMatch
        let bar = titled.waitForExistence(timeout: 10) ? titled : app.navigationBars.firstMatch
        let back = bar.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from this screen")
        back.tap()
        Thread.sleep(forTimeInterval: 0.9)
    }

    /// The log screen's rows: `AppLogRow` combines its children into one
    /// element labelled `"<level> <message>"`, and the arrow tells a row apart
    /// from the picker, the toolbar and the titles.
    private func logRows() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", arrow))
            .allElementsBoundByIndex
            .map(\.label)
    }

    /// Scrolls the list until a row satisfies `accepts` (bounded), and returns it.
    private func revealRow(where accepts: (String) -> Bool) -> String {
        for _ in 0..<12 {
            if let hit = logRows().first(where: accepts) { return hit }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }
        return logRows().first(where: accepts) ?? ""
    }

    /// The system pasteboard, read from the runner. Reading another app's copy
    /// may raise the "Allow Paste" prompt, which only a poll on SpringBoard can
    /// answer while the read waits on a background queue.
    private func readClipboard() -> String {
        var value: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            value = UIPasteboard.general.string
            done.signal()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(15)
        while done.wait(timeout: .now() + 0.5) == .timedOut && Date() < deadline {
            for label in ["Allow Paste", "Autoriser le collage", "Einfügen erlauben"] {
                let button = springboard.alerts.buttons[label]
                if button.exists { button.tap() }
            }
        }
        return value ?? ""
    }

    // MARK: - Scenario

    func test_AC_130_listDetailAndClipboardCarryNoAddressNorToken() throws {
        _ = get("/__reset")
        setProvider("manual")
        app.launch()

        // MARK: Sign in against `<stub>/immich`

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

        // MARK: A real failure: Media Stats while the stub drops the connection

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        Thread.sleep(forTimeInterval: 3.5)

        setDropping(true)
        XCTAssertTrue(hubRow("mediaStatsRow").waitForExistence(timeout: 5), "Media Stats row missing")
        hubRow("mediaStatsRow").tap()
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Try Again", "Réessayer"]))
            .firstMatch.waitForExistence(timeout: 25),
                      "the dropped connection never surfaced on Media Stats")
        setDropping(false)

        // PRE-ASSERTION: the raw request really carried the sub-path, so a log
        // without `/immich` below is the masking at work, not an empty target.
        XCTAssertTrue(rawPaths().contains("/immich\(statisticsPath)"),
                      "the stub never received /immich\(statisticsPath) — raw paths: \(rawPaths())")

        goBack(["Media Stats", "Statistiques"])
        hubRow("appLogsRow").tap()
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "the App Logs screen never loaded")
        Thread.sleep(forTimeInterval: 1.2)

        // MARK: The list

        let url = URL(string: stub)!
        let forbidden = ["/immich", url.host ?? "127.0.0.1", ":\(url.port ?? 8421)", token]
        func assertClean(_ text: String, _ context: String, allowQuestionMark: Bool = false) {
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(context) carries \(needle): \(text)")
            }
            XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"), "\(context) carries a bearer: \(text)")
            if !allowQuestionMark {
                XCTAssertFalse(text.contains("?"), "\(context) carries a query: \(text)")
            }
        }

        let failing = revealRow { $0.lowercased().hasPrefix("severe") && $0.contains(self.statisticsPath) }
        XCTAssertTrue(failing.lowercased().hasPrefix("severe") && failing.contains("\(statisticsPath) \(arrow)"),
                      "no severe line for the dropped statistics call — rows:\n\(logRows().joined(separator: "\n"))")
        for row in logRows() { assertClean(row, "a log row") }

        // MARK: The detail and the clipboard

        let rowElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'severe' AND label CONTAINS %@", statisticsPath))
            .firstMatch
        XCTAssertTrue(rowElement.waitForExistence(timeout: 10), "the failing row vanished")
        rowElement.tap()
        XCTAssertTrue(element("copyLogBlock_message").waitForExistence(timeout: 15), "the detail never opened")

        for section in ["message", "details", "stack"] {
            let copy = element("copyLogBlock_\(section)")
            for _ in 0..<6 where !copy.isHittable {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.5)
            }
            XCTAssertTrue(copy.exists, "the failing line has no \(section) block")
            copy.tap()
            Thread.sleep(forTimeInterval: 0.8)

            let copied = readClipboard()
            XCTAssertFalse(copied.isEmpty, "the \(section) block copied nothing")
            // A call stack is symbols, where a `?` is not a leaked query.
            assertClean(copied, "the copied \(section) block", allowQuestionMark: section == "stack")

            let shown = app.staticTexts.matching(NSPredicate(format: "label == %@", copied)).firstMatch
            XCTAssertTrue(shown.exists, "the copied \(section) block differs from the one on screen")
        }
        for text in app.staticTexts.allElementsBoundByIndex.map(\.label) {
            assertClean(text, "a block on screen", allowQuestionMark: true)
        }
    }
}
