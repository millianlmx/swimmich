import XCTest

/// End-to-end scenarios for a SELF-SIGNED Immich server the user approved
/// (`trustedServers`): thumbnails, the full-screen image and the transfers must
/// really be served over the TLS the app accepted — not only the API calls.
///
/// Every scenario here is proven on the WIRE: the stub (`immich_stub_selfsigned.py`)
/// serves the API over HTTPS on P and logs each request with the status and the
/// bytes it really wrote, so an entry in `/__requests` can only exist if the TLS
/// handshake passed. The runner itself never talks to the HTTPS port (a
/// `URLSession.shared` request would refuse the certificate): it probes and
/// drives the stub through the plain-HTTP control port P+1.
///
/// Run it by hand, stub first (the launcher `.omp/orchestration/uitest.sh` is
/// not involved):
///
///     python3 -u UITests/stubs/immich_stub_selfsigned.py 8421 &
///     TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \
///         -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,name=<iPhone>' \
///         -only-testing:ImmichSwiftUIUITests/SelfSignedTrustUITests
///
/// A SKIPPED test is never a verdict: without the stub every test skips, and a
/// run with a skip proves none of the criteria (AC-47).
///
/// The "Trust this server?" alert is NOT used: against a real server it never
/// appears (`ImmichAPIClient.dispatch` wraps the `URLError` in `APIError.network`),
/// so the host is approved up front with `-trustedServers '("127.0.0.1")'`.
final class SelfSignedTrustUITests: XCTestCase {

    /// `http://127.0.0.1:P`, as every scenario receives it (`TEST_RUNNER_IMMICH_STUB_URL`).
    private let stubURL = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var port: Int { URLComponents(string: stubURL)?.port ?? 8421 }
    /// The app's server URL: HTTPS on P.
    private var apiBase: String { "https://127.0.0.1:\(port)" }
    /// Where the runner probes and drives the stub: plain HTTP on P+1.
    private var control: String { "http://127.0.0.1:\(port + 1)" }

    private var app: XCUIApplication!

