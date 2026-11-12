import XCTest

/// End-to-end scenarios for the editor's server-side edits (lot L-21, editor part): crop, quarter turn
/// and mirror are saved as non-destructive edits (`PUT /api/assets/{id}/edits`) with no copy, removed with
/// `DELETE`, and an old server keeps the copy.
///
/// It drives the real app against `immich_stub_asset_edits.py`, launched with `-assetEditsServerSave YES`
/// (the server mode is off in production until the display of edited photos ships) and
/// `-uiTestImageProbe YES` (the save-mode line and the viewer's banner expose their value). It asserts on
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

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let contained = app.buttons.containing(predicate).firstMatch
        let direct = app.buttons.matching(predicate).firstMatch
        for candidate in [direct, contained] where candidate.waitForExistence(timeout: timeout) {
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
            if button.waitForExistence(timeout: 6) { button.tap(); return }
        }
        for label in ["Continue", "Continuer"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap(); return }
        }
    }

    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch,
                          safari.buttons.matching(predicate).firstMatch] {
            if candidate.waitForExistence(timeout: timeout) { candidate.tap(); return true }
        }
        return false
    }

    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != stub { field.typeText(stub) }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("not-on-login-screen")
            XCTFail("Login screen did not appear — \(screenText())")
        }
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

    /// Reset, arm the stub with `config` (a query string for `/api/__edits/config`), launch with both
    /// switches on, sign in if the device is fresh, and wait for the first tile.
    private func launchSignedIn(config: String = "") {
        reset()
        setProvider("manual")
        if !config.isEmpty { get("/api/__edits/config?\(config)") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-uiTestImageProbe", "YES", "-assetEditsServerSave", "YES"]
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
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

        openEditor()
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
}
