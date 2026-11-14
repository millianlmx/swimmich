import XCTest

/// End-to-end scenarios for server-side edits (lot L-21): crop, quarter turn and mirror are saved as
/// non-destructive edits (`PUT /api/assets/{id}/edits`) with no copy, shown by the viewer, removed with
/// `DELETE`, downloaded as the edited version or the original, and an old server keeps the copy.
///
/// It drives the real app against `immich_stub_asset_edits.py`, launched with `-uiTestImageProbe YES`
/// (the save-mode line and the viewer's banner expose their value). It asserts on
/// the WIRE: a screen that said "saved" could still have uploaded a copy. Targets identifiers and the
/// stub's data, never a localized label.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/asset-edits.uitest.log \
///         UITests/stubs/immich_stub_asset_edits.py AssetEditsUITests --erase
///
/// The helpers are copied from `PartnerLibraryUITests` on purpose: one file per feature, helpers included.
final class AssetEditsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    /// The last reading of `waitForProbe`, in the failure messages (`describe()`): what the screen
    /// showed when the wait gave up.
    private var lastProbeReading = "no probe read"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    /// The first of the stub's six timeline photos: 4000×3000, EXIF orientation 1.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"
    /// The second of the stub's timeline photos: never seeded, so never edited.
    private let secondPhoto = "aaaaaaaa-1111-4111-8111-000000000002"

    // MARK: - Helpers (copied, see the type's doc)

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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-asset-edits-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-asset-edits-\(name).png")
    }

    private func get(_ path: String) {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    private func reset() { get("/__reset") }

    private func setProvider(_ mode: String) { get("/__provider?mode=\(mode)") }

    private func screenText() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement { visible("assetTile_\(assetId)") }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    // MARK: - Wire helpers

    /// The stub's request log, entry by entry (`method`, `path`, `params`, `body`, and what a route noted).
    private func journal() -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var payload = Data()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { payload = data }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")
        return (try? JSONSerialization.jsonObject(with: payload)) as? [[String: Any]] ?? []
    }

    private func entries(_ method: String, where matches: (String) -> Bool) -> [[String: Any]] {
        journal().filter { ($0["method"] as? String) == method && matches($0["path"] as? String ?? "") }
    }

    private func editsEntries(_ method: String) -> [[String: Any]] {
        entries(method) { $0 == "/api/assets/\(photo)/edits" }
    }

    private func uploads() -> [[String: Any]] { entries("POST") { $0 == "/api/assets" } }

    private func param(_ entry: [String: Any], _ key: String) -> String? {
        (entry["params"] as? [String: Any])?[key] as? String
    }

    /// Every thumbnail request of the photo, optionally those whose thumbhash (`c`) ends with `generation`
    /// and whose `size` is `size`.
    private func thumbnails(generation: String? = nil, size: String? = nil) -> [[String: Any]] {
        entries("GET") { $0 == "/api/assets/\(self.photo)/thumbnail" }.filter { entry in
            (generation.map { self.param(entry, "c")?.hasSuffix($0) == true } ?? true)
                && (size.map { self.param(entry, "size") == $0 } ?? true)
        }
    }

    private func originals() -> [[String: Any]] { entries("GET") { $0 == "/api/assets/\(self.photo)/original" } }

    /// The downloads of the offline copy: `GET …/original` asking `edited`. The editor's working image is
    /// an `edited=false` request of the same path, so a copy fetched as the edited version never mixes
    /// with it.
    private func copyDownloads(edited: String) -> [[String: Any]] {
        originals().filter { self.param($0, "edited") == edited }
    }

    private func describe() -> String {
        "probe: \(lastProbeReading)\n" + journal().map { "\($0["method"] ?? "") \($0["path"] ?? "") \($0["params"] ?? "") \($0["body"] ?? "")" }
            .joined(separator: "\n")
    }

    private func editsBody(of entry: [String: Any]) -> NSArray {
        let body = entry["body"] as? [String: Any]
        return (body?["edits"] as? NSArray) ?? []
    }

    private func crop(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [String: Any] {
        ["action": "crop", "parameters": ["x": x, "y": y, "width": width, "height": height]]
    }

    private func rotate(_ angle: Int) -> [String: Any] { ["action": "rotate", "parameters": ["angle": angle]] }

    private func mirror(_ axis: String) -> [String: Any] { ["action": "mirror", "parameters": ["axis": axis]] }

    // MARK: - Navigation

    /// Reset, arm the stub with `config` (a query string for `/api/__edits/config`), launch signed in
    /// with the image probe on, and wait for the first tile.
    private func launchSignedIn(config: String = "", arguments: [String] = []) {
        reset()
        setProvider("manual")
        if !config.isEmpty { get("/api/__edits/config?\(config)") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-uiTestImageProbe", "YES"] + arguments + sessionArguments()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "the app did not start signed in — \(screenText())")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    /// The session the stub's SSO sign-in hands out (`POST /api/oauth/callback`), as the launch
    /// arguments of `AuthViewModel`'s keys: the app starts signed in, the way the onboarding leaves
    /// it, without the onboarding (a minute or two through `SafariViewService`, and a sign-in
    /// consent that shows late on a loaded Mac) that these scenarios do not test.
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

    /// Tile → viewer → edit button → the editor, once the server's state is read (the mode line is shown).
    private func openEditor() {
        tile(photo).tap()
        let edit = element("viewerEditButton")
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "the viewer has no edit button — \(screenText())")
        edit.tap()
        XCTAssertTrue(element("editorSaveModeLabel").waitForExistence(timeout: 20),
                      "the editor never loaded the photo's context — \(screenText())")
    }

    /// Taps an editor control, scrolling the editor up while it is not hittable.
    private func tapEditor(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) missing — \(screenText())")
        for _ in 0..<5 where !control.isHittable { app.swipeUp() }
        control.tap()
    }

    private func saveMode() -> String? { element("editorSaveModeLabel").value as? String }

    /// The viewer is still open behind the closed editor: its edit button opens the editor again.
    private func reopenEditorFromViewer() {
        let edit = element("viewerEditButton")
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "the viewer has no edit button — \(screenText())")
        edit.tap()
        XCTAssertTrue(element("editorSaveModeLabel").waitForExistence(timeout: 20),
                      "the editor never loaded the photo's context — \(screenText())")
    }

    private func save() {
        let button = element("editorSaveButton")
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no Save button")
        XCTAssertTrue(waitUntil(10) { button.isEnabled }, "Save stayed disabled — \(screenText())")
        button.tap()
    }

    private func waitEditorClosed() {
        XCTAssertTrue(waitUntil(15) { !self.element("editorSaveButton").exists }, "the editor stayed open — \(screenText())")
    }

    /// The viewer is open: its editor, a 4:3 crop, Save.
    private func cropAndSave() {
        reopenEditorFromViewer()
        tapEditor("ratioButton.fourByThree")
        save()
        waitEditorClosed()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT — \(describe())")
    }

    /// The viewer is open: its editor, back to the original, Save.
    private func revertAndSave() {
        reopenEditorFromViewer()
        tapEditor("revertToOriginalButton")
        save()
        waitEditorClosed()
    }

    // MARK: - Stub state and screens (display scenarios)

    private let album = "eeeeeeee-2222-4222-8222-000000000001"

    private func getJSON(_ path: String) -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var payload = Data()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { payload = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }

    /// `GET /api/__edits/state` of the photo: generation, `readyAt`, `emittedAt`, thumbhash, `sha`.
    private func state() -> [String: Any] { getJSON("/api/__edits/state?id=\(photo)") }

    private func stubTime(_ key: String) -> Double { state()[key] as? Double ?? 0 }

    private func sha(_ key: String) -> String? { (state()["sha"] as? [String: String])?[key] }

    private func at(_ entry: [String: Any]) -> Double { entry["at"] as? Double ?? 0 }

    private func after(_ time: Double, _ entries: [[String: Any]]) -> [[String: Any]] {
        entries.filter { at($0) >= time }
    }

    /// An edit made by another client: `edits` is the whole list (`[]` removes it).
    private func remote(_ edits: [[String: Any]]) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: edits), as: UTF8.self)
        let encoded = try XCTUnwrap(json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        get("/api/__edits/remote?id=\(photo)&edits=\(encoded)")
    }

    /// A server that does not answer: every `/api/` request fails, the socket is cut.
    private func setDown(_ on: Bool) { get("/api/__edits/config?down=\(on ? 1 : 0)") }

    /// The matching element that is on screen: the grids of the other tabs stay in the tree, and show
    /// the same photo.
    private func visible(_ identifier: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    /// The image probe of an element (`placeholder`, `loaded <w>x<h> …`, `failed`), empty when it is absent.
    private func probe(_ identifier: String) -> String {
        let match = visible(identifier)
        return match.exists ? (match.value as? String ?? "") : ""
    }

    /// Waits for the probe of `identifier` to start with `prefix`: until `within` seconds after the stub's
    /// `key` time (`readyAt` of the change, `emittedAt` of the event), or after the call when that time is past
    /// (a screen reached late is judged from its arrival).
    private func waitForProbe(_ identifier: String, prefix: String, within: TimeInterval = 10,
                              after key: String = "readyAt") -> Bool {
        let start = state()
        let now = start["now"] as? Double ?? 0
        let anchor = max(start[key] as? Double ?? now, now)
        let deadline = Date().addingTimeInterval(anchor - now + within)
        while Date() < deadline {
            if reading(identifier).hasPrefix(prefix) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return reading(identifier).hasPrefix(prefix)
    }

    /// `probe(identifier)`, remembered for the failure messages.
    private func reading(_ identifier: String) -> String {
        let value = probe(identifier)
        lastProbeReading = "\(identifier) = '\(value)'"
        return value
    }

    private func waitForSocket(timeout: TimeInterval = 30) -> Bool {
        waitUntil(timeout) {
            self.journal().contains { ($0["path"] as? String) == "/api/socket.io/" && ($0["status"] as? Int) == 101 }
        }
    }

    /// The stub has emitted `AssetEditReadyV2` for the last change.
    private func waitForEmission(timeout: TimeInterval = 45) -> Bool {
        waitUntil(timeout) { self.state()["emittedAt"] is Double }
    }

    private func tab(_ label: String) {
        let button = app.tabBars.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no \(label) tab — \(screenText())")
        button.tap()
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer has no back button — \(screenText())")
        back.tap()
        XCTAssertTrue(waitUntil(15) { !back.exists }, "the viewer stayed open")
    }

    /// "Keep offline" from the share sheet of the open viewer, then the sheet is closed.
    private func keepOffline() {
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no share button — \(screenText())")
        share.tap()
        let keep = element("downloadForOfflineButton")
        XCTAssertTrue(keep.waitForExistence(timeout: 20), "no Download for Offline — \(screenText())")
        keep.tap()
        XCTAssertTrue(element("offlineAvailableRow").waitForExistence(timeout: 30), "the copy was never kept — \(describe())")
        for _ in 0..<3 where element("offlineAvailableRow").exists {
            app.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// The offline library, reached from the Albums tab.
    private func openOfflineStorage() {
        tab("Albums")
        let row = element("offlineStorageRow")
        for _ in 0..<5 where !row.exists || !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(element("offlineStorageScreen").waitForExistence(timeout: 20), "no offline library — \(screenText())")
    }

    /// The Albums tab, on the list of albums (an album left open on this tab is closed first).
    private func openAlbumList() {
        tab("Albums")
        let card = element("albumCard_\(album)")
        if !card.waitForExistence(timeout: 5) {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card — \(screenText())")
    }

    /// The album of the stub, opened from its card.
    private func openAlbum() {
        openAlbumList()
        element("albumCard_\(album)").tap()
        XCTAssertTrue(element("albumHeroImage").waitForExistence(timeout: 20), "the album never opened — \(screenText())")
    }

    /// "beach" typed in the search tab (an earlier query is cleared).
    private func search(_ text: String) {
        tab("Search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field — \(screenText())")
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() }
        field.typeText("\(text)\n")
    }

    /// The requests for the album cover: their cache key `c` starts with the album's date (`…Z`), a tile's
    /// is a thumbhash.
    private func coverRequests() -> [[String: Any]] {
        thumbnails().filter { (self.param($0, "c") ?? "").contains("Z") }
    }

    /// The stub served the edited rendering for this request.
    private func served(_ entry: [String: Any]) -> Bool { entry["edited_served"] as? Bool == true }

    /// A `GET …/original` of the photo with `edited`, after `time`, that served the file `sha` names.
    private func hasOriginal(edited: String, after time: Double, sha key: String) -> Bool {
        let expected = sha(key)
        return originals().contains {
            self.param($0, "edited") == edited && self.at($0) >= time && $0["sha"] as? String == expected
        }
    }

    // MARK: - AC-181

    func test_AC_181_cropRotateMirrorSavesEdits() {
        launchSignedIn()
        openEditor()
        XCTAssertEqual(saveMode(), "server")
        tapEditor("ratioButton.fourByThree")
        tapEditor("rotate90CWButton")
        tapEditor("mirrorHorizontalButton")
        XCTAssertEqual(saveMode(), "server")
        save()

        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT /edits — \(describe())")
        let puts = editsEntries("PUT")
        XCTAssertEqual(puts.count, 1)
        let expected: [[String: Any]] = [crop(0, 375, 4000, 2250), mirror("vertical"), rotate(90)]
        XCTAssertEqual(editsBody(of: puts[0]), expected as NSArray, "\(describe())")
        XCTAssertTrue(uploads().isEmpty, "no file must be sent — \(describe())")
        XCTAssertTrue(waitUntil(15) { !self.element("editorSaveButton").exists }, "the editor stayed open")
        let banner = element("editedCopySavedBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no banner — \(screenText())")
        XCTAssertEqual(banner.value as? String, "savedEdits")
    }

    // MARK: - AC-182

    func test_AC_182_reopenChangeRotationThenRevert() throws {
        let seeded = [crop(0, 375, 4000, 2250), rotate(90)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: seeded), as: UTF8.self)
        let encoded = try XCTUnwrap(json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        launchSignedIn(config: "seed=\(photo)&edits=\(encoded)")

        openEditor()
        XCTAssertEqual(saveMode(), "server")
        let originals = entries("GET") { $0 == "/api/assets/\(self.photo)/original" }
        XCTAssertFalse(originals.isEmpty, "the working image was never read — \(describe())")
        for entry in originals {
            XCTAssertEqual((entry["params"] as? [String: Any])?["edited"] as? String, "false")
        }
        XCTAssertEqual(editsEntries("GET").count, 1, "the editor reads the saved edits once")

        tapEditor("rotate90CWButton")
        save()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT — \(describe())")
        let expected: [[String: Any]] = [crop(0, 375, 4000, 2250), rotate(180)]
        XCTAssertEqual(editsBody(of: editsEntries("PUT")[0]), expected as NSArray, "the whole list is replaced")
        XCTAssertTrue(waitUntil(15) { !self.element("editorSaveButton").exists }, "the editor stayed open")

        reopenEditorFromViewer()
        tapEditor("revertToOriginalButton")
        save()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        XCTAssertEqual(editsEntries("DELETE").count, 1)
        XCTAssertEqual(editsEntries("PUT").count, 1, "reverting sends no PUT — \(describe())")
        XCTAssertTrue(uploads().isEmpty, "no file must be sent — \(describe())")
    }

    // MARK: - AC-188

    func test_AC_188_oldServerSavesCopy() {
        launchSignedIn(config: "version=2.0.0")
        openEditor()
        XCTAssertEqual(saveMode(), "copy")
        tapEditor("ratioButton.fourByThree")
        save()

        XCTAssertTrue(waitUntil(30) { !self.uploads().isEmpty }, "no copy was uploaded — \(describe())")
        let filename = uploads()[0]["filename"] as? String ?? ""
        XCTAssertTrue(filename.hasSuffix("_edited.jpg"), "unexpected file name \(filename)")
        XCTAssertTrue(journal().allSatisfy { !(($0["path"] as? String) ?? "").contains("/edits") },
                      "an old server must never be asked for /edits — \(describe())")
        let banner = element("editedCopySavedBanner")
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "no banner — \(screenText())")
        XCTAssertEqual(banner.value as? String, "savedCopy")
        XCTAssertFalse(element("editorErrorMessage").exists)
    }

    // MARK: - AC-189

    func test_AC_189_putErrorShowsMessage() {
        launchSignedIn(config: "put=500")
        openEditor()
        tapEditor("ratioButton.fourByThree")
        save()

        XCTAssertTrue(element("editorErrorMessage").waitForExistence(timeout: 20),
                      "no error message — \(screenText())\n\(describe())")
        XCTAssertTrue(element("editorSaveButton").exists, "the editor must stay open")
        XCTAssertFalse(editsEntries("PUT").isEmpty)
        XCTAssertTrue(uploads().isEmpty, "never a silent copy — \(describe())")
    }

    // MARK: - AC-39

    /// Crop, quarter turn and mirror are saved as edits on the photo (no new asset); once the server has
    /// regenerated the thumbnails the viewer and the grid show the edited version, with `edited=true` on
    /// every thumbnail request; after the removal the original comes back on both.
    func test_AC_39_editedVersionShownThenTheOriginalComesBack() {
        launchSignedIn(config: "regen=5")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8", within: 30), "the grid never showed the photo — \(describe())")
        openEditor()
        tapEditor("ratioButton.fourByThree")
        tapEditor("rotate90CWButton")
        tapEditor("mirrorHorizontalButton")
        save()

        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT /edits — \(describe())")
        let expected: [[String: Any]] = [crop(0, 375, 4000, 2250), mirror("vertical"), rotate(90)]
        XCTAssertEqual(editsBody(of: editsEntries("PUT")[0]), expected as NSArray, "\(describe())")
        XCTAssertTrue(uploads().isEmpty, "no new asset: the edits are saved on the photo — \(describe())")
        waitEditorClosed()

        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12"),
                      "the viewer never showed the edited preview — \(describe())")
        let readyAt = stubTime("readyAt")
        XCTAssertFalse(after(readyAt, thumbnails(generation: "-e1", size: "preview")).isEmpty,
                       "no regenerated preview after the switch — \(describe())")
        closeViewer()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12"),
                      "the grid never showed the edited thumbnail — \(describe())")
        XCTAssertFalse(after(readyAt, thumbnails(generation: "-e1", size: "thumbnail")).isEmpty,
                       "no regenerated thumbnail after the switch — \(describe())")

        tile(photo).tap()
        revertAndSave()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        XCTAssertEqual(editsEntries("DELETE").count, 1)
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 8x8"),
                      "the original never came back to the viewer — \(describe())")
        closeViewer()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8"),
                      "the original never came back to the grid — \(describe())")
        XCTAssertFalse((state()["thumbhash"] as? String ?? "-e").contains("-e"), "the server is back on its first thumbhash")
        for entry in thumbnails() {
            XCTAssertEqual(param(entry, "edited"), "true", "every thumbnail asks the edited rendering — \(describe())")
        }
    }

    // MARK: - AC-183

    /// The photo shown by the timeline, an album and the search follows the edit and its removal without a
    /// gesture, although the server serves the old image for 5 s after each change.
    func test_AC_183_timelineAlbumAndSearchFollowTheEditAndItsRemoval() {
        launchSignedIn(config: "regen=5")
        search("beach")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8", within: 30), "the search never showed the photo — \(describe())")
        openAlbum()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8", within: 30), "the album never showed the photo — \(describe())")
        tab("Photos")

        tile(photo).tap()
        cropAndSave()
        closeViewer()
        let readyAt = stubTime("readyAt")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12"),
                      "the timeline kept the old image — \(describe())")
        openAlbum()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12"),
                      "the album kept the old image — \(describe())")
        tab("Search")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12"),
                      "the search kept the old image — \(describe())")
        tab("Photos")
        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12"), "the viewer kept the old image — \(describe())")
        XCTAssertFalse(after(readyAt, thumbnails(generation: "-e1", size: "thumbnail")).isEmpty, "\(describe())")
        XCTAssertFalse(after(readyAt, thumbnails(generation: "-e1", size: "preview")).isEmpty, "\(describe())")

        // The search reads the new thumbhash from the server (`-e1`) before the removal: the original must
        // still come back on it.
        closeViewer()
        search("beach again")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12"), "the search lost the edit — \(describe())")
        tab("Photos")
        tile(photo).tap()
        revertAndSave()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        closeViewer()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8"), "the timeline kept the edited image — \(describe())")
        openAlbum()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8"), "the album kept the edited image — \(describe())")
        tab("Search")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8"), "the search kept the edited image — \(describe())")
        for entry in thumbnails() {
            XCTAssertEqual(param(entry, "edited"), "true", "every thumbnail asks the edited rendering — \(describe())")
        }
    }

    // MARK: - AC-186

    /// A photo kept offline: its copy is downloaded `edited=true`, not again before the regeneration, then
    /// as the edited rendering; after the removal as the original — and the grid, the viewer and the
    /// offline library show the copy with the server cut.
    func test_AC_186_offlineCopyFollowsAfterTheRegeneration() {
        launchSignedIn(config: "regen=5")
        tile(photo).tap()
        keepOffline()
        let kept = originals()
        XCTAssertEqual(kept.count, 1, "\(describe())")
        XCTAssertEqual(param(kept[0], "edited"), "true", "the copy is kept as the displayed version")

        reopenEditorFromViewer()
        tapEditor("ratioButton.fourByThree")
        save()
        waitEditorClosed()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT — \(describe())")
        XCTAssertTrue(waitUntil(30) { self.state()["ready"] as? Bool == true }, "the regeneration never ended")
        let readyAt = stubTime("readyAt")
        XCTAssertTrue(copyDownloads(edited: "true").dropFirst(kept.count).allSatisfy { self.at($0) >= readyAt },
                      "the copy was fetched again before the regeneration — \(describe())")
        XCTAssertTrue(waitUntil(15) { self.hasOriginal(edited: "true", after: readyAt, sha: "originalEdited") },
                      "the copy was never fetched again as the edited version — \(describe())")

        setDown(true)
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 96x96"), "the viewer lost the edited copy")
        closeViewer()
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 96x96"), "the grid lost the edited copy")
        openOfflineStorage()
        XCTAssertTrue(waitForProbe("offlineAsset_\(photo)", prefix: "loaded 96x96"), "the library lost the edited copy")

        setDown(false)
        tab("Photos")
        tile(photo).tap()
        revertAndSave()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        XCTAssertTrue(waitUntil(30) { self.state()["ready"] as? Bool == true }, "the second regeneration never ended")
        let removedAt = stubTime("readyAt")
        XCTAssertTrue(waitUntil(15) { self.hasOriginal(edited: "false", after: removedAt, sha: "original") },
                      "the copy was never fetched again as the original — \(describe())")
        setDown(true)
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 64x64"), "the viewer lost the restored copy")
    }

    // MARK: - AC-196

    /// Another client edits the photo: the timeline and the open viewer follow, without a gesture.
    func test_AC_196_editMadeElsewhereReachesOpenScreens() throws {
        launchSignedIn(config: "regen=5")
        XCTAssertTrue(waitForSocket(), "the app never opened the socket — \(describe())")

        try remote([crop(0, 375, 4000, 2250)])
        XCTAssertTrue(waitForEmission(), "the stub never emitted the event")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12", after: "emittedAt"),
                      "the timeline kept the old image — \(describe())")
        XCTAssertFalse(after(stubTime("readyAt"), thumbnails(generation: "-e1", size: "thumbnail")).isEmpty, "\(describe())")

        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12"), "the viewer opened on the old image")
        try remote([])
        XCTAssertTrue(waitUntil(30) { self.state()["emittedAt"] is NSNull }, "the second change was not seen")
        XCTAssertTrue(waitForEmission(), "the stub never emitted the second event")
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 8x8", after: "emittedAt"),
                      "the viewer kept the edited image — \(describe())")
        XCTAssertFalse((state()["thumbhash"] as? String ?? "-e").contains("-e"), "the server is back on its first thumbhash")

        try remote([rotate(90)])
        XCTAssertTrue(waitUntil(30) { self.state()["emittedAt"] is NSNull }, "the third change was not seen")
        XCTAssertTrue(waitForEmission(), "the stub never emitted the third event")
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12", after: "emittedAt"),
                      "the viewer kept the original — \(describe())")
        XCTAssertTrue((state()["thumbhash"] as? String ?? "").hasSuffix("-e3"))
        XCTAssertTrue(originals().isEmpty, "no copy is kept offline: no original is fetched — \(describe())")
    }

    // MARK: - AC-197

    /// The cover of the album, in the list and in the detail, follows the edit made here, its removal, and
    /// an edit made by another client.
    func test_AC_197_albumCoverFollowsTheEdit() throws {
        launchSignedIn(config: "regen=5")
        openAlbumList()
        XCTAssertTrue(waitUntil(20) { self.coverRequests().contains { !self.served($0) } }, "no cover — \(describe())")
        openAlbum()
        XCTAssertTrue(waitForProbe("albumHeroCover", prefix: "loaded 8x8"), "the header never showed the cover — \(describe())")

        tab("Photos")
        tile(photo).tap()
        cropAndSave()
        closeViewer()
        let readyAt = stubTime("readyAt")
        openAlbum()
        XCTAssertTrue(waitForProbe("albumHeroCover", prefix: "loaded 12x12"), "the header kept the old cover — \(describe())")
        openAlbumList()
        XCTAssertTrue(waitUntil(15) { self.coverRequests().contains { self.served($0) && self.at($0) >= readyAt } },
                      "the list never asked for the edited cover — \(describe())")
        for entry in coverRequests() { XCTAssertEqual(param(entry, "edited"), "true") }

        tab("Photos")
        tile(photo).tap()
        revertAndSave()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        closeViewer()
        XCTAssertTrue(waitUntil(30) { self.state()["ready"] as? Bool == true }, "the second regeneration never ended")
        let removedAt = stubTime("readyAt")
        openAlbumList()
        XCTAssertTrue(waitUntil(15) { self.coverRequests().contains { !self.served($0) && self.at($0) >= removedAt } },
                      "the list never asked for the original cover — \(describe())")
        openAlbum()
        XCTAssertTrue(waitForProbe("albumHeroCover", prefix: "loaded 8x8"), "the header kept the edited cover — \(describe())")

        try remote([rotate(90)])
        XCTAssertTrue(waitUntil(30) { self.state()["emittedAt"] is NSNull }, "the change was not seen")
        XCTAssertTrue(waitForEmission(), "the stub never emitted the event")
        let remoteAt = stubTime("readyAt")
        tab("Photos")
        openAlbumList()
        XCTAssertTrue(waitUntil(15) { self.coverRequests().contains { self.served($0) && self.at($0) >= remoteAt } },
                      "the list never asked for the cover edited elsewhere — \(describe())")
    }

    // MARK: - AC-198

    /// The regeneration takes 15 s, longer than the app's wait: the copy is not fetched again blindly, and
    /// it is fetched, edited, within 10 s of the event.
    func test_AC_198_slowRegenerationRedownloadsOnTheEvent() {
        launchSignedIn(config: "regen=15")
        XCTAssertTrue(waitForSocket(), "the app never opened the socket — \(describe())")
        tile(photo).tap()
        keepOffline()
        let kept = originals()

        reopenEditorFromViewer()
        tapEditor("ratioButton.fourByThree")
        save()
        waitEditorClosed()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT — \(describe())")
        XCTAssertTrue(waitForEmission(), "the stub never emitted the event")
        let readyAt = stubTime("readyAt")
        XCTAssertTrue(copyDownloads(edited: "true").dropFirst(kept.count).allSatisfy { self.at($0) >= readyAt },
                      "the copy was fetched again before the regeneration — \(describe())")
        XCTAssertTrue(waitUntil(10) { self.hasOriginal(edited: "true", after: readyAt, sha: "originalEdited") },
                      "the copy was never fetched again after the event — \(describe())")
        setDown(true)
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 96x96", after: "emittedAt"),
                      "the viewer lost the edited copy")
    }

    // MARK: - AC-199

    /// The viewer is closed before the switch: the search grid follows on the event, all the same.
    func test_AC_199_slowRegenerationReachesTheSearchGridAfterTheViewerClosed() {
        launchSignedIn(config: "regen=15")
        XCTAssertTrue(waitForSocket(), "the app never opened the socket — \(describe())")
        search("beach")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8", within: 30), "the search never showed the photo — \(describe())")
        tab("Photos")
        tile(photo).tap()
        cropAndSave()
        closeViewer()
        XCTAssertLessThan(stubTime("now"), stubTime("readyAt"), "the viewer must close before the switch")

        XCTAssertTrue(waitForEmission(), "the stub never emitted the event")
        tab("Search")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12", after: "emittedAt"),
                      "the search kept the old image — \(describe())")
        XCTAssertFalse(after(stubTime("readyAt"), thumbnails(generation: "-e1", size: "thumbnail")).isEmpty, "\(describe())")
    }

    /// No event at all: reopening the photo after the switch brings the copy up to date.
    func test_AC_199_withoutTheEventTheReopenedViewerResumesTheCopy() {
        launchSignedIn(config: "regen=15&event=0")
        tile(photo).tap()
        keepOffline()
        let kept = originals()
        reopenEditorFromViewer()
        tapEditor("ratioButton.fourByThree")
        save()
        waitEditorClosed()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT — \(describe())")
        closeViewer()

        XCTAssertTrue(waitUntil(40) { self.state()["ready"] as? Bool == true }, "the regeneration never ended")
        let readyAt = stubTime("readyAt")
        XCTAssertTrue(copyDownloads(edited: "true").dropFirst(kept.count).allSatisfy { self.at($0) >= readyAt },
                      "the copy was fetched again before the regeneration — \(describe())")
        tile(photo).tap()
        XCTAssertTrue(waitUntil(10) { self.hasOriginal(edited: "true", after: readyAt, sha: "originalEdited") },
                      "reopening the photo never brought the copy up to date — \(describe())")
        setDown(true)
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 96x96"), "the viewer lost the edited copy")
    }

    // MARK: - Proofs of the display (AC-190 to AC-195)

    private let memory = "dddddddd-4444-4444-8444-000000000001"

    /// The `config` query that stores `edits` as the saved list of the photo (no generation: an edit
    /// that was made before the app started, by another client).
    private func seedConfig(_ edits: [[String: Any]]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: edits), as: UTF8.self)
        let encoded = try XCTUnwrap(json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        return "seed=\(photo)&edits=\(encoded)"
    }

    /// The number after `key=` in a viewer probe (`loaded 12x12 zoom=1.00 max=4.00 off=0.0,0.0 fit=402.0x402.0`).
    private func probeNumber(_ value: String, _ key: String) -> Double? {
        guard let raw = value.split(separator: " ").first(where: { $0.hasPrefix("\(key)=") }) else { return nil }
        return Double(raw.dropFirst(key.count + 1))
    }

    /// The `fit=<w>x<h>` of a viewer probe.
    private func probeFit(_ value: String) -> (width: Double, height: Double)? {
        guard let raw = value.split(separator: " ").first(where: { $0.hasPrefix("fit=") }) else { return nil }
        let sides = raw.dropFirst(4).split(separator: "x").compactMap { Double($0) }
        return sides.count == 2 ? (sides[0], sides[1]) : nil
    }

    /// Terminates the app and starts it again on the same session and arguments: an iOS share sheet that
    /// is open goes with the process.
    private func relaunch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "the app did not start again signed in — \(screenText())")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 5) { whatsNewDone.tap() }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30), "the timeline never rendered again — \(screenText())")
    }

    /// A long press on Share chooses the quality of one share (`original` or `preview`) and shares at once.
    private func shareWithQuality(_ quality: String) {
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no share button — \(screenText())")
        share.press(forDuration: 1.0)
        let choice = element("shareQualityChoice_\(quality)")
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the long press offered no \(quality) choice — \(screenText())")
        choice.tap()
    }

    private func openSlideshow() {
        let direct = element("viewerSlideshowButton")
        if direct.waitForExistence(timeout: 3) {
            direct.tap()
        } else {
            tapElement("viewerOverflowMenu")
            tapElement("viewerMenuSlideshow")
        }
        XCTAssertTrue(element("slideshowCounter").waitForExistence(timeout: 20), "no slideshow — \(screenText())")
    }

    private func tapElement(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) missing — \(screenText())")
        control.tap()
    }

    // MARK: - AC-190

    /// The published app: no launch argument and no hidden setting turn the server mode on, yet the editor
    /// announces a server save and sends a `PUT`, not a copy.
    func test_AC_190_serverSaveIsOnWithoutAnyHiddenSwitch() {
        launchSignedIn()
        XCTAssertFalse(app.launchArguments.contains { $0.lowercased().contains("assetedits") },
                       "the scenario must not switch the server mode on: \(app.launchArguments)")
        openEditor()
        tapEditor("ratioButton.fourByThree")
        XCTAssertEqual(saveMode(), "server")
        save()

        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT /edits — \(describe())")
        XCTAssertEqual(editsEntries("PUT").count, 1)
        XCTAssertTrue(uploads().isEmpty, "no copy: the edits are saved on the photo — \(describe())")
    }

    // MARK: - AC-191

    /// An edited photo whose record still carries the original's EXIF size (4000×3000): the zoom ceiling
    /// is the unknown-size one (4×) and the rectangle is the decoded image's, where an unedited photo's
    /// ceiling follows its EXIF.
    func test_AC_191_editedPhotoZoomLimitIgnoresTheOriginalExif() throws {
        launchSignedIn(config: try seedConfig([crop(0, 375, 4000, 2250)]))
        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12", within: 30),
                      "the viewer never showed the edited image — \(describe())")
        XCTAssertTrue(waitUntil(20) { !self.entries("GET") { $0 == "/api/assets/\(self.photo)" }.isEmpty },
                      "the viewer never read the record — \(describe())")
        Thread.sleep(forTimeInterval: 2)

        let edited = probe("viewerImage_\(photo)")
        XCTAssertEqual(probeNumber(edited, "max") ?? 0, 4, accuracy: 0.001, "unknown size: the default ceiling — \(edited)")
        let fit = probeFit(edited)
        XCTAssertNotNil(fit, "no fit in the probe — \(edited)")
        XCTAssertEqual(fit?.width ?? 0, fit?.height ?? 1, accuracy: 1.0,
                       "the rectangle is the decoded 12×12 image's, not the EXIF 4:3 one — \(edited)")

        closeViewer()
        let other = "aaaaaaaa-1111-4111-8111-000000000002"
        tile(other).tap()
        XCTAssertTrue(waitUntil(20) {
            let value = self.probe("viewerImage_\(other)")
            return value.hasPrefix("loaded") && abs((self.probeNumber(value, "max") ?? 4) - 4) > 0.01
        }, "an unedited photo's ceiling must follow its EXIF size — \(probe("viewerImage_\(other)"))")
    }

    // MARK: - AC-192

    /// Another client edited the photo before the app started: the timeline, a memory, the viewer with its
    /// filmstrip and the slideshow ask `edited=true` for every image of it, and the stub served the edited
    /// rendering each time. The memory and the filmstrip have no probe and share the URL, so the image cache,
    /// of the tile and of the viewer's preview: the journal proves them. The tile, the viewer and the slideshow
    /// slide (dissolve, a `ZoomableImageView`) are read by their probes.
    func test_AC_192_editMadeBeforeShowsOnEverySurface() throws {
        launchSignedIn(config: try seedConfig([crop(0, 375, 4000, 2250)]),
                       arguments: ["-uiTestMemoryPlaybackProbe", "YES", "-uiTestMemoryAutoplayOff", "YES",
                                   "-uiTestSlideshowAutoplayOff", "YES", "-slideshowLook", "dissolve"])
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 12x12", within: 30),
                      "the timeline did not show the edited thumbnail — \(describe())")

        tab("Memories")
        let card = element("memoryCard_\(memory)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no memory card — \(screenText())")
        XCTAssertTrue(waitUntil(20) { self.thumbnails(size: "preview").contains { self.served($0) } },
                      "the memory never asked the edited preview — \(describe())")
        card.tap()
        let playback = element("memoryPlaybackProbe")
        XCTAssertTrue(playback.waitForExistence(timeout: 20), "the memory did not open — \(screenText())")
        let playbackState = (playback.value as? String) ?? ""
        XCTAssertTrue(playbackState.hasPrefix("page=\(memory) photo=0"), "the memory playback reads: \(playbackState)")
        tapElement("memoryMomentClose")

        tab("Photos")
        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12", within: 30),
                      "the viewer did not show the edited image — \(describe())")
        XCTAssertTrue(element("viewerFilmstripCell_0").waitForExistence(timeout: 15),
                      "the filmstrip has no cell for the photo itself — \(screenText())")
        // The viewer keeps its own `viewerImage_<photo>` under the slideshow layer (PhotoViewer.swift:705-717): the
        // slide is the one more element the opening adds, and every one of them reads the edited image.
        let slideImages = { self.app.descendants(matching: .any).matching(identifier: "viewerImage_\(self.photo)") }
        let before = slideImages().count
        openSlideshow()
        XCTAssertTrue(element("slideshowCloseButton").exists, "the slideshow shows no close button — \(screenText())")
        var reading = (count: 0, values: [String]())
        let slideShowsEdited = waitUntil(15) {
            let found = slideImages().allElementsBoundByIndex
            reading = (found.count, found.map { ($0.value as? String) ?? "" })
            return found.count == before + 1 && reading.values.allSatisfy { $0.hasPrefix("loaded 12x12") }
        }
        XCTAssertTrue(slideShowsEdited,
                      "the slideshow slide is not an edited image: viewerImage_<photo> counted \(before) before, \(reading.count) after, reading \(reading.values) — \(describe())")
        tapElement("slideshowCloseButton")
        XCTAssertTrue(waitUntil(15) { self.element("viewerBackButton").exists }, "the slideshow did not close")

        let asked = thumbnails()
        XCTAssertTrue(asked.contains { self.param($0, "size") == "thumbnail" }, "no thumbnail asked — \(describe())")
        XCTAssertTrue(asked.contains { self.param($0, "size") == "preview" }, "no preview asked — \(describe())")
        for entry in asked {
            XCTAssertEqual(param(entry, "edited"), "true", "every image asks the edited rendering — \(describe())")
            XCTAssertTrue(served(entry), "the stub served the original to \(entry) — \(describe())")
        }
        for entry in originals() { XCTAssertEqual(param(entry, "edited"), "true", "\(describe())") }
        XCTAssertTrue(editsEntries("PUT").isEmpty && editsEntries("DELETE").isEmpty, "the app sent no edit — \(describe())")
    }

    // MARK: - AC-194

    /// An edited photo is shared as it was uploaded, in both qualities, and the editor works on the
    /// original: all three requests carry `edited=false` and the stub served the original file.
    func test_AC_194_shareAndEditorStayOnTheOriginal() throws {
        launchSignedIn(config: try seedConfig([crop(0, 375, 4000, 2250), rotate(90)]))
        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12", within: 30),
                      "the viewer must show the edited version before sharing — \(describe())")

        shareWithQuality("original")
        XCTAssertTrue(waitUntil(30) { !self.originals().isEmpty }, "sharing the original never asked for it — \(describe())")
        let sharedOriginals = originals()
        XCTAssertEqual(sharedOriginals.map { self.param($0, "edited") }, ["false"], "\(describe())")
        XCTAssertEqual(sharedOriginals[0]["sha"] as? String, sha("original"), "the file shared is the original")
        relaunch()

        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 12x12"), "\(describe())")
        shareWithQuality("preview")
        XCTAssertTrue(waitUntil(30) { self.thumbnails(size: "preview").contains { self.param($0, "edited") == "false" } },
                      "sharing the preview never asked for the original's — \(describe())")
        let sharedPreview = thumbnails(size: "preview").filter { self.param($0, "edited") == "false" }
        XCTAssertEqual(sharedPreview.count, 1, "\(describe())")
        XCTAssertFalse(served(sharedPreview[0]), "the preview shared is the original's")
        XCTAssertEqual(sharedPreview[0]["sha"] as? String, sha("thumbnail"))
        relaunch()

        let before = originals().count
        tile(photo).tap()
        openEditor()
        XCTAssertTrue(waitUntil(20) { self.originals().count > before }, "the editor never read its working image — \(describe())")
        let working = Array(originals().dropFirst(before))
        for entry in working {
            XCTAssertEqual(param(entry, "edited"), "false", "the editor works on the original — \(describe())")
            XCTAssertEqual(entry["sha"] as? String, sha("original"))
        }
        XCTAssertTrue(originals().allSatisfy { self.param($0, "edited") == "false" }, "\(describe())")
    }

    // MARK: - AC-195

    /// A server that announces 2.0.0 and does not serve `/edits`: the grid and the viewer show the photos as
    /// they always did, with no error, and nothing asks for `/edits`.
    func test_AC_195_oldServerShowsPhotosAsBefore() {
        launchSignedIn(config: "version=2.0.0")
        XCTAssertTrue(waitForProbe("assetTile_\(photo)", prefix: "loaded 8x8", within: 30), "the grid never showed the photo — \(describe())")
        tile(photo).tap()
        XCTAssertTrue(waitForProbe("viewerImage_\(photo)", prefix: "loaded 8x8"), "the viewer never showed the photo — \(describe())")
        XCTAssertTrue(element("viewerFilmstripCell_1").waitForExistence(timeout: 15), "the viewer has no filmstrip")
        Thread.sleep(forTimeInterval: 2)

        XCTAssertEqual(app.alerts.count, 0, "an alert is up — \(screenText())")
        XCTAssertFalse(element("saveSectionError").exists, "an error is shown — \(screenText())")
        XCTAssertFalse(probe("viewerImage_\(photo)").hasPrefix("failed"))
        XCTAssertTrue(journal().allSatisfy { !(($0["path"] as? String) ?? "").contains("/edits") },
                      "an old server must never be asked for /edits — \(describe())")
        XCTAssertFalse(thumbnails().isEmpty, "no image was asked — \(describe())")
        XCTAssertTrue(thumbnails().allSatisfy { !self.served($0) }, "an old server serves the photo as uploaded — \(describe())")
    }

    // MARK: - AC-40

    /// A photo edited on the server is downloaded as the edited version, then as the original: the two
    /// requests carry `edited=true` then `edited=false`, and the stub served two different files.
    func test_AC_40_downloadEditedThenOriginalAsksTwiceWithDifferentFiles() throws {
        let seeded = [crop(0, 375, 4000, 2250), rotate(90)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: seeded), as: UTF8.self)
        let encoded = try XCTUnwrap(json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
        launchSignedIn(config: "seed=\(photo)&edits=\(encoded)")

        tile(photo).tap()
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no share button — \(screenText())")
        share.tap()

        downloadToFiles(choosing: "downloadChoiceEdited")
        XCTAssertTrue(waitUntil(20) { self.originals().count >= 1 }, "no edited download — \(describe())")
        downloadToFiles(choosing: "downloadChoiceOriginal")
        XCTAssertTrue(waitUntil(20) { self.originals().count >= 2 }, "no original download — \(describe())")

        let asked = originals().map { self.param($0, "edited") }
        XCTAssertEqual(asked, ["true", "false"], "\(describe())")
        let files = originals().map { $0["sha"] as? String }
        XCTAssertNotNil(files[0])
        XCTAssertNotEqual(files[0], files[1], "the two files received must differ — \(describe())")
    }

    /// Taps "Download to Files", answers the question "which version?" with `choice`.
    private func downloadToFiles(choosing choice: String) {
        let button = element("downloadToFilesButton")
        XCTAssertTrue(button.waitForExistence(timeout: 20), "no Download to Files — \(screenText())")
        XCTAssertTrue(waitUntil(20) { button.isEnabled }, "Download to Files stayed disabled")
        button.tap()
        let answer = element(choice)
        XCTAssertTrue(answer.waitForExistence(timeout: 20), "the question was never asked — \(screenText())")
        answer.tap()
    }

    // MARK: - AC-187

    /// The downloads of a photo: `GET …/original` WITHOUT the thumbhash `c`, which the viewer's display
    /// of the original always carries.
    private func downloads(of id: String) -> [[String: Any]] {
        entries("GET") { $0 == "/api/assets/\(id)/original" }.filter { self.param($0, "c") == nil }
    }

    private func archives() -> [[String: Any]] { entries("POST") { $0 == "/api/download/archive" } }

    private func infos() -> [[String: Any]] { entries("POST") { $0 == "/api/download/info" } }

    private func bodyEdited(_ entry: [String: Any]) -> Bool? {
        (entry["body"] as? [String: Any])?["edited"] as? Bool
    }

    private func bodyIds(_ entry: [String: Any]) -> Set<String> {
        Set(((entry["body"] as? [String: Any])?["assetIds"] as? [String]) ?? [])
    }

    private func servedEdited(_ entry: [String: Any]) -> [String]? { entry["edited_served"] as? [String] }

    /// The catalogue label of the selection bar's download action, in en, fr, de, es and it. iOS may file
    /// an action under its own overflow button, where an item can lose its identifier: it is then
    /// recognised by its label, compared for EQUALITY.
    private static let barLabels: [String: [String]] = [
        "downloadSelectionButton": ["Download", "Télécharger", "Herunterladen", "Descargar", "Scarica"],
        "selectionCancelButton": ["Cancel", "Annuler", "Abbrechen", "Cancelar", "Annulla"],
        "favoriteSelectedButton": ["Favorite", "Favori", "Favorit", "Favorito", "Preferito"],
        "deleteSelectedButton": ["Delete", "Supprimer", "Löschen", "Eliminar", "Elimina"],
        "addToAlbumButton": ["Add to Album", "Ajouter à l'album", "Zu Album hinzufügen", "Añadir a álbum", "Aggiungi all'album"],
        "archiveButton": ["Archive", "Archiver", "Archivieren", "Archivar", "Archivia"],
        "unarchiveButton": ["Unarchive", "Désarchiver", "Dearchivieren", "Desarchivar", "Rimuovi dall'archivio"],
        "moveToLockedFolderButton": ["Move to Locked Folder", "Déplacer vers le dossier verrouillé",
                                     "In den gesperrten Ordner verschieben", "Mover a la carpeta bloqueada",
                                     "Sposta nella cartella bloccata"],
        "stackButton": ["Stack", "Pile", "Stapel", "Pila", "Gruppo"],
    ]

    /// The element's own identifier, else the action whose label equals its label.
    private func canonicalId(of element: XCUIElement) -> String? {
        if !element.identifier.isEmpty { return element.identifier }
        let label = element.label
        return Self.barLabels.first { $0.value.contains(label) }?.key
    }

    private func selectionBar() -> XCUIElement {
        app.navigationBars.containing(.button, identifier: "selectionCancelButton").firstMatch
    }

    /// The system's overflow button of the bar: of its buttons that carry no identifier and are no known
    /// action, the one furthest right.
    private func overflowButton(in bar: XCUIElement) -> XCUIElement? {
        bar.buttons.allElementsBoundByIndex
            .filter { canonicalId(of: $0) == nil && $0.isHittable }
            .max { $0.frame.maxX < $1.frame.maxX }
    }

    /// The menu's actions while the overflow is open: below the bar, recognised by identifier or label.
    private func overflowActions(below bar: XCUIElement) -> [String] {
        let barBottom = bar.frame.maxY
        let items = app.buttons.allElementsBoundByIndex
            .filter { $0.frame.minY >= barBottom - 1 && $0.isHittable }
            .compactMap { element -> (CGFloat, String)? in
                guard let id = canonicalId(of: element), Self.barLabels[id] != nil else { return nil }
                return (element.frame.minY, id)
            }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// An action of the selection bar, in the bar or in the overflow iOS makes of it.
    private func tapBarAction(_ id: String) {
        let bar = selectionBar()
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "no selection bar — \(screenText())")
        func inBar() -> XCUIElement? {
            bar.buttons.allElementsBoundByIndex.first { canonicalId(of: $0) == id && $0.isHittable }
        }
        if waitUntil(3, { inBar() != nil }), let button = inBar() {
            button.tap()
            return
        }
        if let overflow = overflowButton(in: bar) {
            overflow.tap()
            let found = waitUntil(15) { overflowActions(below: bar).contains(id) }
            if found,
               let item = app.buttons.allElementsBoundByIndex.first(where: {
                   $0.frame.minY >= bar.frame.maxY - 1 && canonicalId(of: $0) == id && $0.isHittable
               }) {
                item.tap()
                return
            }
        }
        XCTFail("no `\(id)` in the selection bar or its overflow — \(screenText())")
    }

    /// Enters the timeline's selection mode and selects the photos.
    private func selectInTimeline(_ ids: [String]) {
        let select = element("selectButton")
        XCTAssertTrue(select.waitForExistence(timeout: 30), "no Select button — \(screenText())")
        select.tap()
        for id in ids { tile(id).tap() }
    }

    /// Answers the question "which version?" with `choice`; the alert goes away and does not come back.
    private func answer(_ choice: String) {
        let button = element(choice)
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the question was never asked — \(screenText())")
        button.tap()
        XCTAssertTrue(element("downloadChoiceEdited").waitForNonExistence(timeout: 5),
                      "the question stayed up after the answer — \(screenText())")
    }

    private func assertNoQuestion(_ context: String) {
        XCTAssertFalse(element("downloadChoiceEdited").waitForExistence(timeout: 5), "a question \(context)")
    }

    /// The download queue holds no `queued` or `running` row: its panel is gone. Called only once the
    /// journal showed the archive request, so the row was at least running. It opens no detail screen,
    /// which an idle queue makes unreachable, and does not prove the file is on disk.
    private func waitQueueIdle() {
        XCTAssertTrue(element("downloadPanel").waitForNonExistence(timeout: 20),
                      "the download queue never went idle — \(describe())")
    }

    /// Answers the system alert Photos raises the first time something is saved.
    private func allowPhotosIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let hosts: [XCUIApplication] = [springboard, app]
        for host in hosts {
            let alert = host.alerts.firstMatch
            guard alert.waitForExistence(timeout: 6) else { continue }
            for label in ["Allow Full Access", "Allow", "OK", "Autoriser"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return }
            }
            XCTFail("the Photos alert offers no allowance — it offers: "
                    + "\(alert.buttons.allElementsBoundByIndex.map(\.label))")
            return
        }
    }

    /// Taps "Save to Photos" in the share sheet and answers the question with `choice`, or checks there is
    /// none when `choice` is nil.
    private func saveToPhotos(answer choice: String?) {
        let save = element("saveToPhotosButton")
        for _ in 0..<4 where !save.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(save.exists, "no Save to Photos button — \(screenText())")
        save.tap()
        if let choice { answer(choice) } else { assertNoQuestion("on Save to Photos") }
        allowPhotosIfAsked()
    }

    /// Waits until the photo was downloaded `count` times, then until Save to Photos reads `saved`.
    private func waitSaved(count: Int, of id: String) {
        XCTAssertTrue(waitUntil(30) { self.downloads(of: id).count == count },
                      "expected \(count) download(s) of the photo — \(describe())")
        let save = element("saveToPhotosButton")
        let saved = waitUntil(30) {
            (save.value as? String) == "saved" || self.element("saveSectionError").exists
        }
        let error = element("saveSectionError")
        XCTAssertFalse(error.exists, "the save failed: \(error.exists ? error.label : "") — \(describe())")
        XCTAssertTrue(saved, "the save never finished — value \(save.value as? String ?? "nil")")
    }

    /// A selection of two photos on a v3.4.0 server whose timeline says nothing about edits: the question
    /// is asked once per download, and each archive asks the server for the answer given. The two files
    /// differ. The second selection waits for the first archive's row to finish (decision #2).
    func test_AC_187_selectionAsksOnceAndCarriesEachAnswer() throws {
        launchSignedIn(config: try seedConfig([crop(0, 375, 4000, 2250), rotate(90)]))
        let both = [photo, secondPhoto]

        selectInTimeline(both)
        tapBarAction("downloadSelectionButton")
        answer("downloadChoiceEdited")
        XCTAssertTrue(waitUntil(20) { self.archives().count == 1 }, "no archive for the edited choice — \(describe())")
        let first = archives()[0]
        XCTAssertEqual(bodyEdited(first), true, "\(describe())")
        XCTAssertEqual(bodyIds(first), Set(both), "\(describe())")
        XCTAssertEqual(servedEdited(first), [photo], "only the edited photo comes edited — \(describe())")
        let log = journal()
        let infoAt = log.firstIndex { ($0["path"] as? String) == "/api/download/info" && self.bodyIds($0) == Set(both) }
        let archiveAt = log.firstIndex { ($0["path"] as? String) == "/api/download/archive" }
        XCTAssertNotNil(infoAt, "the archive was never announced by download/info — \(describe())")
        if let infoAt, let archiveAt { XCTAssertLessThan(infoAt, archiveAt, "download/info comes before the archive — \(describe())") }
        XCTAssertTrue(element("selectButton").waitForExistence(timeout: 15), "the selection was not left — \(screenText())")
        waitQueueIdle()

        selectInTimeline(both)
        tapBarAction("downloadSelectionButton")
        answer("downloadChoiceOriginal")
        XCTAssertTrue(waitUntil(20) { self.archives().count == 2 }, "no archive for the original choice — \(describe())")
        let second = archives()[1]
        XCTAssertEqual(bodyEdited(second), false, "the original is asked explicitly — \(describe())")
        XCTAssertEqual(bodyIds(second), Set(both), "\(describe())")
        XCTAssertEqual(servedEdited(second), [], "\(describe())")
        let files = archives().map { $0["sha"] as? String }
        XCTAssertNotNil(files[0])
        XCTAssertNotEqual(files[0], files[1], "the two archives must differ — \(describe())")

        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(archives().count, 2, "one archive per answer — \(describe())")
        XCTAssertEqual(infos().count, 2, "one announcement per answer — \(describe())")
    }

    /// The same selection on a server that does not serve `/edits`: no question, the original, explicitly.
    func test_AC_187_oldServerSelectionDownloadsOriginalWithoutQuestion() {
        launchSignedIn(config: "version=2.0.0")

        selectInTimeline([photo, secondPhoto])
        tapBarAction("downloadSelectionButton")
        assertNoQuestion("on a server without /edits")
        XCTAssertTrue(waitUntil(20) { self.archives().count == 1 }, "no archive — \(describe())")
        let archive = archives()[0]
        XCTAssertEqual(bodyEdited(archive), false, "\(describe())")
        XCTAssertEqual(bodyIds(archive), Set([photo, secondPhoto]), "\(describe())")
        XCTAssertEqual(servedEdited(archive), [], "\(describe())")
        XCTAssertTrue(element("selectButton").waitForExistence(timeout: 15), "the selection was not left — \(screenText())")
        XCTAssertTrue(journal().allSatisfy { !(($0["path"] as? String) ?? "").contains("/edits") },
                      "an old server must never be asked for /edits — \(describe())")
    }

    /// In the viewer, Save to Photos and Download to Files ask the question for a photo whose record says
    /// edited, every time; Download original never does. A photo whose record says it is not edited is
    /// never asked about.
    func test_AC_187_viewerAsksOnlyForAnEditedRecord() throws {
        // A: the record says edited.
        launchSignedIn(config: try seedConfig([crop(0, 375, 4000, 2250), rotate(90)]))
        tile(photo).tap()
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "the viewer has no share button — \(screenText())")
        share.tap()

        saveToPhotos(answer: "downloadChoiceEdited")
        waitSaved(count: 1, of: photo)
        XCTAssertEqual(param(downloads(of: photo)[0], "edited"), "true", "\(describe())")

        saveToPhotos(answer: "downloadChoiceOriginal")
        waitSaved(count: 2, of: photo)
        XCTAssertEqual(param(downloads(of: photo)[1], "edited"), "false", "\(describe())")
        let files = downloads(of: photo).map { $0["sha"] as? String }
        XCTAssertNotNil(files[0])
        XCTAssertNotEqual(files[0], files[1], "the two files received must differ — \(describe())")

        downloadToFiles(choosing: "downloadChoiceEdited")
        XCTAssertTrue(waitUntil(20) { self.downloads(of: self.photo).count == 3 }, "no third download — \(describe())")
        XCTAssertEqual(param(downloads(of: photo)[2], "edited"), "true", "\(describe())")

        let original = element("downloadOriginalButton")
        XCTAssertTrue(original.waitForExistence(timeout: 20), "no Download original — \(screenText())")
        original.tap()
        assertNoQuestion("on Download original")
        XCTAssertTrue(waitUntil(20) { self.downloads(of: self.photo).count == 4 }, "no fourth download — \(describe())")
        XCTAssertEqual(downloads(of: photo).map { self.param($0, "edited") }, ["true", "false", "true", "false"],
                       "\(describe())")

        // B: the record says it is not edited.
        app.terminate()
        launchSignedIn()
        tile(photo).tap()
        let plainShare = element("viewerShareButton")
        XCTAssertTrue(plainShare.waitForExistence(timeout: 20), "the viewer has no share button — \(screenText())")
        plainShare.tap()

        saveToPhotos(answer: nil)
        waitSaved(count: 1, of: photo)
        XCTAssertEqual(param(downloads(of: photo)[0], "edited"), "false", "\(describe())")

        let toFiles = element("downloadToFilesButton")
        XCTAssertTrue(toFiles.waitForExistence(timeout: 20), "no Download to Files — \(screenText())")
        XCTAssertTrue(waitUntil(20) { toFiles.isEnabled }, "Download to Files stayed disabled")
        toFiles.tap()
        assertNoQuestion("on Download to Files")
        XCTAssertTrue(waitUntil(20) { self.downloads(of: self.photo).count == 2 }, "no second download — \(describe())")
        XCTAssertEqual(param(downloads(of: photo)[1], "edited"), "false", "\(describe())")
    }
}
