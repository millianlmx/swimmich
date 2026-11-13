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

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    /// The first of the stub's six timeline photos: 4000×3000, EXIF orientation 1.
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

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

    private func tile(_ assetId: String) -> XCUIElement { element("assetTile_\(assetId)") }

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

    private func describe() -> String {
        journal().map { "\($0["method"] ?? "") \($0["path"] ?? "") \($0["params"] ?? "") \($0["body"] ?? "")" }
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
    private func launchSignedIn(config: String = "") {
        reset()
        setProvider("manual")
        if !config.isEmpty { get("/api/__edits/config?\(config)") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-uiTestImageProbe", "YES"] + sessionArguments()
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

    /// The edited version reaches the viewer's requests once the server has regenerated it, with
    /// `edited=true` on every thumbnail, and the original comes back after the removal.
    func test_AC_39_editedVersionShownThenTheOriginalComesBack() {
        launchSignedIn()
        openEditor()
        tapEditor("ratioButton.fourByThree")
        tapEditor("rotate90CWButton")
        tapEditor("mirrorHorizontalButton")
        save()

        XCTAssertTrue(waitUntil(20) { !self.editsEntries("PUT").isEmpty }, "no PUT /edits — \(describe())")
        XCTAssertTrue(uploads().isEmpty, "no new asset: the edits are saved on the photo — \(describe())")
        XCTAssertTrue(waitUntil(15) { !self.thumbnails(generation: "-e1", size: "preview").isEmpty },
                      "the viewer never asked for the regenerated preview — \(describe())")
        for entry in thumbnails() {
            XCTAssertEqual(param(entry, "edited"), "true", "every thumbnail asks the edited rendering — \(describe())")
        }

        reopenEditorFromViewer()
        tapEditor("revertToOriginalButton")
        save()
        XCTAssertTrue(waitUntil(20) { !self.editsEntries("DELETE").isEmpty }, "no DELETE — \(describe())")
        XCTAssertTrue(waitUntil(15) { !self.thumbnails(generation: "-e2", size: "preview").isEmpty },
                      "the original never came back to the viewer — \(describe())")
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
}
