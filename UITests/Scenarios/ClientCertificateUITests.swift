import XCTest

/// Client certificate (mutual TLS, L-10): the user imports a PKCS#12 file for a
/// server that REQUIRES one, and every connection the app, its widgets and the
/// share extension open to that server presents it.
///
/// Against `immich_stub_client_cert.py`, an Immich stub whose HTTPS port refuses
/// any handshake that does not present a certificate signed by its CA. The proof
/// is on the wire: `/__handshakes` lists one entry per accepted connection with
/// the certificate it presented (`cert`: "A", "B", "unknown" or nil), whether the
/// TLS session was resumed (`resumed`) and the first path served (`path`);
/// `/__requests` lists what was served. The runner itself never talks to the
/// HTTPS ports (its `URLSession.shared` can neither trust the stub nor present a
/// certificate): it drives the stub through the plain-HTTP control port P+1.
///
/// Ports: P = the API, P+1 = control, P+2 = the same API on another port (AC-22.4).
///
/// IMPORT. The app is launched with `-uiTestClientCertificateFeed <P+1>/__client-cert/current`:
/// "Import Certificate…" then skips the system file picker and downloads the
/// bytes the test selected beforehand (`/__client-cert/select?name=a|b|nokey|notp12`).
/// The password is typed in the interface. `-uiTestResetClientCertificates YES`
/// wipes the identities of an earlier run at launch.
///
/// ONLY identifiers are used wherever the app declares one. The onboarding
/// copy (Get Started, Check connection, Continue, the SSO button), the alert
/// "Trust this server?" and the Albums / Road Trip entries carry no identifier:
/// like every other scenario, they are reached by their English label, the
/// app being launched in English.
///
/// Several methods ("not executed outside a Mac", S-20) read the TLS journal:
/// `test_AC_22`, `test_AC_22_2`, `test_AC_37_2`, `test_AC_22_6`. A SKIPPED test is
/// never a verdict.
///
/// Run it by hand, stub first (macOS, a booted simulator; the share-extension
/// method needs a Photos library seeded with one picture:
/// `xcrun simctl addmedia booted <png>`):
///
///     python3 -u UITests/stubs/immich_stub_client_cert.py 8421 &
///     curl http://127.0.0.1:8422/__whoami
///     TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \
///         -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \
///         -only-testing:ImmichSwiftUIUITests/ClientCertificateUITests/test_AC_21
///
/// One method at a time: the stub is one process and each method resets it.
final class ClientCertificateUITests: XCTestCase {

    /// `http://127.0.0.1:P`, as every scenario receives it (`TEST_RUNNER_IMMICH_STUB_URL`).
    private let stubURL = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var port: Int { URLComponents(string: stubURL)?.port ?? 8421 }
    /// The app's server URL: HTTPS on P, then the same host on P+2.
    private var apiBase: String { "https://127.0.0.1:\(port)" }
    private var otherBase: String { "https://127.0.0.1:\(port + 2)" }
    /// Where the runner probes and drives the stub: plain HTTP on P+1.
    private var control: String { "http://127.0.0.1:\(port + 1)" }

    private var app: XCUIApplication!

    /// The shell's day: photos 1...5, the video (6th) and, after `/__emit`, a 7th photo.
    private let videoId = "aaaaaaaa-1111-4111-8111-000000000006"
    private let photoId = "aaaaaaaa-1111-4111-8111-000000000002"
    private let emittedId = "aaaaaaaa-1111-4111-8111-000000000007"
    private let timelineIds = (1...6).map { "aaaaaaaa-1111-4111-8111-00000000000\($0)" }

    private let roadTripAlbumName = "Paris Weekend"
    private let roadTripIds = (1...9).map { "bbbbbbbb-2222-4222-8222-00000000000\($0)" }

