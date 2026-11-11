import XCTest

/// End-to-end scenarios for the viewer's zoom ceiling (lot L-06, B-10): the
/// maximum zoom follows the photo's recorded resolution (native pixels, 2x floor,
/// 4x when unknown) and the pan never lets an image edge into the screen.
///
/// It drives the real app against `immich_stub_zoom_limit.py`, whose six photos
/// carry different EXIF sizes (HD 8000×6000, SMALL 400×300, PORTRAIT 6000×8000,
/// ROTATED 8000×6000 orientation 6, UNKNOWN, LATE) while serving a few pixels.
/// The app is launched with `-uiTestImageProbe YES`: the viewer image then
/// publishes `loaded <w>x<h> zoom=<s> max=<m> off=<x>,<y> fit=<w>x<h>` as its
/// accessibility VALUE — the scale, the ceiling, the pan and the fitted rectangle.
///
/// Targets identifiers and the stub's data, never a localized label.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/zoom.uitest.log \
///         UITests/stubs/immich_stub_zoom_limit.py ZoomLimitUITests --erase
///
/// The helpers are copied from `JpegXLUITests` on purpose: one file per
/// feature, helpers included.
final class ZoomLimitUITests: XCTestCase {

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

    private let hd = "aaaaaaaa-1111-4111-8111-000000000001"
    private let small = "aaaaaaaa-1111-4111-8111-000000000002"
    private let portrait = "aaaaaaaa-1111-4111-8111-000000000003"
    private let rotated = "aaaaaaaa-1111-4111-8111-000000000004"
    private let unknown = "aaaaaaaa-1111-4111-8111-000000000005"
    private let late = "aaaaaaaa-1111-4111-8111-000000000006"

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-zoom-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-zoom-\(name).png")
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

    private func tile(_ assetId: String) -> XCUIElement { element("assetTile_\(assetId)") }

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
        XCTAssertTrue(tile(hd).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func openViewer(_ assetId: String) {
        let target = tile(assetId)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(assetId) — \(screenText())")
        target.tap()
        XCTAssertTrue(element("viewerImage_\(assetId)").waitForExistence(timeout: 20),
                      "the viewer never showed \(assetId) — \(screenText())")
        waitForProbe(assetId) { _ in true }
    }

    private func closeViewer() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the viewer has no back button")
        back.tap()
        XCTAssertTrue(tile(hd).waitForExistence(timeout: 20), "the grid did not come back")
    }

    // MARK: - The probe

    /// What the viewer image publishes: `loaded 80x60 zoom=1.00 max=4.00 off=0.0,0.0 fit=393.0x294.8`.
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
    /// the window width (every photo of the stub is wider than the window ratio).
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

    /// Drags toward `target` (normalized) until the pan stops moving.
    @discardableResult
    private func dragToStop(_ assetId: String, from start: CGVector, to target: CGVector) -> Probe {
        var last = probe(assetId)
        for _ in 0..<12 {
            let image = element("viewerImage_\(assetId)")
            image.coordinate(withNormalizedOffset: start)
                .press(forDuration: 0.05, thenDragTo: image.coordinate(withNormalizedOffset: target))
            Thread.sleep(forTimeInterval: 0.7)
            let now = probe(assetId)
            if let now, let last, now.off == last.off { return now }
            if let now { last = now }
        }
        return last ?? Probe(zoom: 0, max: 0, off: .zero, fit: .zero, raw: "no probe")
    }

    /// Pan bound on each axis for the current probe, in points.
    private func bound(of p: Probe) -> CGSize {
        CGSize(
            width: max(0, (p.fit.width * p.zoom - Double(windowSize.width)) / 2),
            height: max(0, (p.fit.height * p.zoom - Double(windowSize.height)) / 2)
        )
    }

    // MARK: - AC-16

