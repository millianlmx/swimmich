import UIKit
import XCTest

/// End-to-end proof of lot L-28 "Connexion et démarrage comme le client officiel"
/// (AC-53 to AC-56, AC-330 to AC-346) against `immich_stub_login.py`.
///
/// Targets `accessibilityIdentifier`s. A localized text is read only where the
/// criterion IS about the text: the field names of AC-339 (compared with the
/// catalogue), the default SSO label of AC-332 and the expiry message of AC-342.
/// The welcome button, the tab bar and the navigation bar's back button carry no
/// identifier in the app: they are reached by position or by their English label
/// (every launch passes `-AppleLanguages (en)`, AC-339 excepted).
///
/// Run one test per erased simulator with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/login.uitest.log \
///         UITests/stubs/immich_stub_login.py \
///         LoginStartupUITests/test_AC_53 --erase
///
/// Every test resets the stub (`/__reset`) and starts its app from a state it
/// builds itself: `launchFresh()` passes `-authServerURL ()` (restore finds no
/// server and wipes the token, so the onboarding is guaranteed) and
/// `-uiTestResetClientCertificates YES`; a stored session is a password sign-in
/// in the onboarding followed by `app.terminate()`.
final class LoginStartupUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The shell's day and its photos: `aaaaaaaa-1111-4111-8111-00000000000<n>`.
    private let day = "2026-09-01"
    /// The memory `GET /api/memories` serves (`immich_stub_login.MEMORY`).
    private let memoryID = "dddddddd-4444-4444-8444-000000000001"

    private let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    private let probeArguments = ["-uiTestServerCheckProbe", "YES"]
    private let freshArguments = ["-authServerURL", "()", "-uiTestResetClientCertificates", "YES"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The Photos prompt of a manual backup (AC-344): FULL access, like
        // `SyncBadgeUITests`; every other alert goes to the default handler.
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            guard let button = Self.fullAccessButton(in: alert) else { return false }
            button.tap()
            return true
        }
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
        _ = get("/__reset")
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    // MARK: - Stub

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

    private func query(_ value: String) -> String {
        value.addingPercentEncodingForQuery
    }

    /// `/control/server`: only the given parameters change.
    private func server(version: String? = nil, password: Bool? = nil, oauth: Bool? = nil,
                        buttonText: String? = nil, features: String? = nil) {
        var items: [String] = []
        if let version { items.append("version=\(query(version))") }
        if let password { items.append("password=\(password ? 1 : 0)") }
        if let oauth { items.append("oauth=\(oauth ? 1 : 0)") }
        if let buttonText { items.append("buttonText=\(query(buttonText))") }
        if let features { items.append("features=\(query(features))") }
        let body = get("/control/server?" + items.joined(separator: "&"))
        XCTAssertTrue(body.contains("\"version\""), "the stub did not take /control/server: \(body)")
    }

    private func revoke(_ on: Bool) {
        XCTAssertTrue(get("/control/revoke?on=\(on ? 1 : 0)").contains(on ? "true" : "false"), "revoke not taken")
    }

    private func mute(_ mode: String, seconds: Int = 0) {
        XCTAssertTrue(get("/control/mute?mode=\(mode)&seconds=\(seconds)").contains("\"\(mode)\""), "mute not taken")
    }

    private func delay(_ path: String, seconds: Int) {
        XCTAssertTrue(get("/control/delay?path=\(query(path))&seconds=\(seconds)").contains("delays"), "delay not taken")
    }

    private func setAsset(_ id: String, status: Int) {
        XCTAssertTrue(get("/control/asset?id=\(id)&status=\(status)").contains("assetStatus"), "asset status not taken")
    }

    private struct Entry: Decodable {
        let method: String
        let path: String
    }

    private func journal() -> [Entry] {
        (try? JSONDecoder().decode([Entry].self, from: Data(get("/__requests").utf8))) ?? []
    }

    private func count(_ method: String, _ path: String) -> Int {
        journal().filter { $0.method == method && $0.path == path }.count
    }

    // MARK: - Fixtures

    private func photo(_ n: Int) -> String { String(format: "aaaaaaaa-1111-4111-8111-%012d", n) }

    private func link(_ n: Int) -> URL { URL(string: "app.immich://asset/\(photo(n))?day=\(day)")! }

    /// The other spelling of the stub's address (`127.0.0.1` ↔ `localhost`): a
    /// second server for the app, the same process for the stub.
    private func otherForm(of address: String) -> String {
        if address.contains("127.0.0.1") { return address.replacingOccurrences(of: "127.0.0.1", with: "localhost") }
        if address.contains("localhost") { return address.replacingOccurrences(of: "localhost", with: "127.0.0.1") }
        return address + "/"
    }

    // MARK: - Generic helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenText() -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(24).joined(separator: " | ")
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func assertAbsent(_ identifiers: [String], _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for identifier in identifiers {
            XCTAssertFalse(element(identifier).exists, "\(identifier) is on screen: \(context)", file: file, line: line)
        }
    }

    private func tile(_ n: Int) -> XCUIElement { element("assetTile_\(photo(n))") }

    private func tabButton(_ title: String) -> XCUIElement { app.tabBars.buttons[title] }

    // MARK: - Launching

    /// A launch that ends on the welcome screen: no server, no token.
    private func launchFresh(language: [String]? = nil, extra: [String] = []) {
        app.terminate()
        app.launchArguments = (language ?? english) + probeArguments + freshArguments + extra
        app.launch()
        XCTAssertTrue(element("welcomeTitle").waitForExistence(timeout: 30),
                      "the onboarding did not open — \(screenText())")
    }

    /// A launch that keeps the stored session.
    private func launchStored(extra: [String] = []) {
        app.terminate()
        app.launchArguments = english + probeArguments + extra
        app.launch()
    }

    // MARK: - Onboarding walk (identifiers)

    /// Welcome → server step. The welcome CTA is the only button of the screen
    /// and has no identifier.
    private func openServerStep() {
        let cta = app.buttons.firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "the welcome button is missing")
        cta.tap()
        XCTAssertTrue(app.textFields.matching(identifier: "serverURLField").firstMatch.waitForExistence(timeout: 20),
                      "the server step did not open — \(screenText())")
    }

    private func enterServer(_ address: String) {
        let field = app.textFields.matching(identifier: "serverURLField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the server field is missing")
        field.tap()
        // An empty field reports its placeholder as its value: the extra deletes are harmless.
        let current = (field.value as? String) ?? ""
        if current != address {
            if !current.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(address)
        }
    }

    private func tapContinueButton() {
        let button = app.buttons.matching(identifier: "serverURLContinueButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the server step has no primary button")
        for _ in 0..<3 where !button.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
        }
        button.tap()
    }

    private var probe: XCUIElement { element("serverCheckProbe") }

    private func probeValue() -> String { (probe.value as? String) ?? "" }

    private func checkCount() -> Int {
        for part in probeValue().split(separator: " ") where part.hasPrefix("checks=") {
            return Int(part.dropFirst("checks=".count)) ?? 0
        }
        return 0
    }

    /// Validates the typed address and waits until that validation ended.
    private func checkServer() {
        let before = checkCount()
        tapContinueButton()
        XCTAssertTrue(waitUntil(40) { self.checkCount() > before },
                      "the server check never ended (probe: \(probeValue())) — \(screenText())")
    }

    private func continueToLogin() {
        tapContinueButton()
        XCTAssertTrue(element("loginTitle").waitForExistence(timeout: 20),
                      "the sign-in step did not open — \(screenText())")
    }

    /// Welcome → server → sign-in step, the modes of the server read.
    private func reachLogin(_ address: String? = nil) {
        openServerStep()
        enterServer(address ?? stub)
        checkServer()
        continueToLogin()
        waitForLoginOptions()
    }

    private func waitForLoginOptions() {
        XCTAssertTrue(element("loginOptionsLoading").waitForNonExistence(timeout: 30),
                      "the sign-in modes never arrived — \(screenText())")
    }

    private func signIn(email: String = "stub@example.com", password: String = "stub-password") {
        let emailField = app.textFields.matching(identifier: "loginEmailField").firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 20), "no email field — \(screenText())")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields.matching(identifier: "loginPasswordField").firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "no password field")
        passwordField.tap()
        passwordField.typeText(password)
        let button = app.buttons.matching(identifier: "loginSignInButton").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no sign-in button")
        button.tap()
    }

    /// The Photos tab with its first tile; "What's New" closed (and so seen).
    /// The sheet must be GONE before the caller goes on: its `onDismiss` is what
    /// marks it seen (a `terminate()` that comes first leaves it unseen, and it
    /// covers the next launch), and a sheet presented while it is still leaving
    /// is dropped by UIKit.
    private func reachShell() {
        XCTAssertTrue(tabButton("Photos").waitForExistence(timeout: 40),
                      "the sign-in did not reach the shell — \(screenText())")
        let done = element("whatsNewDoneButton")
        if done.waitForExistence(timeout: 10) {
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 10), "What's New did not close — \(screenText())")
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(tile(1).waitForExistence(timeout: 40), "the timeline never rendered — \(screenText())")
    }

    /// A stored session: password sign-in in the onboarding, then the app is terminated.
    private func storeSession(language: [String]? = nil) {
        launchFresh(language: language)
        reachLogin()
        signIn()
        reachShell()
        app.terminate()
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from this screen")
        back.tap()
        Thread.sleep(forTimeInterval: 0.9)
    }

    /// Polls until the sign-in step shows, failing if any of `identifiers` ever shows before.
    private func waitForLogin(never identifiers: [String], timeout: TimeInterval = 40) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element("loginTitle").exists && Date() < deadline {
            assertAbsent(identifiers, "before the sign-in step")
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(element("loginTitle").exists, "the app never reached the sign-in step — \(screenText())")
        assertAbsent(identifiers, "on the sign-in step")
    }

    // MARK: - Links

    /// The link opens the app from a closed state, once the session is stored.
    private func openCold(_ url: URL) {
        app.terminate()
        app.launchArguments = english + probeArguments
        app.open(url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the link did not bring the app up")
    }

    private func openHot(_ url: URL) {
        app.open(url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the link did not bring the app up")
    }

    /// The viewer is open on its photo: close it and the photo's cell is reachable.
    private func closeViewerAndExpectTile(_ n: Int, _ context: String) {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 40), "\(context): the viewer did not open — \(screenText())")
        back.tap()
        XCTAssertTrue(waitUntil(20) { self.tile(n).exists && self.tile(n).isHittable },
                      "\(context): closing the viewer left no reachable cell for photo \(n)")
    }

    // MARK: - Face ID (simulator Darwin notifications, copied from `AppLockUITests`)

    private enum FaceID {
        private typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
        private typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
        private typealias SetState = @convention(c) (Int32, UInt64) -> UInt32

        private static func symbol<T>(_ name: String, as type: T.Type) -> T {
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            return unsafeBitCast(dlsym(rtldDefault, name)!, to: type)
        }

        private static func post(_ name: String) {
            _ = symbol("notify_post", as: Post.self)(name)
        }

        static func enroll() {
            let name = "com.apple.BiometricKit.enrollmentChanged"
            var token: Int32 = 0
            _ = symbol("notify_register_check", as: Register.self)(name, &token)
            _ = symbol("notify_set_state", as: SetState.self)(token, 1)
            post(name)
        }

        static func match() { post("com.apple.BiometricKit_Sim.pearl.match") }
    }

    private func promptButton(_ springboard: XCUIApplication) -> XCUIElement {
        springboard.buttons.matching(labelPredicate(["Cancel", "Annuler", "Abbrechen"])).firstMatch
    }

    /// Opens the Me sheet and scrolls the hub until `identifier` exists. The tap
    /// is repeated once when the sheet did not come: a presentation asked while
    /// another one is still settling is dropped by UIKit.
    private func openMe(scrollingTo identifier: String) -> XCUIElement {
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "Profile avatar missing")
        avatar.tap()
        if !element("profileList").waitForExistence(timeout: 10) {
            avatar.tap()
        }
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20), "the Me sheet did not open — \(screenText())")
        sleep(2) // the sheet animates in; its Form publishes rows only after
        let target = element(identifier)
        for _ in 0..<8 where !target.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no '\(identifier)' in the Me hub — \(screenText())")
        return target
    }

    /// Turns "Require Face ID" on and concludes the activation prompt with a matching face.
    private func enableAppLock() {
        let toggle = openMe(scrollingTo: "appLockToggle")
        if (toggle.value as? String) != "1" {
            let before = toggle.value as? String
            toggle.tap()
            if !waitUntil(3, { (toggle.value as? String) != before }) {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
            sleep(2) // the activation prompt is presented
            FaceID.match()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            XCTAssertTrue(promptButton(springboard).waitForNonExistence(timeout: 10), "the activation prompt did not close")
        }
        XCTAssertTrue(waitUntil(10) { (toggle.value as? String) == "1" }, "Require Face ID did not turn on")
    }

    // MARK: - System alerts (Photos access, notifications)

    private static func fullAccessButton(in alert: XCUIElement) -> XCUIElement? {
        for needle in ["accès complet", "Full Access", "access to all", "Voller Zugriff", "acceso completo"] {
            let button = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
            if button.exists { return button }
        }
        return nil
    }

    private func answerSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        if let button = Self.fullAccessButton(in: alert) {
            button.tap()
            return
        }
        for label in ["Allow", "Autoriser", "Erlauben", "Consentir"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    // MARK: - Log screen (copied from `AppLogRedactionUITests`)

    private let arrow = "\u{2192}"

    private func logRows() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", arrow))
            .allElementsBoundByIndex
            .map(\.label)
    }

    private func revealRow(where accepts: (String) -> Bool) -> String {
        for _ in 0..<12 {
            if let hit = logRows().first(where: accepts) { return hit }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }
        return logRows().first(where: accepts) ?? ""
    }

    /// The log screen is open: its list and its share button are there.
    private func expectLogScreen(_ context: String) {
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "\(context): the log never opened — \(screenText())")
        XCTAssertTrue(element("appLogShareButton").exists, "\(context): no share button on the log")
    }

    // MARK: - AC-53

    /// AC-53 (B-32): the sign-in step follows the server's modes: SSO only when
    /// the password is refused, both when both are accepted, and — features
    /// unreadable (route absent, error, undecodable) — the password plus an SSO
    /// that follows the configuration's button text.
    func test_AC_53() throws {
        server(password: false, oauth: true)
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginSSOButton").waitForExistence(timeout: 20), "no SSO button — \(screenText())")
        assertAbsent(["loginEmailField", "loginPasswordField", "loginSignInButton"], "password refused, SSO accepted")

        server(password: true, oauth: true)
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginEmailField").waitForExistence(timeout: 20), "no email field with both modes")
        XCTAssertTrue(element("loginPasswordField").exists, "no password field with both modes")
        XCTAssertTrue(element("loginSignInButton").exists, "no sign-in button with both modes")
        XCTAssertTrue(element("loginSSOButton").exists, "no SSO button with both modes")

        for features in ["absent", "error", "bad"] {
            // The booleans a readable route would give (both refused) must not apply.
            server(password: false, oauth: false, buttonText: "Continue with Immich SSO", features: features)
            launchFresh()
            reachLogin()
            XCTAssertTrue(element("loginEmailField").waitForExistence(timeout: 20),
                          "features=\(features): the password form is not shown")
            XCTAssertTrue(element("loginSSOButton").exists, "features=\(features): the SSO follows the configuration's text")
            assertAbsent(["loginDisabledMessage"], "features=\(features)")
        }

        server(buttonText: "", features: "bad")
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginEmailField").waitForExistence(timeout: 20), "no password form with an empty button text")
        assertAbsent(["loginSSOButton"], "unreadable features and an empty button text")
    }

    // MARK: - AC-54

    /// AC-54 (B-32): a server below 2.0.0 gets a notice naming its version and
    /// the minimum, which does not block "Continue"; v3.4.0 gets none.
    func test_AC_54() throws {
        server(version: "1.119.0")
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        let warning = element("serverVersionWarning")
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "no compatibility notice for 1.119.0 — \(screenText())")
        XCTAssertTrue(warning.label.contains("1.119.0"), "the notice does not name the server's version: \(warning.label)")
        XCTAssertTrue(warning.label.contains("2.0.0"), "the notice does not name the minimum: \(warning.label)")
        XCTAssertTrue(app.buttons.matching(identifier: "serverURLContinueButton").firstMatch.isEnabled,
                      "the notice blocks Continue")
        continueToLogin()

        server(version: "3.4.0")
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        XCTAssertTrue(waitUntil(5) { self.element("serverURLContinueButton").exists }, "the server step vanished")
        sleep(1)
        assertAbsent(["serverVersionWarning"], "v3.4.0")
    }

    // MARK: - AC-55

    /// AC-55 (B-32): "App Logs" from the server step, listing and sharing; the
    /// three fields are named in English; the validation emits a success haptic.
    func test_AC_55() throws {
        launchFresh()
        openServerStep()

        let serverField = app.textFields.matching(identifier: "serverURLField").firstMatch
        XCTAssertEqual(serverField.label, "Server URL", "the address field's announced name")
        let logs = app.buttons.matching(identifier: "serverLogsButton").firstMatch
        XCTAssertTrue(logs.waitForExistence(timeout: 10), "no App Logs on the server step")
        logs.tap()
        expectLogScreen("server step")
        goBack()

        enterServer(stub)
        checkServer()
        XCTAssertTrue(waitUntil(10) { self.probeValue().contains("haptic=success#1") },
                      "no success haptic after validating the server (probe: \(probeValue()))")
        continueToLogin()
        waitForLoginOptions()

        XCTAssertEqual(app.textFields.matching(identifier: "loginEmailField").firstMatch.label, "Email")
        XCTAssertEqual(app.secureTextFields.matching(identifier: "loginPasswordField").firstMatch.label, "Password")

        let loginLogs = app.buttons.matching(identifier: "loginLogsButton").firstMatch
        XCTAssertTrue(loginLogs.waitForExistence(timeout: 10), "no App Logs on the sign-in step")
        loginLogs.tap()
        expectLogScreen("sign-in step")
    }

    // MARK: - AC-56

    /// AC-56 (B-32): with a stored session and a server that never answers, the
    /// Photos error state shows in under 3 s; a widget link tapped on a closed
    /// app opens its photo once the session is restored.
    func test_AC_56() throws {
        storeSession()
        mute("drop")
        launchStored()
        XCTAssertTrue(element("timelineLoadErrorState").waitForExistence(timeout: 3),
                      "no error state within 3 s — \(screenText())")
        XCTAssertTrue(element("timelineRetryButton").exists, "no retry button on the error state")

        mute("off")
        openCold(link(3))
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 40),
                      "the link did not open the photo after the cold start — \(screenText())")
    }

    // MARK: - AC-330 … AC-335 (sign-in modes)

    /// AC-330: v3.4.0 reads the public configuration only.
    func test_AC_330() throws {
        server(version: "3.4.0", password: false, oauth: true)
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginSSOButton").waitForExistence(timeout: 20), "no SSO button — \(screenText())")
        assertAbsent(["loginEmailField", "loginPasswordField", "loginSignInButton"], "password off on v3.4.0")
        XCTAssertEqual(count("GET", "/api/server/features"), 0, "the features route was read on v3.4.0")
        XCTAssertGreaterThanOrEqual(count("GET", "/api/public/config"), 1, "the public configuration was never read")
    }

    /// AC-331: a v2.x server reads its features only; they win over the button text.
    func test_AC_331() throws {
        server(version: "2.0.0", password: true, oauth: false, buttonText: "Continue with Immich SSO")
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginEmailField").waitForExistence(timeout: 20), "no email field — \(screenText())")
        XCTAssertTrue(element("loginPasswordField").exists, "no password field")
        XCTAssertTrue(element("loginSignInButton").exists, "no sign-in button")
        assertAbsent(["loginSSOButton"], "oauth refused by the features")
        XCTAssertEqual(count("GET", "/api/public/config"), 0, "the public configuration was read on v2.0.0")
        XCTAssertGreaterThanOrEqual(count("GET", "/api/server/features"), 1, "the features were never read")
    }

    /// AC-332: an empty SSO label falls back to the localized default; tapping starts the SSO.
    func test_AC_332() throws {
        server(password: true, oauth: true, buttonText: "")
        launchFresh()
        reachLogin()
        let sso = element("loginSSOButton")
        XCTAssertTrue(sso.waitForExistence(timeout: 20), "no SSO button with an empty label — \(screenText())")
        XCTAssertEqual(element("loginSSOLabel").label, "Sign in with SSO", "the default SSO label")
        sso.tap()
        XCTAssertTrue(waitUntil(30) { self.count("POST", "/api/oauth/authorize") >= 1 },
                      "tapping the SSO button never reached /api/oauth/authorize")
    }

    /// AC-333: an expired session opens on the sign-in step and reads the modes by itself.
    func test_AC_333() throws {
        storeSession()
        revoke(true)
        server(password: false, oauth: true)
        launchStored()
        waitForLogin(never: ["serverURLField"])
        XCTAssertTrue(element("loginSSOButton").waitForExistence(timeout: 20), "no SSO button after the expiry — \(screenText())")
        assertAbsent(["loginEmailField", "loginPasswordField", "loginSignInButton", "serverURLField"],
                     "expired session on an SSO-only server")
    }

    /// AC-334: nothing of the first server's modes survives a change of server.
    func test_AC_334() throws {
        server(password: true, oauth: false)
        launchFresh()
        reachLogin(stub)
        XCTAssertTrue(element("loginEmailField").waitForExistence(timeout: 20), "the first server shows no password form")
        assertAbsent(["loginSSOButton"], "first server, password only")

        goBack()
        server(password: false, oauth: true)
        enterServer(otherForm(of: stub))
        checkServer()
        continueToLogin()
        XCTAssertTrue(element("loginSSOButton").waitForExistence(timeout: 20), "the second server shows no SSO button — \(screenText())")
        assertAbsent(["loginEmailField", "loginPasswordField", "loginSignInButton"], "second server, SSO only")
    }

    /// AC-335: a server that refuses both modes shows only the message; the log stays reachable.
    func test_AC_335() throws {
        server(password: false, oauth: false)
        launchFresh()
        reachLogin()
        XCTAssertTrue(element("loginDisabledMessage").waitForExistence(timeout: 20), "no disabled-login message — \(screenText())")
        assertAbsent(["loginSignInButton", "loginSSOButton", "loginEmailField", "loginPasswordField"], "login disabled")
        let logs = app.buttons.matching(identifier: "loginLogsButton").firstMatch
        XCTAssertTrue(logs.exists && logs.isEnabled, "App Logs is not reachable on a disabled login")
        XCTAssertEqual(count("POST", "/api/auth/login"), 0, "a login request left")
    }

    // MARK: - AC-336, AC-337 (compatibility notice)

    /// AC-336: a 4.0.0 server is flagged as too new; an unreadable version gives no notice.
    func test_AC_336() throws {
        server(version: "4.0.0")
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        let warning = element("serverVersionWarning")
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "no notice for 4.0.0 — \(screenText())")
        XCTAssertTrue(warning.label.contains("4.0.0"), "the notice does not name the server's version: \(warning.label)")

        for unreadable in ["bad", "error"] {
            server(version: unreadable)
            launchFresh()
            openServerStep()
            enterServer(stub)
            checkServer()
            XCTAssertTrue(waitUntil(5) { self.element("serverURLContinueButton").exists }, "the server step vanished")
            sleep(1)
            assertAbsent(["serverVersionWarning"], "version=\(unreadable)")
            continueToLogin()
        }
    }

    /// AC-337: the notice does not block the sign-in; correcting the address to a v3.4.0 server clears it.
    func test_AC_337() throws {
        server(version: "1.119.0")
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        XCTAssertTrue(element("serverVersionWarning").waitForExistence(timeout: 10), "no notice for 1.119.0")
        continueToLogin()
        waitForLoginOptions()
        signIn()
        reachShell()
        XCTAssertTrue(tabButton("Photos").isSelected, "the sign-in did not land on the Photos tab")

        // A new installation: the notice, then the corrected address on a v3.4.0 server.
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        XCTAssertTrue(element("serverVersionWarning").waitForExistence(timeout: 10), "no notice on the second installation")
        server(version: "3.4.0")
        enterServer(otherForm(of: stub))
        checkServer()
        XCTAssertTrue(waitUntil(5) { self.element("serverURLContinueButton").exists }, "the server step vanished")
        XCTAssertTrue(element("serverVersionWarning").waitForNonExistence(timeout: 10),
                      "the notice survived the corrected address")
    }

    // MARK: - AC-338

    /// AC-338: the failed validation is in the log opened from the server step;
    /// the log carries no address nor token; closing it keeps the typed address.
    func test_AC_338() throws {
        launchFresh()
        openServerStep()
        enterServer(stub)
        mute("drop")
        checkServer()

        let logs = app.buttons.matching(identifier: "serverLogsButton").firstMatch
        XCTAssertTrue(logs.waitForExistence(timeout: 10), "no App Logs on the server step")
        logs.tap()
        expectLogScreen("server step")

        let url = URL(string: stub)!
        let forbidden = [url.host ?? "127.0.0.1", ":\(url.port ?? 8421)"]
        func assertClean(_ text: String, _ context: String) {
            for needle in forbidden {
                XCTAssertFalse(text.contains(needle), "\(context) carries \(needle): \(text)")
            }
            XCTAssertFalse(text.localizedCaseInsensitiveContains("bearer"), "\(context) carries a bearer: \(text)")
        }

        let failing = revealRow { $0.lowercased().hasPrefix("severe") && $0.contains("/api/server/ping") }
        XCTAssertTrue(failing.lowercased().hasPrefix("severe") && failing.contains("/api/server/ping"),
                      "no severe line for the failed ping — rows:\n\(logRows().joined(separator: "\n"))")
        for row in logRows() { assertClean(row, "a log row") }

        let rowElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'severe' AND label CONTAINS '/api/server/ping'"))
            .firstMatch
        XCTAssertTrue(rowElement.waitForExistence(timeout: 10), "the failing row vanished")
        rowElement.tap()
        XCTAssertTrue(element("copyLogBlock_message").waitForExistence(timeout: 15), "the detail never opened")
        // The pasteboard is not read back: the test runner is a background app
        // while the app is in front, and iOS gives it nothing. What a copy button
        // writes is its block's text (`AppLogDetailView`), so the block's text is
        // what is checked, and the button's switch to its "copied" state proves
        // the copy ran.
        for section in ["message", "details", "stack"] {
            let copy = element("copyLogBlock_\(section)")
            for _ in 0..<6 where copy.exists && !copy.isHittable {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard copy.exists else {
                XCTAssertNotEqual(section, "message", "the failing line has no message block")
                continue
            }
            let block = element("logBlockText_\(section)")
            XCTAssertTrue(block.exists, "the \(section) block has no text")
            XCTAssertFalse(block.label.isEmpty, "the \(section) block is empty")
            assertClean(block.label, "the \(section) block")
            let before = copy.label
            copy.tap()
            XCTAssertTrue(waitUntil(5) { copy.label != before }, "the \(section) copy button did not copy (label: \(copy.label))")
        }
        for text in app.staticTexts.allElementsBoundByIndex.map(\.label) { assertClean(text, "a block on screen") }

        goBack() // detail → list
        goBack() // list → server step
        let field = app.textFields.matching(identifier: "serverURLField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the server step did not come back")
        XCTAssertEqual(field.value as? String, stub, "the typed address was not kept")
    }

    // MARK: - AC-339

    /// AC-339: the three fields announce a name of their own language, never their example text.
    func test_AC_339() throws {
        let languages: [(code: String, locale: String, server: String, email: String, password: String)] = [
            ("en", "en_US", "Server URL", "Email", "Password"),
            ("fr", "fr_FR", "URL du serveur", "E-mail", "Mot de passe"),
            ("de", "de_DE", "Server-URL", "E-Mail", "Passwort"),
            ("es", "es_ES", "URL del servidor", "Correo electrónico", "Contraseña"),
            ("it", "it_IT", "URL del server", "Email", "Password"),
        ]
        for entry in languages {
            launchFresh(language: ["-AppleLanguages", "(\(entry.code))", "-AppleLocale", entry.locale])
            openServerStep()
            let serverField = app.textFields.matching(identifier: "serverURLField").firstMatch
            XCTAssertEqual(serverField.label, entry.server, "\(entry.code): the address field's name")
            XCTAssertNotEqual(serverField.label, "https://photos.example.com", "\(entry.code): the address field is named by its example")

            enterServer(stub)
            checkServer()
            continueToLogin()
            waitForLoginOptions()
            let email = app.textFields.matching(identifier: "loginEmailField").firstMatch
            let password = app.secureTextFields.matching(identifier: "loginPasswordField").firstMatch
            XCTAssertTrue(email.waitForExistence(timeout: 20), "\(entry.code): no email field")
            XCTAssertEqual(email.label, entry.email, "\(entry.code): the email field's name")
            XCTAssertNotEqual(email.label, "you@example.com", "\(entry.code): the email field is named by its example")
            XCTAssertEqual(password.label, entry.password, "\(entry.code): the password field's name")
            XCTAssertNotEqual(password.label, "••••••••", "\(entry.code): the password field is named by its mask")
        }
    }

    // MARK: - AC-340

    /// AC-340: each validation ends with one haptic (success, then failure), none when haptics are off.
    func test_AC_340() throws {
        launchFresh()
        openServerStep()
        enterServer(stub)
        checkServer()
        XCTAssertTrue(waitUntil(10) { self.probeValue().contains("haptic=success#1") },
                      "no success haptic (probe: \(probeValue()))")

        mute("drop")
        enterServer(otherForm(of: stub))
        checkServer()
        XCTAssertTrue(waitUntil(10) { self.probeValue().contains("haptic=error#2") },
                      "no failure haptic for the unreachable server (probe: \(probeValue()))")

        mute("off")
        launchFresh(extra: ["-hapticFeedbackEnabled", "NO"])
        openServerStep()
        enterServer(stub)
        checkServer()
        sleep(2)
        XCTAssertEqual(probeValue(), "checks=1 haptic=none", "a haptic was emitted although the setting is off")
    }

    // MARK: - AC-341 (startup reachability)

    private let firstPhotoTile = "assetTile_aaaaaaaa-1111-4111-8111-000000000001"

    /// AC-341, first given: a server that accepts and never answers → error state under 3 s;
    /// the server comes back, "Try Again" loads the content without a new sign-in.
    func test_AC_341() throws {
        storeSession()
        let loginsBefore = count("POST", "/api/auth/login")
        mute("hang", seconds: 30)
        launchStored()
        XCTAssertTrue(element("timelineLoadErrorState").waitForExistence(timeout: 3),
                      "no error state within 3 s — \(screenText())")
        XCTAssertFalse(element("timelineLoadingSkeleton").exists, "the skeleton shows next to the error state")
        let retry = element("timelineRetryButton")
        XCTAssertTrue(retry.exists, "no retry button on the error state — \(screenText())")
        mute("off")
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "the retry button went away once the server came back — \(screenText())")
        retry.tap()
        XCTAssertTrue(element(firstPhotoTile).waitForExistence(timeout: 30), "Try Again did not load the timeline — \(screenText())")
        assertAbsent(["serverURLField", "loginTitle"], "after Try Again")
        XCTAssertEqual(count("POST", "/api/auth/login"), loginsBefore, "Try Again signed in again")
    }

    /// AC-341, second given: a server that answers the probe but serves the first page in 5 s keeps the skeleton.
    func test_AC_341_slowServerKeepsSkeleton() throws {
        storeSession()
        delay("/api/timeline/buckets", seconds: 5)
        launchStored()
        XCTAssertTrue(element("timelineLoadingSkeleton").waitForExistence(timeout: 10), "no loading skeleton — \(screenText())")
        let deadline = Date().addingTimeInterval(40)
        while !element(firstPhotoTile).exists && Date() < deadline {
            XCTAssertFalse(element("timelineLoadErrorState").exists, "the error state showed before the content")
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(element(firstPhotoTile).exists, "the content never came — \(screenText())")
    }

    /// AC-341, third given: a probe that times out, then a first page that arrives → error state, then content, untouched.
    func test_AC_341_lateFirstPageReplacesError() throws {
        storeSession()
        delay("/api/server/ping", seconds: 10)
        delay("/api/timeline/buckets", seconds: 4)
        let started = Date()
        launchStored()
        XCTAssertTrue(element("timelineLoadErrorState").waitForExistence(timeout: 3),
                      "no error state within 3 s of the slow probe — \(screenText())")
        XCTAssertTrue(element(firstPhotoTile).waitForExistence(timeout: max(1, 8 - Date().timeIntervalSince(started))),
                      "the late first page did not replace the error within 8 s — \(screenText())")
    }

    // MARK: - AC-342, AC-343

    /// AC-342: a revoked token ends on the sign-in step, "session expired", nothing of the old session left.
    func test_AC_342() throws {
        storeSession()
        revoke(true)
        launchStored()
        waitForLogin(never: ["serverURLField"])
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'session has expired'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "no expiry message — \(screenText())")
        assertAbsent(["serverURLField", "profileAvatar"], "expired session")
    }

    /// AC-343: with Face ID lock on and an unreachable server, the lock covers the home before its content shows.
    func test_AC_343() throws {
        FaceID.enroll()
        launchFresh()
        reachLogin()
        signIn()
        reachShell()
        enableAppLock()

        app.terminate()
        mute("drop")
        launchStored()
        XCTAssertTrue(element("AppLockOverlay").waitForExistence(timeout: 30), "no lock at the cold start — \(screenText())")
        XCTAssertTrue(element("appLockUnlockButton").waitForExistence(timeout: 10), "no Unlock button on the lock")
        XCTAssertFalse(element("timelineLoadErrorState").isHittable, "the error state is reachable under the lock")
        let anyTile = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'")).firstMatch
        XCTAssertFalse(anyTile.isHittable, "a cell is reachable under the lock")

        sleep(2) // the automatic prompt is up
        FaceID.match()
        XCTAssertTrue(element("AppLockOverlay").waitForNonExistence(timeout: 20), "the lock did not lift")
        XCTAssertTrue(element("timelineLoadErrorState").waitForExistence(timeout: 10),
                      "the home does not show its error state once unlocked — \(screenText())")
    }

    // MARK: - AC-344 (widget links)

    /// AC-344: a photo link on a closed app, then on an open one with the Me sheet up,
    /// opens the viewer on that photo and closing it leaves the cell reachable;
    /// the Memories link selects its tab, hot too.
    func test_AC_344() throws {
        storeSession()
        openCold(link(4))
        closeViewerAndExpectTile(4, "cold link")

        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "Profile avatar missing")
        avatar.tap()
        sleep(4) // the sheet animates in
        openHot(link(5))
        closeViewerAndExpectTile(5, "hot link over the Me sheet")

        openHot(URL(string: "app.immich://memories")!)
        XCTAssertTrue(waitUntil(20) { self.tabButton("Memories").isSelected }, "the Memories link did not select its tab")
        openHot(link(2))
        closeViewerAndExpectTile(2, "hot link from the Memories tab")
        XCTAssertTrue(tabButton("Photos").isSelected, "the photo link did not select the Photos tab")
    }

    /// AC-344: the backup link selects Photos and starts a pass (the stub sees `bulk-upload-check`),
    /// the automatic backup setting left at its default.
    func test_AC_344_widgetBackup() throws {
        storeSession()
        openCold(URL(string: "app.immich://backup")!)
        XCTAssertTrue(tabButton("Photos").waitForExistence(timeout: 40), "the app did not reach the shell — \(screenText())")
        XCTAssertTrue(waitUntil(20) { self.tabButton("Photos").isSelected }, "the backup link did not select Photos")
        let deadline = Date().addingTimeInterval(60)
        while count("POST", "/api/assets/bulk-upload-check") == 0 && Date() < deadline {
            answerSystemAlerts()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertGreaterThanOrEqual(count("POST", "/api/assets/bulk-upload-check"), 1,
                                    "no backup pass reached the stub within 60 s — \(screenText())")
    }

    /// AC-344: "What's New" does not hide a link on a cold start, and closed by the link it is not marked seen.
    func test_AC_344_whatsNewCold() throws {
        storeSession()
        launchStored(extra: ["-uiTestResetWhatsNewSeen", "YES"])
        XCTAssertTrue(element("whatsNewDoneButton").waitForExistence(timeout: 40),
                      "What's New did not show with the reset argument — \(screenText())")
        app.terminate()

        openCold(link(3))
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 40),
                      "the link did not open the photo — \(screenText())")
        assertAbsent(["whatsNewDoneButton"], "What's New hides the linked photo")

        launchStored()
        XCTAssertTrue(element("whatsNewDoneButton").waitForExistence(timeout: 40),
                      "What's New was marked seen by the link — \(screenText())")
    }

    /// AC-344: a full-screen memory open on an open app does not hide the linked photo.
    func test_AC_344_coverOpenWarm() throws {
        storeSession()
        launchStored(extra: ["-uiTestMemoryPlaybackProbe", "YES"])
        XCTAssertTrue(tabButton("Memories").waitForExistence(timeout: 40), "the app did not reach the shell — \(screenText())")
        tabButton("Memories").tap()
        let card = element("memoryCard_\(memoryID)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no memory card — \(screenText())")
        card.tap()
        XCTAssertTrue(element("memoryPlaybackProbe").waitForExistence(timeout: 20), "the memory did not open")

        XCUIDevice.shared.press(.home)
        sleep(2)
        openHot(link(3))
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 30),
                      "the linked photo is hidden by the open memory — \(screenText())")
        XCTAssertTrue(element("memoryPlaybackProbe").waitForNonExistence(timeout: 10), "the memory stayed open under the link")
        closeViewerAndExpectTile(3, "link over a memory")
    }

    // MARK: - AC-345

    /// AC-345: without a session the link is ignored (the onboarding shows); with a refused token
    /// the link is not replayed after the new sign-in.
    func test_AC_345() throws {
        launchFresh()
        app.terminate()
        app.launchArguments = english + probeArguments + freshArguments
        app.open(link(3))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the link did not bring the app up")
        XCTAssertTrue(element("welcomeTitle").waitForExistence(timeout: 30), "no onboarding after a link without a session — \(screenText())")
        assertAbsent(["viewerBackButton"], "link without a session")

        storeSession()
        revoke(true)
        openCold(link(3))
        XCTAssertTrue(element("loginTitle").waitForExistence(timeout: 40), "no sign-in step after the refused token — \(screenText())")
        // The link may have asked for its photo while the token was being refused
        // (once, answered 401), or may have arrived after the refusal and been
        // dropped at once: whichever, nothing more may ask for it from here on.
        waitForLoginOptions()
        let requestsBeforeSignIn = count("GET", "/api/assets/\(photo(3))")
        XCTAssertLessThanOrEqual(requestsBeforeSignIn, 1, "the linked photo was requested more than once before the sign-in")
        revoke(false)
        signIn()
        reachShell()
        XCTAssertTrue(tabButton("Photos").isSelected, "the new sign-in did not land on Photos")
        XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 5), "the link was replayed after the new sign-in")
        XCTAssertEqual(count("GET", "/api/assets/\(photo(3))"), requestsBeforeSignIn,
                       "the linked photo was requested again after the new sign-in")
    }

    // MARK: - AC-346

    /// AC-346: a photo the server refuses (404, then 400) leads to Photos with no viewer, cold then hot,
    /// one request per tap.
    func test_AC_346() throws {
        storeSession()
        let id = photo(3)
        let path = "/api/assets/\(id)"
        for status in [404, 400] {
            setAsset(id, status: status)

            let beforeCold = count("GET", path)
            openCold(link(3))
            XCTAssertTrue(tile(1).waitForExistence(timeout: 40), "status \(status), cold: no timeline — \(screenText())")
            XCTAssertTrue(tabButton("Photos").isSelected, "status \(status), cold: not on Photos")
            XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 5), "status \(status), cold: a viewer opened")
            XCTAssertEqual(count("GET", path) - beforeCold, 1, "status \(status), cold: not exactly one request for the photo")

            let beforeHot = count("GET", path)
            openHot(link(3))
            XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 5), "status \(status), hot: a viewer opened")
            XCTAssertTrue(tabButton("Photos").isSelected, "status \(status), hot: not on Photos")
            XCTAssertEqual(app.state, .runningForeground, "status \(status), hot: the app is gone")
            XCTAssertEqual(count("GET", path) - beforeHot, 1, "status \(status), hot: not exactly one request for the photo")
        }
    }
}

private extension String {
    /// The value as a query-string component.
    var addingPercentEncodingForQuery: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