    private static let getStarted = ["Get Started", "Commencer"]
    private static let checkConnection = ["Check connection", "Vérifier la connexion"]
    private static let tryAgain = ["Try Again", "Réessayer"]
    private static let proceed = ["Continue", "Continuer"]
    private static let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Client-certificate stub not reachable on \(control)")
    }

    /// True only for THIS stub on THIS port: another stub answering the control
    /// port would otherwise turn the scenarios green for the wrong reason.
    private func stubIsReachable() -> Bool {
        guard let url = URL(string: "\(control)/__whoami") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let done = DispatchSemaphore(value: 0)
        var identity: [String: Any]?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data { identity = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 5) == .success, status == 200 else { return false }
        return identity?["stub"] as? String == "immich_stub_client_cert.py"
            && identity?["port"] as? Int == port
    }

    // MARK: - Helpers: the stub

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A request through `URLSession.shared`: only ever for the plain-HTTP control port.
    private func controlGET(_ path: String) -> (status: Int, body: Data)? {
        var request = URLRequest(url: URL(string: "\(control)\(path)")!)
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 12) == .success else { return nil }
        return result
    }

    private func reset() {
        XCTAssertEqual(controlGET("/__reset")?.status, 200, "stub did not answer /__reset on \(control)")
    }

    private func setProvider(_ mode: String) {
        let reply = controlGET("/__provider?mode=\(mode)")
        XCTAssertEqual(reply.map { String(decoding: $0.body, as: UTF8.self) }, "{\"provider\": \"\(mode)\"}")
    }

    /// The file the next "Import Certificate…" downloads.
    private func select(_ name: String) {
        let reply = controlGET("/__client-cert/select?name=\(name)")
        XCTAssertEqual(reply?.status, 200, "the stub refused to select \(name)")
    }

    /// One entry of `/__handshakes`.
    private struct Handshake {
        let port: Int
        let ok: Bool
        let resumed: Bool?
        let cert: String?
        let error: String?
        let path: String?

        init(_ json: [String: Any]) {
            port = json["port"] as? Int ?? 0
            ok = json["ok"] as? Bool ?? false
            resumed = json["resumed"] as? Bool
            cert = json["cert"] as? String
            error = json["error"] as? String
            path = json["path"] as? String
        }

        var isSocket: Bool { path?.hasPrefix("/api/socket.io") == true }
        /// A full handshake that presented nothing: the server refused it.
        var presentedNothing: Bool { !ok && cert == nil }
    }

    private func handshakes(from index: Int = 0) -> [Handshake] {
        guard let reply = controlGET("/__handshakes"),
              let rows = (try? JSONSerialization.jsonObject(with: reply.body)) as? [[String: Any]] else { return [] }
        return rows.dropFirst(index).map(Handshake.init)
    }

    /// The index a later assertion starts from.
    private func handshakeMark() -> Int { handshakes().count }

    private func describe(_ handshakes: [Handshake]) -> String {
        handshakes.map {
            "port=\($0.port) ok=\($0.ok) resumed=\(String(describing: $0.resumed)) "
                + "cert=\(String(describing: $0.cert)) path=\(String(describing: $0.path)) "
                + "error=\(String(describing: $0.error))"
        }.joined(separator: "\n")
    }

    private struct LoggedRequest {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: Any]
        let status: Int?
        let contentLength: Int?
        let sent: Int?
        let aborted: Bool
        let range: String?
        let auth: Bool?

        init(_ json: [String: Any]) {
            method = json["method"] as? String ?? ""
            path = json["path"] as? String ?? ""
            params = (json["params"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            body = json["body"] as? [String: Any] ?? [:]
            status = json["status"] as? Int
            contentLength = json["contentLength"] as? Int
            sent = json["sent"] as? Int
            aborted = json["aborted"] as? Bool ?? false
            range = json["range"] as? String
            auth = json["auth"] as? Bool
        }

        /// Served in full: 200, every announced byte written, the client never left.
        var complete: Bool {
            status == 200 && !aborted && contentLength != nil && sent == contentLength
        }
    }

    private func stubRequests(from index: Int = 0) -> [LoggedRequest] {
        guard let reply = controlGET("/__requests"),
              let rows = (try? JSONSerialization.jsonObject(with: reply.body)) as? [[String: Any]] else { return [] }
        return rows.dropFirst(index).map(LoggedRequest.init)
    }

    private func requestMark() -> Int { stubRequests().count }

    private func describe(_ requests: [LoggedRequest]) -> String {
        requests.map {
            "\($0.method) \($0.path) params=\($0.params) status=\(String(describing: $0.status)) "
                + "sent=\(String(describing: $0.sent))/\(String(describing: $0.contentLength))"
                + ($0.aborted ? " ABORTED" : "")
        }.joined(separator: "\n")
    }

    /// Polls the journal every 0.5 s until `predicate` holds or `timeout` passes. The
    /// status fields are written AFTER the response, so an entry is polled for.
    @discardableResult
    private func waitForRequests(from index: Int = 0, timeout: TimeInterval,
                                 _ predicate: ([LoggedRequest]) -> Bool) -> [LoggedRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var journal = stubRequests(from: index)
        while !predicate(journal) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            journal = stubRequests(from: index)
        }
        return journal
    }

    @discardableResult
    private func waitForHandshakes(from index: Int = 0, timeout: TimeInterval,
                                   _ predicate: ([Handshake]) -> Bool) -> [Handshake] {
        let deadline = Date().addingTimeInterval(timeout)
        var journal = handshakes(from: index)
        while !predicate(journal) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            journal = handshakes(from: index)
        }
        return journal
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return condition()
    }

    // MARK: - Helpers: reading the screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement { element("assetTile_\(assetId)") }

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

    private func screenDump() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label)) "
            + "buttons: \(app.buttons.allElementsBoundByIndex.prefix(40).map(\.identifier))"
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

    /// Taps an element, scrolling first when the keyboard or the form hides it.
    private func tapRevealing(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 15), "no \(identifier) — \(screenDump())")
        for _ in 0..<3 where !target.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        target.tap()
    }

    // MARK: - Helpers: launching

    /// A FRESH launch against the stub: its journals reset, the identities of an
    /// earlier run wiped, no session (`-authServerURL ()` makes `restoreSession`
    /// find no server, so the onboarding is guaranteed).
    ///
    /// `-trustedServers` overrides the persisted approvals for this launch only:
    /// `()` approves nothing, whatever a previous run stored.
    private func launchApp(trusting: Bool = true) {
        if app.state != .notRunning { app.terminate() }
        reset()
        setProvider("manual")
        select("a")
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-authServerURL", "()",
            "-trustedServers", trusting ? "(\"127.0.0.1\")" : "()",
            "-uiTestResetClientCertificates", "YES",
            "-uiTestClientCertificateFeed", "\(control)/__client-cert/current",
        ]
        app.launch()
    }

    // MARK: - Helpers: the server step

    /// The welcome screen's CTA when the app starts at the very beginning, the
    /// server field straight away when it already shows it (after a logout).
    private func reachServerField() {
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 12) { return }
        XCTAssertTrue(tapAnyButton(Self.getStarted, timeout: 30), "Welcome CTA missing — \(screenDump())")
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
    }

    /// Types `url` in the server field (`typeText` APPENDS, so the field is
    /// emptied first when it holds something else).
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

    /// Welcome → the server URL typed. Leaves the app on the server step.
    private func openServerStep(_ url: String? = nil) {
        reachServerField()
        enterServer(url ?? apiBase)
    }

    private func tapCheck() {
        XCTAssertTrue(tapAnyButton(Self.checkConnection + Self.tryAgain), "Check-connection CTA missing — \(screenDump())")
    }

    private func waitReachable() {
        XCTAssertTrue(waitForButton(Self.proceed, timeout: 40), "Server never became reachable — \(screenDump())")
        XCTAssertFalse(element("serverStatusClientCertificateRequired").exists,
                       "the check passed but the status still asks for a certificate")
    }

    private func waitCertificateRequired() {
        XCTAssertTrue(element("serverStatusClientCertificateRequired").waitForExistence(timeout: 40),
                      "the server step never named the missing certificate — \(screenDump())")
    }

    // MARK: - Helpers: the certificate screen

    /// The sheet of the server step, from its "Client Certificate" button.
    private func openCertificateSheetFromServerStep() {
        let button = element("serverClientCertificateButton")
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no Client Certificate button — \(screenDump())")
        XCTAssertTrue(waitUntil(timeout: 10) { button.isEnabled }, "the Client Certificate button stayed disabled")
        button.tap()
        waitForCertificateScreen()
    }

    private func waitForCertificateScreen() {
        XCTAssertTrue(element("clientCertificateImportButton").waitForExistence(timeout: 15),
                      "the certificate screen never opened — \(screenDump())")
    }

    private func closeCertificateSheet() {
        let done = element("clientCertificateDoneButton")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done button on the certificate sheet — \(screenDump())")
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.element("clientCertificateDoneButton").exists },
                      "the certificate sheet stayed open")
    }

    /// Selects `file` on the stub, taps "Import Certificate…" (the app downloads it
    /// from the feed) and types `password` — without submitting.
    private func pickFile(_ file: String, password: String) {
        select(file)
        let importButton = element("clientCertificateImportButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), "no import button — \(screenDump())")
        XCTAssertTrue(waitUntil(timeout: 10) { importButton.isEnabled }, "the import button is disabled")
        importButton.tap()
        let field = element("clientCertificatePasswordField")
        XCTAssertTrue(field.waitForExistence(timeout: 20),
                      "the password field never appeared after picking \(file) — \(screenDump())")
        // A new pick drops the previous outcome: a stale message cannot be read as the new one.
        for kind in ["imported", "removed", "wrongPassword", "unusableFile", "saveFailed", "unreadableFile"] {
            XCTAssertFalse(element("clientCertificateMessage_\(kind)").exists,
                           "the message \(kind) outlived the new pick")
        }
        field.tap()
        field.typeText(password)
    }

    private func submitPassword() {
        tapRevealing("clientCertificatePasswordSubmit")
    }

    /// Picks `file`, types `password`, submits, and returns when SOME outcome shows.
    private func importFile(_ file: String, password: String) {
        pickFile(file, password: password)
        submitPassword()
        XCTAssertTrue(waitUntil(timeout: 30) { self.visibleMessage() != nil },
                      "no outcome after importing \(file) — \(screenDump())")
    }

    private func visibleMessage() -> String? {
        for kind in ["imported", "removed", "wrongPassword", "unusableFile", "saveFailed", "unreadableFile"]
        where element("clientCertificateMessage_\(kind)").exists {
            return kind
        }
        return nil
    }

    private func assertMessage(_ kind: String, _ context: String) {
        XCTAssertTrue(element("clientCertificateMessage_\(kind)").waitForExistence(timeout: 20),
                      "\(context): expected \(kind), the screen shows \(String(describing: visibleMessage())) — \(screenDump())")
    }

    private func assertInstalled(_ installed: Bool, _ context: String) {
        let expected = element(installed ? "clientCertificateStatus_installed" : "clientCertificateStatus_none")
        let other = element(installed ? "clientCertificateStatus_none" : "clientCertificateStatus_installed")
        XCTAssertTrue(expected.waitForExistence(timeout: 15),
                      "\(context): the status does not read \(installed ? "installed" : "none") — \(screenDump())")
        XCTAssertFalse(other.exists, "\(context): both statuses are shown")
    }

    /// Remove → confirm. Leaves the certificate screen with the `removed` message.
    private func removeCertificate() {
        let remove = element("clientCertificateRemoveButton")
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "no Remove button — \(screenDump())")
        XCTAssertTrue(waitUntil(timeout: 10) { remove.isEnabled }, "the Remove button is disabled")
        remove.tap()
        let confirm = element("clientCertificateRemoveConfirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the removal was not confirmed by an alert — \(screenDump())")
        confirm.tap()
        assertMessage("removed", "removal")
    }

    /// The certificate of the typed server, imported on the server step.
    private func importOnServerStep(_ file: String = "a", password: String = "alpha") {
        openCertificateSheetFromServerStep()
        assertInstalled(false, "before the import")
        importFile(file, password: password)
        assertMessage("imported", "import of \(file)")
        assertInstalled(true, "after the import")
        closeCertificateSheet()
    }

    // MARK: - Helpers: signing in

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

    /// From a reachable server step to the login screen.
    private func continueToLogin() {
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            // The CTA sits under the keyboard the typing raised: scrolling dismisses
            // it, and a bounded retry covers the frame it was still animating.
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(Self.proceed), "Continue CTA missing — \(screenDump())")
            onLogin = waitForStaticText(Self.loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("cc-not-on-login-screen")
            XCTFail("Login screen did not appear — \(screenDump())")
        }
    }

    private var whatsNewDone: XCUIElement {
        app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
    }

    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        whatsNewDone.tap()
        _ = waitUntil(timeout: 10) { !self.whatsNewDone.exists }
    }

    /// The SSO of the stub, from the login screen to the timeline.
    private func ssoLogin() {
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell — \(screenDump())")
        XCTAssertTrue(tile(photoId).waitForExistence(timeout: 40), "the timeline never rendered — \(screenDump())")
        dismissWhatsNewIfPresent()
    }

    /// From the server step with the certificate installed (the import re-checked
    /// the server by itself) to the timeline.
    private func signInFromServerStep() {
        waitReachable()
        continueToLogin()
        ssoLogin()
    }

    /// A fresh app, the certificate A imported, signed in, the timeline up.
    private func signInWithCertificateA() {
        launchApp()
        openServerStep()
        importOnServerStep("a", password: "alpha")
        signInFromServerStep()
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
                      "the Me sheet never closed — \(screenDump())")
    }

    /// Me hub → Advanced → Client Certificate.
    private func openCertificateFromHub() {
        openHub()
        reveal("clientCertificateRow")
        let row = element("clientCertificateRow")
        XCTAssertTrue(row.exists, "the Me hub has no Client Certificate row — \(screenDump())")
        row.tap()
        waitForCertificateScreen()
    }

    /// Pulls the timeline down and returns the journal index it started from: a
    /// later request to `/api/timeline` is the refresh.
    private func pullToRefresh() {
        XCTAssertTrue(tile(photoId).waitForExistence(timeout: 20), "the timeline is not on screen — \(screenDump())")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// A refresh that reaches the stub: the timeline's request, answered 200.
    private func refreshTimelineAndWaitServed(from index: Int) {
        pullToRefresh()
        let journal = waitForRequests(from: index, timeout: 40) {
            $0.contains { $0.path.hasPrefix("/api/timeline") && $0.status == 200 }
        }
        XCTAssertTrue(journal.contains { $0.path.hasPrefix("/api/timeline") && $0.status == 200 },
                      "the refresh never reached the stub:\n\(describe(journal))")
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back from the viewer — \(screenDump())")
        back.tap()
        XCTAssertTrue(tile(photoId).waitForExistence(timeout: 20), "the timeline did not come back — \(screenDump())")
    }

    private func logOut() {
        openHub()
        reveal("logoutButton")
        let logout = element("logoutButton")
        XCTAssertTrue(logout.exists, "no Log Out row — \(screenDump())")
        logout.tap()
        let confirm = app.alerts.buttons.matching(identifier: "logoutConfirmButton").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), "no log-out confirmation — \(screenDump())")
        confirm.tap()
    }

    // MARK: - Helpers: the assertions on the journal

    /// Every handshake in `journal` presented `cert` and succeeded.
    private func assertAllPresent(_ cert: String, in journal: [Handshake], _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let others = journal.filter { !$0.ok || $0.cert != cert }
        XCTAssertTrue(others.isEmpty,
                      "\(context): \(others.count) handshake(s) without certificate \(cert):\n\(describe(others))",
                      file: file, line: line)
    }

    /// No session established with `cert` was resumed after the journal index.
    private func assertNoResumption(of cert: String, in journal: [Handshake], _ context: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let resumed = journal.filter { $0.resumed == true && $0.cert == cert }
        XCTAssertTrue(resumed.isEmpty,
                      "\(context): a session established with \(cert) was resumed:\n\(describe(resumed))",
                      file: file, line: line)
    }

    // MARK: - AC-21

    /// The right file with its password, then the connection, the timeline and the
    /// thumbnails: every handshake of the journal presents certificate A.
    func test_AC_21() throws {
        launchApp()
        openServerStep()
        importOnServerStep("a", password: "alpha")
        signInFromServerStep()

        // Thumbnails: each tile of the day was requested and served in full.
        let journal = waitForRequests(timeout: 40) { journal in
            self.timelineIds.allSatisfy { id in
                journal.contains { $0.path == "/api/assets/\(id)/thumbnail" && $0.complete }
            }
        }
        for id in timelineIds {
            XCTAssertTrue(journal.contains { $0.path == "/api/assets/\(id)/thumbnail" && $0.complete },
                          "thumbnail of \(id) not served in full:\n\(describe(journal))")
        }
        XCTAssertTrue(journal.contains { $0.path.hasPrefix("/api/timeline") && $0.status == 200 },
                      "no timeline request served:\n\(describe(journal))")

        let connections = handshakes()
        XCTAssertFalse(connections.isEmpty, "the stub saw no handshake")
        assertAllPresent("A", in: connections, "AC-21")
        shot("cc-ac21-timeline")
    }

    // MARK: - AC-22

    /// Removal on the server step: the check run again fails and says why, and the
    /// TLS journal shows a full handshake without certificate, none resumed from
    /// the session established with A. (Not executed outside a Mac, S-20.)
    func test_AC_22() throws {
        launchApp()
        openServerStep()
        importOnServerStep("a", password: "alpha")
        waitReachable()
        XCTAssertFalse(handshakes().isEmpty, "the first check left no handshake")

        let before = handshakeMark()
        openCertificateSheetFromServerStep()
        assertInstalled(true, "before the removal")
        removeCertificate()
        assertInstalled(false, "after the removal")
        closeCertificateSheet()

        // The removal re-checks the server by itself.
        waitCertificateRequired()
        XCTAssertTrue(element("serverStatusImportCertificateButton").exists, "no way to import from the status")
        XCTAssertFalse(app.buttons.matching(labelPredicate(Self.proceed)).firstMatch.exists,
                       "the check passed without a certificate")

        let after = waitForHandshakes(from: before, timeout: 30) { $0.contains { $0.presentedNothing } }
        XCTAssertTrue(after.contains { $0.presentedNothing && $0.resumed == nil },
                      "no full handshake without certificate after the removal:\n\(describe(after))")
        assertNoResumption(of: "A", in: after, "AC-22")
        XCTAssertFalse(after.contains { $0.ok && $0.cert == "A" },
                       "a connection still presented A after the removal:\n\(describe(after))")
        shot("cc-ac22-required")
    }

    // MARK: - AC-37

    /// A valid file with a wrong password: refused, the message names the
    /// password, nothing is installed.
    func test_AC_37() throws {
        launchApp()
        openServerStep()
        openCertificateSheetFromServerStep()
        importFile("a", password: "not-the-password")
        assertMessage("wrongPassword", "wrong password")
        XCTAssertFalse(element("clientCertificateMessage_unusableFile").exists, "the file was called unusable")
        XCTAssertFalse(element("clientCertificateMessage_imported").exists, "the import succeeded")
        assertInstalled(false, "after the refusal")
        // The password and the file were dropped: the screen asks for a new pick.
        XCTAssertFalse(element("clientCertificatePasswordField").exists, "the password field outlived the attempt")
        shot("cc-ac37-wrong-password")
    }

    // MARK: - AC-21.1

    /// The server step's check failed for want of a certificate; importing the right
    /// one shows the success, the installed state, and the check passes again
    /// without relaunching.
    func test_AC_21_1() throws {
        launchApp()
        openServerStep()
        tapCheck()
        waitCertificateRequired()

        tapRevealing("serverStatusImportCertificateButton")
        waitForCertificateScreen()
        importFile("a", password: "alpha")
        assertMessage("imported", "AC-21.1")
        assertInstalled(true, "AC-21.1")
        closeCertificateSheet()

        waitReachable()
        let served = waitForRequests(timeout: 20) { $0.contains { $0.path == "/api/server/ping" && $0.status == 200 } }
        XCTAssertTrue(served.contains { $0.path == "/api/server/ping" && $0.status == 200 },
                      "the check run again never reached the server:\n\(describe(served))")
        assertAllPresent("A", in: handshakes().filter { $0.ok }, "AC-21.1")
    }

    // MARK: - AC-37.1

    /// A PNG renamed `.p12`, then a PKCS#12 without a private key: both refused with
    /// the "not a usable certificate" message, which is not the password message.
    func test_AC_37_1() throws {
        launchApp()
        openServerStep()
        openCertificateSheetFromServerStep()

        for file in ["notp12", "nokey"] {
            importFile(file, password: "alpha")
            assertMessage("unusableFile", file)
            XCTAssertFalse(element("clientCertificateMessage_wrongPassword").exists,
                           "\(file): the refusal blames the password")
            assertInstalled(false, "after \(file)")
        }
        shot("cc-ac37-1-unusable")
    }

    // MARK: - AC-37.2

    /// A installed, signed in. B with a wrong password: A stays and the next requests
    /// succeed with A. B with its password: B replaces A, the next connection is a
    /// full handshake presenting B, and no later one resumes a session from A.
    /// (Not executed outside a Mac, S-20.)
    func test_AC_37_2() throws {
        signInWithCertificateA()

        // B, wrong password: refused, A stays installed.
        openCertificateFromHub()
        assertInstalled(true, "before B")
        let wrongMark = handshakeMark()
        let wrongRequests = requestMark()
        importFile("b", password: "not-the-password")
        assertMessage("wrongPassword", "B with a wrong password")
        assertInstalled(true, "A after the refused B")
        dismissHub()
        refreshTimelineAndWaitServed(from: wrongRequests)
        assertAllPresent("A", in: handshakes(from: wrongMark), "requests after the refused B")

        // B, right password: B replaces A.
        openCertificateFromHub()
        let replaceMark = handshakeMark()
        importFile("b", password: "bravo")
        assertMessage("imported", "B")
        assertInstalled(true, "after B")
        dismissHub()
        let refreshRequests = requestMark()
        refreshTimelineAndWaitServed(from: refreshRequests)

        let after = waitForHandshakes(from: replaceMark, timeout: 30) {
            $0.contains { $0.ok && $0.cert == "B" && $0.resumed == false }
        }
        XCTAssertTrue(after.contains { $0.ok && $0.cert == "B" && $0.resumed == false },
                      "no full handshake presenting B after the replacement:\n\(describe(after))")
        XCTAssertFalse(after.contains { $0.cert == "A" },
                       "a connection still presented A after B replaced it:\n\(describe(after))")
        assertNoResumption(of: "A", in: after, "AC-37.2")
        shot("cc-ac37-2-replaced")
    }

    // MARK: - AC-22.1

    /// Nothing installed for the typed address: the state says so and Remove is
    /// not offered.
    func test_AC_22_1() throws {
        launchApp()
        openServerStep()
        openCertificateSheetFromServerStep()
        assertInstalled(false, "AC-22.1")
        let remove = element("clientCertificateRemoveButton")
        XCTAssertFalse(remove.exists && remove.isEnabled, "Remove is offered with no certificate installed")
        XCTAssertTrue(element("clientCertificateServer").label.contains("127.0.0.1:\(port)"),
                      "the screen names another server: \(element("clientCertificateServer").label)")
        shot("cc-ac22-1-none")
    }

    // MARK: - AC-22.2

    /// Signed in with A, then logged out: the same address finds the certificate
    /// installed and signs in without a new import. Removed from the Me hub, the next
    /// request fails (the timeline's error banner) and the TLS journal shows a full
    /// handshake without certificate. (Not executed outside a Mac, S-20.)
    func test_AC_22_2() throws {
        signInWithCertificateA()

        logOut()
        reachServerField()
        // Typed again with a trailing slash: the same server, a field that changed.
        enterServer(apiBase + "/")
        openCertificateSheetFromServerStep()
        assertInstalled(true, "after the log-out")
        closeCertificateSheet()
        tapCheck()
        waitReachable()
        continueToLogin()
        ssoLogin()
        XCTAssertTrue(waitForRequests(timeout: 20) { $0.contains { $0.path.hasPrefix("/api/timeline") && $0.status == 200 } }
            .contains { $0.path.hasPrefix("/api/timeline") && $0.status == 200 },
                      "the second sign-in served no timeline")

        // Removed from the Me hub.
        openCertificateFromHub()
        assertInstalled(true, "before the removal")
        let mark = handshakeMark()
        removeCertificate()
        assertInstalled(false, "after the removal")
        dismissHub()

        pullToRefresh()
        XCTAssertTrue(element("timelineLoadErrorBanner").waitForExistence(timeout: 40),
                      "the refresh without certificate raised no error banner — \(screenDump())")
        let after = waitForHandshakes(from: mark, timeout: 30) { $0.contains { $0.presentedNothing } }
        XCTAssertTrue(after.contains { $0.presentedNothing && $0.resumed == nil },
                      "no full handshake without certificate after the removal:\n\(describe(after))")
        XCTAssertFalse(after.contains { $0.ok && $0.cert == "A" },
                       "a connection still presented A after the removal:\n\(describe(after))")
        assertNoResumption(of: "A", in: after, "AC-22.2")
        shot("cc-ac22-2-banner")
    }

    // MARK: - AC-21.2

    /// A self-signed server never approved: with the right certificate imported, the
    /// check raises "Trust this server?". Approving lets the check and the sign-in
    /// pass; refusing lets nothing through, and the client certificate does not
    /// make up for it.
    func test_AC_21_2() throws {
        // Approved.
        launchApp(trusting: false)
        openServerStep()
        openCertificateSheetFromServerStep()
        importFile("a", password: "alpha")
        assertMessage("imported", "AC-21.2")
        closeCertificateSheet()

        var alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 40), "no 'Trust this server?' alert — \(screenDump())")
        alert.buttons["Trust"].tap()
        waitReachable()
        let served = waitForRequests(timeout: 20) { $0.contains { $0.path == "/api/server/ping" && $0.status == 200 } }
        XCTAssertTrue(served.contains { $0.path == "/api/server/ping" && $0.status == 200 },
                      "the approved check never reached the server:\n\(describe(served))")
        assertAllPresent("A", in: handshakes().filter { $0.ok }, "AC-21.2 approved")

        // Refused: a fresh launch, the same steps, "Cancel".
        launchApp(trusting: false)
        openServerStep()
        openCertificateSheetFromServerStep()
        importFile("a", password: "alpha")
        assertMessage("imported", "AC-21.2 refused")
        closeCertificateSheet()

        alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 40), "no 'Trust this server?' alert — \(screenDump())")
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(waitForButton(Self.proceed, timeout: 6), "the check passed although the server was refused")

        XCTAssertTrue(stubRequests().isEmpty, "a request reached the stub:\n\(describe(stubRequests()))")
        let connections = handshakes()
        XCTAssertFalse(connections.contains { $0.ok }, "a handshake succeeded:\n\(describe(connections))")
        XCTAssertFalse(connections.contains { $0.cert != nil },
                       "the client certificate was presented to an unapproved server:\n\(describe(connections))")
    }

    // MARK: - AC-21.3

    /// Signed in with A: a real-time event updates the timeline, the video plays, an
    /// original is downloaded, a photo made available offline, a Road Trip opens with
    /// its pictures — and every connection of the journal, the WebSocket included,
    /// presented A.
    func test_AC_21_3() throws {
        signInWithCertificateA()

        // Real time: the WebSocket is open, an event adds a photo and the timeline follows.
        let socket = waitForHandshakes(timeout: 40) { $0.contains { $0.isSocket && $0.cert == "A" } }
        XCTAssertTrue(socket.contains { $0.isSocket && $0.ok && $0.cert == "A" },
                      "the WebSocket never connected with A:\n\(describe(socket))")
        XCTAssertTrue(waitForRequests(timeout: 20) { $0.contains { $0.path.hasPrefix("/api/socket.io") && $0.auth == true } }
            .contains { $0.path.hasPrefix("/api/socket.io") && $0.auth == true },
                      "the WebSocket carried no Bearer token")
        let emitted = controlGET("/__emit?event=on_upload_success")
        let sockets = (emitted.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } as? [String: Any])?["sockets"] as? Int
        XCTAssertGreaterThanOrEqual(sockets ?? 0, 1, "the stub has no open WebSocket to emit to")
        XCTAssertTrue(tile(emittedId).waitForExistence(timeout: 40),
                      "the timeline never showed the photo the event announced — \(screenDump())")

        // The video: the stream is read over TLS with A.
        let videoMark = requestMark()
        XCTAssertTrue(tile(videoId).waitForExistence(timeout: 20), "the video tile is missing — \(screenDump())")
        tile(videoId).tap()
        let played = waitForRequests(from: videoMark, timeout: 60) {
            $0.contains { $0.path == "/api/assets/\(self.videoId)/video/playback" && ($0.status == 200 || $0.status == 206) }
        }
        XCTAssertTrue(played.contains { $0.path == "/api/assets/\(self.videoId)/video/playback"
                                         && ($0.status == 200 || $0.status == 206) },
                      "the video was never read:\n\(describe(played))")
        XCTAssertTrue(played.contains { $0.path.hasSuffix("/video/playback") && $0.range != nil },
                      "the video was not read by ranges:\n\(describe(played))")
        closeViewer()

        // A photo: offline copy, then a download of its original.
        let photoMark = requestMark()
        tile(photoId).tap()
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 25), "the viewer never opened — \(screenDump())")
        share.tap()

        let offlineRow = element("offlineAvailableRow")
        let downloadOffline = element("downloadForOfflineButton")
        if offlineRow.waitForExistence(timeout: 3) {  // a copy left by an earlier run
            element("removeFromOfflineButton").tap()
            XCTAssertTrue(downloadOffline.waitForExistence(timeout: 15), "the old offline copy was not removed")
        }
        XCTAssertTrue(downloadOffline.waitForExistence(timeout: 15), "no 'Download for offline' — \(screenDump())")
        downloadOffline.tap()
        XCTAssertTrue(offlineRow.waitForExistence(timeout: 60), "the offline copy never became available — \(screenDump())")
        let originals = { (journal: [LoggedRequest]) in
            journal.filter { $0.path == "/api/assets/\(self.photoId)/original" && $0.complete }
        }
        var journal = waitForRequests(from: photoMark, timeout: 15) { !originals($0).isEmpty }
        let offlineCount = originals(journal).count
        XCTAssertGreaterThanOrEqual(offlineCount, 1, "the offline copy fetched no original:\n\(describe(journal))")

        let downloadToFiles = element("downloadToFilesButton")
        XCTAssertTrue(downloadToFiles.waitForExistence(timeout: 25), "no 'Download to Files' — \(screenDump())")
        downloadToFiles.tap()
        journal = waitForRequests(from: photoMark, timeout: 60) { originals($0).count >= offlineCount + 1 }
        XCTAssertGreaterThanOrEqual(originals(journal).count, offlineCount + 1,
                                    "the download fetched no original of its own:\n\(describe(journal))")
        XCTAssertFalse(journal.contains { $0.aborted }, "a request was cut mid-body:\n\(describe(journal))")

        // Courtesy to the other scenarios: leave no offline copy behind.
        let remove = element("removeFromOfflineButton")
        if remove.waitForExistence(timeout: 10) {
            remove.tap()
            _ = downloadOffline.waitForExistence(timeout: 15)
        }
        let close = element("closeShareSheet")
        XCTAssertTrue(close.waitForExistence(timeout: 15), "no Close on the share sheet — \(screenDump())")
        close.tap()
        closeViewer()

        // A Road Trip: the player appears with every geotagged picture requested.
        let albumsTab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 30), "no Albums tab — \(screenDump())")
        albumsTab.tap()
        XCTAssertTrue(tapAnyButton([roadTripAlbumName], timeout: 30), "album \(roadTripAlbumName) not listed — \(screenDump())")
        XCTAssertTrue(tile(roadTripIds[0]).waitForExistence(timeout: 30), "the album grid shows no tile — \(screenDump())")
        let actions = app.buttons["Album actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 15), "no 'Album actions' menu — \(screenDump())")
        actions.tap()
        let roadTrip = app.buttons["Road Trip"].firstMatch
        XCTAssertTrue(roadTrip.waitForExistence(timeout: 10), "no 'Road Trip' in the menu — \(screenDump())")
        roadTrip.tap()

        XCTAssertTrue(element("roadTripPlayer").waitForExistence(timeout: 60), "the Road Trip never played — \(screenDump())")
        XCTAssertFalse(element("roadTripError").exists, "the Road Trip failed — \(screenDump())")
        let previews = waitForRequests(timeout: 20) { journal in
            self.roadTripIds.allSatisfy { id in
                journal.contains { $0.path == "/api/assets/\(id)/thumbnail" && $0.params["size"] == "preview" && $0.complete }
            }
        }
        for id in roadTripIds {
            XCTAssertTrue(previews.contains { $0.path == "/api/assets/\(id)/thumbnail" && $0.params["size"] == "preview" && $0.complete },
                          "preview of \(id) not served in full:\n\(describe(previews))")
        }

        assertAllPresent("A", in: handshakes(), "AC-21.3")
    }

    // MARK: - AC-21.4

    /// Signed in with A, the app terminated: sharing a photo from Photos to Swimmich
    /// uploads it to this server, the extension's connections presenting A.
    /// Needs a Photos library seeded with a picture.
    func test_AC_21_4_shareExtension() throws {
        signInWithCertificateA()

        // The keychain write happens on the login / republish path: give it a beat.
        sleep(3)
        app.terminate()
        sleep(3)
        let requests = requestMark()
        let connections = handshakeMark()

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.terminate()
        photos.launch()
        XCTAssertEqual(photos.state, .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        for label in ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"] {
            let button = photos.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                sleep(2)
            }
        }

        let tiles = photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20), "the Photos library never published a tile")
        // The newest tile is the one `simctl addmedia` seeded.
        tiles.element(boundBy: tiles.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let shareButton = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 25), "the photo viewer never offered its share button")
        shareButton.tap()

        let predicate = NSPredicate(format: "label == 'Swimmich'")
        var activity: XCUIElement?
        for attempt in 0..<3 where activity == nil {
            for root in [photos as XCUIElement, springboard as XCUIElement] {
                let match = root.descendants(matching: .any).matching(predicate).firstMatch
                if match.exists { activity = match }
            }
            if activity == nil && attempt < 2 {
                let row = photos.collectionViews.firstMatch
                if row.exists { row.swipeLeft() } else { photos.swipeLeft() }
                sleep(2)
            }
        }
        guard let activity else {
            XCTFail("the share sheet has no Swimmich activity")
            return
        }
        activity.tap()

        let serverLabel = photos.staticTexts.matching(identifier: "shareExtensionServerLabel").firstMatch
        XCTAssertTrue(serverLabel.waitForExistence(timeout: 40),
                      "the Swimmich sheet never presented itself — it reads no session")
        let upload = photos.buttons.matching(identifier: "shareExtensionUploadButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 20), "the sheet has no upload button")
        upload.tap()

        let sent = waitForRequests(from: requests, timeout: 60) {
            $0.contains { $0.method == "POST" && $0.path == "/api/assets" && $0.status == 201 }
        }
        XCTAssertTrue(sent.contains { $0.method == "POST" && $0.path == "/api/assets" && $0.status == 201 },
                      "no upload reached the stub:\n\(describe(sent))")

        let done = photos.buttons.matching(identifier: "shareExtensionDoneButton").firstMatch
        if done.waitForExistence(timeout: 30) { done.tap() }

        let extensionConnections = handshakes(from: connections)
        XCTAssertTrue(extensionConnections.contains { $0.path == "/api/assets" },
                      "the upload arrived on no recorded connection:\n\(describe(extensionConnections))")
        assertAllPresent("A", in: extensionConnections, "AC-21.4 (the extension's connections)")
    }

    // MARK: - AC-22.3

    /// No certificate installed and a server that requires one: the failure names the
    /// missing certificate (not "unreachable") and leads to the import.
    func test_AC_22_3() throws {
        launchApp()
        openServerStep()
        tapCheck()
        waitCertificateRequired()
        shot("cc-ac22-3-required")

        let importButton = element("serverStatusImportCertificateButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "the status offers no import")
        tapRevealing("serverStatusImportCertificateButton")
        waitForCertificateScreen()
        assertInstalled(false, "AC-22.3")
        closeCertificateSheet()

        let connections = handshakes()
        XCTAssertTrue(connections.contains { $0.presentedNothing },
                      "the stub saw no refused handshake:\n\(describe(connections))")
        XCTAssertFalse(connections.contains { $0.ok }, "a handshake succeeded without a certificate:\n\(describe(connections))")
    }

    // MARK: - AC-22.4

    /// A certificate attached to P is never shown to P+2 (same host, another port):
    /// the stub's journal for that port presents nothing, and the failure names the
    /// missing certificate.
    func test_AC_22_4() throws {
        launchApp()
        openServerStep()
        importOnServerStep("a", password: "alpha")
        waitReachable()
        XCTAssertTrue(handshakes().contains { $0.port == port && $0.ok && $0.cert == "A" },
                      "the first server never saw A:\n\(describe(handshakes()))")

        let mark = handshakeMark()
        enterServer(otherBase)
        tapCheck()
        waitCertificateRequired()

        let other = waitForHandshakes(from: mark, timeout: 30) { $0.contains { $0.port == self.port + 2 } }
        XCTAssertTrue(other.contains { $0.port == self.port + 2 }, "the other port was never contacted:\n\(describe(other))")
        let onOther = other.filter { $0.port == self.port + 2 }
        XCTAssertTrue(onOther.allSatisfy { $0.cert == nil && !$0.ok },
                      "a certificate was presented to the other port:\n\(describe(onOther))")

        tapRevealing("serverStatusImportCertificateButton")
        waitForCertificateScreen()
        assertInstalled(false, "the other port")
        XCTAssertTrue(element("clientCertificateServer").label.contains("127.0.0.1:\(port + 2)"),
                      "the screen names another server: \(element("clientCertificateServer").label)")
        closeCertificateSheet()
    }

    // MARK: - AC-22.6

    /// Signed in with A and the real time connected: replacing A by B reconnects the
    /// WebSocket with a full handshake presenting B; removing B reconnects it again,
    /// this time without certificate (the failure stays silent).
    /// (Not executed outside a Mac, S-20.)
    func test_AC_22_6() throws {
        signInWithCertificateA()
        let first = waitForHandshakes(timeout: 40) { $0.contains { $0.isSocket && $0.cert == "A" } }
        XCTAssertTrue(first.contains { $0.isSocket && $0.ok && $0.cert == "A" },
                      "the WebSocket never connected with A:\n\(describe(first))")

        // A → B.
        openCertificateFromHub()
        let replaceMark = handshakeMark()
        importFile("b", password: "bravo")
        assertMessage("imported", "AC-22.6 replacement")
        let afterReplace = waitForHandshakes(from: replaceMark, timeout: 60) {
            $0.contains { $0.isSocket && $0.ok && $0.cert == "B" && $0.resumed == false }
        }
        XCTAssertTrue(afterReplace.contains { $0.isSocket && $0.ok && $0.cert == "B" && $0.resumed == false },
                      "the WebSocket did not reconnect with a full handshake presenting B:\n\(describe(afterReplace))")
        XCTAssertFalse(afterReplace.contains { $0.isSocket && $0.cert == "A" },
                       "the WebSocket reconnected with A after B replaced it:\n\(describe(afterReplace))")

        // B → nothing.
        let removeMark = handshakeMark()
        removeCertificate()
        let afterRemove = waitForHandshakes(from: removeMark, timeout: 60) { $0.contains { $0.presentedNothing } }
        XCTAssertTrue(afterRemove.contains { $0.presentedNothing && $0.resumed == nil },
                      "the real time did not reconnect without certificate:\n\(describe(afterRemove))")
        XCTAssertFalse(afterRemove.contains { $0.isSocket && $0.ok },
                       "the WebSocket connected although the certificate was removed:\n\(describe(afterRemove))")
        // Silent: the failure raises nothing on the screen.
        XCTAssertFalse(element("timelineLoadErrorBanner").exists, "the real-time failure raised an error banner")
    }

    // MARK: - AC-21.5

    /// A video opened in the viewer: with a certificate installed, the Cast sheet says
    /// AirPlay cannot play it; without one, the hint is absent.
    ///
    /// The Cast pill is disabled while no route exists, and a simulator has none
    /// (`ChromecastUITests`): there the sheet cannot be opened, and the method
    /// skips instead of claiming a verdict. The decision itself is proved in
    /// `CastViewModelTests.test_AC_21_5_hintOnlyForVideoWithCertificate`.
    func test_AC_21_5() throws {
        signInWithCertificateA()

        func openCastSheet() throws {
            XCTAssertTrue(tile(videoId).waitForExistence(timeout: 20), "the video tile is missing — \(screenDump())")
            tile(videoId).tap()
            XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 25), "the viewer never opened — \(screenDump())")
            var cast = element("viewerCastButton")
            if !cast.exists {
                let overflow = element("viewerOverflowMenu")
                XCTAssertTrue(overflow.waitForExistence(timeout: 15), "the viewer has no Cast action — \(screenDump())")
                overflow.tap()
                cast = element("viewerMenuCast")
                XCTAssertTrue(cast.waitForExistence(timeout: 5), "⋯ holds no Cast action — \(screenDump())")
            }
            guard cast.isEnabled else {
                throw XCTSkip("No AirPlay route on this device: the Cast action is disabled and its sheet cannot be opened.")
            }
            cast.tap()
        }

        func closeCastSheet() {
            for _ in 0..<4 where !element("viewerBackButton").isHittable {
                let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
                top.press(forDuration: 0.1, thenDragTo: bottom)
                Thread.sleep(forTimeInterval: 1)
            }
        }

        try openCastSheet()
        XCTAssertTrue(element("castClientCertificateHint").waitForExistence(timeout: 10),
                      "no hint with a certificate installed — \(screenDump())")
        closeCastSheet()
        closeViewer()

        // Without a certificate: the same sheet, no hint.
        openCertificateFromHub()
        removeCertificate()
        dismissHub()
        try openCastSheet()
        XCTAssertFalse(element("castClientCertificateHint").waitForExistence(timeout: 5),
                       "the hint shows with no certificate installed")
    }
}
