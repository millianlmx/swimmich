import XCTest

/// End-to-end scenarios for shared links that hide the photos' metadata: the server
/// then sends a reduced form (no owner, dates, favourite, EXIF), and the app must
/// still open the link, show the grid, open the viewer and keep the zoom at 4x —
/// while a link that exposes its metadata keeps its native-pixel zoom (L-06).
///
/// It drives the real app against `immich_stub_shared_link_masked.py`, whose links
/// (`masked-v3`, `masked-badges`, `masked-locked`, `masked-album`, `masked-v2`,
/// `masked-v2-album`, `exposed-hd`) are pasted in the Shared tab's link viewer. The
/// app is launched with `-uiTestImageProbe YES`: a thumbnail then publishes
/// `loaded …` as its accessibility VALUE once decoded, and the viewer image
/// `loaded <w>x<h> zoom=<s> max=<m> off=<x>,<y> fit=<w>x<h>`.
///
/// "Without error" means: the link's title is on screen and none of the failure
/// state, the dead-link state, the inline message or the password prompt is.
///
/// Targets identifiers, the probe and the stub's data (`1:05`, `SECRET-`, …), never a
/// localized label.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/x.log \
///         UITests/stubs/immich_stub_shared_link_masked.py SharedLinkMaskedMetadataUITests --erase
///
/// The helpers are copied from `ZoomLimitUITests` and `ImmichRenderScreenshots` on
/// purpose: one file per feature, helpers included.
final class SharedLinkMaskedMetadataUITests: XCTestCase {

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-masked-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-masked-\(name).png")
    }

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

    // MARK: - The stub's data

    /// `{slug: [asset ids in grid order]}` — the ids change on every `/__reset`.
    private func maskedIds() -> [String: [String]] {
        let raw = get("/stub/masked-links").body
        let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: [String]]
        XCTAssertNotNil(parsed, "the stub did not answer /stub/masked-links — is it the masked stub? \(raw)")
        return parsed ?? [:]
    }

    private func ids(_ slug: String, _ all: [String: [String]]) -> [String] {
        let found = all[slug] ?? []
        XCTAssertFalse(found.isEmpty, "the stub has no link \(slug)")
        return found
    }

    /// The stub's request log (`GET /__requests`).
    private func requests() -> [[String: Any]] {
        let raw = get("/__requests").body
        return ((try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]) ?? []
    }

    // MARK: - Navigation

    /// Reset, launch on a fresh session, walk onboarding, land on the authenticated shell.
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
    }

    /// The "Shared" tab, whichever language the catalog resolves it in.
    private func openSharedTab() {
        for label in ["Shared", "Partagé"] {
            let tab = app.tabBars.buttons[label].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.tap()
                return
            }
        }
        app.tabBars.buttons.element(boundBy: 3).tap()
    }

    private func openSharedLinkViewer() {
        let entry = app.buttons["openSharedLinkViewer"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no entry point in the Shared toolbar")
        entry.tap()
        XCTAssertTrue(app.textFields["sharedLinkViewerField"].waitForExistence(timeout: 15),
                      "the viewer did not present")
    }

    /// Types a received link into the viewer's field and opens it.
    private func pasteSharedLink(_ link: String) {
        let field = app.textFields["sharedLinkViewerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no link field")
        field.tap()
        field.typeText(link)
        app.buttons["openSharedLink"].tap()
        sleep(3)
    }

    /// Opens the link `slug` of the stub from the Shared tab.
    private func openLink(_ slug: String) {
        openSharedTab()
        openSharedLinkViewer()
        pasteSharedLink("\(stub)/s/\(slug)")
    }

    /// The link is open: its title is there and no error state is.
    private func assertOpenedWithoutError(_ context: String) {
        XCTAssertTrue(element("sharedLinkViewerTitle").waitForExistence(timeout: 30),
                      "\(context): the link never opened — \(screenText())")
        for identifier in ["sharedLinkViewerFailure", "sharedLinkViewerDeadLink",
                           "sharedLinkViewerMessage", "sharedLinkViewerPassword"] {
            XCTAssertFalse(element(identifier).exists, "\(context): \(identifier) is on screen — \(screenText())")
        }
    }

    // MARK: - Grid

    /// The cell of a photo: its image layer, or the cell's own identifier when that
    /// one replaced it.
    private func cell(_ assetId: String) -> XCUIElement {
        let image = element("assetTile_\(assetId)")
        return image.exists ? image : element("sharedLinkAsset_\(assetId)")
    }

    private func thumbnailIsLoaded(_ assetId: String) -> Bool {
        for identifier in ["assetTile_\(assetId)", "sharedLinkAsset_\(assetId)"] {
            let candidate = element(identifier)
            if candidate.exists, let value = candidate.value as? String, value.hasPrefix("loaded") { return true }
        }
        return false
    }

    private func waitForLoadedThumbnails(_ assetIds: [String], timeout: TimeInterval = 40) {
        let deadline = Date().addingTimeInterval(timeout)
        var pending = assetIds
        repeat {
            pending = assetIds.filter { !thumbnailIsLoaded($0) }
            if pending.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("thumbnails never loaded: \(pending) — \(screenText())")
    }

    private func waitForLabel(containing text: String, timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// Every label and value on screen, but the probes (`loaded …`), which are numbers.
    private func onScreenStrings() -> [String] {
        var strings: [String] = []
        for candidate in app.descendants(matching: .any).allElementsBoundByIndex where candidate.exists {
            strings.append(candidate.label)
            if let value = candidate.value as? String, !value.hasPrefix("loaded") { strings.append(value) }
        }
        return strings
    }

    private func assertNothingMaskedOnScreen(_ context: String) {
        let forbidden = ["SECRET-", "owner-secret", "Lisbon", "Portugal", "2019", "360°", "Stub User"]
        let strings = onScreenStrings()
        for word in forbidden {
            XCTAssertFalse(strings.contains { $0.contains(word) },
                           "\(context): `\(word)` is on screen — \(strings.filter { $0.contains(word) })")
        }
        XCTAssertFalse(element("favoriteBadge").exists, "\(context): a favourite badge is on screen")
    }

    // MARK: - Viewer

    private func openPager(_ assetId: String) {
        let target = cell(assetId)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no cell for \(assetId) — \(screenText())")
        target.tap()
        XCTAssertTrue(element("closeSharedLinkPager").waitForExistence(timeout: 20),
                      "the link's viewer never opened — \(screenText())")
        XCTAssertTrue(element("viewerImage_\(assetId)").waitForExistence(timeout: 20),
                      "the viewer never showed \(assetId) — \(screenText())")
        waitForProbe(assetId) { _ in true }
    }

    private func closePager() {
        let close = element("closeSharedLinkPager")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the viewer has no close button")
        close.tap()
        XCTAssertTrue(element("sharedLinkViewerTitle").waitForExistence(timeout: 20), "the grid did not come back")
    }

    // MARK: - The probe

    /// What the viewer image publishes: `loaded 8x8 zoom=1.00 max=4.00 off=0.0,0.0 fit=393.0x393.0`.
    private struct Probe: CustomStringConvertible {
        let zoom: Double
        let max: Double
        let off: CGSize
        let fit: CGSize
        let raw: String
        var description: String { raw }
    }

    private func probe(_ assetId: String) -> Probe? {
        let candidate = element("viewerImage_\(assetId)")
        guard candidate.exists, let raw = candidate.value as? String,
              raw.hasPrefix("loaded"),
              let match = raw.range(
                of: #"zoom=(-?[0-9.]+) max=(-?[0-9.]+) off=(-?[0-9.]+),(-?[0-9.]+) fit=([0-9.]+)x([0-9.]+)"#,
                options: .regularExpression
              )
        else { return nil }
        let numbers = raw[match]
            .components(separatedBy: CharacterSet(charactersIn: "= ,x").union(.letters))
            .compactMap(Double.init)
        guard numbers.count == 6 else { return nil }
        return Probe(
            zoom: numbers[0], max: numbers[1],
            off: CGSize(width: numbers[2], height: numbers[3]),
            fit: CGSize(width: numbers[4], height: numbers[5]),
            raw: raw
        )
    }

    /// Polls every 300 ms until `condition` holds for the probe of `assetId`.
    @discardableResult
    private func waitForProbe(_ assetId: String, timeout: TimeInterval = 30,
                              _ condition: (Probe) -> Bool) -> Probe? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Probe?
        repeat {
            last = probe(assetId)
            if let last, condition(last) { return last }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("the probe of \(assetId) never met the condition — last read: \(last?.raw ?? "none"); \(screenText())")
        return nil
    }

    // MARK: - Geometry

    private var windowSize: CGSize { app.windows.firstMatch.frame.size }
    private var screenScale: Double { Double(XCUIScreen.main.screenshot().image.scale) }

    /// Native scale of a photo whose displayed width is `pixels` wide, fitted to
    /// the window width (the stub serves a square image: it fits the width).
    private func nativeScale(pixels: Double) -> Double {
        pixels / (Double(windowSize.width) * screenScale)
    }

    /// Pinches until the scale stops moving between two reads.
    @discardableResult
    private func pinchToMax(_ assetId: String) -> Probe {
        var previous = -1.0
        var last = probe(assetId)
        for _ in 0..<8 {
            element("viewerImage_\(assetId)").pinch(withScale: 3, velocity: 5)
            Thread.sleep(forTimeInterval: 0.8)
            last = probe(assetId)
            if let zoom = last?.zoom, abs(zoom - previous) < 0.005 { break }
            previous = last?.zoom ?? previous
        }
        return last ?? Probe(zoom: 0, max: 0, off: .zero, fit: .zero, raw: "no probe")
    }

    private func assertStopsAtFour(_ reached: Probe, _ context: String) {
        XCTAssertEqual(reached.zoom, 4.0, accuracy: 0.005, "\(context): zoom — \(reached)")
        XCTAssertEqual(reached.max, 4.0, accuracy: 0.005, "\(context): max — \(reached)")
    }

    // MARK: - AC-115

    func test_AC_115_maskedIndividualLinkOpens() {
        launchSignedIn()
        let photos = ids("masked-v3", maskedIds())
        openLink("masked-v3")
        assertOpenedWithoutError("masked-v3")
        waitForLoadedThumbnails(photos)
        XCTAssertEqual(photos.count, 2)
        shot("ac115-grid")
    }

    // MARK: - AC-116

    func test_AC_116_maskedProtectedLinkOpensAfterPassword() {
        launchSignedIn()
        let photos = ids("masked-locked", maskedIds())
        openLink("masked-locked")

        let passwordField = app.secureTextFields["sharedLinkViewerPassword"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 20),
                      "the protected link did not stop at the prompt — \(screenText())")
        shot("ac116-prompt")
        passwordField.tap()
        passwordField.typeText("hunter2")
        app.buttons["submitSharedLinkPassword"].tap()

        assertOpenedWithoutError("masked-locked after the password")
        waitForLoadedThumbnails(photos)
        let logins = requests().filter { ($0["method"] as? String) == "POST"
            && ($0["path"] as? String) == "/api/shared-links/login" }
        XCTAssertFalse(logins.isEmpty, "the app never posted /api/shared-links/login")
        shot("ac116-grid")
    }

    // MARK: - AC-117

    func test_AC_117_maskedVideoShowsItsDuration() {
        launchSignedIn()
        let photos = ids("masked-badges", maskedIds())
        openLink("masked-badges")
        assertOpenedWithoutError("masked-badges")
        waitForLoadedThumbnails(photos)
        XCTAssertTrue(waitForLabel(containing: "1:05"), "no video duration `1:05` on screen — \(screenText())")
        shot("ac117-badges")
    }

    // MARK: - AC-118

    func test_AC_118_maskedAlbumListsEveryPage() {
        launchSignedIn()
        let photos = ids("masked-album", maskedIds())
        XCTAssertEqual(photos.count, 6)
        openLink("masked-album")
        assertOpenedWithoutError("masked-album")
        XCTAssertTrue(cell(photos[0]).waitForExistence(timeout: 30), "the first page never showed — \(screenText())")

        for _ in 0..<6 where !photos.allSatisfy({ cell($0).exists }) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        for photo in photos {
            XCTAssertTrue(cell(photo).waitForExistence(timeout: 20), "photo \(photo) is missing — \(screenText())")
        }
        assertOpenedWithoutError("masked-album at the bottom")
        shot("ac118-bottom")

        let searches = requests().filter { ($0["path"] as? String) == "/api/search/metadata" }
        let pages = searches.compactMap { $0["page"] as? Int }
        XCTAssertEqual(pages.filter { $0 == 1 }.count, 1, "page 1 was not searched exactly once — \(pages)")
        XCTAssertEqual(pages.filter { $0 == 2 }.count, 1, "page 2 was not searched exactly once — \(pages)")
    }

    // MARK: - AC-119

    func test_AC_119_viewerOpensAndSwipes() {
        launchSignedIn()
        let photos = ids("masked-v3", maskedIds())
        openLink("masked-v3")
        assertOpenedWithoutError("masked-v3")
        waitForLoadedThumbnails(photos)

        openPager(photos[0])
        XCTAssertTrue((element("viewerImage_\(photos[0])").value as? String)?.hasPrefix("loaded") == true,
                      "the first photo is not loaded")
        shot("ac119-first")

        element("viewerImage_\(photos[0])").swipeLeft()
        XCTAssertTrue(element("viewerImage_\(photos[1])").waitForExistence(timeout: 20),
                      "the swipe did not reach the next photo — \(screenText())")
        waitForProbe(photos[1]) { _ in true }
        shot("ac119-second")

        closePager()
        assertOpenedWithoutError("masked-v3 after the viewer")
        waitForLoadedThumbnails(photos)
    }

    // MARK: - AC-120

    func test_AC_120_maskedZoomStopsAtFour() {
        launchSignedIn()
        let photos = ids("masked-v3", maskedIds())
        let first = photos[0]
        openLink("masked-v3")
        assertOpenedWithoutError("masked-v3")
        waitForLoadedThumbnails(photos)
        openPager(first)

        assertStopsAtFour(pinchToMax(first), "after the pinch")
        shot("ac120-max")

        let image = "viewerImage_\(first)"
        element(image).doubleTap()
        waitForProbe(first) { abs($0.zoom - 1) < 0.005 }
        element(image).doubleTap()
        waitForProbe(first) { abs($0.zoom - 3) < 0.005 }
        element(image).doubleTap()
        waitForProbe(first) { abs($0.zoom - 1) < 0.005 }

        closePager()
        assertOpenedWithoutError("masked-v3 after the zoom")
    }

    // MARK: - AC-121

    func test_AC_121_noMaskedInformationOnScreen() {
        launchSignedIn()
        let photos = ids("masked-v2-album", maskedIds())
        XCTAssertEqual(photos.count, 2)
        openLink("masked-v2-album")
        assertOpenedWithoutError("masked-v2-album")
        waitForLoadedThumbnails(photos)
        shot("ac121-grid")
        assertNothingMaskedOnScreen("grid")

        openPager(photos[0])
        waitForProbe(photos[0]) { abs($0.max - 4) < 0.005 }
        shot("ac121-viewer")
        assertNothingMaskedOnScreen("viewer")
        XCTAssertEqual(probe(photos[0])?.max ?? 0, 4.0, accuracy: 0.005, "the viewer's ceiling is not 4x")
    }

    // MARK: - AC-123

    func test_AC_123_exposedLinkReachesNativeScale() {
        launchSignedIn()
        let photos = ids("exposed-hd", maskedIds())
        openLink("exposed-hd")
        assertOpenedWithoutError("exposed-hd")
        waitForLoadedThumbnails(photos)
        openPager(photos[0])

        let expected = nativeScale(pixels: 8000)
        waitForProbe(photos[0]) { abs($0.max - expected) < 0.02 }
        let reached = pinchToMax(photos[0])
        shot("ac123-native")
        XCTAssertEqual(reached.zoom, expected, accuracy: 0.02, "not the native scale — \(reached)")
        XCTAssertEqual(reached.max, expected, accuracy: 0.02, "not the native ceiling — \(reached)")
    }

    // MARK: - AC-124

    func test_AC_124_v2LinksOpenWithoutError() {
        launchSignedIn()
        let all = maskedIds()
        let individual = ids("masked-v2", all)
        let album = ids("masked-v2-album", all)

        openLink("masked-v2")
        assertOpenedWithoutError("masked-v2")
        waitForLoadedThumbnails(individual)
        XCTAssertTrue(waitForLabel(containing: "1:05"), "no video duration `1:05` on screen — \(screenText())")
        shot("ac124-individual")

        openPager(individual[1])
        assertStopsAtFour(pinchToMax(individual[1]), "v2 photo")
        shot("ac124-zoom")
        closePager()

        let closeViewer = element("closeSharedLinkViewer")
        XCTAssertTrue(closeViewer.waitForExistence(timeout: 10), "the link viewer has no close button")
        closeViewer.tap()

        openLink("masked-v2-album")
        assertOpenedWithoutError("masked-v2-album")
        for photo in album {
            XCTAssertTrue(cell(photo).waitForExistence(timeout: 30), "photo \(photo) is missing — \(screenText())")
        }
        shot("ac124-album")
    }
}
