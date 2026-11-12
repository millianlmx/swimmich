import UIKit
import XCTest

/// End-to-end proof of the Reduce Motion setting (lot L-18, B-22, AC-33 and
/// AC-162…AC-171): with the setting on, nothing the app shows moves — a photo
/// opens and closes by a fade, a tile at the edge of the screen keeps its size,
/// the album header does not stretch, the grid changes density without a
/// transition, the shimmer of a waiting tile stands still, and every full-screen
/// presentation stays where it is. With the setting off, the same gestures still
/// move (AC-169), and the app follows the system setting without a relaunch
/// (AC-170).
///
/// "No movement" is read on the accessibility FRAME of an element, sampled
/// twelve times, 40 ms apart (`sampleFrames`): every sample has the size of the
/// last one (1 pt), and an origin equal to the first sample's or to the last
/// one's — never one in between.
///
/// The scenarios target identifiers and the stub's data, never a localized label
/// (the language is pinned to English). Every test launches with
/// `-uiTestReduceMotion YES`, except AC-169 and AC-170, which run on the
/// system's own setting. Run one method at a time with the launcher:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/reduce-motion-<méthode>.log \
///         UITests/stubs/immich_stub_reduce_motion.py ReduceMotionUITests/<méthode> --erase
///
/// Helpers are copied from `ViewerZoomUITests` and `JpegXLUITests` on purpose:
/// one file per feature, helpers included.
@MainActor
final class ReduceMotionUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // MARK: - The stub's data (see `immich_stub_reduce_motion.py`)

    /// The photos of the timeline are numbered 1…90, three a day, newest first.
    private func photo(_ n: Int) -> String { String(format: "aaaaaaaa-1111-4111-8111-%012d", n) }
    private let album = "22222222-2222-4222-8222-000000001818"
    private let albumPhoto = "a1b2c3d4-1818-4818-8818-000000000001"
    private let newerMemory = "eeeeeeee-1818-4818-8818-000000000002"
    private let olderMemory = "eeeeeeee-1818-4818-8818-000000000001"
    private let trashedPhoto = "cccccccc-1818-4818-8818-000000000001"
    private let sharedKey = "reduce-motion-shared-key-1818"
    private let sharedPhoto = "ffffffff-1818-4818-8818-000000000001"

    /// AC-169 and AC-170 run on the system's setting; every other test forces it.
    private var forcesReduceMotion: Bool {
        !(name.contains("test_AC_169") || name.contains("test_AC_170"))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-authServerURL", "()",
            "-uiTestMemoryPlaybackProbe", "YES",
            "-uiTestMemoryAutoplayOff", "YES",
        ]
        if forcesReduceMotion { app.launchArguments += ["-uiTestReduceMotion", "YES"] }
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        // AC-170 flips a SYSTEM setting: leave the simulator as it was found.
        if name.contains("test_AC_170") { setSystemReduceMotion(false) }
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

    @discardableResult
    private func get(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return body
    }

    private func screenText() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
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
        if !onLogin { XCTFail("Login screen did not appear — \(screenText())") }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement { element("assetTile_\(assetId)") }

    private var window: XCUIElement { app.windows.firstMatch }

    // MARK: - Navigation

    /// Reset the stub (`slow` delays every thumbnail by 3 s), launch on a fresh
    /// session, walk onboarding, land on the timeline.
    private func launchSignedIn(slow: Bool = false) {
        if app.state != .notRunning { app.terminate() }
        get(slow ? "/__reset?slow=1" : "/__reset")
        get("/__provider?mode=manual")
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        waitForTimeline()
    }

    private func waitForTimeline() {
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 5) { whatsNewDone.tap() }
        XCTAssertTrue(tile(photo(1)).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func showTimeline() {
        app.tabBars.buttons["Photos"].firstMatch.tap()
        XCTAssertTrue(tile(photo(1)).waitForExistence(timeout: 20), "the timeline did not come back — \(screenText())")
    }

    private func openMemoriesTab() {
        for label in ["Memories", "Souvenirs"] {
            let tab = app.tabBars.buttons[label].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.tap()
                return
            }
        }
        app.tabBars.buttons.element(boundBy: 1).tap()
    }

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

    /// Albums tab → the album's card → the album screen, header image on screen.
    private func openAlbum() {
        let tab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "the Albums tab is missing")
        tab.tap()
        if !element("albumHeroTitle").exists {
            let card = element("albumCard_\(album)")
            XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card — \(screenText())")
            card.tap()
        }
        XCTAssertTrue(element("albumHeroImage").waitForExistence(timeout: 20),
                      "the album header image never rendered — \(screenText())")
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    private func dragDown(_ distance: CGFloat, duration: TimeInterval = 0.4) {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: duration, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
    }

    // MARK: - Sampling

    /// The frame of `element`, `count` times, `interval` seconds apart. A sample
    /// taken while the element is not in the tree (a closing presentation that is
    /// already gone) is skipped, not read as an empty frame.
    private func sampleFrames(of element: XCUIElement, count: Int = 12, interval: TimeInterval = 0.04) -> [CGRect] {
        var frames: [CGRect] = []
        for index in 0..<count {
            if element.exists { frames.append(element.frame) }
            if index < count - 1 { Thread.sleep(forTimeInterval: interval) }
        }
        return frames
    }

    private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Nothing moved: every sample has the size of the last one (1 pt) and an
    /// origin equal to the first's or to the last's (1 pt) — never in between.
    private func assertNoMovement(_ frames: [CGRect], _ what: String, requireSamples: Bool = true,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let initial = frames.first, let final = frames.last else {
            if requireSamples { XCTFail("\(what): the element was never sampled", file: file, line: line) }
            return
        }
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.width, final.width, accuracy: 1, "\(what), sample \(i): the width changed — \(frames)", file: file, line: line)
            XCTAssertEqual(frame.height, final.height, accuracy: 1, "\(what), sample \(i): the height changed — \(frames)", file: file, line: line)
            let atInitial = abs(frame.minX - initial.minX) <= 1 && abs(frame.minY - initial.minY) <= 1
            let atFinal = abs(frame.minX - final.minX) <= 1 && abs(frame.minY - final.minY) <= 1
            XCTAssertTrue(atInitial || atFinal, "\(what), sample \(i): the origin is between its start and its end — \(frames)", file: file, line: line)
        }
    }

    /// A presentation's root: its origin never leaves `origin` (the window's
    /// corner), or — when the root has no fixed place — its final origin.
    private func assertRootStays(_ frames: [CGRect], at origin: CGPoint?, _ what: String,
                                 requireSamples: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        guard let final = frames.last else {
            if requireSamples { XCTFail("\(what): the root was never sampled", file: file, line: line) }
            return
        }
        let wanted = origin ?? final.origin
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.minX, wanted.x, accuracy: 0.5, "\(what), sample \(i): the root moved horizontally — \(frames)", file: file, line: line)
            XCTAssertEqual(frame.minY, wanted.y, accuracy: 0.5, "\(what), sample \(i): the root moved vertically — \(frames)", file: file, line: line)
        }
    }

    // MARK: - Tiles on screen

    private func visibleTiles() -> [(id: String, frame: CGRect)] {
        let bounds = window.frame
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "assetTile_"))
        return query.allElementsBoundByIndex.compactMap { candidate in
            let frame = candidate.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(bounds) else { return nil }
            return (candidate.identifier, frame)
        }
    }

    /// A tile entirely inside the window, the closest to its middle.
    private func centeredTile() -> (id: String, frame: CGRect)? {
        let bounds = window.frame
        return visibleTiles()
            .filter { bounds.contains($0.frame) }
            .min { abs($0.frame.midY - bounds.midY) < abs($1.frame.midY - bounds.midY) }
    }

    /// The number of tiles on the first full row of the grid.
    private func firstRowColumnCount() -> Int {
        let bounds = window.frame
        let inside = visibleTiles().filter { $0.frame.minY >= bounds.minY && $0.frame.maxY <= bounds.maxY }
        guard let top = inside.map({ $0.frame.minY }).min() else { return 0 }
        return inside.filter { abs($0.frame.minY - top) <= 2 }.count
    }

    /// Scrolls the grid by small drags until a tile is half outside the window
    /// (30–70 % of it visible), then returns its frame and a centered tile's.
    private func edgeAndCenterFrames() -> (edge: CGRect, center: CGRect)? {
        let bounds = window.frame
        for _ in 0..<16 {
            let tiles = visibleTiles()
            let half = tiles.first { entry in
                let shown = entry.frame.intersection(bounds)
                let fraction = (shown.isNull ? 0 : shown.height) / entry.frame.height
                return fraction >= 0.3 && fraction <= 0.7
            }
            if let half, let center = centeredTile() { return (half.frame, center.frame) }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -40)),
                        withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTFail("no tile ever stood half outside the window — \(visibleTiles().map { $0.frame })")
        return nil
    }

    // MARK: - Viewer

    /// Taps the tile of `id` and samples the viewer's image as it opens.
    private func openViewerSampling(_ id: String) -> (tile: CGRect, frames: [CGRect]) {
        let target = tile(id)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(id) — \(screenText())")
        let tileFrame = target.frame
        target.tap()
        let image = element("viewerImage_\(id)")
        XCTAssertTrue(image.waitForExistence(timeout: 20), "the viewer never opened on \(id) — \(screenText())")
        return (tileFrame, sampleFrames(of: image))
    }

    /// Taps the back button and samples the viewer's image as it closes.
    private func closeViewerSampling(_ id: String) -> [CGRect] {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the viewer has no back button")
        let image = element("viewerImage_\(id)")
        back.tap()
        return sampleFrames(of: image)
    }

    private func waitForViewerGone(_ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: element("viewerBackButton"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, message)
    }

    /// True when the first sample of an opening is nearer the thumbnail than the
    /// final frame — the photo grows out of its tile.
    private func opensFromThumbnail(_ opening: (tile: CGRect, frames: [CGRect])) -> Bool {
        guard let first = opening.frames.first, let last = opening.frames.last else { return false }
        return abs(first.width - opening.tile.width) < abs(first.width - last.width)
    }

    // MARK: - AC-33

    /// AC-33: the timeline scroll, a photo's open and close, the density pinch and
    /// a memory's opening — none of them moves.
    func test_AC_33() {
        launchSignedIn()

        // Scroll: the tile the scroll leaves on screen is at rest.
        app.swipeUp()
        if let resting = centeredTile() {
            assertNoMovement(sampleFrames(of: tile(resting.id)), "the timeline after its scroll")
        } else {
            XCTFail("no tile on screen after the scroll — \(screenText())")
        }
        app.swipeDown()
        XCTAssertTrue(tile(photo(1)).waitForExistence(timeout: 20), "the timeline did not scroll back")

        // A photo opens, then closes.
        let id = photo(1)
        let opening = openViewerSampling(id)
        assertNoMovement(opening.frames, "the photo opening")
        assertNoMovement(closeViewerSampling(id), "the photo closing", requireSamples: false)
        waitForViewerGone("the viewer did not close")

        // The density pinch.
        let before = firstRowColumnCount()
        app.pinch(withScale: 0.6, velocity: -2)
        if let resting = centeredTile() {
            assertNoMovement(sampleFrames(of: tile(resting.id)), "the grid after its density pinch")
        } else {
            XCTFail("no tile on screen after the pinch — \(screenText())")
        }
        XCTAssertNotEqual(firstRowColumnCount(), before, "the pinch did not change the density")

        // A memory opens.
        openMemoriesTab()
        let card = element("memoryCard_\(newerMemory)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no memory card — \(screenText())")
        card.tap()
        let probe = element("memoryPlaybackProbe")
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "the memory never opened — \(screenText())")
        assertNoMovement(sampleFrames(of: probe), "the memory opening")
    }

    // MARK: - AC-162

    /// AC-162: a tile half outside the window has a centered tile's size, and
    /// pulling the top of the album does not stretch its header.
    func test_AC_162() {
        launchSignedIn()

        guard let frames = edgeAndCenterFrames() else { return }
        XCTAssertEqual(frames.edge.width, frames.center.width, accuracy: 1,
                       "the tile at the edge is not the size of a centered tile — \(frames)")
        XCTAssertEqual(frames.edge.height, frames.center.height, accuracy: 1,
                       "the tile at the edge is not the size of a centered tile — \(frames)")

        openAlbum()
        let hero = element("albumHeroImage")
        let rest = hero.frame
        pullDownAlbum()
        for (i, frame) in sampleFrames(of: hero).enumerated() {
            XCTAssertEqual(frame.height, rest.height, accuracy: 1, "sample \(i): the header grew when pulled — \(frame) vs \(rest)")
        }
    }

    /// A pull on the top of the album, released at once: the header is read right after.
    private func pullDownAlbum() {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)),
                    withVelocity: .slow, thenHoldForDuration: 0)
    }

    // MARK: - AC-163

    /// AC-163: the photo is on its final frame from the first sample; it closes by
    /// the button and by a 400 pt drag without moving; a 50 pt drag put back leaves
    /// it in place.
    func test_AC_163() {
        launchSignedIn()
        let id = photo(1)

        let opening = openViewerSampling(id)
        guard let first = opening.frames.first, let last = opening.frames.last else {
            XCTFail("the opening was never sampled"); return
        }
        XCTAssertTrue(near(first, last, 1), "the first sample is not the final frame: \(first) vs \(last)")
        XCTAssertFalse(opensFromThumbnail(opening), "the photo grew out of its thumbnail \(opening.tile)")
        assertNoMovement(opening.frames, "the opening")

        assertNoMovement(closeViewerSampling(id), "the close by the button", requireSamples: false)
        waitForViewerGone("the viewer did not close by the button")

        _ = openViewerSampling(id)
        sleep(1)
        dragDown(400)
        assertNoMovement(sampleFrames(of: element("viewerImage_\(id)")), "the close by the 400 pt drag", requireSamples: false)
        waitForViewerGone("the viewer did not close by the drag")

        let reopened = openViewerSampling(id)
        sleep(1)
        let placed = element("viewerImage_\(id)").frame
        dragDown(50)
        for (i, frame) in sampleFrames(of: element("viewerImage_\(id)"), count: 2).enumerated() {
            XCTAssertTrue(near(frame, placed, 1), "after the 50 pt drag, sample \(i) is not in place: \(frame) vs \(placed) (opened from \(reopened.tile))")
        }
    }

    // MARK: - AC-164

    /// AC-164: a double tap zooms and a second one zooms back, each sample at scale 1
    /// or at the zoomed scale; after a swipe, the filmstrip's cell holds still.
    func test_AC_164() {
        launchSignedIn()
        let id = photo(1)
        _ = openViewerSampling(id)
        sleep(1)
        let image = element("viewerImage_\(id)")
        let base = image.frame

        image.doubleTap()
        let zooming = sampleFrames(of: image).map { $0.width / base.width }
        guard let zoomed = zooming.last, zoomed > 1.2 else {
            XCTFail("the double tap did not zoom: \(zooming)"); return
        }
        for (i, scale) in zooming.enumerated() {
            XCTAssertTrue(abs(scale - 1) <= 0.02 || abs(scale - zoomed) <= 0.02,
                          "zoom sample \(i) is between the two scales (1 and \(zoomed)): \(zooming)")
        }

        image.doubleTap()
        let unzooming = sampleFrames(of: image).map { $0.width / base.width }
        for (i, scale) in unzooming.enumerated() {
            XCTAssertTrue(abs(scale - 1) <= 0.02 || abs(scale - zoomed) <= 0.02,
                          "unzoom sample \(i) is between the two scales (1 and \(zoomed)): \(unzooming)")
        }
        XCTAssertEqual(unzooming.last ?? 0, 1, accuracy: 0.02, "the second double tap did not zoom back")

        window.swipeLeft()
        let cell = element("viewerFilmstripCell_1")
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the filmstrip has no cell 1 — \(screenText())")
        assertNoMovement(sampleFrames(of: cell), "the filmstrip cell after the swipe")
    }

    // MARK: - AC-165

    /// AC-165: the pinch gives 5 columns, the preferences 4, each change without
    /// movement, and the 4 survive a relaunch.
    func test_AC_165() {
        launchSignedIn()

        for _ in 0..<4 where firstRowColumnCount() != 5 {
            app.pinch(withScale: 0.7, velocity: -1)
            if let resting = centeredTile() {
                assertNoMovement(sampleFrames(of: tile(resting.id)), "the grid after a density pinch")
            }
        }
        XCTAssertEqual(firstRowColumnCount(), 5, "the pinch did not bring 5 columns")

        openHub()
        let row = hubRow("preferencesRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Preferences row missing — \(screenText())")
        row.tap()
        let stepper = app.steppers.matching(identifier: "preferencesColumnsStepper").firstMatch
        XCTAssertTrue(stepper.waitForExistence(timeout: 15), "the Columns stepper is missing — \(screenText())")
        for _ in 0..<6 {
            let current = Int((stepper.value as? String) ?? "") ?? 0
            if current == 4 { break }
            stepper.buttons[current > 4 ? "Decrement" : "Increment"].tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        app.swipeDown()
        XCTAssertTrue(tile(photo(1)).waitForExistence(timeout: 20), "the timeline did not come back")
        if let resting = centeredTile() {
            assertNoMovement(sampleFrames(of: tile(resting.id)), "the grid after the preference")
        }
        XCTAssertEqual(firstRowColumnCount(), 4, "the preference did not bring 4 columns")

        // A relaunch WITHOUT `/__reset`: the density is stored.
        app.terminate()
        app.launch()
        waitForTimeline()
        XCTAssertEqual(firstRowColumnCount(), 4, "the density did not survive the relaunch")
    }

    // MARK: - AC-166

    /// AC-166: a memory opens, goes to its next photo, to the next memory and
    /// closes, its probe on the top edge (`origin.y == 0`) at every sample.
    func test_AC_166() {
        launchSignedIn()
        openMemoriesTab()
        let card = element("memoryCard_\(newerMemory)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no memory card — \(screenText())")
        card.tap()
        let probe = element("memoryPlaybackProbe")
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "the playback did not open — \(screenText())")
        assertProbeOnTop(sampleFrames(of: probe), "the memory opening")

        app.swipeLeft() // the next photo
        assertProbeOnTop(sampleFrames(of: probe), "the next photo")

        app.swipeUp() // the next memory
        assertProbeOnTop(sampleFrames(of: probe), "the next memory")

        let close = element("memoryMomentClose")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no close button on the memory — \(screenText())")
        close.tap()
        assertProbeOnTop(sampleFrames(of: probe), "the memory closing", requireSamples: false)
    }

    private func assertProbeOnTop(_ frames: [CGRect], _ what: String, requireSamples: Bool = true,
                                  file: StaticString = #filePath, line: UInt = #line) {
        if frames.isEmpty && requireSamples { XCTFail("\(what): the probe was never sampled", file: file, line: line) }
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.minY, 0, accuracy: 0.5, "\(what), sample \(i): the probe is off the top edge — \(frames)", file: file, line: line)
        }
    }

    // MARK: - AC-167

    /// AC-167: the journey of the criterion — timeline, photo, album, memory, trash —
    /// and each element touched is checked right after its tap.
    func test_AC_167() {
        launchSignedIn()

        // A timeline tile, then the photo's close.
        let first = tile(photo(1))
        first.tap()
        assertNoMovement(sampleFrames(of: first), "the tapped timeline tile")
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never opened")
        element("viewerBackButton").tap()
        waitForViewerGone("the viewer did not close")

        // The Albums tab, an album card, a photo of the album.
        let albumsTab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 30), "the Albums tab is missing")
        albumsTab.tap()
        let card = element("albumCard_\(album)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card — \(screenText())")
        card.tap()
        assertNoMovement(sampleFrames(of: card), "the tapped album card", requireSamples: false)
        XCTAssertTrue(element("albumHeroImage").waitForExistence(timeout: 20), "the album never opened")
        let inAlbum = tile(albumPhoto)
        XCTAssertTrue(inAlbum.waitForExistence(timeout: 20), "no tile for the album's photo — \(screenText())")
        inAlbum.tap()
        assertNoMovement(sampleFrames(of: inAlbum), "the tapped album tile")
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the album viewer never opened")
        element("viewerBackButton").tap()
        waitForViewerGone("the album viewer did not close")
        app.navigationBars.buttons.firstMatch.tap()

        // A memory.
        openMemoriesTab()
        let memory = element("memoryCard_\(olderMemory)")
        XCTAssertTrue(memory.waitForExistence(timeout: 30), "no memory card — \(screenText())")
        for _ in 0..<6 where !memory.isHittable {
            app.swipeUp()
            sleep(1)
        }
        memory.tap()
        assertNoMovement(sampleFrames(of: memory), "the tapped memory card", requireSamples: false)
        let close = element("memoryMomentClose")
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the memory never opened — \(screenText())")
        close.tap()

        // The trash and one of its photos.
        openAlbumsLibraryRow("trashRow")
        XCTAssertTrue(element("trashScreen").waitForExistence(timeout: 20), "the trash never opened")
        let trashed = tile(trashedPhoto)
        XCTAssertTrue(trashed.waitForExistence(timeout: 20), "no tile for the trashed photo — \(screenText())")
        trashed.tap()
        assertNoMovement(sampleFrames(of: trashed), "the tapped trash tile")
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the trash viewer never opened")
    }

    // MARK: - AC-168

    /// AC-168: a tile waiting for its thumbnail (3 s on the stub) shows the same
    /// pixels half a second apart — the shimmer stands still.
    func test_AC_168() {
        launchSignedIn(slow: true)
        let waiting = tile(photo(1))
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "no tile — \(screenText())")
        let (earlier, later) = twoShotsOfWaitingTile(waiting)
        XCTAssertEqual(earlier, later, "the waiting tile changed between two captures: the shimmer moves")
    }

    /// Two captures of `target`, half a second apart.
    private func twoShotsOfWaitingTile(_ target: XCUIElement) -> (Data, Data) {
        let earlier = target.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.5)
        let later = target.screenshot().pngRepresentation
        return (earlier, later)
    }

    // MARK: - AC-169

    /// AC-169: without the argument, and with the system setting off, everything
    /// moves as before: the viewer grows out of the tile, the trash viewer slides
    /// in, an edge tile is smaller, the album header grows, the shimmer plays.
    func test_AC_169() {
        // The shimmer, on its own launch: the thumbnails wait 3 s there.
        launchSignedIn(slow: true)
        let waiting = tile(photo(1))
        XCTAssertTrue(waiting.waitForExistence(timeout: 30), "no tile — \(screenText())")
        let (earlier, later) = twoShotsOfWaitingTile(waiting)
        XCTAssertNotEqual(earlier, later, "the waiting tile did not change: the shimmer does not play")

        launchSignedIn()

        // The viewer grows out of its thumbnail.
        let id = photo(1)
        let opening = openViewerSampling(id)
        XCTAssertTrue(opensFromThumbnail(opening), "the first sample is not near the thumbnail \(opening.tile): \(opening.frames)")
        _ = closeViewerSampling(id)
        waitForViewerGone("the viewer did not close")

        // A tile half outside the window is smaller than a centered one.
        if let frames = edgeAndCenterFrames() {
            XCTAssertLessThan(frames.edge.width, frames.center.width - 1,
                              "the edge tile is not smaller than a centered tile — \(frames)")
        }

        // The album header grows when pulled.
        openAlbum()
        let hero = element("albumHeroImage")
        let rest = hero.frame
        pullDownAlbum()
        let grown = sampleFrames(of: hero).contains { $0.height > rest.height + 1 }
        XCTAssertTrue(grown, "the album header did not grow when pulled (rest \(rest))")
        app.navigationBars.buttons.firstMatch.tap()

        // The trash viewer slides in from below.
        openAlbumsLibraryRow("trashRow")
        let slid = openViewerSampling(trashedPhoto)
        let settled = slid.frames.last?.minY ?? 0
        XCTAssertTrue(slid.frames.contains { $0.minY > 0 && $0.minY > settled + 1 },
                      "the trash viewer did not slide in: \(slid.frames)")
    }

    // MARK: - AC-170

    /// AC-170: the app follows the system's "Reduce Motion" without a relaunch.
    func test_AC_170() {
        launchSignedIn()
        let id = photo(1)

        setSystemReduceMotion(true)
        app.activate()
        XCTAssertTrue(tile(id).waitForExistence(timeout: 30), "the timeline did not come back — \(screenText())")
        let reduced = openViewerSampling(id)
        guard let first = reduced.frames.first, let last = reduced.frames.last else {
            XCTFail("the opening was never sampled"); return
        }
        XCTAssertTrue(near(first, last, 1), "reduced: the first sample is not the final frame: \(first) vs \(last)")
        XCTAssertFalse(opensFromThumbnail(reduced), "reduced: the photo grew out of its thumbnail")
        assertNoMovement(reduced.frames, "reduced: the opening")
        _ = closeViewerSampling(id)
        waitForViewerGone("the viewer did not close")

        setSystemReduceMotion(false)
        app.activate()
        XCTAssertTrue(tile(id).waitForExistence(timeout: 30), "the timeline did not come back — \(screenText())")
        let restored = openViewerSampling(id)
        XCTAssertTrue(opensFromThumbnail(restored),
                      "the setting is off again but the first sample is not near the thumbnail \(restored.tile): \(restored.frames)")
    }

    /// Flips "Reduce Motion" in the Settings app (Accessibility › Motion) and
    /// leaves the Settings app. English labels, with the French ones as a fallback.
    private func setSystemReduceMotion(_ on: Bool) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let toggle = settings.switches.matching(labelPredicate(["Reduce Motion", "Réduire les animations"])).firstMatch
        if !toggle.waitForExistence(timeout: 3) {
            // Back to the root of Settings, then down to the Motion page.
            for _ in 0..<4 where !settings.staticTexts.matching(labelPredicate(["Accessibility", "Accessibilité"])).firstMatch.exists {
                let back = settings.navigationBars.buttons.firstMatch
                if back.exists { back.tap() }
            }
            tapSettingsRow(settings, ["Accessibility", "Accessibilité"])
            tapSettingsRow(settings, ["Motion", "Mouvement"])
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the Reduce Motion switch is missing in Settings")
        if (toggle.value as? String) != (on ? "1" : "0") { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "Reduce Motion did not reach \(on ? "on" : "off")")
    }

    private func tapSettingsRow(_ settings: XCUIApplication, _ labels: [String]) {
        let row = settings.staticTexts.matching(labelPredicate(labels)).firstMatch
        for _ in 0..<8 where !row.exists { settings.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no \(labels) row in Settings")
        row.tap()
    }

    // MARK: - AC-171

    /// AC-171: the trash, the offline library, a shared link and the album's Road
    /// Trip: each presentation's root keeps its place at every sample, opening and
    /// closing.
    func test_AC_171() {
        launchSignedIn()

        // The trash.
        openAlbumsLibraryRow("trashRow")
        let trash = element("trashScreen")
        XCTAssertTrue(trash.waitForExistence(timeout: 20), "the trash never opened — \(screenText())")
        assertRootStays(sampleFrames(of: trash), at: .zero, "the trash opening")
        app.navigationBars.buttons.firstMatch.tap()
        assertRootStays(sampleFrames(of: trash), at: .zero, "the trash closing", requireSamples: false)

        // The offline library: save a photo, then open the library on it.
        showTimeline()
        let id = photo(1)
        tile(id).tap()
        let share = element("viewerShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 20), "no share button — \(screenText())")
        share.tap()
        let offline = element("downloadForOfflineButton")
        for _ in 0..<4 where !offline.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(offline.exists, "no offline button on the share sheet — \(screenText())")
        offline.tap()
        XCTAssertTrue(element("offlineAvailableRow").waitForExistence(timeout: 60),
                      "the copy never became available offline — \(screenText())")
        element("offlineAvailableRow").swipeDown()
        sleep(1)
        if element("viewerBackButton").waitForExistence(timeout: 5) { element("viewerBackButton").tap() }
        XCTAssertTrue(tile(id).waitForExistence(timeout: 20), "the grid did not come back")

        openAlbumsLibraryRow("offlineStorageRow")
        let offlineScreen = element("offlineStorageScreen")
        XCTAssertTrue(offlineScreen.waitForExistence(timeout: 20), "the offline library never opened — \(screenText())")
        assertRootStays(sampleFrames(of: offlineScreen), at: .zero, "the offline library opening")
        let cached = element("offlineAsset_\(id)")
        XCTAssertTrue(cached.waitForExistence(timeout: 20), "the offline library does not list the photo — \(screenText())")
        cached.tap()
        let offlineImage = element("viewerImage_\(id)")
        XCTAssertTrue(offlineImage.waitForExistence(timeout: 20), "the offline viewer never opened — \(screenText())")
        assertRootStays(sampleFrames(of: offlineImage), at: nil, "the offline viewer opening")
        let offlineBack = element("viewerBackButton")
        XCTAssertTrue(offlineBack.waitForExistence(timeout: 10), "the offline viewer has no back button")
        offlineBack.tap()
        assertRootStays(sampleFrames(of: offlineImage), at: nil, "the offline viewer closing", requireSamples: false)
        waitForViewerGone("the offline viewer did not close")
        app.navigationBars.buttons.firstMatch.tap()
        assertRootStays(sampleFrames(of: offlineScreen), at: .zero, "the offline library closing", requireSamples: false)

        // A shared link.
        openSharedTab()
        let entry = app.buttons["openSharedLinkViewer"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no entry point in the Shared toolbar")
        entry.tap()
        let field = element("sharedLinkViewerField")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the shared-link viewer did not present")
        field.tap()
        field.typeText("\(stub)/share/\(sharedKey)")
        app.buttons["openSharedLink"].tap()
        let linked = element("sharedLinkAsset_\(sharedPhoto)")
        XCTAssertTrue(linked.waitForExistence(timeout: 30), "the link never opened — \(screenText())")
        linked.tap()
        let position = element("sharedLinkPagerPosition")
        XCTAssertTrue(position.waitForExistence(timeout: 20), "the pager never opened — \(screenText())")
        assertRootStays(sampleFrames(of: position), at: nil, "the shared-link pager opening")
        let closePager = element("closeSharedLinkPager")
        XCTAssertTrue(closePager.waitForExistence(timeout: 10), "the pager has no close button")
        closePager.tap()
        assertRootStays(sampleFrames(of: position), at: nil, "the shared-link pager closing", requireSamples: false)
        XCTAssertTrue(linked.waitForExistence(timeout: 20), "the link's grid did not come back")
        element("closeSharedLinkViewer").tap()

        // The album's Road Trip.
        let albumsTab = app.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 30), "the Albums tab is missing")
        albumsTab.tap()
        let card = element("albumCard_\(album)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card — \(screenText())")
        card.tap()
        let actions = element("albumActionsMenu")
        XCTAssertTrue(actions.waitForExistence(timeout: 20), "no album actions menu — \(screenText())")
        actions.tap()
        let roadTrip = app.buttons["Road Trip"].firstMatch
        XCTAssertTrue(roadTrip.waitForExistence(timeout: 10), "no 'Road Trip' in the menu — \(screenText())")
        roadTrip.tap()
        let preparing = element("roadTripPreparing")
        let player = element("roadTripPlayer")
        let deadline = Date().addingTimeInterval(60)
        while !preparing.exists && !player.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let root = player.exists ? player : preparing
        XCTAssertTrue(root.exists, "the Road Trip never opened — \(screenText())")
        assertRootStays(sampleFrames(of: root), at: .zero, "the Road Trip opening")
        let closeRoadTrip = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeRoadTrip.waitForExistence(timeout: 10), "the Road Trip has no close button")
        closeRoadTrip.tap()
        assertRootStays(sampleFrames(of: root), at: .zero, "the Road Trip closing", requireSamples: false)
    }
}
