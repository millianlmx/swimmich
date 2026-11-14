import XCTest

/// End-to-end scenario for "Remaining to back up" (L-32): the Backup screen's
/// entry and the list behind it, over the real Photos library of the simulator.
///
/// It drives the real app: onboarding → SSO → the "Me" hub → Backup →
/// "Remaining to back up" (Photos access asked from the list itself) → the
/// seeded photos listed → "Run now" against a server that accepts everything →
/// the entry falls to 0 and the list says everything is backed up. The wire
/// proves the pass sent the seeded photos.
///
/// A wiped simulator also holds its own sample photos (six, dated 2009 to
/// 2018), so nothing here counts absolutely: the seeded media are recognised by
/// the CURRENT YEAR in their row's label (they are the most recent, hence first)
/// and every count is an inclusion.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/backup-remainder.uitest.log \
///         UITests/stubs/immich_stub_backup_remainder.py \
///         BackupRemainderUITests/test_AC_65_remainderFromBackupScreen \
///         --erase --media /tmp/media-a.png --media /tmp/media-b.png --media /tmp/media-c.png
final class BackupRemainderUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var promptsSeen: [String] = []

    /// The year every seeded media carries in its date, whatever the language.
    private let currentYear = String(Calendar.current.component(.year, from: Date()))

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A monitor registered here runs BEFORE XCUITest's default, which would
        // answer the Photos prompt with "add only" and leave the list without
        // access.
        addUIInterruptionMonitor(withDescription: "Photos access") { [weak self] alert in
            let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
            self?.promptsSeen.append(labels.joined(separator: "|"))
            let fullAccess = alert.buttons.matching(Self.labelsContain(Self.fullAccessLabels))
            if fullAccess.firstMatch.exists {
                fullAccess.firstMatch.tap()
                return true
            }
            let allow = alert.buttons.matching(Self.labelsContain(Self.allowLabels))
            guard allow.firstMatch.exists else { return false }
            allow.firstMatch.tap()
            return true
        }
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

    // MARK: - Helpers (copied from `UploadDetailUITests`: one file per feature)

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

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

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        Self.labelsContain(labels)
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

    private static let fullAccessLabels = [
        "Allow Full Access", "Allow Access to All Photos",
        "Autoriser l'accès complet", "Autoriser l'accès à toutes",
        "Accès complet", "Vollständiger Zugriff", "Vollen Zugriff",
        "Erlauben", "Permitir el acceso completo", "Consenti l'accesso completo",
    ]

    private static let allowLabels = ["Allow", "Autoriser", "Erlauben", "Permitir", "Consenti"]

    /// `label CONTAINS` over several labels, labels BOUND as arguments (an inline
    /// `NSPredicate(format:)` without `argumentArray` kills the runner).
    private static func labelsContain(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    /// Answers the permission prompts the app raises (Photos, notifications):
    /// both trees are searched, full access is preferred, and the loop keeps
    /// answering until no prompt has appeared for a few seconds.
    @discardableResult
    private func answerPermissionPrompts(window: TimeInterval = 30) -> [String] {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(window)
        var quietSince = Date()
        var journal: [String] = []
        while Date() < deadline {
            var tapped = false
            for alerts in [app.alerts, springboard.alerts] {
                let alert = alerts.firstMatch
                guard alert.exists else { continue }
                promptsSeen.append(alert.buttons.allElementsBoundByIndex
                    .map(\.label).joined(separator: "|"))
                let fullAccess = alert.buttons.matching(Self.labelsContain(Self.fullAccessLabels))
                let generic = alert.buttons.matching(Self.labelsContain(Self.allowLabels))
                guard let button = [fullAccess.firstMatch, generic.firstMatch].first(where: \.exists) else {
                    journal.append("unmatched: " + alert.buttons.allElementsBoundByIndex
                        .map(\.label).joined(separator: "|"))
                    shot("remainder-unknown-permission-prompt")
                    return journal
                }
                journal.append(button.label)
                button.tap()
                tapped = true
                break
            }
            if tapped {
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) > 5 {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return journal
    }

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
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
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("remainder-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// A row of a pushed screen, by IDENTIFIER (labels are localized five ways).
    /// A `Form` only publishes what it rendered, so it is scrolled into view:
    /// first the requested way, then back the other way — at AX5 the entry sits
    /// far below the fold, at the default size it is already on screen.
    private func row(_ identifier: String, swiping direction: String = "up",
                     swipes: Int = 10) -> XCUIElement {
        let element = app.buttons.matching(identifier: identifier).firstMatch
        func reachable() -> Bool { element.exists && element.isHittable }
        for way in [direction, direction == "down" ? "up" : "down"] {
            for _ in 0..<swipes where !reachable() {
                if way == "down" { app.swipeDown() } else { app.swipeUp() }
                _ = element.waitForExistence(timeout: 1)
            }
            if reachable() { break }
        }
        return element
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(what)")
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let deviceAssetId: String?
        let fileCreatedAt: String?
        let outcome: String?
    }

    private func uploads() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 12), .success, "stub did not answer /__requests")
        let all = (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
        return all.filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    // MARK: - Navigation

    /// Onboarding → SSO → the shell → the "Me" hub → the Backup screen.
    private func openBackupScreen() {
        reset()
        setProvider("manual")
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
        let backupRow = row("backupRow")
        XCTAssertTrue(backupRow.waitForExistence(timeout: 10), "Backup row missing in the Me hub")
        backupRow.tap()
    }

    /// Opens the list from the Backup screen and grants Photos access from it.
    private func openRemainderList() {
        let remainderRow = row("backupRemainderRow", swiping: "up", swipes: 12)
        XCTAssertTrue(remainderRow.waitForExistence(timeout: 20), "no \"Remaining to back up\" row")
        remainderRow.tap()
        XCTAssertTrue(element("backupRemainderScreen").waitForExistence(timeout: 15), "the list never opened")
        let allow = app.buttons.matching(identifier: "backupRemainderAllowAccessButton").firstMatch
        if allow.waitForExistence(timeout: 10) {
            allow.tap()
            answerPermissionPrompts()
        }
    }

    /// The rows of the seeded media: current year in the label.
    private func seededRows() -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'remainderAsset_' AND label CONTAINS %@",
            argumentArray: [currentYear]
        ))
    }

    /// Returns to the previous screen: the first hittable button of the most
    /// recently added navigation bar, since a covered screen's bar can also be
    /// in the tree (see `AlbumSyncUITests.goBack`).
    private func goBack() {
        for bar in app.navigationBars.allElementsBoundByIndex.reversed() {
            let back = bar.buttons.firstMatch
            if back.exists && back.isHittable {
                back.tap()
                return
            }
        }
        app.swipeRight()
    }

    /// One line that says what the screen holds, for an assertion message: the CI
    /// log keeps a failure's first line only, and no screenshot reaches it.
    private func diagnostics() -> String {
        let bars = app.navigationBars.allElementsBoundByIndex.map { bar in
            "\(bar.identifier)[" + bar.buttons.allElementsBoundByIndex.map(\.label).joined(separator: ",") + "]"
        }
        let identifiers = app.descendants(matching: .any).allElementsBoundByIndex
            .map(\.identifier).filter { !$0.isEmpty }
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label)
        return "bars=\(bars) ids=\(Array(Set(identifiers)).sorted().prefix(40)) texts=\(texts)"
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - AC-65

    func test_AC_65_remainderFromBackupScreen() throws {
        openBackupScreen()
        shot("remainder-01-backup")
        openRemainderList()

        // The three seeded media are listed, with a name and a date.
        waitUntil(15, "at least 3 rows dated this year") { seededRows().count >= 3 }
        shot("remainder-02-list")
        let seeded = Set((0..<seededRows().count).map {
            seededRows().element(boundBy: $0).identifier.replacingOccurrences(of: "remainderAsset_", with: "")
        })
        XCTAssertGreaterThanOrEqual(seeded.count, 3, "the seeded media must be listed")

        // The entry counts them (and the sample photos of a wiped simulator).
        goBack()
        let count = app.staticTexts.matching(identifier: "backupRemainderCount").firstMatch
        waitUntil(15, "the entry's count") {
            let value = count.exists ? Int(count.label) : nil
            return (value ?? 0) >= 3
        }
        let before = Int(count.label) ?? 0
        XCTAssertGreaterThanOrEqual(before, 3)

        // A pass that accepts everything sends the lot.
        let runNow = row("runBackupButton")
        XCTAssertTrue(runNow.waitForExistence(timeout: 20), "the Backup screen has no Run now button")
        runNow.tap()
        answerPermissionPrompts()

        // Back to the top of the screen, where the entry lives, and watch it fall.
        _ = row("backupRemainderRow", swiping: "down")
        waitUntil(120, "the entry to fall to 0") { count.exists && count.label == "0" }
        shot("remainder-03-entry-zero")

        // The count falls as the pass records each photo, while the pass is still
        // running (album mirror, tracking): the Form re-lays out under a finger
        // until "Run now" is back. Reopen the list only once the pass is over.
        // The button sits in the progress section, below the fold: scroll to it.
        waitUntil(120, "the pass to end (Run now is back)") {
            let button = row("runBackupButton", swiping: "up", swipes: 4)
            return button.exists && button.isHittable
        }

        // The list now says everything is backed up. Reopen the Backup screen from
        // the hub so it opens at the top, the entry fully on screen: an entry
        // scrolled back into view sits under the bar's edge, and a tap there
        // pushes nothing.
        goBack()
        // The hub comes back where it was when Backup was opened, its row on
        // screen: no swipe here, a downward swipe would dismiss the sheet.
        let backupRow = app.buttons.matching(identifier: "backupRow").firstMatch
        XCTAssertTrue(backupRow.waitForExistence(timeout: 15) && backupRow.isHittable,
                      "no way back to the Me hub — \(diagnostics())")
        backupRow.tap()
        let remainderRow = app.buttons.matching(identifier: "backupRemainderRow").firstMatch
        let entryDeadline = Date().addingTimeInterval(20)
        while !(remainderRow.exists && remainderRow.isHittable), Date() < entryDeadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(remainderRow.exists && remainderRow.isHittable, "the entry must be reachable — \(diagnostics())")
        remainderRow.tap()
        // The diagnostic comes BEFORE the assertion: with `continueAfterFailure`
        // off, nothing after a failed assertion runs.
        let screen = element("backupRemainderScreen")
        let reopened = screen.waitForExistence(timeout: 15)
        if !reopened {
            shot("remainder-04-not-reopened")
            print("TREE \(app.debugDescription)")
        }
        XCTAssertTrue(reopened, "the list never reopened — \(diagnostics())")
        let emptyState = element("backupRemainderEmptyState")
        let explained = emptyState.waitForExistence(timeout: 15)
        if !explained {
            shot("remainder-04-no-empty-state")
            print("TREE \(app.debugDescription)")
        }
        XCTAssertTrue(explained, "an empty list must explain itself — \(diagnostics())")
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'remainderAsset_'")).count, 0)
        shot("remainder-04-empty")

        // The wire: every seeded media went up, dated this year.
        let sent = uploads()
        let sentIDs = Set(sent.compactMap(\.deviceAssetId))
        XCTAssertTrue(sentIDs.isSuperset(of: seeded),
                      "the pass must have uploaded the seeded media — sent \(sentIDs), seeded \(seeded)")
        for request in sent where seeded.contains(request.deviceAssetId ?? "") {
            XCTAssertTrue((request.fileCreatedAt ?? "").hasPrefix(currentYear),
                          "an upload carried the wrong date: \(request)")
        }
    }

    // MARK: - AC-65.9

    func test_AC_65_9_rowsReadableAtAX5() throws {
        openBackupScreen()
        openRemainderList()

        let first = seededRows().firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "the seeded media must be listed")
        shot("remainder-ax5-list")
        XCTAssertTrue(first.isHittable, "the row must be reachable at AX5")
        XCTAssertTrue(first.label.lowercased().contains(".png"),
                      "the file name must be readable, whole — label: \(first.label)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(first.frame.maxX, window.maxX + 0.5, "the row must not overflow the window")
        XCTAssertGreaterThanOrEqual(first.frame.minX, window.minX - 0.5)
    }
}
