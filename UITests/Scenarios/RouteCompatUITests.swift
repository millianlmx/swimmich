import XCTest

/// Routes by server version (L-20, B-24): merging people, reading the server
/// configuration and running admin jobs use the replacement route of a
/// deprecated one only on a server that serves it — and never a route that
/// server does not have.
///
/// Against `immich_stub_route_compat.py`, which announces a version chosen at run
/// time (`/stub/version?v=X.Y.Z[&host=…]`) on top of `immich_stub_base.py`'s
/// route table: a route the announced version lacks answers 404 AND stays in
/// `/__requests`. Every scenario therefore reads the journal and fails on any
/// request for a route its version does not serve (`unservedRoutes`), then checks
/// the route that did serve.
///
/// An administrator signs in by SSO; the people are Ada, Ben and Cleo (ids
/// recopied below). Everything is addressed by `accessibilityIdentifier`.
///
/// NOT PROVEN here (the unit suite and the stub's Python tests carry them): the
/// "Domain" and "Initialized" rows of the server card, which have no identifier.
/// The scenarios are COMPILED by the CI, not run (no simulator there).
///
///     python3 -u UITests/stubs/immich_stub_route_compat.py 8421 &
///     TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test-without-building \
///         -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,id=<UDID>' \
///         -only-testing:ImmichSwiftUIUITests/RouteCompatUITests
final class RouteCompatUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The fixture of `immich_stub_route_compat.py`: keep the two in step.
    private let ada = "cccccccc-4444-4444-8444-000000000001"
    private let ben = "cccccccc-4444-4444-8444-000000000002"
    private let cleo = "cccccccc-4444-4444-8444-000000000003"
    private let queue = "thumbnailGeneration"
    private let publicDomain = "photos.public.example"

    private static let welcome = ["Your photo library", "Votre photothèque"]
    /// A fresh launch wipes any session left behind (restore finds no server).
    private let freshLaunch = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-authServerURL", "()"]
    /// A relaunch that keeps the stored session.
    private let relaunch = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        guard stubIsReachable() else { return }
        app.terminate()
        app.launchArguments = freshLaunch
        app.launch()
        app.terminate()
    }

    // MARK: - AC-36

    /// Against each threshold: the people merge, the configuration before and
    /// after sign-in and the admin jobs all succeed with no error on screen, and
    /// the journal holds no route this version does not serve.
    func test_AC_36() throws {
        for version in ["2.0.0", "3.1.0", "3.2.0", "3.4.0"] {
            try begin(version: version)
            try signIn()
            mergeAdaAndBenIntoCleo()
            openAdministration()
            XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20), "no jobs at \(version)")
            XCTAssertFalse(element("adminRefreshError").exists, "Administration shows an error at \(version)")
            XCTAssertFalse(element("peopleRefreshError").exists)

            let journal = requests()
            XCTAssertEqual(unservedRoutes(journal, version: version), [],
                           "a route this server does not serve was requested at \(version)")
        }
    }

    // MARK: - AC-174

    func test_AC_174() throws {
        try begin(version: "3.4.0")
        try signIn()
        let mark = requests().count
        mergeAdaAndBenIntoCleo()

        let merges = requests().dropFirst(mark).filter { $0.method == "POST" && $0.path.hasSuffix("merge") }
        XCTAssertFalse(merges.isEmpty, "no merge reached the stub")
        XCTAssertTrue(merges.allSatisfy { $0.path == "/api/people/merge" }, "a legacy merge route was used")
        XCTAssertTrue(merges.allSatisfy { $0.body?.ids?.first == cleo }, "the target is not first in `ids`")
        XCTAssertEqual(Set(merges.flatMap { ($0.body?.ids ?? []).dropFirst() }), [ada, ben])
        XCTAssertFalse(element("personRow_\(ada)").exists || element("personRow_\(ben)").exists, "a merged person is still listed")

        try begin(version: "3.2.0")
        try signIn()
        let legacyMark = requests().count
        mergeAdaAndBenIntoCleo()
        let legacy = requests().dropFirst(legacyMark).filter { $0.method == "POST" && $0.path.hasSuffix("merge") }
        XCTAssertFalse(legacy.isEmpty)
        XCTAssertTrue(legacy.allSatisfy { $0.path == "/api/people/\(cleo)/merge" })
        XCTAssertEqual(Set(legacy.flatMap { $0.body?.ids ?? [] }), [ada, ben])
    }

    // MARK: - AC-175

    func test_AC_175() throws {
        for version in ["3.2.0", "3.4.0", "2.0.0", "3.1.0"] {
            try begin(version: version)
            let modern = version == "3.2.0" || version == "3.4.0"
            try walkToLogin()
            var paths = requests().map(\.path)
            XCTAssertEqual(paths.contains("/api/public/config"), modern, "server step at \(version)")
            XCTAssertEqual(paths.contains("/api/server/config"), !modern, "server step at \(version)")

            try completeSSOSignIn()
            paths = requests().map(\.path)
            XCTAssertEqual(paths.contains("/api/config"), modern, "after sign-in at \(version)")
            XCTAssertEqual(paths.contains("/api/server/config"), !modern)
            XCTAssertFalse(paths.contains("/api/public/config") && !modern)

            openSharedLinks()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", publicDomain))
                .firstMatch.waitForExistence(timeout: 20), "the link's public URL lost the external domain at \(version)")
        }
    }

    // MARK: - AC-176

    func test_AC_176() throws {
        // A session on 3.1.0, relaunched against 3.4.0 without going through the server step.
        try begin(version: "3.1.0")
        try signIn()
        app.terminate()
        stubGet("/stub/version?v=3.4.0")
        let mark = requests().count
        launch(arguments: relaunch)
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40))
        mergeAdaAndBenIntoCleo()
        openAdministration()
        XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20))

        let after = Array(requests().dropFirst(mark))
        let paths = after.map(\.path)
        XCTAssertTrue(paths.contains("/api/config"), "the configuration was not read by /api/config")
        XCTAssertTrue(paths.contains("/api/people/merge"))
        XCTAssertTrue(paths.contains("/api/queues"))
        XCTAssertFalse(paths.contains("/api/server/config") || paths.contains("/api/jobs"), "a replaced route was called")

        // The other way round: a 3.4.0 session relaunched against 2.0.0.
        app.terminate()
        stubGet("/stub/version?v=2.0.0")
        let legacyMark = requests().count
        launch(arguments: relaunch)
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40))
        openAdministration()
        XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20))
        let legacyPaths = requests().dropFirst(legacyMark).map(\.path)
        XCTAssertTrue(legacyPaths.contains("/api/server/config"))
        XCTAssertEqual(unservedRoutes(Array(requests().dropFirst(legacyMark)), version: "2.0.0"), [])
        XCTAssertFalse(element("adminRefreshError").exists)
    }

    // MARK: - AC-177

    func test_AC_177() throws {
        for version in ["3.1.0", "3.4.0", "2.0.0"] {
            try begin(version: version)
            try signIn()
            openAdministration()
            XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20))
            let queues = version != "2.0.0"
            let paths = requests().map(\.path)
            XCTAssertEqual(paths.contains("/api/queues"), queues, "list at \(version)")
            XCTAssertEqual(paths.contains("/api/jobs"), !queues, "list at \(version)")

            let mark = requests().count
            for command in ["pause", "resume", "empty", "start", "clear-failed"] {
                runJob(command)
            }
            let sent = requests().dropFirst(mark).filter { $0.method != "GET" }
            let routes = sent.map { "\($0.method) \($0.path)" }
            let expected = queues
                ? ["PUT /api/queues/\(queue)", "PUT /api/queues/\(queue)", "DELETE /api/queues/\(queue)/jobs",
                   "PUT /api/jobs/\(queue)", "PUT /api/jobs/\(queue)"]
                : Array(repeating: "PUT /api/jobs/\(queue)", count: 5)
            XCTAssertEqual(routes, expected, "commands at \(version)")
            if queues {
                XCTAssertEqual(sent.first?.body?.isPaused, true)
                XCTAssertNil(sent.dropFirst(2).first?.body?.failed, "Empty must not clear the failed jobs")
                XCTAssertEqual(sent.last?.body?.command, "clear-failed")
            }
            XCTAssertFalse(element("adminRefreshError").exists, "a command failed at \(version)")
        }
    }

    // MARK: - AC-178

    func test_AC_178() throws {
        for broken in ["broken", "garbage"] {
            try begin(version: broken)
            try signIn()
            mergeAdaAndBenIntoCleo()
            openAdministration()
            XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20), "no jobs with a \(broken) version")
            runJob("pause")

            let journal = requests()
            let paths = journal.map(\.path)
            XCTAssertFalse(paths.contains("/api/people/merge") || paths.contains("/api/queues")
                           || paths.contains("/api/public/config") || paths.contains("/api/config"),
                           "a replacement route was used with a \(broken) version")
            XCTAssertTrue(paths.contains("/api/server/config") && paths.contains("/api/jobs"))
            XCTAssertTrue(journal.contains { $0.method == "PUT" && $0.path == "/api/jobs/\(queue)" })
            XCTAssertFalse(element("adminRefreshError").exists)
            XCTAssertFalse(element("peopleRefreshError").exists)
        }
    }

    // MARK: - AC-179

    func test_AC_179() throws {
        for version in ["2.0.0", "3.4.0"] {
            try begin(version: version)
            try signIn()
            setReadOnly(true)
            let mark = requests().count

            mergeAdaAndBenIntoCleo()
            openAdministration()
            XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20),
                          "the job list is a read: it must stay available")
            runJob("pause")

            // A search is a read sent as a POST: the mode lets it through.
            let writes = requests().dropFirst(mark).filter { $0.method != "GET" && !$0.path.hasPrefix("/api/search/") }
            XCTAssertEqual(writes.map { "\($0.method) \($0.path)" }, [], "a write left the app in read-only mode at \(version)")
            XCTAssertTrue(requests().dropFirst(mark).contains { $0.path == (version == "2.0.0" ? "/api/jobs" : "/api/queues") })
        }
    }

    // MARK: - AC-180

    /// A on 127.0.0.1 (3.4.0), B (administrator) on localhost (2.0.0): B only ever
    /// gets legacy routes, its configuration is read again, A gets the
    /// replacements back.
    func test_AC_180() throws {
        try begin(version: "3.4.0")
        stubGet("/stub/version?v=2.0.0&host=localhost")
        try signInWithSSO()
        try addAccount(url: "http://localhost:\(port)")
        // Both accounts exist now: the switch itself is what the scenario watches.
        switchToAccount(containing: "127.0.0.1")
        stubGet("/stub/people")

        let mark = requests().count
        switchToAccount(containing: "localhost")
        mergeAdaAndBenIntoCleo()
        openAdministration()
        XCTAssertTrue(element("adminJob_\(queue)").waitForExistence(timeout: 20))
        runJob("pause")

        let sent = Array(requests().dropFirst(mark))
        let paths = sent.map(\.path)
        XCTAssertTrue(paths.contains("/api/server/version"), "B's version was not read")
        XCTAssertTrue(paths.contains("/api/server/config"), "B's configuration was not read")
        XCTAssertEqual(unservedRoutes(sent, version: "2.0.0"), [], "a replacement route reached B")
        XCTAssertFalse(paths.contains("/api/config"), "B was asked for A's configuration route")
        XCTAssertFalse(element("adminRefreshError").exists)

        stubGet("/stub/people")
        switchToAccount(containing: "127.0.0.1")
        let back = requests().count
        mergeAdaAndBenIntoCleo()
        XCTAssertTrue(requests().dropFirst(back).contains { $0.path == "/api/people/merge" },
                      "A did not get its replacement routes back")
    }

    // MARK: - Scenario steps

    private var port: String { URL(string: stub)?.port.map(String.init) ?? "8421" }

    /// Resets the stub, fixes the version it announces and starts the app on a clean slate.
    private func begin(version: String) throws {
        if app.state != .notRunning { app.terminate() }
        stubGet("/__reset")
        XCTAssertEqual(stubGet("/__provider?mode=manual"), "{\"provider\": \"manual\"}")
        XCTAssertTrue(stubGet("/stub/version?v=\(version)").contains(version), "the stub rejected version \(version)")
        launch(arguments: freshLaunch)
    }

    private func launch(arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    /// Signed in with the stub's session from the launch arguments
    /// (`-uiTestSessionToken`): these scenarios watch the routes of the signed-in
    /// app, not the sign-in, which AC-175 and AC-180 walk for real
    /// (`signInWithSSO`). The SSO sheet (`SafariViewService`) is what failed most
    /// on a loaded Mac.
    private func signIn() throws {
        app.terminate()
        launch(arguments: relaunch + sessionArguments())
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "the app did not start signed in")
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40),
                      "the timeline never rendered")
        dismissWhatsNewIfPresent()
    }

    private func signInWithSSO() throws {
        try walkToLogin()
        try completeSSOSignIn()
    }

    /// The session the stub's SSO sign-in hands out (`POST /api/oauth/callback`),
    /// as the launch arguments of `AuthViewModel`'s keys.
    private func sessionArguments() -> [String] {
        var request = URLRequest(url: URL(string: "\(stub)/api/oauth/callback")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var login: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, _ in
            login = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        guard let token = login["accessToken"] as? String else {
            XCTFail("the stub's /api/oauth/callback gave no session: \(login)")
            return []
        }
        return [
            "-uiTestSessionToken", token,
            "-authServerURL", stub,
            "-authUserId", login["userId"] as? String ?? "",
            "-authUserName", login["name"] as? String ?? "",
            "-authUserEmail", login["userEmail"] as? String ?? "",
            "-authIsAdmin", (login["isAdmin"] as? Bool ?? false) ? "YES" : "NO",
        ]
    }

    private func walkToLogin() throws {
        XCTAssertTrue(app.staticTexts.matching(labelPredicate(Self.welcome)).firstMatch.waitForExistence(timeout: 30),
                      "the onboarding did not appear")
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        enterServerURL(stub)
    }

    /// Types the address, checks it, and continues to the login screen.
    private func enterServerURL(_ url: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != url {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != url { field.typeText(url) }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        for _ in 0..<3 {
            app.swipeUp()
            _ = tapAnyButton(["Continue", "Continuer"], timeout: 10)
            if app.staticTexts.matching(labelPredicate(["Sign in to Immich", "Connectez-vous à Immich"]))
                .firstMatch.waitForExistence(timeout: 10) { break }
        }
    }

    private func completeSSOSignIn() throws {
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on the login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell")
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40),
                      "the timeline never rendered")
        dismissWhatsNewIfPresent()
    }

    private func dismissWhatsNewIfPresent() {
        let done = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        guard done.waitForExistence(timeout: 5) else { return }
        done.tap()
    }

    /// Albums tab → People → Cleo → merge Ada, then Ben, into her.
    private func mergeAdaAndBenIntoCleo() {
        app.tabBars.buttons.matching(labelPredicate(["Albums", "Alben"])).firstMatch.tap()
        XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 20), "the Albums library never appeared")
        let row = app.buttons.matching(identifier: "peopleRow").firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(element("personRow_\(cleo)").waitForExistence(timeout: 30), "the people list never rendered")
        element("personRow_\(cleo)").tap()
        for other in [ada, ben] {
            XCTAssertTrue(element("personMergeMenu").waitForExistence(timeout: 20), "no merge menu on Cleo's card")
            element("personMergeMenu").tap()
            let item = element("personMerge_\(other)")
            XCTAssertTrue(item.waitForExistence(timeout: 10), "\(other) is not offered for a merge")
            item.tap()
            XCTAssertTrue(waitUntil(timeout: 20) { !self.element("personMerge_\(other)").exists },
                          "\(other) is still offered after the merge")
        }
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
    }

    /// The Me sheet, from the Photos tab: the merge leaves the Albums tab on a
    /// pushed screen (People), whose bar has no avatar.
    private func openProfile() {
        dismissWhatsNewIfPresent()
        // Still open from the previous step, on a pushed page (Administration):
        // back to the hub's root.
        let back = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        for _ in 0..<3 where !element("profileList").exists && back.exists { back.tap() }
        if element("profileList").waitForExistence(timeout: 2) { return }
        app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch.tap()
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Profile avatar missing")
        avatar.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20), "the Me hub never opened")
    }

    private func openAdministration() {
        openProfile()
        reveal("adminRow")
        element("adminRow").tap()
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.element("adminInstancePhotos").exists || self.element("adminInstanceStatsError").exists
        }, "Administration never showed its instance statistics")
    }

    private func setReadOnly(_ enabled: Bool) {
        openProfile()
        reveal("readOnlyModeToggle")
        let toggle = element("readOnlyModeToggle")
        let wanted = enabled ? "1" : "0"
        // A tap on the row's label does not flip the switch: its right end does
        // (or, at large text sizes, its lower left), checked on the value.
        for point in [CGVector(dx: 0.92, dy: 0.5), CGVector(dx: 0.13, dy: 0.85), CGVector(dx: 0.5, dy: 0.5)]
        where toggle.value as? String != wanted {
            toggle.coordinate(withNormalizedOffset: point).tap()
            _ = waitUntil(timeout: 3) { toggle.value as? String == wanted }
        }
        XCTAssertEqual(toggle.value as? String, wanted, "the read-only switch did not turn \(enabled ? "on" : "off")")
        dismissMeSheet()
    }

    /// The Me sheet, dragged down from its bar: a swipe on the scrolled list only
    /// scrolled it back, and the sheet stayed over the tab bar.
    private func dismissMeSheet() {
        let albums = app.tabBars.buttons.matching(labelPredicate(["Albums", "Alben"])).firstMatch
        for attempt in 0..<3 where !(albums.exists && albums.isHittable) {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            _ = waitUntil(timeout: 6) { albums.exists && albums.isHittable }
        }
        XCTAssertTrue(albums.exists && albums.isHittable, "the Me sheet never dismissed")
    }

    /// Long-presses the queue's row and taps the command in its context menu.
    private func runJob(_ command: String) {
        let row = element("adminJob_\(queue)")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no job row")
        row.press(forDuration: 1.2)
        let item = element("adminJobCommand_\(command)")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(command) command in the job menu")
        item.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func openSharedLinks() {
        app.tabBars.buttons.matching(labelPredicate(["Shared", "Partagé", "Geteilt"])).firstMatch.tap()
    }

    private func addAccount(url: String) throws {
        openProfile()
        reveal("addAccountButton")
        element("addAccountButton").tap()
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30))
        enterServerURL(url)
        try completeSSOSignIn()
    }

    private func switchToAccount(containing text: String) {
        openProfile()
        reveal("addAccountButton")
        // The row shows the account's name; its identifier carries the server's
        // address (`savedAccountRow_<url>|<email>`).
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'savedAccountRow_' AND identifier CONTAINS %@", text)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no saved account on \(text)")
        row.tap()
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40))
    }

    // MARK: - Reading the journal

    /// The routes a server of `version` does not have, among what the app asked.
    private func unservedRoutes(_ journal: [StubRequest], version: String) -> [String] {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let v = parts.count == 3 ? (parts[0], parts[1], parts[2]) : nil
        func atLeast(_ minimum: (Int, Int, Int)) -> Bool { v.map { $0 >= minimum } ?? false }
        return journal.compactMap { request -> String? in
            let route = "\(request.method) \(request.path)"
            let unserved =
                (request.path == "/api/queues" || request.path.hasPrefix("/api/queues/")) && !atLeast((2, 4, 0))
                || (request.path == "/api/public/config" || request.path == "/api/config") && !atLeast((3, 2, 0))
                || (request.method == "POST" && request.path == "/api/people/merge") && !atLeast((3, 2, 1))
            return unserved ? route : nil
        }
    }

    private struct StubRequest: Decodable {
        struct Body: Decodable {
            let ids: [String]?
            let command: String?
            let isPaused: Bool?
            let failed: Bool?
        }
        let method: String
        let path: String
        let body: Body?
    }

    private func requests() -> [StubRequest] {
        (try? JSONDecoder().decode([StubRequest].self, from: Data(stubGet("/__requests").utf8))) ?? []
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls the Me hub down to `identifier`. Never back up: a swipe down on
    /// the hub at its top dismisses the sheet, which then hid every row.
    private func reveal(_ identifier: String) {
        let target = element(identifier)
        for _ in 0..<14 where !(target.exists && target.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
        }
    }

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "), argumentArray: labels)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
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
    }

    /// The provider page loads in another process (`SafariViewService`), slowly on a
    /// loaded Mac, and the system's sign-in consent can show late: while the
    /// "Authorize" link is awaited, the consent is accepted whenever it is up.
    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 60) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        let consent = NSPredicate(format: "label IN %@", ["Continue", "Continuer"])
        let candidates = [safari.links.matching(predicate).firstMatch, safari.buttons.matching(predicate).firstMatch]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let authorize = candidates.first(where: { $0.exists }) {
                authorize.tap()
                return true
            }
            for button in [springboard.alerts.buttons.matching(consent).firstMatch,
                           app.alerts.buttons.matching(consent).firstMatch] where button.exists {
                button.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // MARK: - The stub

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

    @discardableResult
    private func stubGet(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer \(path)")
        return body
    }
}
