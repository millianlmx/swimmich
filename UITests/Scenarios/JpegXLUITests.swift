import XCTest

/// End-to-end scenarios for JPEG XL photos (lot L-05, B-9): a server that
/// generates its thumbnails, previews and originals as JPEG XL must show them in
/// the grids, the viewer and the offline library, and name what it saves `.jxl`.
///
/// It drives the real app against `immich_stub_jpeg_xl.py`, which serves REAL
/// JPEG XL files (`UITests/stubs/fixtures/jxl/`). The app is launched with
/// `-uiTestImageProbe YES`: every `AuthenticatedAsyncImage` then publishes what
/// it holds as its accessibility VALUE (`placeholder`, `failed`, `loaded <w>x<h>`,
/// plus `zoom=<s>` in the viewer). The pixel size is what proves WHICH file was
/// decoded (thumbnail 200×200, preview 1024×631, original 1600×1096) — a broken
/// tile and a decoded one are otherwise a screenshot apart.
///
/// Targets identifiers and the stub's data, never a localized label (the Albums
/// tab is the one English label, pinned with the language).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/jxl.uitest.log \
///         UITests/stubs/immich_stub_jpeg_xl.py JpegXLUITests --erase
///
/// The helpers are copied from `TagsHierarchyUITests` on purpose: one file per
/// feature, helpers included.
final class JpegXLUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-authServerURL", "()",
            "-uiTestImageProbe", "YES",
        ]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    private let jxlPhoto = "aaaaaaaa-1111-4111-8111-000000000001"
    private let pngPhoto = "aaaaaaaa-1111-4111-8111-000000000002"
    private let brokenPhoto = "aaaaaaaa-1111-4111-8111-000000000003"
    private let thumbOnlyPhoto = "aaaaaaaa-1111-4111-8111-000000000004"
    private let albumName = "JXL Album"

    private let thumbnailValue = "loaded 200x200"
    private let previewValue = "loaded 1024x631"
    private let originalValue = "loaded 1600x1096"

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-jxl-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-jxl-\(name).png")
    }

    /// One GET on the stub: the status and the body.
    @discardableResult
    private func get(_ path: String) -> (status: Int?, body: String) {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var body = ""
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return (status, body)
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

    /// A row of the "Me" hub, by identifier; scrolled into view first.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let dropped: Bool?
    }

    private func stubRequests() -> [StubRequest] {
        let body = get("/__requests").body
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)\($0.dropped == true ? " DROPPED" : "")" }
            .joined(separator: "\n")
    }

    // MARK: - The probe

    /// The probe value of `identifier`: `placeholder`, `failed`, `loaded <w>x<h>`…
    private func value(_ identifier: String) -> String? {
        let candidate = element(identifier)
        return candidate.exists ? (candidate.value as? String) : nil
    }

    /// Polls every 300 ms until the value of `identifier` starts with `prefix`.
    /// A failure quotes what was last read, the screen and the stub's log.
    @discardableResult
    private func waitForValue(_ identifier: String, prefix: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        repeat {
            last = value(identifier)
            if let last, last.hasPrefix(prefix) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("\(identifier) never started with “\(prefix)” — last read: \(last ?? "no element"); "
                + "\(screenText()); stub log:\n\(describe(stubRequests()))")
        return false
    }

    // MARK: - Navigation

    /// Reset, launch on a fresh session, walk onboarding, land on the timeline.
    private func launchSignedIn() {
        reset()
        setProvider("manual")
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
        XCTAssertTrue(tile(pngPhoto).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func openViewer(_ assetId: String) {
        let target = tile(assetId)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(assetId) — \(screenText())")
        target.tap()
        XCTAssertTrue(element("viewerImage_\(assetId)").waitForExistence(timeout: 20),
                      "the viewer never showed \(assetId) — \(screenText())")
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the viewer has no back button")
        back.tap()
        XCTAssertTrue(tile(pngPhoto).waitForExistence(timeout: 20), "the grid did not come back")
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    /// Selects the Albums tab and taps the tile `identifier` of its Library
    /// section, scrolling the Albums ScrollView only when it is not hittable.
    private func openAlbumsLibraryRow(_ identifier: String) {
        let tab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "the Albums tab is missing")
        tab.tap()
        let row = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(identifier) tile missing — \(screenText())")
        for _ in 0..<4 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        row.tap()
    }

    /// The Me hub → Preferences → "Load Full Quality" flipped → back to the timeline.
    private func enableLoadFullQuality() {
        openHub()
        let row = hubRow("preferencesRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Preferences row missing — \(screenText())")
        row.tap()
        let toggle = element("preferencesLoadOriginalToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Load Full Quality toggle is missing")
        let before = toggle.value as? String
        for _ in 0..<3 {
            // The element is the whole row: its own control sits at the trailing edge.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let deadline = Date().addingTimeInterval(4)
            while (toggle.value as? String) == before && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
            if (toggle.value as? String) != before { break }
        }
        XCTAssertNotEqual(toggle.value as? String, before, "Load Full Quality never flipped")
        // Back out of Preferences, then close the Me sheet.
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        app.swipeDown()
        XCTAssertTrue(tile(pngPhoto).waitForExistence(timeout: 20), "the timeline did not come back")
    }

    private func openAlbumsTab() {
        let tab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "the Albums tab is missing")
        tab.tap()
        XCTAssertTrue(tapAnyButton([albumName], timeout: 30),
                      "no card named \(albumName) — buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    private func openSearchAndType(_ text: String) {
        let tab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Search tab")
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field — \(screenText())")
        field.tap()
        field.typeText("\(text)\n")
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

    // MARK: - Scenarios

    func test_AC_15_gridAndViewerShowJpegXL() {
        launchSignedIn()

        XCTAssertTrue(waitForValue("assetTile_\(jxlPhoto)", prefix: thumbnailValue),
                      "the JPEG XL thumbnail never decoded in the grid")
        shot("ac15-grid")

        openViewer(jxlPhoto)
        XCTAssertTrue(waitForValue("viewerImage_\(jxlPhoto)", prefix: previewValue),
                      "the full-screen photo shows the thumbnail, not the decoded preview")
        XCTAssertFalse((value("viewerImage_\(jxlPhoto)") ?? "").hasPrefix(thumbnailValue))
        shot("ac15-viewer")
    }

    func test_AC_97_thumbnailDecodedInTimelineAlbumSearch() {
        launchSignedIn()

        // Timeline.
        waitForValue("assetTile_\(jxlPhoto)", prefix: thumbnailValue)
        waitForValue("assetTile_\(brokenPhoto)", prefix: "failed")

        // Album.
        openAlbumsTab()
        waitForValue("assetTile_\(jxlPhoto)", prefix: thumbnailValue)
        waitForValue("assetTile_\(brokenPhoto)", prefix: "failed")
        shot("ac97-album")

        // Search.
        openSearchAndType("jxl")
        waitForValue("assetTile_\(jxlPhoto)", prefix: thumbnailValue)
        waitForValue("assetTile_\(brokenPhoto)", prefix: "failed")
        shot("ac97-search")

        let thumbnails = stubRequests().filter {
            $0.method == "GET" && $0.path == "/api/assets/\(jxlPhoto)/thumbnail" && $0.params["size"] == "thumbnail"
        }
        XCTAssertFalse(thumbnails.isEmpty, "the app never asked for the thumbnail of the JPEG XL photo")
    }

    func test_AC_98_viewerDecodesPreviewThenOriginal() {
        launchSignedIn()

        // 1. Preview of the valid photo.
        openViewer(jxlPhoto)
        waitForValue("viewerImage_\(jxlPhoto)", prefix: previewValue)
        closeViewer()

        // 2. Negative control: a truncated preview never reads `loaded`.
        openViewer(brokenPhoto)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            XCTAssertFalse((value("viewerImage_\(brokenPhoto)") ?? "").hasPrefix("loaded"),
                           "a truncated JPEG XL preview was reported as decoded")
            Thread.sleep(forTimeInterval: 0.3)
        }
        let broken = value("viewerImage_\(brokenPhoto)") ?? ""
        XCTAssertTrue(broken.hasPrefix("placeholder") || broken.hasPrefix("failed"), "read “\(broken)”")
        closeViewer()

        // 3. The tier-0.5 trap: the grid's thumbnail is cached, the preview fails.
        waitForValue("assetTile_\(thumbOnlyPhoto)", prefix: thumbnailValue)
        openViewer(thumbOnlyPhoto)
        var readings: [String] = []
        let window = Date().addingTimeInterval(10)
        while Date() < window {
            if let reading = value("viewerImage_\(thumbOnlyPhoto)") { readings.append(reading) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(readings.isEmpty, "viewerImage_\(thumbOnlyPhoto) never existed")
        XCTAssertFalse(readings.contains { $0.hasPrefix("loaded") },
                       "the cached thumbnail was reported as the decoded preview: \(readings)")
        XCTAssertTrue(readings.last?.hasPrefix("placeholder") == true,
                      "a failed preview over a shown thumbnail must read placeholder, read \(readings.last ?? "nothing")")
        XCTAssertTrue(stubRequests().contains {
            $0.path == "/api/assets/\(thumbOnlyPhoto)/thumbnail" && $0.params["size"] == "preview"
        }, "the preview of \(thumbOnlyPhoto) was never requested — the failure did not happen in the window")
        closeViewer()

        // 4. "Load Full Quality" on.
        enableLoadFullQuality()

        // 5. The original, not the thumbnail or the preview.
        openViewer(jxlPhoto)
        waitForValue("viewerImage_\(jxlPhoto)", prefix: originalValue)
        shot("ac98-original")

        // 6. Wire order: the preview first, then the original.
        let log = stubRequests()
        let lastPreview = log.lastIndex {
            $0.path == "/api/assets/\(jxlPhoto)/thumbnail" && $0.params["size"] == "preview"
        }
        let firstOriginal = log.firstIndex { $0.path == "/api/assets/\(jxlPhoto)/original" }
        XCTAssertNotNil(lastPreview, "no preview request in the log:\n\(describe(log))")
        XCTAssertNotNil(firstOriginal, "no original request in the log:\n\(describe(log))")
        if let lastPreview, let firstOriginal {
            XCTAssertLessThan(lastPreview, firstOriginal, "the original was requested before the preview")
        }
    }

    func test_AC_99_zoomKeepsJpegXLDecoded() {
        launchSignedIn()
        openViewer(jxlPhoto)
        let id = "viewerImage_\(jxlPhoto)"
        waitForValue(id, prefix: previewValue)

        // The size (1600×1096) arrives with the record: native ≈ 1.36 sits under
        // the 2x floor, so the ceiling is 2.00 (L-06). Pinch only once it is in.
        let ceilingDeadline = Date().addingTimeInterval(15)
        while !(value(id) ?? "").contains("max=2.00") && Date() < ceilingDeadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue((value(id) ?? "").contains("max=2.00"), "the zoom ceiling never became 2.00 — read \(value(id) ?? "nothing")")
        element(id).pinch(withScale: 2.5, velocity: 3)
        let deadline = Date().addingTimeInterval(10)
        var zoom = 0.0
        while Date() < deadline {
            if let read = value(id), read.hasPrefix("\(previewValue) zoom="),
               let parsed = Double(read.dropFirst("\(previewValue) zoom=".count).prefix { $0 != " " }) {
                zoom = parsed
                if zoom >= 1.5 { break }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertGreaterThanOrEqual(zoom, 1.5, "the pinch never zoomed — read \(value(id) ?? "nothing")")
        shot("ac99-pinched")

        element(id).doubleTap()
        waitForValue(id, prefix: "\(previewValue) zoom=1.00")

        element(id).doubleTap()
        waitForValue(id, prefix: "\(previewValue) zoom=2.00")

        element(id).doubleTap()
        waitForValue(id, prefix: "\(previewValue) zoom=1.00")
    }

    func test_AC_100_offlineCopyDecodedWithServerDown() {
        launchSignedIn()

        // 1. Save the original for offline.
        openViewer(jxlPhoto)
        waitForValue("viewerImage_\(jxlPhoto)", prefix: previewValue)
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "no share button")
        share.tap()
        let offline = element("downloadForOfflineButton")
        for _ in 0..<4 where !offline.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(offline.exists, "no offline button on the share sheet — \(screenText())")
        offline.tap()
        XCTAssertTrue(element("offlineAvailableRow").waitForExistence(timeout: 60),
                      "the copy never became available offline — \(screenText())")

        // 2. Close the sheet and the viewer, then take the server down.
        element("offlineAvailableRow").swipeDown()
        sleep(1)
        if element("viewerBackButton").waitForExistence(timeout: 5) { element("viewerBackButton").tap() }
        XCTAssertTrue(tile(pngPhoto).waitForExistence(timeout: 20), "the grid did not come back")
        let down = get("/control/unreachable?on=1")
        XCTAssertEqual(down.status, 200)
        XCTAssertTrue(down.body.contains("\"unreachable\": true"), "unexpected control answer: \(down.body)")
        let noted = stubRequests().count

        // 3. The offline library reads the copy from disk.
        openAlbumsLibraryRow("offlineStorageRow")
        XCTAssertTrue(element("offlineAsset_\(jxlPhoto)").waitForExistence(timeout: 20),
                      "the offline library does not list the photo — \(screenText())")
        waitForValue("offlineAsset_\(jxlPhoto)", prefix: originalValue)
        shot("ac100-offline-grid")

        // 4. …and so does the viewer.
        element("offlineAsset_\(jxlPhoto)").tap()
        waitForValue("viewerImage_\(jxlPhoto)", prefix: originalValue)
        shot("ac100-offline-viewer")

        // 5. The server really was down, and the original was not fetched again.
        let after = Array(stubRequests().dropFirst(noted))
        XCTAssertTrue(after.contains { $0.path.hasPrefix("/api/") && $0.dropped == true },
                      "no request reached the downed server — the scenario proves nothing:\n\(describe(after))")
        XCTAssertFalse(after.contains { $0.path == "/api/assets/\(jxlPhoto)/original" },
                       "the original was downloaded again instead of read from disk:\n\(describe(after))")
    }

    func test_AC_103_pngTilesBesideJpegXL() {
        launchSignedIn()
        waitForValue("assetTile_\(pngPhoto)", prefix: "loaded 8x8")
        waitForValue("assetTile_\(jxlPhoto)", prefix: thumbnailValue)
    }

    func test_AC_105_saveJpegXLToPhotos() {
        launchSignedIn()
        openViewer(jxlPhoto)
        waitForValue("viewerImage_\(jxlPhoto)", prefix: previewValue)
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "no share button")
        share.tap()

        let save = element("saveToPhotosButton")
        for _ in 0..<4 where !save.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(save.exists, "no Save to Photos button — \(screenText())")
        XCTAssertEqual(save.value as? String, "idle", "the button must start idle")

        save.tap()
        allowPhotosIfAsked()
        let saved = waitUntilSaved(save)
        let error = element("saveSectionError")
        XCTAssertFalse(error.exists,
                       "Photos refused the JPEG XL original: \(error.exists ? error.label : "") — blocking finding (decision #6)")
        XCTAssertTrue(saved, "the save never finished — value \(save.value as? String ?? "nil")")
        shot("ac105-saved")
    }

    private func waitUntilSaved(_ button: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if (button.value as? String) == "saved" { return true }
            if element("saveSectionError").exists { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
