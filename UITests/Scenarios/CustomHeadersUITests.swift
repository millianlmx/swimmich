import XCTest

/// Custom HTTP headers (L-09): the user defines headers for a server, and every
/// request the app, its widgets and the share extension send to THAT server
/// carries them — which is what lets an app through a reverse proxy that refuses
/// everything else.
///
/// Against `immich_stub_proxy_headers.py`, which IS such a proxy. Its gate
/// (`PUT /stub/proxy-mode`):
///
///   * `xaccess` — 403 unless `X-Access: secret` (the default after `/__reset`);
///   * `basic`   — 401 with `WWW-Authenticate` unless `Authorization: Basic
///                 dXNlcjpwYXNz`, then 401 without it unless `x-immich-user-token`;
///   * `off`     — no gate, for the scenarios that only watch what the app sends.
///
/// The gate only applies to the host `127.0.0.1` (server A). The same process also
/// answers as `localhost` (server B of AC-120), never filtered: what is proved
/// there is what the app SENT.
///
/// WHAT IS ASSERTED. The stub's `/__requests` log carries, for every request, the
/// headers it received (`headers`), the host it was addressed to (`host`) and,
/// when the gate refused it, the status (`proxy_status`). Each scenario reads the
/// log from an INDEX taken at a known point (never from a timestamp), so a request
/// can only be matched if it was sent after that point. Every element is reached
/// by `accessibilityIdentifier`; the only labels used are the onboarding's own
/// copy, as every other scenario does.
///
/// The widget leg of AC-19 / AC-119 / AC-125 is NOT driven here: a widget cannot be
/// reached in SpringBoard under test (`ImmichWidgetHomeScreen` needs an already
/// signed-in device). Its proof is unitary (S-19).
///
/// SESSION AND KEYCHAIN. Every launch passes `-authServerURL ()`, so the app finds
/// no server, wipes the token and shows the onboarding: sign-in runs each time.
/// The headers live in the Keychain, which that argument does NOT wipe, so
/// `tearDown` opens the editor for `127.0.0.1:<port>` then `localhost:<port>`,
/// deletes every row and saves, whatever state the method died in.
///
/// RUNNING BY HAND (macOS, a booted simulator, the sharing scenarios need a
/// Photos library seeded with one picture: `xcrun simctl addmedia booted <png>`):
///
///     python3 UITests/stubs/immich_stub_proxy_headers.py 8421
///     curl http://127.0.0.1:8421/__whoami            # {"port": 8421, "stub": "immich_stub_proxy_headers.py", …}
///     xcodebuild test -scheme ImmichSwiftUI \
///         -destination 'platform=iOS Simulator,name=iPhone 17' \
///         -only-testing:ImmichSwiftUIUITests/CustomHeadersUITests/test_AC_116
///
/// One method at a time (`test_AC_19`, `test_AC_20`, `test_AC_116`, `test_AC_117`,
/// `test_AC_118`, `test_AC_119`, `test_AC_120`, `test_AC_121`, `test_AC_123`,
/// `test_AC_124`, `test_AC_125`): the stub is one process, and each method starts
/// by resetting it.
final class CustomHeadersUITests: XCTestCase {

    /// The stub as `uitest.sh` hands it over (`TEST_RUNNER_IMMICH_STUB_URL`); the
    /// fallback is the port a by-hand run starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The first tile of the day is the video (`immich_stub_video_player`), the
    /// second a photo.
    private let videoID = "aaaaaaaa-1111-4111-8111-000000000001"
    private let photoID = "aaaaaaaa-1111-4111-8111-000000000002"
    private let token = "stub-access-token"
    private let basicAuthorization = "Basic dXNlcjpwYXNz"

    private static let welcome = ["Your photo library", "Votre photothèque"]
    private static let getStarted = ["Get Started", "Commencer"]
    private static let checkConnection = ["Check connection", "Vérifier la connexion"]
    private static let tryAgain = ["Try Again", "Réessayer"]
    private static let proceed = ["Continue", "Continuer"]
    private static let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
    private static let expiredCopy = ["Your session has expired. Please sign in again."]

    private let wipeArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-authServerURL", "()"]
    private let keepArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    /// Server A (behind the gate), server B (same stub, other host name), and the
    /// same host as A on another port (no header was ever defined for it).
    private var port: Int { URL(string: stub)?.port ?? 8421 }
    private var serverA: String { "http://127.0.0.1:\(port)" }
    private var serverB: String { "http://localhost:\(port)" }
    private var serverOtherPort: String { "http://127.0.0.1:\(port + 1)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        guard stubIsReachable() else { return }
        // The Keychain survives `-authServerURL ()`: leave no header behind, or the
        // next class's sign-in would send it (and a proxy-less stub would still pass).
        app.terminate()
        app.launchArguments = wipeArguments
        app.launch()
        reachServerField()
        for server in [serverA, serverB] {
            enterServer(server)
            clearHeadersOnServerStep()
        }
        app.terminate()
    }

    // MARK: - Helpers: the stub

    /// A request that got ANY answer from the control route is proof enough: the
    /// stub may be left in a mode that refuses `/api/server/ping`, and a skip
    /// here would hide the whole class.
    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(stub)/__whoami") else { return false }
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

