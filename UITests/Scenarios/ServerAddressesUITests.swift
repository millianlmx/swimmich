import XCTest

/// Local and external address of the server (L-26), against
/// `immich_stub_server_addresses.py`: the external address is `127.0.0.1:P` (the
/// one the app connects with), the local address `127.0.0.1:<localPort>`, a port
/// the stub reports in `/__whoami`; both served by
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
    /// The stub's own ports, read from its `/__whoami` in `setUpWithError`.
    private var stubPorts: StubPorts!
    private var localPort: Int { stubPorts.localPort }
    private var localAddress: String { "http://127.0.0.1:\(localPort)" }
    /// The local address over TLS (self-signed certificate, client certificate required).
    private var tlsLocalAddress: String? { stubPorts.tlsLocalPort.map { "https://127.0.0.1:\($0)" } }
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

    private struct StubPorts: Decodable {
        let localPort: Int
        /// The local address over TLS, null when the stub could not make its certificates.
        let tlsLocalPort: Int?
        /// A port the stub holds without listening: a connection there is refused.
        let deadPort: Int
    }

    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(stub)/__whoami") else { return false }
        let done = DispatchSemaphore(value: 0)
        var ports: StubPorts?
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, _ in
            // Another stub on the port would be a false green: this one names its local and dead ports.
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                ports = try? JSONDecoder().decode(StubPorts.self, from: data)
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 5) == .success, let ports else { return false }
        stubPorts = ports
        return true
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
        let params: [String: String]?
        /// What the header `X-Access` carried, null without it.
        let xAccess: String?
        /// True for a request that arrived on the stub's TLS port.
        let tls: Bool?
        /// On the TLS port, the client certificate shown ("A"), null without one.
        let cert: String?

        var isProbe: Bool { path == "/api/server/ping" || path == "/api/server/version" }
        /// The widget asks its photos at `size=preview`; the app's grid asks `size=thumbnail`.
        var isWidgetPreview: Bool { path.hasSuffix("/thumbnail") && params?["size"] == "preview" }
        var isUpload: Bool { method == "POST" && path == "/api/assets" }
        var onTLS: Bool { tls == true }
    }

    /// One TLS handshake of the stub's TLS port (`/__handshakes`).
    private struct Handshake: Decodable {
        let ok: Bool
        let cert: String?
    }

    private func handshakes() -> [Handshake] {
        (try? JSONDecoder().decode([Handshake].self, from: Data(send("GET", "/__handshakes").utf8))) ?? []
    }

    private func requests() -> [StubRequest] {
        let body = send("GET", "/__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func mark() -> Int { requests().count }

    private func traffic(from index: Int) -> [StubRequest] { Array(requests().dropFirst(index)) }

    private func describe(_ list: [StubRequest]) -> String {
        list.map {
            "\($0.address)\($0.onTLS ? "/tls" : "") \($0.method) \($0.path) token=\($0.token) xAccess=\($0.xAccess ?? "-") cert=\($0.cert ?? "-")"
        }.joined(separator: "\n")
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

        saveLocal("http://127.0.0.1:\(stubPorts.deadPort)")   // nobody listens there
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
        let switched = mark()
        simulateNetworkChange()
        waitForActiveKind("external", timeout: 30)
        // The socket follows the switch: it reconnects on the external address.
        let socket = waitForRequest(from: switched, timeout: 30) {
            $0.path.hasPrefix("/api/socket.io") && $0.address == "external"
        }
        XCTAssertNotNil(socket, "the realtime socket never reconnected on the external address:\n\(describe(traffic(from: switched)))")
        dismissHub()

        let index = mark()
        // A download: the share sheet's "Download for Offline" fetches the original.
        XCTAssertTrue(tile(photoID).waitForExistence(timeout: 30), "the photo tile never rendered — \(screenReads())")
        tile(photoID).tap()
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 25), "the viewer never opened — \(screenReads())")
        share.tap()
        reveal("downloadForOfflineButton")
        let download = element("downloadForOfflineButton")
        XCTAssertTrue(download.waitForExistence(timeout: 15), "no 'Download for Offline' — \(screenReads())")
        download.tap()
        let original = waitForRequest(from: index, timeout: 60) { $0.path == "/api/assets/\(self.photoID)/original" }
        XCTAssertEqual(original?.address, "external", "the original is downloaded from the external address:\n\(describe(traffic(from: index)))")
        let close = element("closeShareSheet")
        if close.waitForExistence(timeout: 5) { close.tap() }
        let back = element("viewerBackButton")
        if back.waitForExistence(timeout: 20) { back.tap() }

        // A video (the stub serves `videoID` as a real MP4).
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

    // MARK: - AC-239 (widget)

    /// The Photos widget, posed on the Home Screen with the app closed, applies the
    /// app's rule itself: its photos come from the local address while it answers
    /// as this server, and from the external one once it is mute. The widget is
    /// told apart from the app by its `size=preview` thumbnails (the grid asks
    /// `size=thumbnail`). The share extension has its own scenario
    /// (`test_AC_239_shareExtension`); the favorite button's intent is proved in unit tests
    /// (`WidgetServerAddressTests.test_AC_239_favoriteIntentWritesToTheChosenAddress`).
    func test_AC_239() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        dismissHub()

        // 1. The local address answers: the widget reads its photos there.
        app.terminate()
        let posed = mark()
        poseWidget(title: NSPredicate(format: "label CONTAINS 'Swimmich' AND label CONTAINS 'Photos'"))
        XCTAssertTrue(waitUntil(timeout: 90) { !self.widgetPhotos().isEmpty },
                      "the Photos widget never drew a dated photo: \(widgetPhotos().map(\.label))")
        let local = waitForRequest(from: posed, timeout: 30) { $0.isWidgetPreview && $0.address == "local" }
        XCTAssertEqual(local?.token, true, "the widget reads its photos on the local address:\n\(describe(traffic(from: posed)))")
        XCTAssertFalse(traffic(from: posed).contains { $0.isWidgetPreview && $0.address == "external" },
                       "nothing goes to the external address while the local one answers:\n\(describe(traffic(from: posed)))")

        // 2. The local address goes mute: saving the setting again republishes the
        // session, which reloads the widget; its next refresh goes external.
        setLocalMode("silent")
        relaunchKeepingSession()
        settleOnShell()
        openNetwork()
        let muted = mark()
        saveLocal(localAddress)
        // The probe of the mute address times out: the save is over, the session republished.
        waitForLocalStatus("unreachable", timeout: 20)
        app.terminate()
        let external = waitForRequest(from: muted, timeout: 90) { $0.isWidgetPreview && $0.address == "external" }
        XCTAssertEqual(external?.token, true, "the widget falls back on the external address:\n\(describe(traffic(from: muted)))")
        XCTAssertFalse(traffic(from: muted).contains { $0.isWidgetPreview && $0.address == "local" },
                       "the mute local address gets probes only:\n\(describe(traffic(from: muted)))")
    }

    // MARK: - AC-239 (share extension)

    /// The share extension, driven from Photos with the app closed, applies the
    /// same rule: its upload goes to the local address while it answers as this
    /// server, and to the external one once it is mute (the 2 s probe of the
    /// extension times out: no `shareExtensionErrorBadge`, no message).
    func test_AC_239_shareExtension() throws {
        start()
        openNetwork()
        setSwitch(on: true)
        saveLocal(localAddress)
        waitForLocalStatus("reachable")
        dismissHub()
        app.terminate()

        // 1. The local address answers: the upload goes there, with the session.
        var index = mark()
        shareNewestPhotoFromPhotos()
        let local = waitForRequest(from: index, timeout: 60) { $0.isUpload && $0.address == "local" }
        XCTAssertEqual(local?.token, true, "the extension uploads to the local address:\n\(describe(traffic(from: index)))")
        XCTAssertFalse(traffic(from: index).contains { $0.isUpload && $0.address == "external" },
                       "nothing is uploaded to the external address while the local one answers:\n\(describe(traffic(from: index)))")

        // 2. The local address goes mute: the probe gives up, the upload goes external.
        setLocalMode("silent")
        index = mark()
        shareNewestPhotoFromPhotos()
        let external = waitForRequest(from: index, timeout: 60) { $0.isUpload && $0.address == "external" }
        XCTAssertEqual(external?.token, true, "the extension falls back on the external address:\n\(describe(traffic(from: index)))")
        let after = traffic(from: index)
        XCTAssertFalse(after.contains { $0.address == "local" && !$0.isProbe },
                       "the mute local address gets probes only:\n\(describe(after))")
        XCTAssertFalse(after.contains { $0.address == "local" && $0.token },
                       "a probe never carries the session:\n\(describe(after))")
    }

    // MARK: - AC-241 (widget and extension, self-signed local address, header, client certificate)

    private struct MissingTLSPort: Error {}

    private func tlsAddressOrFail() throws -> String {
        guard let address = tlsLocalAddress else {
            XCTFail("the stub has no TLS port: is openssl on the PATH?")
            throw MissingTLSPort()
        }
        return address
    }

    /// A self-signed local address that requires client certificate A, approved in
    /// the app, with the header `X-Access: secret`: the widget then the extension
    /// reach it, carry the header and present the certificate. The TLS port logs a
    /// request only after a handshake that accepted the certificate of the stub and
    /// showed A, so a journal entry there already says both.
    func test_AC_241() throws {
        let tlsAddress = try tlsAddressOrFail()
        start(extraArguments: [
            "-uiTestResetClientCertificates", "YES",
            "-uiTestClientCertificateFeed", "\(stub)/__client-cert/current",
        ])
        importClientCertificateA()
        addHeaderFromHub(name: "X-Access", value: "secret")
        openNetwork()
        setSwitch(on: true)
        saveLocal(tlsAddress)
        answerTrustAlert("Trust")
        waitForLocalStatus("reachable", timeout: 30)
        dismissHub()
        app.terminate()

        // The widget.
        var index = mark()
        poseWidget(title: NSPredicate(format: "label CONTAINS 'Swimmich' AND label CONTAINS 'Photos'"))
        XCTAssertTrue(waitUntil(timeout: 90) { !self.widgetPhotos().isEmpty },
                      "the Photos widget never drew a dated photo: \(widgetPhotos().map(\.label))")
        let preview = waitForRequest(from: index, timeout: 30) { $0.isWidgetPreview && $0.onTLS }
        XCTAssertEqual(preview?.cert, "A", "the widget presents the account's certificate:\n\(describe(traffic(from: index)))")
        XCTAssertEqual(preview?.xAccess, "secret", "the widget's request carries the header")
        XCTAssertEqual(preview?.token, true)
        var onTLS = traffic(from: index).filter(\.onTLS)
        XCTAssertTrue(onTLS.allSatisfy { $0.cert == "A" && $0.xAccess == "secret" },
                      "every request of the widget on the TLS port, probes included, carries the header and A:\n\(describe(onTLS))")
        XCTAssertTrue(onTLS.filter(\.isProbe).allSatisfy { !$0.token }, "a probe never carries the session:\n\(describe(onTLS))")
        XCTAssertFalse(traffic(from: index).contains { $0.isWidgetPreview && $0.address == "external" },
                       "the widget never fell back on the external address:\n\(describe(traffic(from: index)))")

        // The share extension.
        index = mark()
        shareNewestPhotoFromPhotos()
        let upload = waitForRequest(from: index, timeout: 60) { $0.isUpload && $0.onTLS }
        XCTAssertEqual(upload?.cert, "A", "the extension presents the account's certificate:\n\(describe(traffic(from: index)))")
        XCTAssertEqual(upload?.xAccess, "secret", "the extension's upload carries the header")
        XCTAssertEqual(upload?.token, true)
        onTLS = traffic(from: index).filter(\.onTLS)
        XCTAssertTrue(onTLS.filter(\.isProbe).allSatisfy { !$0.token && $0.xAccess == "secret" && $0.cert == "A" },
                      "the extension's probes carry the header, A, and no session:\n\(describe(onTLS))")
        XCTAssertFalse(traffic(from: index).contains { $0.isUpload && $0.address == "external" },
                       "the upload never fell back on the external address:\n\(describe(traffic(from: index)))")
    }

    /// The same local address, NOT approved in the app: neither the widget nor the
    /// extension trusts it, both fall back on the external address without a message.
    func test_AC_241_2() throws {
        let tlsAddress = try tlsAddressOrFail()
        start(extraArguments: [
            "-trustedServers", "()",
            "-uiTestResetClientCertificates", "YES",
            "-uiTestClientCertificateFeed", "\(stub)/__client-cert/current",
        ])
        // A is installed: without it the port would refuse the handshake even of an
        // approved host, and the scenario would prove nothing about trust.
        importClientCertificateA()
        openNetwork()
        setSwitch(on: true)
        saveLocal(tlsAddress)
        answerTrustAlert("Cancel")
        waitForLocalStatus("untrusted")
        waitForActiveKind("external")
        dismissHub()
        app.terminate()

        // The widget.
        var index = mark()
        let handshakeMark = handshakes().count
        poseWidget(title: NSPredicate(format: "label CONTAINS 'Swimmich' AND label CONTAINS 'Photos'"))
        let preview = waitForRequest(from: index, timeout: 90) { $0.isWidgetPreview && $0.address == "external" }
        XCTAssertEqual(preview?.token, true, "the widget falls back on the external address:\n\(describe(traffic(from: index)))")
        XCTAssertFalse(traffic(from: index).contains(where: \.onTLS),
                       "an address that is not approved gets no request:\n\(describe(traffic(from: index)))")
        XCTAssertTrue(handshakes().dropFirst(handshakeMark).contains { !$0.ok },
                      "the widget tried the local address, then gave up")

        // The share extension.
        index = mark()
        shareNewestPhotoFromPhotos()
        let upload = waitForRequest(from: index, timeout: 60) { $0.isUpload && $0.address == "external" }
        XCTAssertNotNil(upload, "the extension uploads to the external address:\n\(describe(traffic(from: index)))")
        XCTAssertFalse(traffic(from: index).contains(where: \.onTLS),
                       "an address that is not approved gets no request:\n\(describe(traffic(from: index)))")
    }

    /// Me hub → Advanced → Client Certificate → import A (the app downloads it from the stub's feed).
    private func importClientCertificateA() {
        openHub()
        reveal("clientCertificateRow")
        let row = element("clientCertificateRow")
        XCTAssertTrue(row.exists, "the Me hub has no Client Certificate row — \(screenReads())")
        row.tap()
        let importButton = element("clientCertificateImportButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), "the certificate screen never opened — \(screenReads())")
        XCTAssertTrue(waitUntil(timeout: 10) { importButton.isEnabled }, "the import button is disabled")
        importButton.tap()
        let password = element("clientCertificatePasswordField")
        XCTAssertTrue(password.waitForExistence(timeout: 20), "the password field never appeared — \(screenReads())")
        password.tap()
        password.typeText("alpha")
        let submit = element("clientCertificatePasswordSubmit")
        XCTAssertTrue(submit.waitForExistence(timeout: 15), "no password submit button — \(screenReads())")
        for _ in 0..<3 where !submit.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        submit.tap()
        XCTAssertTrue(element("clientCertificateMessage_imported").waitForExistence(timeout: 30),
                      "the certificate was not imported — \(screenReads())")
        dismissHub()
    }

    /// Me hub → Advanced → Custom HTTP Headers → one more header, saved.
    private func addHeaderFromHub(name: String, value: String) {
        openHub()
        reveal("customHeadersRow")
        let row = element("customHeadersRow")
        XCTAssertTrue(row.exists, "the Me hub has no Custom HTTP Headers row — \(screenReads())")
        row.tap()
        let save = element("customHeadersSaveButton")
        XCTAssertTrue(save.waitForExistence(timeout: 15), "the headers editor never opened — \(screenReads())")
        var index = 0
        while element("customHeaderName_\(index)").exists { index += 1 }
        let add = element("customHeaderAddButton")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the editor has no Add Header button — \(screenReads())")
        add.tap()
        XCTAssertTrue(element("customHeaderName_\(index)").waitForExistence(timeout: 10),
                      "the new row \(index) never appeared — \(screenReads())")
        replaceText(in: "customHeaderName_\(index)", with: name)
        replaceText(in: "customHeaderValue_\(index)", with: value)
        XCTAssertTrue(save.isEnabled, "the Save button is disabled — \(screenReads())")
        save.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !self.element("customHeadersSaveButton").exists },
                      "the editor stayed open after Save (a save error? \(element("customHeadersSaveError").exists))")
        Thread.sleep(forTimeInterval: 1)
        dismissHub()
    }

    /// The alert "Trust this server?" of the Network setting, answered with `label`.
    private func answerTrustAlert(_ label: String) {
        let alert = app.alerts.matching(NSPredicate(format: "label CONTAINS 'Trust this server'")).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "no 'Trust this server?' alert — \(screenReads())")
        alert.buttons[label].tap()
    }

    /// Photos (relaunched) → its newest photo (the media the CI seeded) → Share →
    /// Swimmich → Upload. The sheet must carry no error badge, which is what a
    /// fall back after a mute local address must look like.
    private func shareNewestPhotoFromPhotos() {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if photos.state != .notRunning { photos.terminate() }
        sleep(2)
        photos.launch()
        XCTAssertEqual(photos.state, .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        let onboarding = photos.buttons.matching(
            NSPredicate(format: "label IN %@", ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"])
        ).firstMatch
        for _ in 0..<30 where onboarding.exists {
            if onboarding.isHittable {
                onboarding.tap()
                sleep(2)
            } else {
                photos.swipeUp(velocity: .fast)
            }
        }
        let grid = photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 20), "the Photos library never published a tile")
        grid.element(boundBy: grid.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let share = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25), "no share button in the Photos viewer")
        share.tap()

        let predicate = NSPredicate(format: "label == 'Swimmich'")
        var activity: XCUIElement?
        for attempt in 0..<3 where activity == nil {
            for root in [photos as XCUIElement, springboard as XCUIElement] {
                let match = root.descendants(matching: .any).matching(predicate).firstMatch
                if match.exists { activity = match; break }
            }
            if activity == nil && attempt < 2 {
                let row = photos.collectionViews.firstMatch
                if row.exists { row.swipeLeft() } else { photos.swipeLeft() }
                sleep(2)
            }
        }
        guard let activity else { return XCTFail("the share sheet has no Swimmich activity") }
        activity.tap()

        let upload = photos.buttons.matching(identifier: "shareExtensionUploadButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 40), "the Swimmich sheet offers no upload — it reads no session")
        XCTAssertFalse(photos.descendants(matching: .any).matching(identifier: "shareExtensionErrorBadge").firstMatch.exists,
                       "the sheet shows an error")
        for _ in 0..<4 where !upload.isHittable {
            photos.swipeUp()
            sleep(1)
        }
        upload.tap()
        let done = photos.buttons.matching(identifier: "shareExtensionDoneButton").firstMatch
        if done.waitForExistence(timeout: 30) { done.tap() }
    }

    /// "Photo, from <day>" or "Video …": the label of a drawn tile carries the day,
    /// the waiting state's does not (`WidgetDisplaySizeUITests`).
    private func widgetPhotos() -> [XCUIElement] {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let predicate = NSPredicate(
            format: "(label BEGINSWITH 'Photo' OR label BEGINSWITH 'Video' OR label BEGINSWITH 'Vidéo') AND label MATCHES '.*[0-9].*'"
        )
        return springboard.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
    }

    /// Poses the widget whose page title matches `title`, in its first size, through
    /// SpringBoard's edit mode (flow of `WidgetDisplaySizeUITests.poseLargeWidget`).
    private func poseWidget(title: NSPredicate) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func hittable(_ text: String, timeout: TimeInterval) -> XCUIElement? {
            let query = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", text))
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                for index in 0..<query.count where query.element(boundBy: index).isHittable {
                    return query.element(boundBy: index)
                }
                usleep(400_000)
            }
            return nil
        }
        XCUIDevice.shared.press(.home)
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2.0)
        sleep(3)
        if let edit = hittable("Modifier", timeout: 6) ?? hittable("Edit", timeout: 2) {
            edit.tap()
            sleep(2)
        }
        guard let addWidget = hittable("Ajouter un widget", timeout: 8) ?? hittable("Add Widget", timeout: 2) else {
            return XCTFail("the edit menu has no widget entry — SpringBoard flow changed")
        }
        addWidget.tap()
        sleep(4)
        let gallerySearch = [springboard.searchFields["Rechercher des widgets"], springboard.searchFields["Search Widgets"]]
            .first { $0.waitForExistence(timeout: 8) }
        guard let gallerySearch else { return XCTFail("the widget gallery never appeared") }
        gallerySearch.tap()
        gallerySearch.typeText("Swimmich")
        sleep(3)
        let result = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Swimmich'")).firstMatch
        guard result.waitForExistence(timeout: 10) else { return XCTFail("the gallery lists no Swimmich widget") }
        result.tap()
        sleep(3)
        let preview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Widget'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "the sheet shows no widget preview")
        let widgetTitle = springboard.staticTexts.matching(title).firstMatch
        for _ in 0..<12 where !widgetTitle.exists {
            preview.swipeLeft()
            sleep(2)
        }
        XCTAssertTrue(widgetTitle.waitForExistence(timeout: 5), "never reached the widget's page")
        guard let place = hittable("Ajouter le widget", timeout: 10) ?? hittable("Add Widget", timeout: 2) else {
            return XCTFail("the widget sheet has no add button")
        }
        place.tap()
        sleep(2)
        XCUIDevice.shared.press(.home)
        sleep(2)
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