    func test_AC_16_hdReachesNativeSmallStopsLower() {
        launchSignedIn()

        openViewer(hd)
        waitForProbe(hd) { $0.max > 4.5 }
        let hdMax = pinchToMax(hd)
        shot("ac16-hd")
        XCTAssertGreaterThanOrEqual(hdMax.zoom, nativeScale(pixels: 8000) - 0.02, "HD stops before its native pixels — \(hdMax)")
        closeViewer()

        openViewer(small)
        waitForProbe(small) { $0.max < 2.5 }
        let smallMax = pinchToMax(small)
        shot("ac16-small")
        XCTAssertLessThan(smallMax.zoom, hdMax.zoom, "the small image zooms as far as the HD photo")
        XCTAssertEqual(smallMax.zoom, 2.0, accuracy: 0.02)
    }

    // MARK: - AC-106

    func test_AC_106_pinchStopsAtNativeScale() {
        launchSignedIn()
        openViewer(hd)
        let expected = nativeScale(pixels: 8000)
        waitForProbe(hd) { abs($0.max - expected) < 0.02 }

        let first = pinchToMax(hd)
        XCTAssertGreaterThan(first.zoom, 4, "the pinch stayed under the old 4x — \(first)")
        XCTAssertEqual(first.zoom, expected, accuracy: 0.02, "not the native scale — \(first)")

        for _ in 0..<2 {
            element("viewerImage_\(hd)").pinch(withScale: 2, velocity: 4)
            Thread.sleep(forTimeInterval: 0.8)
            let again = probe(hd)
            XCTAssertEqual(again?.zoom ?? 0, first.zoom, accuracy: 0.02, "the zoom moved past its ceiling")
            XCTAssertEqual(again?.max ?? 0, first.max, accuracy: 0.001)
        }
    }

    // MARK: - AC-107

    func test_AC_107_smallImageStopsAtFloor() {
        launchSignedIn()
        openViewer(small)
        waitForProbe(small) { abs($0.max - 2) < 0.001 }
        let id = "viewerImage_\(small)"

        element(id).pinch(withScale: 3, velocity: 5)
        waitForProbe(small) { abs($0.zoom - 2) < 0.001 }

        element(id).doubleTap()
        waitForProbe(small) { abs($0.zoom - 1) < 0.001 }

        element(id).doubleTap()
        waitForProbe(small) { abs($0.zoom - 2) < 0.001 }
    }

    // MARK: - AC-108

    func test_AC_108_portraitAndRotatedReachNative() {
        launchSignedIn()
        let expected = nativeScale(pixels: 6000)

        openViewer(portrait)
        waitForProbe(portrait) { abs($0.max - expected) < 0.02 }
        let portraitMax = pinchToMax(portrait)
        XCTAssertEqual(portraitMax.zoom, expected, accuracy: 0.02, "portrait — \(portraitMax)")
        closeViewer()

        openViewer(rotated)
        waitForProbe(rotated) { abs($0.max - expected) < 0.02 }
        let rotatedMax = pinchToMax(rotated)
        XCTAssertEqual(rotatedMax.zoom, expected, accuracy: 0.02, "rotated — \(rotatedMax)")
    }

    // MARK: - AC-109