    private func send(_ method: String, _ path: String, body: String? = nil) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var text = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { text = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer \(method) \(path)")
        return text
    }

    /// Back to the initial state (mode `xaccess`, an empty log).
    private func reset() {
        _ = send("GET", "/__reset")
    }

    /// `manual`: the provider page waits for a click on "Authorize".
    private func setProvider(_ mode: String) {
        XCTAssertEqual(send("GET", "/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    /// Switches the proxy gate: `xaccess`, `basic` or `off`.
    private func setProxyMode(_ mode: String) {
        let answer = send("PUT", "/stub/proxy-mode", body: "{\"mode\": \"\(mode)\"}")
        XCTAssertTrue(answer.contains("\"\(mode)\""), "the stub refused the proxy mode \(mode): \(answer)")
    }

    // MARK: - Helpers: the request log

    /// One entry of `/__requests`: the headers the stub received (names as the
    /// client wrote them), the host it was addressed to, and the status the gate
    /// refused it with, if it did.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let host: String?
        let headers: [String: String]?
        let proxyStatus: Int?

        private enum CodingKeys: String, CodingKey {
            case method, path, host, headers
            case proxyStatus = "proxy_status"
        }

        func header(_ name: String) -> String? {
            headers?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The stub's own control call (`PUT /stub/proxy-mode`) is logged like any
        /// request but is the test's, not the app's.
        var isTraffic: Bool { !path.hasPrefix("/stub/") }
        var isServerA: Bool { host?.hasPrefix("127.0.0.1") == true }
        var isServerB: Bool { host?.hasPrefix("localhost") == true }
        var isSocket: Bool { path.hasPrefix("/api/socket.io") }
        var isPublic: Bool {
            ["/api/server/ping", "/api/server/version", "/api/server/config", "/api/server/features",
             "/api/oauth/authorize", "/api/oauth/callback", "/api/auth/login"].contains(path)
        }
    }

    private func stubRequests() -> [StubRequest] {
        let body = send("GET", "/__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    /// The index a later assertion starts from: everything past it was sent after
    /// this call returned.
    private func mark() -> Int { stubRequests().count }

    /// What the app (or the extension) sent past `index`, the test's own control
    /// calls left out.
    private func traffic(from index: Int = 0) -> [StubRequest] {
        Array(stubRequests().dropFirst(index)).filter(\.isTraffic)
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { request in
            var line = "\(request.method) \(request.path) host=\(request.host ?? "nil")"
            for name in ["X-Access", "Authorization", "x-immich-user-token"] {
                if let value = request.header(name) { line += " \(name)=\(value)" }
            }
            if let status = request.proxyStatus { line += " REFUSED=\(status)" }
            return line
        }.joined(separator: "\n")
    }

    @discardableResult
    private func waitForRequest(from index: Int, timeout: TimeInterval = 40,
                                where matches: (StubRequest) -> Bool) -> StubRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = traffic(from: index).first(where: matches) { return found }
            Thread.sleep(forTimeInterval: 0.7)
        } while Date() < deadline
        return nil
    }

    private func assertAllCarry(_ name: String, _ value: String, in requests: [StubRequest],
                                _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let missing = requests.filter { $0.header(name) != value }
        XCTAssertTrue(missing.isEmpty,
                      "\(context): \(missing.count) request(s) without \(name): \(value):\n\(describe(missing))",
                      file: file, line: line)
    }

    private func assertNoneRefused(_ requests: [StubRequest], _ context: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let refused = requests.filter { $0.proxyStatus != nil }
        XCTAssertTrue(refused.isEmpty, "\(context): the proxy refused\n\(describe(refused))", file: file, line: line)
    }

    // MARK: - Helpers: reading the screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetID: String) -> XCUIElement { element("assetTile_\(assetID)") }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    private func waitForButton(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.buttons.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    private func screenReads() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))"
    }

    private func digits(_ identifier: String) -> String {
        let target = element(identifier)
        guard target.exists else { return "" }
        return (target.label + " " + ((target.value as? String) ?? "")).filter(\.isNumber)
    }

    /// Scrolls a `Form` (which only publishes what it rendered) until the element
    /// exists — down first, then back up.
    private func reveal(_ identifier: String) {
        let target = element(identifier)
        for direction in [true, false] {
            for _ in 0..<14 where !target.exists {
                if direction { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.7)
            }
        }
    }

    // MARK: - Helpers: the headers editor

    private func rowCount() -> Int {
        var count = 0
        while count < 12 && element("customHeaderName_\(count)").exists { count += 1 }
        return count
    }

    private func fieldText(_ identifier: String) -> String {
        (element(identifier).value as? String) ?? ""
    }

    /// Replaces the content of a text field: `typeText` appends, and a field
    /// whose value is its placeholder takes the extra deletes harmlessly.
    private func replaceText(in identifier: String, with text: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field \(identifier) — \(screenReads())")
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// Adds one row and fills it: the name, then the value.
    private func addRow(name: String, value: String) {
        let index = rowCount()
        let add = element("customHeaderAddButton")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the editor has no Add Header button — \(screenReads())")
        add.tap()
        XCTAssertTrue(element("customHeaderName_\(index)").waitForExistence(timeout: 10),
                      "the new row \(index) never appeared — \(screenReads())")
        replaceText(in: "customHeaderName_\(index)", with: name)
        replaceText(in: "customHeaderValue_\(index)", with: value)
    }

    private func waitForEditor() {
        XCTAssertTrue(element("customHeadersSaveButton").waitForExistence(timeout: 15),
                      "the headers editor never opened — \(screenReads())")
    }

    /// "Save" closes the editor on success (sheet or pushed screen alike).
    private func saveEditor() {
        let save = element("customHeadersSaveButton")
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save button — \(screenReads())")
        XCTAssertTrue(save.isEnabled, "the Save button is disabled — \(screenReads())")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element("customHeadersSaveButton").exists },
                      "the editor stayed open after Save (a save error? \(element("customHeadersSaveError").exists))")
    }

    /// Deletes every row. The trash button of row 0 is tapped until none is left.
    private func deleteAllRows() {
        for _ in 0..<12 {
            let delete = element("customHeaderDelete_0")
            guard delete.waitForExistence(timeout: 2) else { return }
            delete.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Helpers: the server step

    /// The welcome screen's CTA when the app starts at the very beginning, the
    /// server field straight away when it already shows it (after a logout).
    private func reachServerField() {
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 12) { return }
        XCTAssertTrue(tapAnyButton(Self.getStarted, timeout: 30), "Welcome CTA missing — \(screenReads())")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
    }

    private func enterServer(_ url: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let current = (field.value as? String) ?? ""
        if current == url { return }
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(url)
    }

    private func openEditorFromServerStep() {
        let button = element("serverHeadersButton")
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no HTTP Headers button — \(screenReads())")
        XCTAssertTrue(waitUntil(timeout: 10) { button.isEnabled }, "the HTTP Headers button stayed disabled")
        button.tap()
        waitForEditor()
    }

    /// B-1: "HTTP Headers" on the server step, one row per header, Save.
    private func defineHeadersOnServerStep(_ headers: [(name: String, value: String)]) {
        openEditorFromServerStep()
        for header in headers { addRow(name: header.name, value: header.value) }
        saveEditor()
        XCTAssertTrue(element("serverHeadersCount").waitForExistence(timeout: 10),
                      "the server step shows no header count after Save — \(screenReads())")
    }

    private func clearHeadersOnServerStep() {
        openEditorFromServerStep()
        deleteAllRows()
        let save = element("customHeadersSaveButton")
        if save.isEnabled {
            save.tap()
            if waitUntil(timeout: 10, { !self.element("customHeadersSaveButton").exists }) { return }
        }
        let cancel = element("customHeadersCancelButton")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "cleanup: no way out of the editor — \(screenReads())")
        cancel.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("customHeadersSaveButton").exists },
                      "cleanup: the editor never closed")
    }

    private func tapCheck() {
        XCTAssertTrue(tapAnyButton(Self.checkConnection + Self.tryAgain), "Check-connection CTA missing — \(screenReads())")
    }

    private func waitReachable() {
        XCTAssertTrue(waitForButton(Self.proceed, timeout: 30), "Server never became reachable — \(screenReads())")
    }

    private func waitUnreachable() {
        XCTAssertTrue(waitForButton(Self.tryAgain, timeout: 30), "Server never became unreachable — \(screenReads())")
        XCTAssertFalse(waitForButton(Self.proceed, timeout: 2), "the check passed without the proxy's header")
    }

    /// The CTA sits under the keyboard the typing raised: scrolling dismisses it,
    /// and a bounded retry covers the frame the keyboard was still animating over.
    private func continueToLogin() {
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(Self.proceed), "Continue CTA missing — \(screenReads())")
            onLogin = waitForStaticText(Self.loginCopy, timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenReads())")
    }

    private func dismissSystemSignInAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in Self.proceed {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 6) {
                button.tap()
                return
            }
        }
        for label in Self.proceed {
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
                          safari.buttons.matching(predicate).firstMatch] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    /// The SSO of the stub, from the login screen to the authenticated shell.
    private func ssoLogin() {
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell — \(screenReads())")
    }

    private var whatsNewDone: XCUIElement {
        app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
    }

    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        whatsNewDone.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.whatsNewDone.exists }, "What's New never closed")
    }

    /// The timeline rendered (the stub's second tile is a photo), over What's New.
    private func settleOnShell() {
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 40),
                      "the timeline never rendered — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    /// From a fresh onboarding to the shell of the account on `server`, with the
    /// given headers defined on the server step first.
    private func signIn(server: String, headers: [(name: String, value: String)] = []) {
        reachServerField()
        enterServer(server)
        if !headers.isEmpty { defineHeadersOnServerStep(headers) }
        tapCheck()
        waitReachable()
        continueToLogin()
        ssoLogin()
        settleOnShell()
    }

    /// A fresh stub in `mode`, a fresh app on the onboarding.
    private func start(mode: String) {
        if app.state != .notRunning { app.terminate() }
        reset()
        setProxyMode(mode)
        setProvider("manual")
        app.launchArguments = wipeArguments
        app.launch()
    }

    /// The app again, SIGNED-IN session kept (no `-authServerURL ()`).
    private func relaunchKeepingSession() {
        app.terminate()
        app.launchArguments = keepArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 40), "the session did not survive the relaunch — \(screenReads())")
        settleOnShell()
    }

    // MARK: - Helpers: the signed-in app

    private func openHub() {
        for _ in 0..<2 {
            dismissWhatsNewIfPresent()
            let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Profile avatar missing")
            avatar.tap()
            // The sheet animates in; its Form is not published before it does.
            Thread.sleep(forTimeInterval: 4)
            if !whatsNewDone.exists { return }
        }
    }

    /// The Me sheet closes by the pull-down gesture: its avatar is hittable again
    /// once the shell is back.
    private func dismissHub() {
        for _ in 0..<4 {
            if app.buttons.matching(identifier: "profileAvatar").firstMatch.isHittable { return }
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            top.press(forDuration: 0.1, thenDragTo: bottom)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(app.buttons.matching(identifier: "profileAvatar").firstMatch.isHittable,
                      "the Me sheet never closed — \(screenReads())")
    }

    /// B-2: Me hub → Advanced → "Custom HTTP Headers", without signing out.
    private func openEditorFromHub() {
        openHub()
        reveal("customHeadersRow")
        let row = element("customHeadersRow")
        XCTAssertTrue(row.exists, "the Me hub has no Custom HTTP Headers row — \(screenReads())")
        row.tap()
        waitForEditor()
    }

    /// Saves the hub's editor (it pops back to the hub), then closes the hub.
    private func saveHubEditorAndLeave() {
        saveEditor()
        Thread.sleep(forTimeInterval: 1)
        dismissHub()
    }

    private func removeAllHeadersFromHub() {
        openEditorFromHub()
        deleteAllRows()
        saveHubEditorAndLeave()
    }

    /// Pulls the timeline down and waits for the refresh to hit the stub.
    @discardableResult
    private func refreshTimeline(from index: Int) -> StubRequest? {
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 20), "the timeline is not on screen — \(screenReads())")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        return waitForRequest(from: index, timeout: 30) { $0.path.hasPrefix("/api/timeline") }
    }

    /// Opens the photo full screen and waits for its image to be fetched.
    private func openPhoto(from index: Int) {
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 20), "no photo tile — \(screenReads())")
        tile(photoID).tap()
        XCTAssertNotNil(waitForRequest(from: index) { $0.path.hasPrefix("/api/assets/\(self.photoID)/") },
                        "the viewer never fetched the photo:\n\(describe(traffic(from: index)))")
        XCTAssertTrue(element("viewerShareButton").waitForExistence(timeout: 20), "the viewer never opened — \(screenReads())")
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from the viewer — \(screenReads())")
        back.tap()
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 20), "the timeline did not come back — \(screenReads())")
    }

    /// Opens the video tile and waits for the stub to serve its playback stream.
    private func playVideo(from index: Int) {
        XCTAssertTrue(tile(videoID).waitForExistence(timeout: 30), "the video tile never rendered — \(screenReads())")
        tile(videoID).tap()
        XCTAssertNotNil(waitForRequest(from: index, timeout: 60) { $0.path == "/api/assets/\(self.videoID)/video/playback" },
                        "the video was never read:\n\(describe(traffic(from: index)))")
        closeViewer()
    }

    // MARK: - Helpers: the share extension

    private func photosTiles(_ photos: XCUIApplication) -> XCUIElementQuery {
        photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
    }

    private func dismissPhotosOnboarding(_ photos: XCUIApplication) {
        for label in ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"] {
            let button = photos.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                sleep(2)
            }
        }
    }

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

    /// Terminates the app (so every request past the returned index is the
    /// extension's), shares the seeded picture from Photos to Swimmich, and waits
    /// for its `POST /api/assets`. Returns that request.
    @discardableResult
    private func shareSeededPhoto() -> StubRequest? {
        // The keychain write happens on the login / republish path: give it a beat.
        sleep(3)
        app.terminate()
        sleep(3)
        let baseline = mark()

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.terminate()
        photos.launch()
        XCTAssertEqual(photos.state, .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        dismissPhotosOnboarding(photos)

        let tiles = photosTiles(photos)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20),
                      "the Photos library never published a tile (\(screenLabels(photos)))")
        // The newest tile is the one `--media` seeded.
        tiles.element(boundBy: tiles.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let shareButton = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 25),
                      "the photo viewer never offered its share button (\(screenLabels(photos)))")
        shareButton.tap()

        guard let activity = shareActivity(photos, springboard) else {
            XCTFail("the share sheet has no Swimmich activity (\(screenLabels(photos)))")
            return nil
        }
        activity.tap()

        let serverLabel = photos.staticTexts.matching(identifier: "shareExtensionServerLabel").firstMatch
        XCTAssertTrue(serverLabel.waitForExistence(timeout: 40),
                      "the Swimmich sheet never presented itself — it reads no session (\(screenLabels(photos)))")

        let upload = photos.buttons.matching(identifier: "shareExtensionUploadButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 20), "the sheet has no upload button")
        upload.tap()

        let sent = waitForRequest(from: baseline, timeout: 60) { $0.method == "POST" && $0.path == "/api/assets" }
        XCTAssertNotNil(sent, "no upload reached the stub:\n\(describe(traffic(from: baseline)))")

        let done = photos.buttons.matching(identifier: "shareExtensionDoneButton").firstMatch
        if done.waitForExistence(timeout: 30) { done.tap() }
        _ = waitUntil(timeout: 30) { !serverLabel.exists }
        return sent
    }

    // MARK: - AC-19

    /// A proxy that refuses (403) every request without `X-Access: secret`: the
    /// header is defined on the server step, then the sign-in, the timeline, a
    /// photo and the extension's upload all go through, and every request the
    /// stub logged carried it.
    func test_AC_19() throws {
        start(mode: "xaccess")
        signIn(server: serverA, headers: [("X-Access", "secret")])
        XCTAssertNotNil(waitForRequest(from: 0) { $0.path.hasSuffix("/thumbnail") },
                        "no thumbnail was loaded:\n\(describe(traffic()))")
        openPhoto(from: 0)
        closeViewer()

        let upload = shareSeededPhoto()
        XCTAssertNotNil(upload, "the extension never uploaded")

        let all = traffic()
        assertAllCarry("X-Access", "secret", in: all, "AC-19")
        assertNoneRefused(all, "AC-19")
        for (label, matches) in [
            ("the SSO", { (request: StubRequest) in request.path.hasPrefix("/api/oauth/") }),
            ("the timeline", { $0.path.hasPrefix("/api/timeline/") }),
            ("a thumbnail", { $0.path.hasSuffix("/thumbnail") }),
            ("the extension's upload", { $0.method == "POST" && $0.path == "/api/assets" }),
        ] as [(String, (StubRequest) -> Bool)] {
            XCTAssertTrue(all.contains(where: matches), "AC-19: the log has no request for \(label):\n\(describe(all))")
        }
    }

    // MARK: - AC-20

    /// Signed in with `X-Access: secret` (no gate), the row is deleted from the
    /// Me hub — no sign-out — and the requests sent after Save no longer carry it,
    /// the session intact.
    func test_AC_20() throws {
        start(mode: "off")
        signIn(server: serverA, headers: [("X-Access", "secret")])
        XCTAssertNotNil(waitForRequest(from: 0) { $0.path.hasPrefix("/api/timeline") && $0.header("X-Access") == "secret" },
                        "precondition: the timeline did not carry the header:\n\(describe(traffic()))")

        removeAllHeadersFromHub()
        Thread.sleep(forTimeInterval: 1)
        let saved = mark()
        XCTAssertNotNil(refreshTimeline(from: saved), "the refresh never reached the stub")

        let after = traffic(from: saved)
        XCTAssertFalse(after.isEmpty, "nothing was sent after Save")
        XCTAssertTrue(after.allSatisfy { $0.header("X-Access") == nil },
                      "AC-20: a request still carries X-Access:\n\(describe(after.filter { $0.header("X-Access") != nil }))")
        XCTAssertTrue(tile(photoID).exists, "AC-20: the session was interrupted — \(screenReads())")
        XCTAssertFalse(waitForStaticText(Self.welcome, timeout: 2), "AC-20: the app went back to the onboarding")
    }

    // MARK: - AC-116

    /// Without the header the check fails; with it, added from the server step, the
    /// same check passes, on `GET /api/server/ping` as on the SSO that follows.
    func test_AC_116() throws {
        start(mode: "xaccess")
        reachServerField()
        enterServer(serverA)
        tapCheck()
        waitUnreachable()
        let refused = traffic().first { $0.path == "/api/server/ping" }
        XCTAssertEqual(refused?.proxyStatus, 403, "the proxy did not refuse the bare ping:\n\(describe(traffic()))")
        XCTAssertNil(refused?.header("X-Access"))

        let afterFailure = mark()
        defineHeadersOnServerStep([("X-Access", "secret")])
        tapCheck()
        waitReachable()
        let ping = waitForRequest(from: afterFailure) { $0.path == "/api/server/ping" }
        XCTAssertEqual(ping?.header("X-Access"), "secret", "the ping did not carry the header:\n\(describe(traffic(from: afterFailure)))")
        XCTAssertNil(ping?.proxyStatus)

        continueToLogin()
        ssoLogin()
        settleOnShell()
        let after = traffic(from: afterFailure)
        for path in ["/api/oauth/authorize", "/api/oauth/callback"] {
            let request = after.first { $0.method == "POST" && $0.path == path }
            XCTAssertNotNil(request, "no POST \(path):\n\(describe(after))")
            XCTAssertEqual(request?.header("X-Access"), "secret", "POST \(path) lacks the header")
        }
        assertAllCarry("X-Access", "secret", in: after, "AC-116")
        assertNoneRefused(after, "AC-116")
    }

    // MARK: - AC-117

    /// Replacing the value in the Me hub takes effect on the next request, and the
    /// session is not interrupted.
    func test_AC_117() throws {
        start(mode: "off")
        signIn(server: serverA, headers: [("X-Access", "secret")])

        openEditorFromHub()
        replaceText(in: "customHeaderValue_0", with: "secret2")
        saveHubEditorAndLeave()
        Thread.sleep(forTimeInterval: 1)
        let saved = mark()
        XCTAssertNotNil(refreshTimeline(from: saved), "the refresh never reached the stub")

        let after = traffic(from: saved)
        XCTAssertTrue(after.contains { $0.header("X-Access") == "secret2" },
                      "AC-117: no request carries secret2:\n\(describe(after))")
        XCTAssertFalse(after.contains { $0.header("X-Access") == "secret" },
                       "AC-117: a request still carries the old value:\n\(describe(after))")
        assertAllCarry("X-Access", "secret2", in: after.filter(\.isServerA), "AC-117")
        XCTAssertTrue(tile(photoID).exists, "AC-117: the session was interrupted — \(screenReads())")
        XCTAssertFalse(waitForStaticText(Self.welcome, timeout: 2), "AC-117: the app went back to the onboarding")
    }

    // MARK: - AC-118

    /// Behind the 403 proxy: the full-screen photo, the video stream, an original
    /// and the real-time handshake all carry the header, and nothing was refused.
    func test_AC_118() throws {
        start(mode: "xaccess")
        signIn(server: serverA, headers: [("X-Access", "secret")])
        let signedIn = mark()

        openPhoto(from: signedIn)
        // The share sheet's "Download for Offline" fetches the ORIGINAL.
        element("viewerShareButton").tap()
        reveal("downloadForOfflineButton")
        let download = element("downloadForOfflineButton")
        if download.exists {
            download.tap()
            XCTAssertNotNil(waitForRequest(from: signedIn) { $0.path == "/api/assets/\(self.photoID)/original" },
                            "the original was never downloaded:\n\(describe(traffic(from: signedIn)))")
        } else {
            XCTAssertTrue(element("offlineAvailableRow").exists, "no offline download row — \(screenReads())")
        }
        let close = element("closeShareSheet")
        if close.waitForExistence(timeout: 5) { close.tap() }
        closeViewer()

        playVideo(from: signedIn)

        let all = traffic()
        let playback = all.filter { $0.path == "/api/assets/\(videoID)/video/playback" }
        XCTAssertFalse(playback.isEmpty, "no playback request:\n\(describe(all))")
        assertAllCarry("X-Access", "secret", in: all, "AC-118")
        assertNoneRefused(all, "AC-118")
        let handshakes = all.filter(\.isSocket)
        assertAllCarry("X-Access", "secret", in: handshakes, "AC-118 (real-time handshake)")
    }

    // MARK: - AC-119

    /// The extension, used once with the header, then again after the header was
    /// deleted in the app: the second `POST /api/assets` no longer carries it.
    func test_AC_119() throws {
        start(mode: "xaccess")
        signIn(server: serverA, headers: [("X-Access", "secret")])

        let first = shareSeededPhoto()
        XCTAssertEqual(first?.header("X-Access"), "secret", "AC-119: the first upload lacks the header")
        XCTAssertNil(first?.proxyStatus, "AC-119: the first upload was refused")

        // Without the header the proxy would refuse everything: open the gate, the
        // scenario watches what is SENT.
        setProxyMode("off")
        relaunchKeepingSession()
        removeAllHeadersFromHub()
        Thread.sleep(forTimeInterval: 2)
        let removed = mark()

        let second = shareSeededPhoto()
        XCTAssertNotNil(second, "AC-119: the second share never uploaded")
        let after = traffic(from: removed)
        XCTAssertTrue(after.allSatisfy { $0.header("X-Access") == nil },
                      "AC-119: a request after the removal still carries X-Access:\n\(describe(after))")
    }

    // MARK: - AC-120

    /// Two accounts on two servers (same stub, `127.0.0.1` and `localhost`), the
    /// header defined for A only: nothing sent to B carries it, before or after a
    /// switch, while A's requests do.
    func test_AC_120() throws {
        start(mode: "off")
        signIn(server: serverA, headers: [("X-Access", "secret")])

        openHub()
        let add = app.buttons.matching(labelPredicate(["Add Account"])).firstMatch
        for _ in 0..<14 where !add.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
        }
        XCTAssertTrue(add.exists, "the Me hub has no Add Account row — \(screenReads())")
        add.tap()

        signIn(server: serverB)

        // Both accounts show "Stub User" (or their address): tapping each row in
        // turn visits both whatever their order, and tapping the active one is a no-op.
        let accounts = NSPredicate(format: "label CONTAINS 'Stub User' OR label CONTAINS '127.0.0.1' OR label CONTAINS 'localhost'")
        for position in 0..<2 {
            openHub()
            let rows = app.buttons.matching(accounts)
            for _ in 0..<14 where rows.count < 2 {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.7)
            }
            XCTAssertGreaterThanOrEqual(rows.count, 2, "the Me hub lists fewer than two accounts — \(screenReads())")
            rows.element(boundBy: position).tap()
            Thread.sleep(forTimeInterval: 2)
            dismissHub()
            settleOnShell()
            XCTAssertNotNil(refreshTimeline(from: mark()), "the timeline of account #\(position) never refreshed")
        }

        let all = traffic()
        let toB = all.filter(\.isServerB)
        XCTAssertFalse(toB.isEmpty, "AC-120: nothing reached server B:\n\(describe(all))")
        XCTAssertTrue(toB.allSatisfy { $0.header("X-Access") == nil },
                      "AC-120: a request to localhost carries X-Access:\n\(describe(toB.filter { $0.header("X-Access") != nil }))")
        let toA = all.filter(\.isServerA)
        XCTAssertTrue(toA.contains { $0.header("X-Access") == "secret" },
                      "AC-120: server A never received the header:\n\(describe(toA))")
    }

    // MARK: - AC-121

    /// Each faulty entry is refused with its own message and blocks Save; the
    /// padded entry is saved trimmed, and a blank row is not saved at all.
    func test_AC_121() throws {
        start(mode: "off")
        reachServerField()
        enterServer(serverA)
        openEditorFromServerStep()
        let save = element("customHeadersSaveButton")

        // A name with a space.
        addRow(name: "X Access", value: "secret")
        XCTAssertTrue(element("customHeaderIssue_0").waitForExistence(timeout: 10),
                      "no issue shown for the name \"X Access\" — \(screenReads())")
        XCTAssertFalse(save.isEnabled, "Save is enabled with an invalid name")
        let invalidMessage = element("customHeaderIssue_0").label
        XCTAssertFalse(invalidMessage.isEmpty)
        XCTAssertFalse(invalidMessage.contains("secret"), "the message echoes the value")

        // The app's own token header.
        replaceText(in: "customHeaderName_0", with: "x-immich-user-token")
        XCTAssertTrue(element("customHeaderIssue_0").waitForExistence(timeout: 10), "no issue shown for a reserved name")
        XCTAssertFalse(save.isEnabled, "Save is enabled with a reserved name")
        let reservedMessage = element("customHeaderIssue_0").label
        XCTAssertNotEqual(reservedMessage, invalidMessage, "the reserved-name message is the invalid-name message")

        // Twice the same name.
        replaceText(in: "customHeaderName_0", with: "X-Access")
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("customHeaderIssue_0").exists },
                      "the valid name still shows an issue")
        addRow(name: "X-Access", value: "other")
        XCTAssertTrue(waitUntil(timeout: 10) { self.element("customHeaderIssue_0").exists || self.element("customHeaderIssue_1").exists },
                      "no issue shown for the duplicate name — \(screenReads())")
        XCTAssertFalse(save.isEnabled, "Save is enabled with a duplicate name")
        let duplicate = element("customHeaderIssue_1").exists ? element("customHeaderIssue_1") : element("customHeaderIssue_0")
        XCTAssertNotEqual(duplicate.label, invalidMessage)
        XCTAssertNotEqual(duplicate.label, reservedMessage)

        // Fixed: the duplicate goes, the padded entry stays, plus a blank row.
        element("customHeaderDelete_1").tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("customHeaderName_1").exists }, "the duplicate row stayed")
        replaceText(in: "customHeaderName_0", with: " X-Access ")
        replaceText(in: "customHeaderValue_0", with: " secret ")
        element("customHeaderAddButton").tap()
        XCTAssertTrue(element("customHeaderName_1").waitForExistence(timeout: 10), "the blank row never appeared")
        XCTAssertTrue(waitUntil(timeout: 10) { save.isEnabled }, "Save stayed disabled with a valid list and a blank row")
        saveEditor()
        XCTAssertEqual(digits("serverHeadersCount"), "1", "the blank row was counted — \(screenReads())")

        // Reopened: trimmed, and the blank row is gone.
        openEditorFromServerStep()
        XCTAssertEqual(fieldText("customHeaderName_0"), "X-Access", "the name was not trimmed")
        XCTAssertEqual(fieldText("customHeaderValue_0"), "secret", "the value was not trimmed")
        XCTAssertFalse(element("customHeaderName_1").exists, "the blank row was saved")
        element("customHeadersCancelButton").tap()
    }

    // MARK: - AC-123

    /// The list belongs to the server: after signing out, the same address finds it
    /// again and signs in through the proxy with no new entry; another port finds
    /// nothing.
    func test_AC_123() throws {
        start(mode: "xaccess")
        signIn(server: serverA, headers: [("X-Access", "secret")])

        openHub()
        reveal("logoutButton")
        let logout = element("logoutButton")
        XCTAssertTrue(logout.exists, "no Log Out row — \(screenReads())")
        logout.tap()
        let confirm = app.alerts.buttons.matching(identifier: "logoutConfirmButton").firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.tap()
        } else {
            XCTAssertTrue(app.alerts.buttons.matching(labelPredicate(["Log Out", "Se déconnecter"])).firstMatch.exists,
                          "no log-out confirmation — \(screenReads())")
            app.alerts.buttons.matching(labelPredicate(["Log Out", "Se déconnecter"])).firstMatch.tap()
        }

        reachServerField()
        enterServer(serverOtherPort)
        XCTAssertTrue(element("serverHeadersButton").waitForExistence(timeout: 10), "no HTTP Headers button")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(element("serverHeadersCount").exists,
                       "another port lists the headers of \(serverA): \(digits("serverHeadersCount"))")

        enterServer(serverA + "/")
        XCTAssertTrue(element("serverHeadersCount").waitForExistence(timeout: 10),
                      "the headers did not survive the sign-out — \(screenReads())")
        XCTAssertEqual(digits("serverHeadersCount"), "1")

        let relogin = mark()
        tapCheck()
        waitReachable()
        continueToLogin()
        ssoLogin()
        settleOnShell()
        let after = traffic(from: relogin)
        assertAllCarry("X-Access", "secret", in: after, "AC-123")
        assertNoneRefused(after, "AC-123")
    }

    // MARK: - AC-124

    /// No header defined: what the app and the extension send is what they sent
    /// before the feature — the Bearer token alone, nothing of the proxy's.
    func test_AC_124() throws {
        start(mode: "off")
        signIn(server: serverA)
        openPhoto(from: 0)
        closeViewer()
        let upload = shareSeededPhoto()
        XCTAssertNotNil(upload, "the extension never uploaded")

        let all = traffic()
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { $0.header("X-Access") == nil },
                      "AC-124: X-Access appeared:\n\(describe(all.filter { $0.header("X-Access") != nil }))")
        XCTAssertTrue(all.allSatisfy { $0.header("x-immich-user-token") == nil },
                      "AC-124: x-immich-user-token appeared:\n\(describe(all.filter { $0.header("x-immich-user-token") != nil }))")
        let authorized = all.filter { $0.header("Authorization") != nil }
        XCTAssertFalse(authorized.isEmpty, "no request carried the token")
        assertAllCarry("Authorization", "Bearer \(token)", in: authorized, "AC-124")
        XCTAssertTrue(all.contains { $0.path.hasPrefix("/api/timeline") && $0.header("Authorization") == "Bearer \(token)" },
                      "AC-124: the timeline carried no Bearer token:\n\(describe(all))")
        XCTAssertEqual(upload?.header("Authorization"), "Bearer \(token)", "AC-124: the upload lacks the Bearer token")
    }

    // MARK: - AC-125

    /// Behind a proxy that wants `Authorization: Basic …`: the header is defined,
    /// every request carries it with the token in `x-immich-user-token`, never
    /// `Bearer`. Deleted (the proxy still in `basic`), the next requests are the
    /// plain Bearer ones, the proxy refuses them with `WWW-Authenticate`, and the
    /// session survives; open the gate and the same token works.
    func test_AC_125() throws {
        start(mode: "basic")
        signIn(server: serverA, headers: [("Authorization", basicAuthorization)])
        let signedIn = mark()
        openPhoto(from: signedIn)
        closeViewer()
        playVideo(from: signedIn)
        shareSeededPhoto()

        let all = traffic()
        assertAllCarry("Authorization", basicAuthorization, in: all, "AC-125")
        let authenticated = all.filter { !$0.isPublic && !$0.isSocket }
        XCTAssertFalse(authenticated.isEmpty)
        assertAllCarry("x-immich-user-token", token, in: authenticated, "AC-125 (authenticated requests)")
        XCTAssertTrue(all.allSatisfy { !($0.header("Authorization") ?? "").contains("Bearer") },
                      "AC-125: a request carries Bearer:\n\(describe(all.filter { ($0.header("Authorization") ?? "").contains("Bearer") }))")
        XCTAssertTrue(all.contains { $0.path == "/api/assets/\(videoID)/video/playback" },
                      "AC-125: the video was never read:\n\(describe(all))")
        assertNoneRefused(all, "AC-125")

        // The header deleted, the proxy unchanged: Bearer again, refused with a
        // proxy challenge, the session kept.
        relaunchKeepingSession()
        removeAllHeadersFromHub()
        Thread.sleep(forTimeInterval: 1)
        let removed = mark()
        _ = refreshTimeline(from: removed)
        XCTAssertNotNil(waitForRequest(from: removed) { $0.path.hasPrefix("/api/timeline") && $0.proxyStatus == 401 },
                        "AC-125: no timeline request was refused after the removal:\n\(describe(traffic(from: removed)))")
        let after = traffic(from: removed).filter { !$0.isPublic && !$0.isSocket }
        XCTAssertFalse(after.isEmpty)
        assertAllCarry("Authorization", "Bearer \(token)", in: after, "AC-125 (after removal)")
        XCTAssertTrue(after.allSatisfy { $0.header("x-immich-user-token") == nil },
                      "AC-125: x-immich-user-token is still sent after the removal")
        XCTAssertTrue(tile(photoID).exists, "AC-125: the session was interrupted — \(screenReads())")
        XCTAssertFalse(waitForStaticText(Self.welcome, timeout: 2), "AC-125: the app went back to the onboarding")
        XCTAssertFalse(waitForStaticText(Self.expiredCopy, timeout: 2), "AC-125: the proxy's refusal was read as an expired session")

        // The gate open: the same token is accepted, so it was kept.
        setProxyMode("off")
        let opened = mark()
        let refreshed = refreshTimeline(from: opened)
        XCTAssertNotNil(refreshed, "AC-125: the refresh after opening the gate never reached the stub")
        XCTAssertEqual(refreshed?.header("Authorization"), "Bearer \(token)", "AC-125: the token was not kept")
        XCTAssertNil(refreshed?.proxyStatus)
    }
}
