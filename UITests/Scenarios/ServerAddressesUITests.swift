import XCTest

/// Local and external address of the server (L-26), against
/// `immich_stub_server_addresses.py`: the external address is `127.0.0.1:P` (the
/// one the app connects with), the local address `127.0.0.1:P+100`, both served by
/// ONE process and logged in ONE `/__requests` list, each entry saying which
/// address (`address`) it reached and whether it carried the session (`token`).
///
/// The scenarios drive the real "Network" setting (Me hub → Advanced → Network).
/// A change of network is the setting's test control (`networkSimulateChangeButton`,
/// shown by `-uiTestNetworkControls YES`): the simulator has no network to change.
/// The retour au premier plan is `XCUIDevice.shared.press(.home)` then
/// `app.activate()`. The permission "local network" is not applied by the
/// simulator: AC-250 launches with `-uiTestLocalNetworkDenied YES`, and the real
/// refusal is checked by hand on a device (S-18).
///
/// Every element is reached by `accessibilityIdentifier`, never by localized text,
/// except the onboarding's own copy, as in every other scenario.
///
/// RUNNING BY HAND: see the header of `immich_stub_server_addresses.py`.
final class ServerAddressesUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private var port: Int { URL(string: stub)?.port ?? 8421 }
    private var localPort: Int { port + 100 }
    private var localAddress: String { "http://127.0.0.1:\(localPort)" }
    private let videoID = "aaaaaaaa-1111-4111-8111-000000000001"
    private let photoID = "aaaaaaaa-1111-4111-8111-000000000002"
    /// A photo of the same day that is NOT a neighbour of `photoID` in the viewer:
    /// the paging viewer renders the pages next to the one on screen, so their
    /// previews are fetched (and cached) along with it.
    private let farPhotoID = "aaaaaaaa-1111-4111-8111-000000000006"

    private static let getStarted = ["Get Started", "Commencer"]
    private static let checkConnection = ["Check connection", "Vérifier la connexion"]
    private static let tryAgain = ["Try Again", "Réessayer"]
    private static let proceed = ["Continue", "Continuer"]
    private static let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]

    private let baseArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestNetworkControls", "YES"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning { app.terminate() }
        guard stubIsReachable() else { return }
        _ = send("GET", "/__reset")
    }

    // MARK: - The stub

    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(stub)/__whoami") else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, _ in
            // Another stub on the port would be a false green: this one names a local port.
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            ok = (response as? HTTPURLResponse)?.statusCode == 200 && text.contains("localPort")
            done.signal()
        }.resume()
        return done.wait(timeout: .now() + 5) == .success && ok
    }

    @discardableResult
    private func send(_ method: String, _ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var text = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { text = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer \(method) \(path)")
        return text
    }

    private func setLocalMode(_ mode: String) {
        XCTAssertTrue(send("GET", "/__addresses?local=\(mode)").contains(mode), "the stub refused the mode \(mode)")
    }

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let address: String
        let token: Bool

        var isProbe: Bool { path == "/api/server/ping" || path == "/api/server/version" }
    }

    private func requests() -> [StubRequest] {
        let body = send("GET", "/__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func mark() -> Int { requests().count }

    private func traffic(from index: Int) -> [StubRequest] { Array(requests().dropFirst(index)) }

    private func describe(_ list: [StubRequest]) -> String {
        list.map { "\($0.address) \($0.method) \($0.path) token=\($0.token)" }.joined(separator: "\n")
    }

    private func waitForRequest(from index: Int, timeout: TimeInterval = 30,
                                where matches: (StubRequest) -> Bool) -> StubRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = traffic(from: index).first(where: matches) { return found }
            Thread.sleep(forTimeInterval: 0.6)
        } while Date() < deadline
        return nil
    }

    // MARK: - The screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ id: String) -> XCUIElement { element("assetTile_\(id)") }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func screenReads() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))"
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
    }

    @discardableResult
    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func reveal(_ identifier: String) {
        let target = element(identifier)
        for direction in [true, false] {
            for _ in 0..<14 where !target.exists {
                if direction { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.7)
            }
        }
    }

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

    private var whatsNewDone: XCUIElement { app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch }

    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        whatsNewDone.tap()
        _ = waitUntil(timeout: 10) { !self.whatsNewDone.exists }
    }

    // MARK: - Sign-in

    private func signIn() {
        let field = app.textFields.firstMatch
        if !field.waitForExistence(timeout: 12) {
            XCTAssertTrue(tapAnyButton(Self.getStarted, timeout: 30), "Welcome CTA missing — \(screenReads())")
            XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        }
        field.tap()
        field.typeText(stub)
        XCTAssertTrue(tapAnyButton(Self.checkConnection + Self.tryAgain), "Check-connection CTA missing — \(screenReads())")
        XCTAssertTrue(app.buttons.matching(labelPredicate(Self.proceed)).firstMatch.waitForExistence(timeout: 30),
                      "Server never became reachable — \(screenReads())")
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(Self.proceed), "Continue CTA missing — \(screenReads())")
            onLogin = app.staticTexts.matching(labelPredicate(Self.loginCopy)).firstMatch.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenReads())")
        XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in Self.proceed where springboard.alerts.buttons[label].waitForExistence(timeout: 6) {
            springboard.alerts.buttons[label].tap()
            break
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let authorize = NSPredicate(format: "label CONTAINS 'Authorize'")
        let link = safari.links.matching(authorize).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), "Authorize link not reachable in the auth sheet")
        link.tap()
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch.waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell — \(screenReads())")
        settleOnShell()
    }

    private func settleOnShell() {
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 40), "the timeline never rendered — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    /// A fresh stub, a fresh app on the onboarding, signed in.
    private func start(extraArguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        send("GET", "/__reset")
        send("GET", "/__provider?mode=manual")
        app.launchArguments = baseArguments + ["-authServerURL", "()"] + extraArguments
        app.launch()
        signIn()
    }

    /// The same session, the app started again (with the stub as it is now).
    private func relaunchKeepingSession(extraArguments: [String] = []) {
        app.terminate()
        app.launchArguments = baseArguments + extraArguments
        app.launch()
    }

    // MARK: - The Network setting

    private func openHub() {
        for _ in 0..<2 {
            dismissWhatsNewIfPresent()
            let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Profile avatar missing")
            avatar.tap()
            Thread.sleep(forTimeInterval: 4)
            if !whatsNewDone.exists { return }
        }
    }

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

    private func openNetwork() {
        openHub()
        reveal("networkSettingsRow")
        let row = element("networkSettingsRow")
        XCTAssertTrue(row.exists, "the Me hub has no Network row — \(screenReads())")
        row.tap()
        XCTAssertTrue(element("networkLocalAddressField").waitForExistence(timeout: 15),
                      "the Network setting never opened — \(screenReads())")
    }

    private func setSwitch(on: Bool) {
        let toggle = element("networkAutoSwitchToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no automatic-switching toggle — \(screenReads())")
        let isOn = (toggle.value as? String) == "1"
        if isOn != on { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertTrue(waitUntil(timeout: 10) { ((toggle.value as? String) == "1") == on }, "the toggle did not follow the tap")
    }

    private func saveLocal(_ address: String) {
        // Return ends the editing: the keyboard would otherwise hide the lower rows
        // of the form (address in use, the test control) that the scenario taps next.
        replaceText(in: "networkLocalAddressField", with: address + "\n")
        element("networkLocalSaveButton").tap()
    }

    private func simulateNetworkChange() {
        reveal("networkSimulateChangeButton")
        let button = element("networkSimulateChangeButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the test control is missing — \(screenReads())")
        button.tap()
    }

    private func waitForLocalStatus(_ state: String, timeout: TimeInterval = 20) {
        reveal("networkLocalAddressField")
        XCTAssertTrue(element("networkLocalStatus_\(state)").waitForExistence(timeout: timeout),
                      "the local address never read \(state) — \(screenReads())")
    }

    private func waitForActiveKind(_ kind: String, timeout: TimeInterval = 20) {
        reveal("networkActiveAddress")
        XCTAssertTrue(element("networkActiveAddressKind_\(kind)").waitForExistence(timeout: timeout),
                      "the address in use never became \(kind) — \(screenReads())")
    }

    /// Opens the photo (its preview was never asked for, so it hits the network)
    /// and returns the request that served it.
    private func openPhotoAndFindPreview(from index: Int, id: String) -> StubRequest? {
        XCTAssertTrue(tile(id).waitForExistence(timeout: 20), "no tile \(id) — \(screenReads())")
        tile(id).tap()
        let served = waitForRequest(from: index) { $0.path.hasPrefix("/api/assets/\(id)/") }
        let back = element("viewerBackButton")
        if back.waitForExistence(timeout: 20) { back.tap() }
        XCTAssertTrue(tile(id).waitForExistence(timeout: 20), "the timeline did not come back — \(screenReads())")
        return served
    }

    // MARK: - AC-49 / AC-236 / AC-242

    func test_AC_49() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        simulateNetworkChange()
        waitForActiveKind("local")
        dismissHub()

        var index = mark()
        let local = openPhotoAndFindPreview(from: index, id: photoID)
        XCTAssertEqual(local?.address, "local", "the app is on the local address:\n\(describe(traffic(from: index)))")
        XCTAssertEqual(local?.token, true)

        setLocalMode("silent")
        openNetwork()
        simulateNetworkChange()
        waitForActiveKind("external", timeout: 30)
        dismissHub()
        index = mark()
        let external = openPhotoAndFindPreview(from: index, id: farPhotoID)
        XCTAssertEqual(external?.address, "external", "the local address went silent:\n\(describe(traffic(from: index)))")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch.exists,
                      "the user must still be signed in")
    }

    func test_AC_236() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        setLocalMode("silent")
        saveLocal(localAddress)
        waitForLocalStatus("unreachable", timeout: 30)
        waitForActiveKind("external")

        setLocalMode("immich")
        simulateNetworkChange()
        waitForLocalStatus("reachable")
        waitForActiveKind("local")
    }

    func test_AC_242() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        simulateNetworkChange()
        waitForActiveKind("local")
        setLocalMode("silent")
        simulateNetworkChange()
        waitForActiveKind("external", timeout: 30)
    }

    // MARK: - AC-235

    func test_AC_235() throws {
        start()
        openNetwork()
        XCTAssertEqual(element("networkAutoSwitchToggle").value as? String, "0", "the switch starts off")
        XCTAssertTrue(((element("networkExternalAddressField").value as? String) ?? "").contains("127.0.0.1:\(port)"),
                      "the external address is the connection address")

        let index = mark()
        saveLocal("http://a b")
        XCTAssertTrue(element("networkLocalValidationMessage").waitForExistence(timeout: 10), "a malformed address must be refused")
        XCTAssertFalse(traffic(from: index).contains { $0.address == "local" }, "nothing is sent for a refused address")

        saveLocal("http://127.0.0.1:\(localPort + 1)")   // nobody listens there
        waitForLocalStatus("unreachable", timeout: 30)

        saveLocal(localAddress)
        waitForLocalStatus("reachable")
    }

    // MARK: - AC-246

    func test_AC_246() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        let index = mark()

        setLocalMode("notimmich")
        saveLocal(localAddress)
        waitForLocalStatus("notThisServer")
        simulateNetworkChange()
        waitForActiveKind("external")

        setLocalMode("otherversion")
        simulateNetworkChange()
        waitForLocalStatus("notThisServer")
        waitForActiveKind("external")

        let leaked = traffic(from: index).filter { $0.address == "local" && $0.token }
        XCTAssertTrue(leaked.isEmpty, "the session must never reach an address that is not this server:\n\(describe(leaked))")
    }

    // MARK: - AC-248

    func test_AC_248() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        simulateNetworkChange()
        waitForActiveKind("local")

        setLocalMode("silent")
        relaunchKeepingSession()
        let started = Date()
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 15), "the timeline never rendered — \(screenReads())")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the timeline must come from the external address within 3 s")
        dismissWhatsNewIfPresent()
        XCTAssertFalse(element("timelineLoadErrorBanner").exists, "no error message")

        // The Network screen measures the addresses again when it opens: that
        // measure (bounded by 2 s) must end on the external address before the
        // local one comes back, so the reload below is the network change's.
        openNetwork()
        Thread.sleep(forTimeInterval: 3)
        waitForLocalStatus("unreachable", timeout: 30)
        waitForActiveKind("external")
        setLocalMode("immich")
        let index = mark()
        simulateNetworkChange()
        waitForActiveKind("local")
        dismissHub()
        let reloaded = waitForRequest(from: index) { $0.path.hasPrefix("/api/timeline/buckets") && $0.address == "local" }
        XCTAssertNotNil(reloaded, "the visible tab reloads from the local address:\n\(describe(traffic(from: index)))")
    }

    // MARK: - AC-238 / AC-240

    func test_AC_238() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        simulateNetworkChange()
        waitForActiveKind("local")
        setLocalMode("silent")
        simulateNetworkChange()
        waitForActiveKind("external", timeout: 30)
        dismissHub()

        let index = mark()
        XCTAssertTrue(tile(videoID).waitForExistence(timeout: 30), "the video tile never rendered — \(screenReads())")
        tile(videoID).tap()
        let playback = waitForRequest(from: index, timeout: 60) { $0.path == "/api/assets/\(self.videoID)/video/playback" }
        XCTAssertEqual(playback?.address, "external", "the video is read from the external address:\n\(describe(traffic(from: index)))")
        let after = traffic(from: index)
        XCTAssertFalse(after.contains { $0.address == "local" && !$0.isProbe }, "the local address only gets probes:\n\(describe(after))")
    }

    func test_AC_240() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        simulateNetworkChange()
        waitForActiveKind("local")
        dismissHub()
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 20), "the grid is on screen — \(screenReads())")

        openNetwork()
        setLocalMode("silent")
        let index = mark()
        simulateNetworkChange()
        waitForActiveKind("external", timeout: 30)
        dismissHub()
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 20), "the grid is still there — \(screenReads())")
        Thread.sleep(forTimeInterval: 3)
        let thumbs = traffic(from: index).filter { $0.path.hasSuffix("/thumbnail") }
        XCTAssertTrue(thumbs.isEmpty, "a thumbnail already seen is not requested again:\n\(describe(thumbs))")
    }

    // MARK: - AC-250

    func test_AC_250() throws {
        start(extraArguments: ["-uiTestLocalNetworkDenied", "YES"])
        openNetwork()
        setSwitch(on: true)
        let index = mark()
        saveLocal(localAddress)
        waitForLocalStatus("denied")
        reveal("networkOpenSettingsButton")
        XCTAssertTrue(element("networkOpenSettingsButton").exists, "no button towards the system settings")
        waitForActiveKind("external")
        XCTAssertFalse(traffic(from: index).contains { $0.address == "local" }, "a refused local network sends nothing there")
        XCTAssertFalse(element("networkLocalValidationMessage").exists, "a refusal is a state, not an error message")
    }
}