    func test_AC_109_unknownSizeStopsAtFour() {
        launchSignedIn()
        openViewer(unknown)
        // The record carries no dimensions: give the (ignored) read time to land.
        Thread.sleep(forTimeInterval: 2)
        let reached = pinchToMax(unknown)
        XCTAssertEqual(reached.zoom, 4.0, accuracy: 0.01, "\(reached)")
        XCTAssertEqual(reached.max, 4.0, accuracy: 0.001, "\(reached)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "an error was shown")
    }

    // MARK: - AC-112

    func test_AC_112_dragStaysOnImageEdges() {
        launchSignedIn()

        // SMALL (4:3) at its 2x ceiling: the zoomed image is shorter than the
        // screen, so a downward drag leaves it centered vertically.
        openViewer(small)
        waitForProbe(small) { abs($0.max - 2) < 0.001 }
        pinchToMax(small)
        let down = dragToStop(small, from: CGVector(dx: 0.5, dy: 0.3), to: CGVector(dx: 0.5, dy: 0.9))
        XCTAssertEqual(down.off.height, 0, accuracy: 0.5, "off \(down.off) — \(down)")
        closeViewer()

        // HD at its ceiling: each corner stops at the bound computed on the fitted image.
        openViewer(hd)
        waitForProbe(hd) { $0.max > 4.5 }
        let top = pinchToMax(hd)
        let limits = bound(of: top)
        for (name, start, target) in [
            ("bottom-right", CGVector(dx: 0.1, dy: 0.1), CGVector(dx: 0.9, dy: 0.9)),
            ("top-left", CGVector(dx: 0.9, dy: 0.9), CGVector(dx: 0.1, dy: 0.1)),
            ("bottom-left", CGVector(dx: 0.9, dy: 0.1), CGVector(dx: 0.1, dy: 0.9)),
            ("top-right", CGVector(dx: 0.1, dy: 0.9), CGVector(dx: 0.9, dy: 0.1)),
        ] {
            let corner = dragToStop(hd, from: start, to: target)
            XCTAssertEqual(abs(corner.off.width), limits.width, accuracy: 1, "\(name) x — \(corner)")
            XCTAssertEqual(abs(corner.off.height), limits.height, accuracy: 1, "\(name) y — \(corner)")
        }
        shot("ac112-corner")

        // Zooming out after a pan re-bounds the offset to the smaller image.
        element("viewerImage_\(hd)").pinch(withScale: 0.5, velocity: -2)
        Thread.sleep(forTimeInterval: 1)
        if let reduced = probe(hd), reduced.zoom > 1.05 {
            let newLimits = bound(of: reduced)
            XCTAssertLessThanOrEqual(abs(reduced.off.width), newLimits.width + 1, "\(reduced)")
            XCTAssertLessThanOrEqual(abs(reduced.off.height), newLimits.height + 1, "\(reduced)")
        }
    }

    /// The pan bound follows the decoded image (4:3 here), not the grid item's
    /// square ratio: UNKNOWN's record has no dimensions to fall back on.
    func test_AC_112_unknownSizeBoundFollowsDecodedImage() {
        launchSignedIn()
        openViewer(unknown)
        let first = waitForProbe(unknown) { $0.fit.width > 0 }
        guard let first else { return }

        XCTAssertEqual(Double(first.fit.width), Double(windowSize.width), accuracy: 1, "\(first)")
        XCTAssertEqual(Double(first.fit.width / first.fit.height), 4.0 / 3.0, accuracy: 0.01, "not the square — \(first)")

        let top = pinchToMax(unknown)
        let down = dragToStop(unknown, from: CGVector(dx: 0.5, dy: 0.2), to: CGVector(dx: 0.5, dy: 0.95))
        XCTAssertEqual(down.off.height, bound(of: top).height, accuracy: 1, "\(down)")
    }

    // MARK: - AC-113

    func test_AC_113_zoomedSwipeDownKeepsViewer() {
        launchSignedIn()
        openViewer(hd)
        waitForProbe(hd) { $0.max > 4.5 }
        let top = pinchToMax(hd)
        XCTAssertGreaterThan(top.zoom, 4)

        element("viewerImage_\(hd)").swipeDown()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(element("viewerImage_\(hd)").exists, "the swipe closed the zoomed viewer")

        element("viewerImage_\(hd)").doubleTap()
        waitForProbe(hd) { abs($0.zoom - 1) < 0.001 }
    }

    // MARK: - AC-114

    func test_AC_114_lateDimensionsLowerTheZoom() {
        launchSignedIn()
        // The record of LATE answers 6 s after the request: zoom under the
        // provisional 4x first, then watch the late size bring the ceiling down.
        let id = "viewerImage_\(late)"
        tile(late).tap()
        XCTAssertTrue(element(id).waitForExistence(timeout: 20), "the viewer never showed LATE")
        waitForProbe(late, timeout: 10) { $0.max == 4 }
        element(id).pinch(withScale: 3, velocity: 5)
        waitForProbe(late, timeout: 5) { abs($0.zoom - 4) < 0.001 && abs($0.max - 4) < 0.001 }

        let settled = waitForProbe(late, timeout: 20) { abs($0.zoom - 2) < 0.001 && abs($0.max - 2) < 0.001 }
        shot("ac114-late")
        if let settled {
            XCTAssertLessThanOrEqual(abs(settled.off.width), bound(of: settled).width + 1, "\(settled)")
        }
    }
}
