import AVFoundation
import UIKit
import XCTest

/// End-to-end proof of the viewer's zoom open and close (lot L-14, B-18): the
/// photo grows out of its thumbnail, shrinks back onto the thumbnail of the photo
/// on screen, and its controls are there as soon as the animation ends.
///
/// It is judged on PIXELS, not on state. The simulator is FILMED and the photo is
/// found in each frame by its colour (see `immich_stub_viewer_zoom.py`: the marked
/// photo's thumbnail is pure magenta, its preview pure yellow, the video pure
/// green, everything else grey). The recording is driven through files by a host
/// script, because a UI test cannot run `xcrun simctl`:
///
///     UITests/stubs/tools/sim_video_watcher.sh        # leave it running
///
/// Without it the scenarios FAIL ("enregistreur vidéo absent"), never pass or skip.
/// Set `TEST_RUNNER_SWIMMICH_EVIDENCE_DIR` to keep each film next to the proofs
/// (`.harness/evidence/<ac>/`); every film is also attached to the result.
///
/// Run one method at a time with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/viewer-zoom-<méthode>.log \
///         UITests/stubs/immich_stub_viewer_zoom.py ViewerZoomUITests/<méthode> --erase
///
/// Targets identifiers and the stub's data, never a localized label (the tabs are
/// the English labels, pinned with the language). Helpers are copied from
/// `JpegXLUITests` on purpose: one file per feature, helpers included.
@MainActor
final class ViewerZoomUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // MARK: - The stub's data

    private let photo = "cccccccc-1414-4141-8141-000000000001"
    private let partner = "cccccccc-1414-4141-8141-000000000002"
    private let slow = "cccccccc-1414-4141-8141-000000000003"
    private let video = "cccccccc-1414-4141-8141-000000000004"
    private let archivable = "cccccccc-1414-4141-8141-000000000005"
    private let far = "cccccccc-1414-4141-8141-000000000075"
    private let trashed = "cccccccc-1414-4141-8141-000000000101"
    private let foldered = "cccccccc-1414-4141-8141-000000000111"
    private let album = "22222222-2222-4222-8222-000000001414"
    /// 16:9, the ratio of the video file the stub serves.
    private let videoRatio: CGFloat = 480.0 / 270.0

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-zoom-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func post(_ path: String, _ json: [String: Any]) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
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

    /// Reset, launch on a fresh session, walk onboarding, land on the timeline.
    private func launchSignedIn() {
        get("/__reset")
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
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    /// Arms the photo whose colours the films will follow (and the delay of its
    /// preview), then relaunches: the images are fetched at launch, not on demand.
    private func arm(_ id: String, previewDelay: Double = 0) {
        let body = post("/control/mark", ["id": id, "previewDelay": previewDelay])
        XCTAssertTrue(body.contains(id), "the stub did not arm \(id): \(body)")
        if app.state != .notRunning { app.terminate() }
        app.launch()
        waitForTimeline()
    }

    private enum Grid { case timeline, album, search }

    private func show(_ grid: Grid) {
        switch grid {
        case .timeline:
            app.tabBars.buttons["Photos"].firstMatch.tap()
        case .album:
            app.tabBars.buttons["Albums"].firstMatch.tap()
            if !element("albumHeroTitle").exists {
                let card = element("albumCard_\(album)")
                XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card — \(screenText())")
                card.tap()
            }
        case .search:
            let tab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Search tab")
            tab.tap()
            if !tile(photo).waitForExistence(timeout: 3) {
                let field = app.searchFields.firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field — \(screenText())")
                field.tap()
                field.typeText("x\n")
            }
        }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 30), "\(grid) never showed the photos — \(screenText())")
    }

    private func openViewer(_ id: String) {
        let target = tile(id)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(id) — \(screenText())")
        target.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never opened on \(id)")
    }

    private func closeWithBack() {
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the viewer has no back button")
        back.tap()
    }

    /// A vertical drag of `distance` pt from the middle of the window, at a
    /// finger-like pace (it must not be taken for a flick on the way).
    private func dragDown(_ distance: CGFloat, duration: TimeInterval = 0.4) {
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: duration, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
    }

    // MARK: - Films

    private let videoDir = "/tmp/swimmich-video"

    private func startRecording(_ name: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: videoDir, withIntermediateDirectories: true)
        for ext in ["recording", "done", "mov", "stop"] { try? fm.removeItem(atPath: "\(videoDir)/\(name).\(ext)") }
        fm.createFile(atPath: "\(videoDir)/\(name).start", contents: Data())
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if fm.fileExists(atPath: "\(videoDir)/\(name).recording") { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("enregistreur vidéo absent : lancer UITests/stubs/tools/sim_video_watcher.sh")
    }

    private func stopRecording(_ name: String) -> URL {
        let fm = FileManager.default
        fm.createFile(atPath: "\(videoDir)/\(name).stop", contents: Data())
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if fm.fileExists(atPath: "\(videoDir)/\(name).done") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(fm.fileExists(atPath: "\(videoDir)/\(name).done"), "the recording '\(name)' never ended")
        let url = URL(fileURLWithPath: "\(videoDir)/\(name).mov")
        let attachment = XCTAttachment(
            data: (try? Data(contentsOf: url)) ?? Data(), uniformTypeIdentifier: "com.apple.quicktime-movie"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let evidence = ProcessInfo.processInfo.environment["SWIMMICH_EVIDENCE_DIR"] {
            try? fm.createDirectory(atPath: evidence, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: "\(evidence)/\(name).mov")
            try? fm.copyItem(at: url, to: URL(fileURLWithPath: "\(evidence)/\(name).mov"))
        }
        return url
    }

    /// The pixel classes of S-15 (the stub's colours).
    private enum PixelClass: Hashable {
        case m, y, v, my

        func matches(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            switch self {
            case .m: return r >= 180 && g <= 90 && b >= 180
            case .y: return r >= 180 && g >= 180 && b <= 90
            case .v: return g >= 150 && r <= 100 && b <= 100
            // Any mix of magenta and yellow lies on R = 255, G + B = 255.
            case .my: return r >= 180 && abs(g + b - 255) <= 60
            }
        }
    }

    private struct Component {
        let rect: CGRect       // points
        let fill: Double       // share of the bounding box the component covers
    }

    private struct FilmFrame {
        let time: Double
        let parts: [PixelClass: Component]
    }

    /// Every frame of `url`: the biggest connected component of each class,
    /// sampled on one pixel in two, in points of the window.
    private func analyse(_ url: URL, classes: [PixelClass]) async throws -> [FilmFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("the recording has no video track")
            return []
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        guard reader.startReading() else {
            XCTFail("cannot read the recording: \(String(describing: reader.error))")
            return []
        }
        let windowWidth = window.frame.width
        var frames: [FilmFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let ratio = CGFloat(CVPixelBufferGetWidth(buffer)) / windowWidth
            var parts: [PixelClass: Component] = [:]
            for cls in classes {
                if let component = largestComponent(buffer, cls, ratio: ratio) { parts[cls] = component }
            }
            frames.append(FilmFrame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, parts: parts))
        }
        XCTAssertFalse(frames.isEmpty, "the recording has no frame")
        return frames
    }

    private func largestComponent(_ buffer: CVPixelBuffer, _ cls: PixelClass, ratio: CGFloat) -> Component? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let gw = CVPixelBufferGetWidth(buffer) / 2
        let gh = CVPixelBufferGetHeight(buffer) / 2
        var member = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            let row = bytes + gy * 2 * rowBytes
            for gx in 0..<gw {
                let p = row + gx * 8
                if cls.matches(Int(p[2]), Int(p[1]), Int(p[0])) { member[gy * gw + gx] = true }
            }
        }
        var best: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)?
        var stack: [Int] = []
        for seed in 0..<member.count where member[seed] {
            member[seed] = false
            stack.append(seed)
            var count = 0
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            while let cell = stack.popLast() {
                let x = cell % gw, y = cell / gw
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, member[cell - 1] { member[cell - 1] = false; stack.append(cell - 1) }
                if x < gw - 1, member[cell + 1] { member[cell + 1] = false; stack.append(cell + 1) }
                if y > 0, member[cell - gw] { member[cell - gw] = false; stack.append(cell - gw) }
                if y < gh - 1, member[cell + gw] { member[cell + gw] = false; stack.append(cell + gw) }
            }
            if count > (best?.count ?? 0) { best = (count, minX, minY, maxX, maxY) }
        }
        guard let best, best.count >= 30 else { return nil }
        let boxCells = (best.maxX - best.minX + 1) * (best.maxY - best.minY + 1)
        let rect = CGRect(
            x: CGFloat(best.minX * 2) / ratio,
            y: CGFloat(best.minY * 2) / ratio,
            width: CGFloat((best.maxX - best.minX + 1) * 2) / ratio,
            height: CGFloat((best.maxY - best.minY + 1) * 2) / ratio
        )
        return Component(rect: rect, fill: Double(best.count) / Double(boxCells))
    }

    // MARK: - Judging a film

    private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    private func edgeMove(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    /// The photo's component on a frame: the thumbnail/preview, or for a video the
    /// poster and then the picture.
    private func photoPart(_ frame: FilmFrame, video: Bool) -> Component? {
        frame.parts[.my] ?? (video ? frame.parts[.v] : nil)
    }

    /// First frame after which the rectangle moves less than 1 pt for 100 ms.
    private func animationEnd(_ frames: [FilmFrame], video: Bool, after start: Int) -> Int? {
        for i in start..<frames.count {
            guard let anchor = photoPart(frames[i], video: video) else { continue }
            let span = frames[i...].prefix { $0.time - frames[i].time <= 0.1 }
            guard span.last.map({ $0.time - frames[i].time >= 0.1 }) ?? false else { return nil }
            if span.allSatisfy({ photoPart($0, video: video).map { near($0.rect, anchor.rect, 1) } ?? false }) {
                return i
            }
        }
        return nil
    }

    /// AC-27.1: leaves the thumbnail without a jump, never disappears, lands on `target`.
    private func assertOpening(
        _ frames: [FilmFrame], tile: CGRect, target: CGRect, video: Bool, label: String
    ) {
        let height = window.frame.height
        guard let leave = frames.firstIndex(where: { f in
            photoPart(f, video: video).map { !near($0.rect, tile, 2) } ?? false
        }), let first = photoPart(frames[leave], video: video) else {
            XCTFail("\(label): the image never left its place")
            return
        }
        XCTAssertLessThanOrEqual(hypot(first.rect.midX - tile.midX, first.rect.midY - tile.midY), 8,
                                 "\(label): the first moved frame is not centred on the thumbnail")
        XCTAssertLessThanOrEqual(first.rect.width, tile.width * 1.25, "\(label): first frame too wide")
        XCTAssertLessThanOrEqual(first.rect.height, tile.height * 1.25, "\(label): first frame too tall")
        for i in 0..<frames.count {
            guard let part = photoPart(frames[i], video: video) else {
                XCTFail("\(label): the image disappeared on frame \(i) (t=\(frames[i].time))")
                return
            }
            if i > 0, let before = photoPart(frames[i - 1], video: video) {
                XCTAssertLessThanOrEqual(edgeMove(before.rect, part.rect), 0.2 * height,
                                         "\(label): a jump on frame \(i)")
            }
        }
        guard let endIndex = animationEnd(frames, video: video, after: leave),
              let end = photoPart(frames[endIndex], video: video) else {
            XCTFail("\(label): the animation never settled")
            return
        }
        XCTAssertTrue(near(end.rect, target, 1), "\(label): landed on \(end.rect), expected \(target)")
        if video {
            // Poster, then picture: never black, and no jump at the hand-over.
            if let firstV = frames.firstIndex(where: { $0.parts[.v] != nil }),
               let lastM = frames[..<firstV].lastIndex(where: { $0.parts[.m] != nil }),
               let m = frames[lastM].parts[.m], let v = frames[firstV].parts[.v] {
                XCTAssertTrue(near(m.rect, v.rect, 1), "\(label): the video jumped off its poster: \(m.rect) → \(v.rect)")
            }
        }
    }

    /// AC-27.3: shrinks onto the thumbnail, no jump, lands on it.
    private func assertClosing(_ frames: [FilmFrame], tileAfter: CGRect, label: String, mustStayFilled: Bool = false) {
        let height = window.frame.height
        let parts = frames.compactMap { f in f.parts[.my].map { (time: f.time, part: $0) } }
        guard let last = parts.last else {
            XCTFail("\(label): the image was never seen")
            return
        }
        XCTAssertLessThanOrEqual(hypot(last.part.rect.midX - tileAfter.midX, last.part.rect.midY - tileAfter.midY), 8,
                                 "\(label): the last image is not on the thumbnail")
        XCTAssertLessThanOrEqual(last.part.rect.width, tileAfter.width * 1.25, "\(label): last image too wide")
        for i in 1..<max(parts.count, 1) {
            XCTAssertLessThanOrEqual(edgeMove(parts[i - 1].part.rect, parts[i].part.rect), 0.2 * height,
                                     "\(label): a jump at t=\(parts[i].time)")
        }
        if mustStayFilled {
            for entry in parts {
                XCTAssertGreaterThanOrEqual(entry.part.fill, 0.8, "\(label): the image faded at t=\(entry.time)")
            }
        }
    }

    // MARK: - Judging a screenshot

    private func rgba(_ image: UIImage, in rect: CGRect) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        let px = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                        width: rect.width * image.scale, height: rect.height * image.scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !px.isEmpty, let crop = cg.cropping(to: px) else { return nil }
        let w = crop.width, h = crop.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? data : nil
    }

    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    }

    private func lumas(_ data: [UInt8]) -> [Double] {
        stride(from: 0, to: data.count, by: 4).map { luminance(Double(data[$0]), Double(data[$0 + 1]), Double(data[$0 + 2])) }
    }

    /// Share of the pixels whose luminance differs by more than 0.2 from the
    /// dominant colour of the frame (a glyph on its glass pill). 0 on a flat fill.
    private func glyphShare(_ data: [UInt8]) -> Double {
        var histogram: [Int: Int] = [:]
        for i in stride(from: 0, to: data.count, by: 4) {
            let key = (Int(data[i]) >> 4) << 8 | (Int(data[i + 1]) >> 4) << 4 | (Int(data[i + 2]) >> 4)
            histogram[key, default: 0] += 1
        }
        guard let mode = histogram.max(by: { $0.value < $1.value })?.key else { return 0 }
        let dominant = luminance(Double(((mode >> 8) & 15) * 16 + 8), Double(((mode >> 4) & 15) * 16 + 8), Double((mode & 15) * 16 + 8))
        let all = lumas(data)
        return Double(all.filter { abs($0 - dominant) > 0.2 }.count) / Double(max(all.count, 1))
    }

    private func percentile95(_ data: [UInt8]) -> Double {
        let sorted = lumas(data).sorted()
        return sorted.isEmpty ? 0 : sorted[Int(0.95 * Double(sorted.count - 1))]
    }

    private func meanLuma(_ data: [UInt8]) -> Double {
        let all = lumas(data)
        return all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
    }

    private func controlNames(hasFavorite: Bool) -> [String] {
        let badge = element("viewerBadgeDate").exists ? "viewerBadgeDate" : "viewerBadgeSingleLine"
        return ["viewerBackButton", "viewerShareButton", "viewerOverflowMenu", badge]
            + (hasFavorite ? ["viewerFavoriteButton"] : [])
    }

    /// AC-28.1: each control's glyph is on `now` as strongly as on `reference`.
    private func assertControlsDrawn(
        now: UIImage, reference: UIImage, hasFavorite: Bool, label: String
    ) {
        for name in controlNames(hasFavorite: hasFavorite) {
            let control = element(name)
            XCTAssertTrue(control.exists && control.isHittable, "\(label): \(name) is missing or not hittable")
            let frame = control.frame
            guard let nowPixels = rgba(now, in: frame), let referencePixels = rgba(reference, in: frame) else {
                XCTFail("\(label): cannot read the pixels of \(name)")
                continue
            }
            let expected = glyphShare(referencePixels)
            let seen = glyphShare(nowPixels)
            XCTAssertGreaterThan(expected, 0.02, "\(label): \(name) is not drawn even on the reference")
            XCTAssertGreaterThanOrEqual(seen, 0.5 * expected, "\(label): \(name) was drawn late (\(seen) vs \(expected))")
        }
    }

    /// Opens `id` from the grid `repetitions` times, each time capturing the screen
    /// right after the touch and again 3 s later.
    private func assertControlsAtOpening(of id: String, hasFavorite: Bool, repetitions: Int) {
        for run in 1...repetitions {
            let target = tile(id)
            XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(id) — \(screenText())")
            let t0 = Date()
            target.tap()
            let now = XCUIScreen.main.screenshot().image
            XCTAssertLessThanOrEqual(Date().timeIntervalSince(t0), 1.0, "capture trop tardive")
            XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never opened")
            Thread.sleep(forTimeInterval: 3)
            let reference = XCUIScreen.main.screenshot().image
            if run == 1 { shot("controls-\(id.suffix(2))") }
            if !hasFavorite {
                XCTAssertFalse(element("viewerFavoriteButton").exists, "a partner's photo offers a favorite")
            }
            assertControlsDrawn(now: now, reference: reference, hasFavorite: hasFavorite, label: "open \(run) of \(id.suffix(2))")
            closeWithBack()
            XCTAssertTrue(tile(id).waitForExistence(timeout: 20), "the grid did not come back")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - The probe

    /// `fit=<w>x<h>` of the page's probe value: the rectangle the image is drawn in.
    private func fittedSize(of id: String) -> CGSize? {
        let value = element("viewerImage_\(id)").value as? String ?? ""
        guard let range = value.range(of: #"fit=([0-9.]+)x([0-9.]+)"#, options: .regularExpression) else { return nil }
        let parts = value[range].dropFirst(4).split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Where a photo settles: its fitted rectangle centred in the page's frame.
    private func photoTarget(_ id: String) -> CGRect {
        let page = element("viewerImage_\(id)").frame
        guard let size = fittedSize(of: id) else {
            XCTFail("no fit= in the probe of \(id)")
            return .zero
        }
        return CGRect(x: page.midX - size.width / 2, y: page.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func videoTarget() -> CGRect {
        let frame = window.frame
        let width = min(frame.width, frame.height * videoRatio)
        let height = width / videoRatio
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    // MARK: - Shared flows

    private struct OpeningFilm {
        let frames: [FilmFrame]
        let tile: CGRect
    }

    /// Films the touch on `id`'s thumbnail until 1.5 s after the viewer showed.
    private func filmOpening(_ id: String, name: String, isVideo: Bool, classes: [PixelClass] = [.my, .m, .v]) async throws -> OpeningFilm {
        let target = tile(id)
        XCTAssertTrue(target.waitForExistence(timeout: 20), "no tile for \(id) — \(screenText())")
        let tileFrame = target.frame
        startRecording(name)
        target.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the viewer never opened")
        Thread.sleep(forTimeInterval: 1.5)
        let url = stopRecording(name)
        return OpeningFilm(frames: try await analyse(url, classes: classes), tile: tileFrame)
    }

    private func filmClosing(name: String, classes: [PixelClass] = [.my, .m], by close: () -> Void) async throws -> [FilmFrame] {
        startRecording(name)
        close()
        Thread.sleep(forTimeInterval: 1.5)
        return try await analyse(stopRecording(name), classes: classes)
    }

    // MARK: - Scenarios

    /// AC-27, timeline: opens by growing out of the thumbnail; after a swipe to
    /// another photo and back, a drag down shrinks onto the thumbnail again.
    func test_AC_27() async throws {
        launchSignedIn()
        arm(photo)

        let opening = try await filmOpening(photo, name: "ac27-open", isVideo: false)
        assertOpening(opening.frames, tile: opening.tile, target: photoTarget(photo), video: false, label: "AC-27 open")

        // Away and back: the thumbnail to land on is the one of the photo shown.
        window.swipeLeft()
        sleep(1)
        window.swipeRight()
        XCTAssertTrue(element("viewerImage_\(photo)").waitForExistence(timeout: 10), "back on the first photo")
        sleep(1)

        let frames = try await filmClosing(name: "ac27-close") { dragDown(400) }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 20), "the grid did not come back")
        assertClosing(frames, tileAfter: tile(photo).frame, label: "AC-27 close")
    }

    /// AC-27.1: the open, from an album and from search, for a photo and a video.
    func test_AC_27_1() async throws {
        launchSignedIn()
        for grid in [Grid.album, Grid.search] {
            for (id, isVideo) in [(photo, false), (video, true)] {
                arm(id)
                show(grid)
                let film = try await filmOpening(id, name: "ac27-1-\(grid)-\(isVideo ? "video" : "photo")", isVideo: isVideo)
                let label = "AC-27.1 \(grid) \(isVideo ? "video" : "photo")"
                let target = isVideo ? videoTarget() : photoTarget(id)
                assertOpening(film.frames, tile: film.tile, target: target, video: isVideo, label: label)
            }
        }
    }

    /// AC-27.2: a slow preview is replaced in place, with no shimmer and no half
    /// transparent image on the way.
    func test_AC_27_2() async throws {
        launchSignedIn()
        arm(slow, previewDelay: 2)

        let target = tile(slow)
        XCTAssertTrue(target.waitForExistence(timeout: 20))
        let tileFrame = target.frame
        startRecording("ac27-2")
        target.tap()
        XCTAssertTrue(element("viewerImage_\(slow)").waitForExistence(timeout: 20), "the viewer never opened")
        Thread.sleep(forTimeInterval: 1)
        let fitBefore = fittedSize(of: slow)
        Thread.sleep(forTimeInterval: 2.5)
        let fitAfter = fittedSize(of: slow)
        let frames = try await analyse(stopRecording("ac27-2"), classes: [.my, .m, .y])

        XCTAssertNotNil(fitBefore)
        XCTAssertEqual(fitBefore, fitAfter, "the page's frame changed when the preview arrived")
        guard let firstY = frames.firstIndex(where: { $0.parts[.y] != nil }) else {
            XCTFail("the preview never showed")
            return
        }
        guard let leave = frames.firstIndex(where: { f in f.parts[.my].map { !near($0.rect, tileFrame, 2) } ?? false }),
              let end = animationEnd(frames, video: false, after: leave),
              let endRect = frames[end].parts[.my]?.rect else {
            XCTFail("the open never settled")
            return
        }
        // During the open: the thumbnail's pixels fill its rectangle.
        for i in 0...end {
            guard let m = frames[i].parts[.m] else {
                XCTFail("frame \(i): no thumbnail pixels during the open (shimmer or black?)")
                return
            }
            XCTAssertGreaterThanOrEqual(m.fill, 0.8, "frame \(i): the thumbnail is not filling its rectangle")
        }
        // From the end of the animation to 0.5 s after the preview: one image, filled, in place.
        for i in end..<frames.count where frames[i].time <= frames[firstY].time + 0.5 {
            guard let part = frames[i].parts[.my] else {
                XCTFail("frame \(i): no image between the open and the preview")
                return
            }
            XCTAssertGreaterThanOrEqual(part.fill, 0.8, "frame \(i): a half-transparent or shimmering image")
            XCTAssertTrue(near(part.rect, endRect, 1), "frame \(i): the image moved: \(part.rect) vs \(endRect)")
        }
        if let y = frames[firstY].parts[.y], firstY > 0, let lastM = frames[..<firstY].lastIndex(where: { $0.parts[.m] != nil }),
           let m = frames[lastM].parts[.m] {
            XCTAssertTrue(near(y.rect, m.rect, 1), "the preview jumped off the thumbnail: \(m.rect) → \(y.rect)")
        }
    }

    /// AC-27.3: the close by the back button, from each grid.
    func test_AC_27_3() async throws {
        launchSignedIn()
        arm(photo)
        for grid in [Grid.timeline, Grid.album, Grid.search] {
            show(grid)
            openViewer(photo)
            sleep(2)
            let frames = try await filmClosing(name: "ac27-3-\(grid)") { closeWithBack() }
            XCTAssertTrue(tile(photo).waitForExistence(timeout: 20), "\(grid): the grid did not come back")
            assertClosing(frames, tileAfter: tile(photo).frame, label: "AC-27.3 \(grid)")
            XCTAssertTrue(tile(photo).isHittable, "\(grid): the thumbnail does not answer")
            tile(photo).tap()
            XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "\(grid): the viewer did not reopen")
            closeWithBack()
            XCTAssertTrue(tile(photo).waitForExistence(timeout: 20))
        }
    }

    /// AC-27.4: under the threshold the photo springs back; past it, it shrinks onto
    /// the thumbnail; zoomed, a vertical drag does not close.
    func test_AC_27_4() async throws {
        launchSignedIn()
        arm(photo)
        openViewer(photo)
        sleep(3) // the preview (yellow) is in

        // 1. Under the 75 pt threshold, released slowly: back to full screen.
        let before = XCUIScreen.main.screenshot().image
        startRecording("ac27-4-under")
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 40)),
                    withVelocity: 100.0, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 0.5)
        let after = XCUIScreen.main.screenshot().image
        let frames = try await analyse(stopRecording("ac27-4-under"), classes: [.y])
        guard let r0 = frames.first?.parts[.y]?.rect else {
            XCTFail("the preview was not on the first frame")
            return
        }
        XCTAssertTrue(frames.contains { $0.parts[.y].map { edgeMove($0.rect, r0) > 20 } ?? false },
                      "the drag never moved the image")
        if let last = frames.last?.parts[.y]?.rect {
            XCTAssertTrue(near(last, r0, 1), "the image did not come back: \(last) vs \(r0)")
        } else {
            XCTFail("no image on the last frame")
        }
        XCTAssertTrue(element("viewerBackButton").exists, "the viewer closed on a small drag")
        assertControlsDrawn(now: after, reference: before, hasFavorite: true, label: "after the small drag")
        for name in controlNames(hasFavorite: true) {
            let frame = element(name).frame
            if let a = rgba(after, in: frame), let b = rgba(before, in: frame) {
                XCTAssertEqual(percentile95(a), percentile95(b), accuracy: 0.03, "\(name) stayed under full opacity")
            }
        }
        let band = CGRect(x: r0.minX, y: r0.maxY + 4, width: r0.width, height: 20)
        if let a = rgba(after, in: band), let b = rgba(before, in: band) {
            XCTAssertEqual(meanLuma(a), meanLuma(b), accuracy: 0.02, "the backdrop is not back to black")
        }

        // 2. Past the threshold: closes onto the thumbnail.
        let closing = try await filmClosing(name: "ac27-4-past") { dragDown(400) }
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 20), "the grid did not come back")
        assertClosing(closing, tileAfter: tile(photo).frame, label: "AC-27.4 past the threshold")

        // 3. Zoomed 3×: a vertical drag does not close.
        openViewer(photo)
        element("viewerImage_\(photo)").doubleTap()
        sleep(1)
        dragDown(400)
        sleep(1)
        XCTAssertTrue(element("viewerBackButton").exists, "a zoomed photo was closed by a vertical drag")
    }

    /// AC-27.5: the thumbnail of the photo on screen may be far out of view: the grid
    /// scrolls to it, and the image shrinks onto it, never fading.
    func test_AC_27_5() async throws {
        launchSignedIn()
        arm(far)
        for grid in [Grid.timeline, Grid.album, Grid.search] {
            show(grid)
            for byDrag in [false, true] {
                openViewer(photo)
                var swipes = 0
                while !element("viewerImage_\(far)").exists && swipes < 74 {
                    window.swipeLeft()
                    swipes += 1
                }
                XCTAssertTrue(element("viewerImage_\(far)").waitForExistence(timeout: 10), "never reached the far photo")
                sleep(1)
                let name = "ac27-5-\(grid)-\(byDrag ? "drag" : "back")"
                let frames = try await filmClosing(name: name) {
                    if byDrag { dragDown(400) } else { closeWithBack() }
                }
                let farTile = tile(far)
                XCTAssertTrue(farTile.waitForExistence(timeout: 20), "\(name): the far thumbnail is not on screen")
                let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : window.frame.maxY - 100
                let safe = CGRect(x: 0, y: 100, width: window.frame.width, height: bottom - 100)
                XCTAssertTrue(safe.contains(farTile.frame), "\(name): the thumbnail is not entirely visible: \(farTile.frame)")
                assertClosing(frames, tileAfter: farTile.frame, label: name, mustStayFilled: true)

                // Back to the top for the next pass.
                for _ in 0..<40 where !tile(photo).isHittable {
                    window.swipeDown()
                }
            }
        }
    }

    /// AC-27.6: a photo no longer in the grid's list (archived from the viewer)
    /// closes in a fade, without an error.
    func test_AC_27_6() async throws {
        launchSignedIn()
        arm(archivable)
        openViewer(archivable)
        sleep(2)
        let archive = element("viewerArchiveButton")
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "no archive button")
        archive.tap()
        XCTAssertTrue(element("viewerUnarchiveButton").waitForExistence(timeout: 10), "the archive did not go through")
        sleep(1)

        let frames = try await filmClosing(name: "ac27-6") { closeWithBack() }
        let parts = frames.compactMap { $0.parts[.my]?.rect }
        guard let first = parts.first else {
            XCTFail("the image was never seen")
            return
        }
        // Fading: the same rectangle until it is gone (the grid has no thumbnail to land on).
        for rect in parts {
            XCTAssertTrue(near(rect, first, 1), "the image moved while it should fade: \(rect) vs \(first)")
        }
        XCTAssertEqual(app.alerts.count, 0, "an alert appeared on close")
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 20))
        tile(photo).tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20), "the grid does not answer after the fade")
    }

    /// AC-27.7: selection, favorite and the info panel are as before.
    func test_AC_27_7() async throws {
        launchSignedIn()

        // Selection mode: a touch selects, the viewer stays closed.
        let select = element("selectButton")
        XCTAssertTrue(select.waitForExistence(timeout: 15), "no select button")
        select.tap()
        tile(photo).tap()
        XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 2), "the viewer opened in selection mode")
        // Leaves the mode by a fresh launch: the toolbar changes while selecting.
        app.terminate()
        app.launch()
        waitForTimeline()

        // Favorite in the viewer, then the thumbnail shows it.
        openViewer(photo)
        let favorite = element("viewerFavoriteButton")
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "no favorite button")
        favorite.tap()
        sleep(1)
        closeWithBack()
        XCTAssertTrue(tile(photo).waitForExistence(timeout: 20))
        XCTAssertTrue(element("favoriteBadge").waitForExistence(timeout: 10), "the thumbnail does not show the favorite")

        // An upward drag opens the info panel.
        openViewer(photo)
        sleep(1)
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -300)))
        XCTAssertTrue(element("viewerInfoClose").waitForExistence(timeout: 10), "the info panel did not open")
    }

    /// Pops the Albums tab to its root: the tab's own re-tap, else the back button.
    private func backToAlbumsRoot() {
        app.tabBars.buttons["Albums"].firstMatch.tap()
        if !app.buttons.matching(identifier: "trashRow").firstMatch.waitForExistence(timeout: 3) {
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    /// AC-27.8: the other grids and the album list keep their presentation.
    func test_AC_27_8() async throws {
        launchSignedIn()
        let albumsTab = app.tabBars.buttons["Albums"].firstMatch

        // The album list opens the album as before (zoom reserved to iOS 27).
        albumsTab.tap()
        let card = element("albumCard_\(album)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no album card")
        card.tap()
        XCTAssertTrue(element("albumHeroTitle").waitForExistence(timeout: 20), "the album did not open")
        backToAlbumsRoot()

        // Trash.
        let trashRow = app.buttons.matching(identifier: "trashRow").firstMatch
        XCTAssertTrue(trashRow.waitForExistence(timeout: 15), "no trash tile")
        for _ in 0..<4 where !trashRow.isHittable { app.swipeUp(); sleep(1) }
        trashRow.tap()
        XCTAssertTrue(element("trashScreen").waitForExistence(timeout: 20))
        openViewer(trashed)
        closeWithBack()
        XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 3), "the trash viewer did not close")
        backToAlbumsRoot()

        // A folder.
        let foldersRow = app.buttons.matching(identifier: "foldersRow").firstMatch
        XCTAssertTrue(foldersRow.waitForExistence(timeout: 15), "no folders tile")
        for _ in 0..<4 where !foldersRow.isHittable { app.swipeUp(); sleep(1) }
        foldersRow.tap()
        let folder = app.buttons.matching(identifier: "folderRow_/x").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20), "no folder row")
        folder.tap()
        openViewer(foldered)
        closeWithBack()
        XCTAssertFalse(element("viewerBackButton").waitForExistence(timeout: 3), "the folder viewer did not close")
    }

    /// AC-28: the controls are drawn as soon as the animation ends (the common volet).
    func test_AC_28() {
        launchSignedIn()
        assertControlsAtOpening(of: photo, hasFavorite: true, repetitions: 1)
    }

    /// AC-28.1: five openings of a photo of mine and five of a partner's.
    func test_AC_28_1() {
        launchSignedIn()
        assertControlsAtOpening(of: photo, hasFavorite: true, repetitions: 5)
        assertControlsAtOpening(of: partner, hasFavorite: false, repetitions: 5)
    }

    /// AC-28.2: with Reduce Motion the open and the close are fades.
    func test_AC_28_2() async throws {
        app.launchArguments += ["-uiTestReduceMotion", "YES"]
        launchSignedIn()
        arm(photo)

        // Open: the image is either on its thumbnail or on its final frame, never between.
        let opening = try await filmOpening(photo, name: "ac28-2-open", isVideo: false)
        let target = photoTarget(photo)
        for (i, frame) in opening.frames.enumerated() {
            guard let part = frame.parts[.my] else { continue }
            XCTAssertTrue(near(part.rect, opening.tile, 2) || near(part.rect, target, 1),
                          "open frame \(i): the image is moving: \(part.rect)")
        }
        let reference = XCUIScreen.main.screenshot().image
        assertControlsDrawn(now: reference, reference: reference, hasFavorite: true, label: "end of the fade")

        // Close by the button: same frame until it is gone.
        sleep(2)
        let byButton = try await filmClosing(name: "ac28-2-back") { closeWithBack() }
        let shown = byButton.compactMap { $0.parts[.my]?.rect }
        for (i, rect) in shown.enumerated() {
            XCTAssertTrue(near(rect, target, 1) || near(rect, tile(photo).frame, 2), "back frame \(i): moving: \(rect)")
        }

        // Open again, close by a drag: only the position follows the finger.
        openViewer(photo)
        sleep(2)
        let byDrag = try await filmClosing(name: "ac28-2-drag") { dragDown(400) }
        let sizes = byDrag.compactMap { $0.parts[.my]?.rect }.filter { $0.width > tile(photo).frame.width * 1.5 }
        if let first = sizes.first {
            for (i, rect) in sizes.enumerated() {
                XCTAssertEqual(rect.width, first.width, accuracy: 1, "drag frame \(i): the image changed size")
                XCTAssertEqual(rect.height, first.height, accuracy: 1, "drag frame \(i): the image changed size")
            }
        } else {
            XCTFail("the dragged image was never seen")
        }
    }
}