    /// The first photo of the shell's day: the one whose original streams slowly.
    private let target = "aaaaaaaa-1111-4111-8111-000000000001"
    private let timelineIds = (1...6).map { "aaaaaaaa-1111-4111-8111-00000000000\($0)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Self-signed stub not reachable on \(control)")
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
        return identity?["stub"] as? String == "immich_stub_selfsigned.py"
            && identity?["port"] as? Int == port
    }

    // MARK: - Helpers
    //
    // Copied from `DownloadPanelUITests` on purpose (one file per feature, no
    // shared support file); only the URLs differ.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// A request through `URLSession.shared`: only ever for the plain-HTTP control port.
    private func send(_ request: URLRequest) -> (status: Int, body: Data)? {
        var request = request
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

    private func controlGET(_ path: String) -> (status: Int, body: Data)? {
        send(URLRequest(url: URL(string: "\(control)\(path)")!))
    }

    /// Empties the stub's journal and TLS counters and rotates its thumbhash.
    private func reset() {
        let reply = controlGET("/__reset")
        XCTAssertEqual(reply?.status, 200, "stub did not answer /__reset on \(control)")
    }

    private func setProvider(_ mode: String) {
        let reply = controlGET("/__provider?mode=\(mode)")
        XCTAssertEqual(reply.map { String(decoding: $0.body, as: UTF8.self) }, "{\"provider\": \"\(mode)\"}")
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

    /// Welcome → the server URL typed → "Check connection" tapped.
    private func enterServerURL() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        // The field can hold a previous run's URL and `typeText` APPENDS.
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != apiBase {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != apiBase {
            field.typeText(apiBase)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
    }

    /// Welcome → server URL → login. Leaves the app on the login screen.
    private func walkOnboardingToLogin() {
        enterServerURL()
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        // The CTA sits under the keyboard the typing raised: scrolling dismisses
        // it, and a bounded retry covers the frame it was still animating.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("st-not-on-login-screen")
            XCTFail("Login screen did not appear — \(screenDump())")
        }
    }

    /// Onboarding against the approved server, then "Immich SSO", up to the timeline.
    private func signIn() {
        walkOnboardingToLogin()
        shot("st-login-sso")
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell; \(screenDump())")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }
    }

    /// A FRESH launch against the stub with its journal and counters reset.
    ///
    /// `-authServerURL ()` makes `restoreSession` find no server and wipe the
    /// token a previous run left in the Keychain: the onboarding is guaranteed.
    /// `-trustedServers` overrides the persisted approvals for this launch only —
    /// `'()'` approves nothing, whatever a previous run stored.
    private func launchApp(trusting: Bool) {
        reset()
        setProvider("manual")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-authServerURL", "()",
                               "-trustedServers", trusting ? "(\"127.0.0.1\")" : "()"]
        app.launch()
        XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                      "the onboarding did not appear — the scenario would have started from a stale session; "
                        + "\(screenDump())")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement {
        element("assetTile_\(assetId)")
    }

    private func screenDump() -> String {
        let bars = app.progressIndicators.allElementsBoundByIndex
            .map { "[\($0.identifier): \(String(describing: $0.value))]" }
        return "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label)) "
            + "buttons: \(app.buttons.allElementsBoundByIndex.map(\.identifier)) "
            + "bars: \(bars)"
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// A determinate bar's value as a 0...100 percentage, `nil` when it has none.
    private func percentage(_ bar: XCUIElement) -> Double? {
        guard let value = bar.value as? String else { return nil }
        if value.contains("%") {
            return value.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }.last
        }
        guard let fraction = Double(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return fraction <= 1 ? fraction * 100 : fraction
    }

    private func summaryCounts() -> [Int] {
        let label = app.staticTexts.matching(identifier: "downloadInfoSummary").firstMatch.label
        return label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private func settledSummary(_ expected: [Int], timeout: TimeInterval = 15) -> [Int] {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = summaryCounts()
        while seen != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            seen = summaryCounts()
        }
        return seen
    }

    /// The ids of the grid tiles that are really on screen.
    private func visibleTileIds() -> [String] {
        timelineIds.filter { tile($0).exists && tile($0).isHittable }
    }

    /// Visible `offlineBadge`s: a tile whose picture comes from the DISK, not the network.
    private func visibleOfflineBadges() -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: "offlineBadge")
            .allElementsBoundByIndex.filter { $0.isHittable }
    }

    // MARK: - Wire helpers

    private struct LoggedRequest {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: Any]
        let status: Int?
        let contentLength: Int?
        let sent: Int?
        let aborted: Bool

        init(_ json: [String: Any]) {
            method = json["method"] as? String ?? ""
            path = json["path"] as? String ?? ""
            params = (json["params"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            body = json["body"] as? [String: Any] ?? [:]
            status = json["status"] as? Int
            contentLength = json["contentLength"] as? Int
            sent = json["sent"] as? Int
            aborted = json["aborted"] as? Bool ?? false
        }

        /// Served in full: 200, every announced byte written, the client never left.
        var complete: Bool {
            status == 200 && !aborted && contentLength != nil && sent == contentLength
        }
    }

    private func stubRequests() -> [LoggedRequest] {
        guard let reply = controlGET("/__requests"),
              let rows = (try? JSONSerialization.jsonObject(with: reply.body)) as? [[String: Any]] else { return [] }
        return rows.map(LoggedRequest.init)
    }

    /// Polls the journal every 0.5 s until `predicate` holds or `timeout` passes,
    /// and returns the last journal. The status fields are written AFTER the
    /// response, so an entry is polled for, never read once.
    private func waitForRequests(timeout: TimeInterval, _ predicate: ([LoggedRequest]) -> Bool) -> [LoggedRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var journal = stubRequests()
        while !predicate(journal) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            journal = stubRequests()
        }
        return journal
    }

    private func tlsCounters() -> [String: Int] {
        guard let reply = controlGET("/__tls"),
              let counters = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Int] else { return [:] }
        return counters
    }

    private func describe(_ journal: [LoggedRequest]) -> String {
        journal.map {
            "\($0.method) \($0.path) params=\($0.params) status=\(String(describing: $0.status)) "
                + "sent=\(String(describing: $0.sent))/\(String(describing: $0.contentLength))"
                + ($0.aborted ? " ABORTED" : "")
        }.joined(separator: "\n")
    }

    private func thumbnail(_ id: String) -> (LoggedRequest) -> Bool {
        { $0.method == "GET" && $0.path == "/api/assets/\(id)/thumbnail" && $0.complete }
    }

    /// The full-screen image: the viewer's preview, or the original with "Load original".
    private func fullScreen(_ id: String) -> (LoggedRequest) -> Bool {
        {
            $0.method == "GET" && $0.complete
                && (($0.path == "/api/assets/\(id)/thumbnail" && $0.params["size"] == "preview")
                    || $0.path == "/api/assets/\(id)/original")
        }
    }

    private func originals(_ journal: [LoggedRequest]) -> [LoggedRequest] {
        journal.filter { $0.method == "GET" && $0.path == "/api/assets/\(target)/original" && $0.complete }
    }

    // MARK: - Certificate probe (the runner's own session, anchored on the stub's certificate)

    /// A request to the HTTPS port, made by a session that anchors on the
    /// certificate the server presents — the app's own approval rule, replayed
    /// so a test can read the certificate. `status == -1` on a transport failure.
    private func anchoredRequest(_ request: URLRequest) -> (status: Int, body: Data, probe: TrustProbe) {
        let delegate = AnchoringDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = request
        request.timeoutInterval = 10
        let done = DispatchSemaphore(value: 0)
        var status = -1
        var body = Data()
        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse { status = http.statusCode }
            body = data ?? Data()
            if let error { delegate.probe.transportError = "\(error)" }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + 10) != .success { delegate.probe.transportError = "timeout" }
        return (status, body, delegate.probe)
    }

    // MARK: - Scenarios

    func test_AC40_certificateIsSelfSignedAndAcceptedOnlyWhenAnchored() throws {
        reset()
        let reply = anchoredRequest(URLRequest(url: URL(string: "\(apiBase)/api/server/ping")!))
        let probe = reply.probe
        XCTAssertEqual(probe.defaultTrusted, false, "the system trust store accepts the stub's certificate")
        XCTAssertEqual(probe.anchoredTrusted, true,
                       "iOS refuses the certificate even when it is its own anchor — one of SAN IP:127.0.0.1, "
                        + "EKU serverAuth, SHA-2, RSA >= 2048 or validity <= 825 days is missing: "
                        + "\(probe.anchoredError ?? "no error"); transport: \(probe.transportError ?? "none")")
        XCTAssertEqual(probe.chain.count, 1, "the chain is not a single self-signed certificate")
        let leaf = try XCTUnwrap(probe.chain.first, "no certificate presented")

        let key = try XCTUnwrap(SecCertificateCopyKey(leaf), "the certificate has no public key")
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(key) as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeRSA as String)
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits as String] as? Int, 2048)

        let notBefore = try XCTUnwrap(SecCertificateCopyNotValidBeforeDate(leaf) as Date?)
        let notAfter = try XCTUnwrap(SecCertificateCopyNotValidAfterDate(leaf) as Date?)
        XCTAssertLessThanOrEqual(notBefore, Date(), "the certificate is not valid yet")
        XCTAssertGreaterThanOrEqual(notAfter, Date(), "the certificate has expired")
        XCTAssertLessThanOrEqual(notAfter.timeIntervalSince(notBefore), 825 * 86_400,
                                 "validity above the 825 days iOS accepts")

        XCTAssertEqual(reply.status, 200, "ping over the anchored TLS failed: \(probe.transportError ?? "no error")")
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: String], ["res": "pong"])
    }

    func test_AC41_controlPortServesNoAPIAndNothingIsLogged() throws {
        reset()
        let before = stubRequests().count
        XCTAssertEqual(before, 0)
        XCTAssertEqual(controlGET("/api/server/ping")?.status, 404)
        XCTAssertEqual(controlGET("/api/assets/\(target)/thumbnail")?.status, 404)
        var post = URLRequest(url: URL(string: "\(control)/api/oauth/authorize")!)
        post.httpMethod = "POST"
        XCTAssertEqual(send(post)?.status, 404)
        XCTAssertEqual(stubRequests().count, before, "the control port logged an /api request")

        let whoami = try XCTUnwrap(controlGET("/__whoami"), "no answer from /__whoami")
        let identity = try XCTUnwrap((try? JSONSerialization.jsonObject(with: whoami.body)) as? [String: Any])
        XCTAssertEqual(identity["port"] as? Int, port)
        XCTAssertGreaterThan(identity["pid"] as? Int ?? 0, 0)
        XCTAssertEqual(identity["stub"] as? String, "immich_stub_selfsigned.py")
    }

    func test_AC42_authorizeRedirectsToControlPortProvider() throws {
        reset()
        setProvider("manual")
        var request = URLRequest(url: URL(string: "\(apiBase)/api/oauth/authorize")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"redirectUri": "app.immich:///oauth-callback", "state": "s", "codeChallenge": "c"}"#.utf8)
        let reply = anchoredRequest(request)
        XCTAssertEqual(reply.status, 200, "authorize failed: \(reply.probe.transportError ?? "no error")")
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])
        XCTAssertEqual(json["url"] as? String, "\(control)/provider-manual")

        let page = try XCTUnwrap(controlGET("/provider-manual"), "the provider page did not answer")
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("href=\"app.immich:///oauth-callback"), html)
        XCTAssertTrue(html.contains(">Authorize</a>"), html)
    }

    func test_AC44_controlPortProbeAndControlRoutesSucceed() throws {
        XCTAssertTrue(stubIsReachable())
        let resetReply = try XCTUnwrap(controlGET("/__reset"))
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: resetReply.body)) as? [String: Bool], ["reset": true])
        setProvider("manual")
        let requests = try XCTUnwrap(controlGET("/__requests"))
        let rows = (try? JSONSerialization.jsonObject(with: requests.body)) as? [Any]
        XCTAssertEqual(rows?.count, 0)
        XCTAssertEqual(tlsCounters(), ["connections": 0, "handshakesOK": 0, "handshakesFailed": 0])
    }

    func test_AC7_thumbnailsAndViewerLoadFromApprovedSelfSignedServer() throws {
        launchApp(trusting: true)
        signIn()
        XCTAssertTrue(tile(target).waitForExistence(timeout: 30), "no timeline tile; \(screenDump())")

        // A tile or a viewer page with an offline copy is read from the DISK
        // before the network, so a copy left by an earlier run would make the
        // journal below prove nothing. Remove every visible copy, relaunch (which
        // empties the journal), and check none is left.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        if !visibleOfflineBadges().isEmpty {
            for id in timelineIds where tile(id).exists && tile(id).isHittable {
                tile(id).tap()
                let share = app.buttons.matching(identifier: "viewerShareButton").firstMatch
                XCTAssertTrue(share.waitForExistence(timeout: 25), "no viewer for \(id); \(screenDump())")
                share.tap()
                let row = element("offlineAvailableRow")
                if row.waitForExistence(timeout: 3) {
                    app.buttons.matching(identifier: "removeFromOfflineButton").firstMatch.tap()
                    XCTAssertTrue(app.buttons.matching(identifier: "downloadForOfflineButton").firstMatch
                        .waitForExistence(timeout: 15), "the offline copy of \(id) was not removed")
                }
                let close = app.buttons.matching(identifier: "closeShareSheet").firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 15), "no Close on the share sheet")
                close.tap()
                let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
                XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer did not come back")
                back.tap()
            }
            app.terminate()
            launchApp(trusting: true)
            signIn()
            XCTAssertTrue(tile(target).waitForExistence(timeout: 30), "no timeline tile; \(screenDump())")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            if !visibleOfflineBadges().isEmpty {
                XCTFail("offline copy survived purge; \(screenDump())")
            }
        }

        shot("st-ac7-grid")
        let visible = visibleTileIds()
        if visible.isEmpty { XCTFail("no visible tile; \(screenDump())") }

        var journal = waitForRequests(timeout: 20) { journal in
            visible.allSatisfy { id in journal.contains(where: self.thumbnail(id)) }
        }
        for id in visible {
            XCTAssertTrue(journal.contains(where: thumbnail(id)),
                          "no complete GET /api/assets/\(id)/thumbnail reached the stub:\n\(describe(journal))")
        }

        tile(target).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 25),
                      "the viewer did not open; \(screenDump())")
        journal = waitForRequests(timeout: 30) { $0.contains(where: self.fullScreen(self.target)) }
        XCTAssertTrue(journal.contains(where: fullScreen(target)),
                      "no complete full-screen request for \(target) reached the stub:\n\(describe(journal))")
        shot("st-ac7-viewer")
    }

    func test_AC8_offlineAndFilesDownloadsCompleteFromApprovedSelfSignedServer() throws {
        launchApp(trusting: true)
        signIn()
        XCTAssertTrue(tile(target).waitForExistence(timeout: 30), "no timeline tile; \(screenDump())")
        tile(target).tap()
        let share = app.buttons.matching(identifier: "viewerShareButton").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25), "the viewer's bottom bar never appeared; \(screenDump())")
        share.tap()

        // A copy left by an earlier run would answer the button before any request.
        let offlineRow = element("offlineAvailableRow")
        let downloadOffline = app.buttons.matching(identifier: "downloadForOfflineButton").firstMatch
        if offlineRow.waitForExistence(timeout: 3) {
            app.buttons.matching(identifier: "removeFromOfflineButton").firstMatch.tap()
            XCTAssertTrue(downloadOffline.waitForExistence(timeout: 15), "the old offline copy was not removed")
        }

        XCTAssertTrue(downloadOffline.waitForExistence(timeout: 15), "no 'Download for offline'; \(screenDump())")
        downloadOffline.tap()
        XCTAssertTrue(offlineRow.waitForExistence(timeout: 60),
                      "the offline copy never became available; \(screenDump())")
        var journal = waitForRequests(timeout: 15) { !self.originals($0).isEmpty }
        let offlineCount = originals(journal).count
        XCTAssertGreaterThanOrEqual(offlineCount, 1,
                                    "the offline copy never fetched the original:\n\(describe(journal))")
        shot("st-ac8-offline")

        let downloadToFiles = app.buttons.matching(identifier: "downloadToFilesButton").firstMatch
        XCTAssertTrue(downloadToFiles.waitForExistence(timeout: 25), "no 'Download to Files'; \(screenDump())")
        downloadToFiles.tap()
        let close = app.buttons.matching(identifier: "closeShareSheet").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15), "no Close on the share sheet")
        close.tap()
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer did not come back")
        back.tap()

        let panel = element("downloadPanel")
        XCTAssertTrue(panel.waitForExistence(timeout: 25), "the download panel never appeared; \(screenDump())")
        panel.tap()
        let row = element("downloadInfoRow_\(target)")
        XCTAssertTrue(row.waitForExistence(timeout: 25), "the info screen does not list the asset; \(screenDump())")
        let bar = app.progressIndicators.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the running row draws no progress bar; \(screenDump())")

        // The stub streams the original over ~16 s: an intermediate value is observable.
        var seen: Double?
        let deadline = Date().addingTimeInterval(30)
        while seen == nil && Date() < deadline {
            if let value = percentage(bar), value > 0, value < 100 { seen = value }
            else { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        }
        XCTAssertNotNil(seen, "no intermediate progress (0 < p < 100) was ever read; \(screenDump())")
        shot("st-ac8-progress")

        let cancel = app.buttons.matching(identifier: "downloadInfoCancel_\(target)").firstMatch
        let retry = app.buttons.matching(identifier: "downloadInfoRetry_\(target)").firstMatch
        XCTAssertTrue(waitForDisappearance(cancel, timeout: 90),
                      "the transfer never left 'running'; \(screenDump())")
        XCTAssertTrue(row.exists, "the completed row vanished; \(screenDump())")
        XCTAssertFalse(retry.exists, "the row offers a Retry: the download did not complete; \(screenDump())")
        XCTAssertEqual(settledSummary([1, 1]), [1, 1], "the summary does not read '1 of 1'; \(screenDump())")
        let clearCompleted = app.buttons.matching(identifier: "downloadInfoClearCompleted").firstMatch
        XCTAssertTrue(clearCompleted.isEnabled, "'Clear completed' is disabled; \(screenDump())")

        journal = waitForRequests(timeout: 15) { self.originals($0).count >= offlineCount + 1 }
        XCTAssertGreaterThanOrEqual(originals(journal).count, offlineCount + 1,
                                    "the Files download never fetched its own original:\n\(describe(journal))")
        XCTAssertFalse(journal.contains { $0.aborted }, "a request was cut mid-body:\n\(describe(journal))")

        clearCompleted.tap()
        XCTAssertTrue(waitForDisappearance(row, timeout: 15), "'Clear completed' left the row; \(screenDump())")
        app.buttons.matching(identifier: "downloadInfoDone").firstMatch.tap()

        // Courtesy to the other scenarios: leave no offline copy behind.
        tile(target).tap()
        XCTAssertTrue(share.waitForExistence(timeout: 25), "no viewer for the cleanup; \(screenDump())")
        share.tap()
        let remove = app.buttons.matching(identifier: "removeFromOfflineButton").firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "no 'Remove from offline' for the cleanup")
        remove.tap()
        XCTAssertTrue(downloadOffline.waitForExistence(timeout: 15), "the offline copy was not removed")
        XCTAssertTrue(close.waitForExistence(timeout: 15), "no Close on the share sheet")
        close.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer did not come back")
        back.tap()
    }

    func test_AC45_untrustedSelfSignedServerIsRefusedAtTheHandshake() throws {
        launchApp(trusting: false)
        enterServerURL()

        let refusal = app.descendants(matching: .any)
            .matching(labelPredicate(["Try Again", "Réessayer", "Server unreachable", "Serveur injoignable"]))
            .firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30),
                      "the app never reported the refused server; \(screenDump())")
        shot("st-ac45-refused")

        // As long as the trusted walk waits for the "Continue" that signals a reachable server.
        XCTAssertFalse(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "the app went past the server check without approval")
        XCTAssertFalse(waitForStaticText(["Sign in to Immich", "Connectez-vous à Immich"], timeout: 1),
                       "the login screen appeared without approval")
        XCTAssertFalse(app.tabBars.buttons["Photos"].exists, "the app reached the grid without approval")

        let deadline = Date().addingTimeInterval(10)
        var counters = tlsCounters()
        while (counters["handshakesFailed"] ?? 0) < 1 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            counters = tlsCounters()
        }
        XCTAssertGreaterThanOrEqual(counters["connections"] ?? 0, 1,
                                    "the app never connected to the HTTPS port (dead listener?): \(counters)")
        XCTAssertGreaterThanOrEqual(counters["handshakesFailed"] ?? 0, 1, "no handshake was refused: \(counters)")
        XCTAssertEqual(counters["handshakesOK"], 0, "a handshake succeeded without approval: \(counters)")
        let apiCalls = stubRequests().filter { $0.path.hasPrefix("/api/") }
        XCTAssertTrue(apiCalls.isEmpty, "an API request reached the stub without approval:\n\(describe(apiCalls))")
    }
}

// MARK: - Certificate probe types

/// What the anchoring delegate saw. Filled on the session's queue and read after
/// the request's semaphore — never concurrently.
private final class TrustProbe: @unchecked Sendable {
    var defaultTrusted: Bool?
    var anchoredTrusted: Bool?
    var anchoredError: String?
    var transportError: String?
    var chain: [SecCertificate] = []
}

/// The app's approval rule, replayed: refuse by default, then anchor on the
/// certificate presented and evaluate again for `127.0.0.1`.
private final class AnchoringDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let probe = TrustProbe()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        probe.defaultTrusted = SecTrustEvaluateWithError(trust, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        probe.chain = chain
        guard let leaf = chain.first else {
            probe.anchoredTrusted = false
            probe.anchoredError = "the server presented no certificate"
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        _ = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "127.0.0.1" as CFString))
        _ = SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        _ = SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        probe.anchoredTrusted = trusted
        probe.anchoredError = error.map { "\($0)" }
        if trusted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
