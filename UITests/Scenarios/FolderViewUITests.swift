import XCTest

/// End-to-end scenario for the folder view (gap G11) — the directory tree the
/// server sees on its disk, one level per push, reached from the Library
/// section of the Albums tab.
///
/// It drives the real app (onboarding → SSO → the hub → Folders → two levels)
/// and asserts on the WIRE what each level asked for, which is the point of the
/// feature: `GET /api/view/folder?path=` answers the DIRECT children of the
/// folder it is handed, so a screen that sent the first path of the tree for
/// every row would look perfectly healthy while showing the wrong folder. The
/// stub gives each folder its own asset ids (`dddd…` for `/Photos`, `eeee…` for
/// `/Videos`) so the grid itself also says which folder answered, and it keeps
/// `/Videos/2026` empty so "there is no folder at all" and "this folder is
/// empty" are two visibly different screens: the second one still prints its
/// path bar.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/folder-view.uitest.log \
///         UITests/stubs/immich_stub_folder_view.py FolderViewUITests/test_folderView
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// ordinary timeline, real PNG thumbnails, `/__requests`, `/__reset`) and adds
/// the two folder routes plus `/control/tree`; see its docstring.
final class FolderViewUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The asset the stub gives `/Videos/2026`… nothing: that folder is the
    /// empty one. These two are the first asset of each root.
    private let firstPhoto = "dddddddd-1111-4111-8111-000000000001"
    private let firstClip = "eeeeeeee-1111-4111-8111-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip-vs-run only, so a full-scheme run without a stub stays green.
        // `uitest.sh` starts the stub first and treats a skip as a failure, so
        // this never masks anything under the launcher.
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
    // Copied from `ImmichRenderScreenshots` / `RecentlyTakenUITests` on purpose:
    // these are `private` there, and the shared file is frozen. The harness rule
    // is one file per feature, helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log, so
    /// no assertion below can be satisfied by a previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks, like `test_01` of the shared class.
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

    /// Empties (`empty`) or refills (`full`) the library the stub reports on
    /// `unique-paths`. The folder view caches the tree for the life of its
    /// ViewModel, so the empty library is only observable in a NEW launch — the
    /// scenario relaunches the app for it.
    private func setTree(_ mode: String) {
        let url = URL(string: "\(stub)/control/tree?mode=\(mode)")!
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "the stub did not answer /control/tree")
        XCTAssertEqual(body, "{\"tree\": \"\(mode)\"}", "the stub did not switch its tree to \(mode)")
    }

    /// Waits for any button whose label contains `text` and taps it. Case
    /// sensitive on purpose: the keyboard's return key is labelled "continuer"
    /// in lowercase and would shadow the "Continuer" CTA.
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

    /// The onboarding copy is localized (issue #21), and the repo's own
    /// simulator is in German while the runs use English slots: a walk accepts
    /// both, never one hard-coded language.
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

    /// The provider page lives in `SafariViewService`, a separate process, so
    /// its "Authorize" link is not in the app's own accessibility tree.
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
        // The field can hold the PREVIOUS run's URL — a warm slot seeds it — and
        // `typeText` APPENDS. With a random stub port per run that value is
        // always stale, so it is cleared before typing rather than trusted.
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
        // Typing the URL raised the keyboard, and the CTA sits under it: a tap
        // computed from the button's frame then lands on the keyboard and the
        // flow never leaves this screen (measured — it cost one run in two).
        // Scrolling dismisses the keyboard (`.scrollDismissesKeyboard(.immediately)`),
        // so the CTA is really hittable when it is tapped, and a bounded retry
        // covers the frame the keyboard was still animating over.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("\(phase)-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// The screenshot prefix of the launch currently being driven: this
    /// scenario launches the app twice (the folder view caches its tree for the
    /// life of its ViewModel), and two launches sharing a shot name would
    /// overwrite each other's evidence.
    private var phase = "fv"

    /// Onboarding → OAuth → the authenticated shell. A session persisted by the
    /// first launch skips the walk instead of failing, so the relaunch below
    /// works whether or not the app keeps its Keychain session.
    private func enterShell(_ phase: String) {
        self.phase = phase
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("\(phase)-welcome")
            walkOnboardingToLogin()
            shot("\(phase)-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the hub would never open under it. Its Done
        // button carries an identifier because its label is translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("\(phase)-whats-new")
            whatsNewDone.tap()
        }
    }

    /// A tile of the Albums tab's Library section, by IDENTIFIER (its label is
    /// localized: "Folders" / "Dossiers" / "Ordner"). The Albums ScrollView is
    /// scrolled only when the tile is not hittable.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        _ = row.waitForExistence(timeout: 10)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// The shell → the Albums tab → its Folders tile. Leaves the app on the folder
    /// screen; what that screen shows is the caller's business (the caller
    /// waits for its own evidence).
    private func openFolders() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "Albums tab missing")
        albums.tap()

        let row = libraryRow("foldersRow")
        if !row.waitForExistence(timeout: 10) {
            shot("\(phase)b-albums-without-folders-row")
            XCTFail("Folders tile missing in the Albums library:\n\(app.debugDescription)")
        }
        shot("\(phase)a-albums-library")
        row.tap()
    }

    // MARK: - Screen helpers

    /// One grid tile, by the identity the grid gives it — the same identifier
    /// the timeline uses, so a folder's grid is asserted exactly like any other.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// One folder line of a level. The identifier carries the ABSOLUTE path, so
    /// `/Videos` and `/Videos/2026` are two different rows and a level can be
    /// asked about its own children.
    private func folderRow(_ path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "folderRow_\(path)").firstMatch
    }

    /// Taps one folder line. The identifier sits on the `NavigationLink`, so the
    /// element is a button; the `any` query is the fallback for the shape a
    /// half-settled list publishes.
    private func openFolderRow(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons.matching(identifier: "folderRow_\(path)").firstMatch
        if button.waitForExistence(timeout: 15) {
            button.tap()
        } else {
            let any = folderRow(path)
            XCTAssertTrue(any.waitForExistence(timeout: 10),
                          "no row for \(path) — \(screenReport())", file: file, line: line)
            any.tap()
        }
    }

    private var folderRowQuery: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'folderRow_'"))
    }

    private func folderRowIdentifiers() -> [String] {
        folderRowQuery.allElementsBoundByIndex.map(\.identifier)
    }

    /// The monospace path bar. It is hidden at the TOP level — no folder, no
    /// path — and that absence is what tells a library without any folder apart
    /// from a folder that holds nothing.
    private var pathBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "folderPathBar").firstMatch
    }

    /// Every tile currently on screen whose asset id carries `prefix` (empty =
    /// all of them): the evidence a failure message needs, and the way "the
    /// OTHER folder's assets are here" is asserted.
    private func tileIds(prefix: String = "") -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assetTile_\(prefix)"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    /// What the screen actually reads, for a failure message. A folder scenario
    /// fails either because the level was not pushed at all or because it was
    /// pushed and drew something else, and only these lists tell them apart —
    /// the wire below says whether a folder request ever went out.
    private func screenReport() -> String {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        return "nav bars \(app.navigationBars.allElementsBoundByIndex.map(\.identifier)); "
            + "back button \(back.exists ? back.label : "<none>"); "
            + "folder rows \(folderRowIdentifiers()); "
            + "path bar \(pathBar.exists ? pathBar.label : "<none>"); "
            + "tiles \(tileIds()); "
            + "buttons \(app.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }); "
            + "asked \(askedFolders()); "
            + "tree reads \(treeReads()); "
            + "texts \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    /// The empty state. A `ContentUnavailableView` does not reliably keep an
    /// identifier placed on the container (measured on `offlineEmptyState`), so
    /// it is matched by identifier OR by its title — the two languages of the
    /// slots and of the repo's own simulator.
    private func waitForEmptyState(timeout: TimeInterval) -> Bool {
        let identified = app.descendants(matching: .any).matching(identifier: "foldersEmptyState").firstMatch
        if identified.waitForExistence(timeout: timeout) { return true }
        return app.staticTexts.matching(labelPredicate(["Empty folder", "Dossier vide", "Leerer Ordner"]))
            .firstMatch.waitForExistence(timeout: 5)
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query
    /// string, so `path` is the folder the level actually asked the server for.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
    }

    private func stubRequests() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    /// The `path` of every `/api/view/folder` the app sent, in order — the one
    /// route the whole feature hangs on. The listing route
    /// (`/api/view/folder/unique-paths`) is a different path and never lands here.
    private func askedFolders() -> [String] {
        stubRequests().filter { $0.path == "/api/view/folder" }
            .map { $0.params["path"] ?? "<no path parameter>" }
    }

    private func treeReads() -> Int {
        stubRequests().filter { $0.path == "/api/view/folder/unique-paths" }.count
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    // MARK: - Scenario

    func test_folderView() throws {
        reset()
        setProvider("manual")
        app.launch()
        enterShell("fv01")

        // MARK: Top level — the two roots of the tree

        openFolders()
        XCTAssertTrue(folderRow("/Photos").waitForExistence(timeout: 25),
                      "the first root of unique-paths is not on the top level — rows: \(folderRowIdentifiers())")
        XCTAssertTrue(folderRow("/Videos").exists,
                      "the SECOND root of unique-paths is missing — a level that only ever shows "
                      + "the first path would pass — rows: \(folderRowIdentifiers())")
        XCTAssertFalse(pathBar.exists, "the top level prints no folder path, so no path bar may show")
        shot("fv03-top-level-two-roots")

        // A level that lists folders reads NO folder: `path` empty would be the
        // disk root, which is not what the row the user tapped means.
        XCTAssertEqual(askedFolders(), [],
                       "the top level read a folder before one was opened — asked: \(askedFolders())")
        let treeReadsAtTopLevel = treeReads()
        XCTAssertGreaterThanOrEqual(treeReadsAtTopLevel, 1,
                                    "the screen never read unique-paths — \(screenReport())")

        // MARK: Descending asks for the row's OWN path, not the first of the list

        // The row's own state, and the screen either side of the tap, are kept
        // for the failure message: a row that renders but cannot be activated —
        // a link whose destination cannot be resolved "typically appears as
        // disabled" (Apple) — and a level that loads but never comes on screen
        // look identical from the assertions below.
        let rowIsEnabled = folderRow("/Videos").isEnabled
        let rowIsHittable = folderRow("/Videos").isHittable
        let beforeDescent = screenReport()
        openFolderRow("/Videos")
        sleep(3)
        let firstLook = screenReport()
        shot("fv04-videos-level")
        XCTAssertTrue(tile(firstClip).waitForExistence(timeout: 20),
                      "the folder that was opened did not render its own assets — row enabled=\(rowIsEnabled) "
                      + "hittable=\(rowIsHittable); before the tap: \(beforeDescent); after the tap: \(firstLook)")
        XCTAssertEqual(askedFolders(), ["/Videos"],
                       "opening the second root must ask the server for ITS path — asked: \(askedFolders())")
        XCTAssertTrue(pathBar.waitForExistence(timeout: 10), "an opened folder prints its path")
        XCTAssertEqual(pathBar.label, "/Videos",
                       "the path bar must print the folder that was opened, not another one")
        XCTAssertTrue(folderRow("/Videos/2026").exists,
                      "the sub-folder unique-paths announced is missing — rows: \(folderRowIdentifiers())")
        XCTAssertEqual(tileIds(prefix: "dddd"), [],
                       "the grid shows the FIRST path's assets under the second path's name — "
                       + "the folder that was asked for is not the folder that was drawn")

        // MARK: An empty folder is not a library without folders

        openFolderRow("/Videos/2026")
        sleep(3)
        shot("fv05-empty-folder")
        XCTAssertTrue(waitForEmptyState(timeout: 25),
                      "'Empty folder' never appeared for a folder that holds no sub-folder and no asset — "
                      + screenReport())
        XCTAssertEqual(askedFolders(), ["/Videos", "/Videos/2026"],
                       "each level reads the folder it shows — asked: \(askedFolders())")
        XCTAssertEqual(pathBar.label, "/Videos/2026",
                       "an empty FOLDER still prints its own path — that is exactly what tells it apart "
                       + "from a library that holds no folder at all")

        // MARK: Walking back costs nothing, and the other root reads its own folder

        app.navigationBars.firstMatch.buttons.firstMatch.tap() // /Videos/2026 → /Videos
        XCTAssertTrue(tile(firstClip).waitForExistence(timeout: 20),
                      "coming back up did not repaint the parent level")
        app.navigationBars.firstMatch.buttons.firstMatch.tap() // /Videos → top level
        XCTAssertTrue(folderRow("/Photos").waitForExistence(timeout: 20), "not back at the top level")
        XCTAssertEqual(askedFolders(), ["/Videos", "/Videos/2026"],
                       "the per-path cache holds what has been read — walking back up asked again: "
                       + "\(askedFolders())")

        openFolderRow("/Photos")
        sleep(3)
        shot("fv06-photos-level")
        XCTAssertTrue(tile(firstPhoto).waitForExistence(timeout: 20),
                      "the first root did not render its own assets — \(screenReport())")
        XCTAssertEqual(askedFolders(), ["/Videos", "/Videos/2026", "/Photos"],
                       "each of the three levels must have asked for its OWN path, in the order they were "
                       + "opened — asked: \(askedFolders())")
        XCTAssertEqual(tileIds(prefix: "eeee"), [],
                       "the second folder's assets leaked into the first one's grid")

        // AC-5108, read off the wire: descending a level replays nothing.
        XCTAssertEqual(treeReads(), treeReadsAtTopLevel,
                       "descending a level must not replay unique-paths (the tree is built once)")

        // MARK: No folder at all — the other empty screen

        // The tree is cached for the life of its ViewModel (`root != nil` bails
        // out), so an emptied library is only observable in a fresh launch. What
        // must change is what the screen says: the same "nothing here" copy, but
        // without a path bar, without a row — and without reading a folder.
        setTree("empty")
        app.terminate()
        app.launch()
        enterShell("fv07")
        let marker = stubRequests().count
        openFolders()
        XCTAssertTrue(waitForEmptyState(timeout: 30),
                      "a library that holds no folder no longer shows its empty state — "
                      + screenReport())
        XCTAssertFalse(pathBar.exists,
                       "a library with no folder has no path to print — that is what separates 'no folder' "
                       + "from 'empty folder', which still prints one")
        XCTAssertEqual(folderRowIdentifiers(), [],
                       "no folder row may survive — got: \(folderRowIdentifiers())")
        shot("fv08-no-folders")

        let afterRelaunch = Array(stubRequests().dropFirst(marker))
        XCTAssertTrue(afterRelaunch.contains { $0.path == "/api/view/folder/unique-paths" },
                      "the new launch must read the tree again, or the empty screen below is a leftover — "
                      + "got:\n\(describe(afterRelaunch))")
        XCTAssertEqual(afterRelaunch.filter { $0.path == "/api/view/folder" }.count, 0,
                       "a top level with no folder must not read a folder — got:\n\(describe(afterRelaunch))")
    }
}
