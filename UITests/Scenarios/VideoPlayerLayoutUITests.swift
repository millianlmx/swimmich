import CoreGraphics
import ImageIO
import XCTest

/// End-to-end scenario for the video player's transport placement. One
/// `XCTestCase` per feature, in its own file, against its own committed stub —
/// the pattern `RecentlyTakenUITests` set for the suite.
///
/// It drives the real app (onboarding → SSO → the Photos grid) and pins three
/// claims in ONE run:
///
///   AC-1 — on a video page of the viewer the transport block (play/pause,
///          ±15 s, scrubber, time labels) is anchored to the BOTTOM of the PAGE
///          (the pager's own box, which is a sub-rectangle of the screen), above
///          the filmstrip, and the page really is PLAYING while it is checked
///          (the scrubber value moves between two reads). The probe is
///          page-relative because the screen is not the surface: measured on
///          this harness, the viewer's page box is {{0, 118}, {402, 261}} inside
///          an 874 pt screen on one run and {{0, 118}, {402, 562}} on another
///          (it varies with the inset the viewer inherits), so "lower half of
///          the screen" is unreliable even for a correct fix.
///   AC-2 — the image stays whole: a black letterbox band above a green image,
///          both probed against the page. The fixture is a 480x270 flat green
///          clip, so a layer that cropped it to fill the page
///          (`.resizeAspectFill`) would read GREEN where this scenario reads
///          black.
///   AC-3 — Souvenirs are untouched: the memory's hero video plays with NO
///          transport of its own, and the moment's four action buttons stay in
///          the bottom half.
///
/// This scenario FAILS on the tree before the fix. Measured on the pre-fix tree
/// with the identifiers in place (2026-10-07), so that the failure names the
/// DEFECT and not just the missing identifier: `page = (0, 118, 402, 562)`,
/// `scrubber.maxY = 426.7` — the transport sat 253.3 pt above the page's bottom
/// edge and the anchoring assertion (`page.maxY - scrubber.maxY < 60`) failed.
/// Without the identifiers (the tree as it was) it stops one step earlier, on
/// `scrubber.waitForExistence`.
///
/// The fixture is 12 SECONDS long, not 3: a 3 s clip reached `.ended` before the
/// geometry assertions ran, and `.ended` replaces the play/pause row with the
/// Replay button (measured: `videoPlayerPlayPause` existed=false) — the state the
/// AC-1 row is about would never have been on screen.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/video-player-layout.uitest.log \
///         UITests/stubs/immich_stub_video_player.py VideoPlayerLayoutUITests/test_videoPlayerLayout \
///         --erase
///
/// `--erase` is not decoration: the stub port is drawn at random per run, and a
/// session persisted against a dead port is only dropped on a 401 — an erased
/// device is the one that walks onboarding and types THIS run's URL.
final class VideoPlayerLayoutUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The stub's own addresses — `immich_stub_video_player.py` carries the same
    /// two ids in its docstring.
    private let videoID = "aaaaaaaa-1111-4111-8111-000000000001"
    private let memoryID = "dddddddd-4444-4444-8444-000000000001"

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
    // Copied from `VideoDurationUITests` (itself copied from
    // `RecentlyTakenUITests`) on purpose: these are `private` there and each
    // scenario owns its copy — extracting them into a shared support file would
    // be a second convention next to the existing one.

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
    /// itself. This scenario clicks, like `VideoDurationUITests` does.
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
        // Scrolling dismisses the keyboard, so the CTA is really hittable when
        // it is tapped, and a bounded retry covers the animating frame.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("v02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// Every label on screen — what a failed assertion names instead of saying
    /// only "not found".
    private func screenLabels() -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex.map(\.label)
    }

    // MARK: - Transport helpers (this scenario's own)

    /// `Slider` and `Button` are the element types the app exposes; the lookups
    /// go through the element type first (a SwiftUI slider is an adjustable) and
    /// fall back to any descendant, because a wrong type would make the whole
    /// AC-1 block read "missing" on a screen that renders it.
    private func scrubber() -> XCUIElement {
        let slider = app.sliders["videoPlayerScrubber"].firstMatch
        return slider.exists ? slider : app.descendants(matching: .any)
            .matching(identifier: "videoPlayerScrubber").firstMatch
    }

    private func playPause() -> XCUIElement {
        app.buttons["videoPlayerPlayPause"].firstMatch
    }

    /// AC-1's "really playing" gate: the scrubber's value must MOVE. A paused
    /// page would satisfy every geometric assertion while proving nothing about
    /// the state the controls are checked in.
    private func waitForPlaybackProgress(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let first = element.value as? String
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(1_500_000)
            let next = element.value as? String
            if let first, let next, first != next { return true }
        }
        return false
    }

    /// Mean colour of a `radius`-wide block around `point` (screen POINTS), read
    /// off a screenshot's PNG. A 3x3 mean for the default `radius` 1: one pixel
    /// of H.264 output is not evidence, a small average survives compression
    /// noise. Decoded with ImageIO rather than UIKit — a UI-test bundle has no
    /// business depending on the app's UI framework for four bytes.
    private func averageColor(_ png: Data, at point: CGPoint, radius: Int = 1) -> (r: Int, g: Int, b: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // The screenshot is in device PIXELS; the frames below are in points.
        let scale = CGFloat(image.width) / app.frame.width
        let side = radius * 2 + 1
        let rect = CGRect(x: (point.x * scale).rounded() - CGFloat(radius),
                          y: (point.y * scale).rounded() - CGFloat(radius),
                          width: CGFloat(side), height: CGFloat(side))
        // Cropping first keeps the flip question out of it: a symmetric 3x3
        // block averages the same whichever way its rows are ordered.
        guard let region = image.cropping(to: rect) else { return nil }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sums = (r: 0, g: 0, b: 0)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            sums.r += Int(bytes[index])
            sums.g += Int(bytes[index + 1])
            sums.b += Int(bytes[index + 2])
        }
        let count = side * side
        return (sums.r / count, sums.g / count, sums.b / count)
    }

    /// AC-2, as pixels: on the video page, the middle of the PAGE is GREEN (the
    /// fixture's flat frame) and the strip just under the page's top edge is
    /// BLACK. Both probes are page-relative for the same reason AC-1's are (the
    /// page is a sub-rectangle of the screen), and both are a 3x3 mean so one
    /// compression artefact cannot decide the verdict. Bounded, not instant —
    /// the decoder needs a moment after the `playback` bytes arrive.
    private func assertVideoImageIsLetterboxed() {
        let back = app.buttons["viewerBackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 20), "viewerBackButton missing")
        let page = app.collectionViews.firstMatch.frame
        XCTAssertFalse(page.isEmpty, "the viewer's pager has no frame")
        // 6 pt below the page's top edge: inside the letterbox band of a 16:9
        // image (half of the 35 pt a 261 pt page leaves) and inside the black
        // the page paints even before the first frame arrives.
        let topProbe = CGPoint(x: page.midX, y: page.minY + 6)
        // The middle probe cannot be the page's middle: the transport covers the
        // page's bottom, and in a SHORT page its play/pause button reaches up to
        // the page's centre — measured, `page.midY` sampled the button
        // (middle=(r: 245, g: 251, b: 244)) instead of the video. The fixture is
        // 16:9 and the image is centered in the page, so its top edge is
        // derivable, and 20 pt below it is inside the image and clear of the
        // controls in every layout measured (page 261 pt: image 135–361,
        // transport from 244; page 562 pt: image 286–512, transport from 545).
        let imageHeight = min(page.height, page.width * 9.0 / 16.0)
        let middleProbe = CGPoint(x: page.midX, y: page.midY - imageHeight / 2 + 20)

        let deadline = Date().addingTimeInterval(10)
        var middle: (r: Int, g: Int, b: Int)?
        var top: (r: Int, g: Int, b: Int)?
        repeat {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            middle = averageColor(png, at: middleProbe)
            top = averageColor(png, at: topProbe)
            if let middle, middle.g > 120, middle.r < 100, middle.b < 100 { break }
            usleep(500_000)
        } while Date() < deadline

        guard let middle, let top else {
            XCTFail("AC-2: could not read the screenshot")
            return
        }
        XCTAssertTrue(middle.g > 120 && middle.r < 100 && middle.b < 100,
                      "AC-2: no green video image at \(middleProbe) "
                      + "(middle=\(middle), page=\(page)) — the page is not playing the fixture")
        XCTAssertTrue(top.r < 60 && top.g < 60 && top.b < 60,
                      "AC-2: the strip under the page's top edge is not a black letterbox band "
                      + "(top=\(top), page=\(page)) — a cropped `.resizeAspectFill` page reads green there")
    }

    /// How many `…/video/playback` requests the stub has served so far. TWO per
    /// video read (AVFoundation probes `Range: bytes=0-1`, then asks for the
    /// body), which is why the memory leg asserts on a DELTA: a total of two is
    /// satisfied by the viewer alone.
    private func playbackRequestCount() -> Int {
        struct Entry: Decodable { let path: String }
        guard let url = URL(string: "\(stub)/__requests") else { return -1 }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var count = -1
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) {
                count = entries.filter { $0.path.hasSuffix("/video/playback") }.count
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return count
    }

    /// The playback route is asked twice per read, and the hero video starts
    /// preparing when the moment view appears — poll rather than race it.
    private func waitForPlaybackRequests(atLeast target: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = playbackRequestCount()
        while count < target, Date() < deadline {
            usleep(500_000)
            count = playbackRequestCount()
        }
        return count
    }

    private func tapTab(_ labels: [String]) -> Bool {
        let button = app.tabBars.buttons.matching(labelPredicate(labels)).firstMatch
        guard button.waitForExistence(timeout: 20) else { return false }
        button.tap()
        return true
    }

    // MARK: - Scenario

    func test_videoPlayerLayout() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful; the
        // launcher's drop of `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("v01-welcome")
            walkOnboardingToLogin()
            shot("v02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" over the shell, and a modal
        // swallows every tap: the tiles would never be reachable under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("v03-whats-new")
            whatsNewDone.tap()
        }

        // Leg 1 — the viewer's video page (AC-1 and AC-2).
        XCTAssertTrue(tile(videoID).waitForExistence(timeout: 30),
                      "the video tile never rendered — screen reads: \(screenLabels())")
        shot("v04-video-tile")
        tile(videoID).tap()

        let scrubber = scrubber()
        XCTAssertTrue(scrubber.waitForExistence(timeout: 30),
                      "the transport never appeared on the video page — screen reads: \(screenLabels())")

        // AC-1 is about the controls as they are shown DURING playback.
        XCTAssertTrue(waitForPlaybackProgress(scrubber),
                      "the video never advanced past its first frame (scrubber reads "
                      + "\(String(describing: scrubber.value))) — screen reads: \(screenLabels())")
        shot("v05-viewer-transport")

        // The transport's surface is the PAGE, not the screen: the viewer
        // reserves room for its chrome and (measured on this harness) for the
        // keyboard inset left by onboarding, so the page box is a sub-rectangle
        // of the screen — asserting "lower half of the screen" would fail on a
        // correct fix. The page is the pager's cell; `app.collectionViews` is
        // what the viewer's `TabView` publishes.
        let page = app.collectionViews.firstMatch.frame
        XCTAssertFalse(page.isEmpty, "the viewer's pager has no frame")
        XCTAssertGreaterThan(scrubber.frame.midY, page.midY,
                             "AC-1: the scrubber is not in the lower half of the page "
                             + "(scrubber midY=\(scrubber.frame.midY), page=\(page))")
        // The whole point of the fix, in one number: the block sits ON the page's
        // bottom edge — only the time labels and the transport's own 12 pt
        // padding remain under the scrubber. A centered block leaves the slider
        // ~100 pt above that edge.
        XCTAssertLessThan(page.maxY - scrubber.frame.maxY, 60,
                          "AC-1: the transport is not anchored to the page's bottom edge "
                          + "(scrubber maxY=\(scrubber.frame.maxY), page=\(page))")
        let playPauseFrame = playPause().frame
        XCTAssertGreaterThan(playPauseFrame.midY, page.midY,
                             "AC-1: the play/pause row is not in the lower half of the page "
                             + "(button=\(playPauseFrame), page=\(page))")
        let share = app.buttons["viewerShareButton"]
        XCTAssertTrue(share.exists, "the viewer's bottom bar is missing — screen reads: \(screenLabels())")
        XCTAssertLessThanOrEqual(scrubber.frame.maxY, share.frame.minY - 8,
                                 "AC-1: the transport is not clear of the bottom chrome "
                                 + "(scrubber maxY=\(scrubber.frame.maxY), share minY=\(share.frame.minY))")

        // AC-2 — same page, still playing: whole image, black band above it.
        assertVideoImageIsLetterboxed()

        // Leg 2 — Souvenirs (AC-3), with leg 1's request count as the baseline.
        let beforeMemory = playbackRequestCount()
        XCTAssertGreaterThanOrEqual(beforeMemory, 2,
                                    "AC-3: the viewer's own video was never read (playback requests=\(beforeMemory))")
        app.buttons["viewerBackButton"].tap()
        XCTAssertTrue(tapTab(["Memories", "Erinnerungen", "Souvenirs", "Recuerdos", "Ricordi"]),
                      "the Memories tab is unreachable — screen reads: \(screenLabels())")

        let card = app.descendants(matching: .any).matching(identifier: "memoryCard_\(memoryID)").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30),
                      "the memory card never rendered — screen reads: \(screenLabels())")
        card.tap()

        let save = app.buttons["memoryMomentSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 30),
                      "the memory moment never opened — screen reads: \(screenLabels())")
        shot("v06-memory-moment")

        // Verification 2 of S-3 — the negative control: a fix that rendered the
        // transport everywhere would show both elements here and fail.
        XCTAssertFalse(app.sliders["videoPlayerScrubber"].exists,
                       "AC-3: the memory moment shows the viewer's scrubber")
        XCTAssertFalse(app.buttons["videoPlayerPlayPause"].exists,
                       "AC-3: the memory moment shows the viewer's play/pause button")

        // Verification 3 of S-3 — the moment's own bottom panel, unchanged.
        for identifier in ["memoryMomentSave", "memoryMomentAddPhotos",
                           "memoryMomentRemovePhoto", "memoryMomentDelete"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists,
                          "AC-3: \(identifier) missing on the memory moment — screen reads: \(screenLabels())")
            XCTAssertGreaterThan(button.frame.midY, app.frame.midY,
                                 "AC-3: \(identifier) is not in the bottom half "
                                 + "(midY=\(button.frame.midY), screen midY=\(app.frame.midY))")
        }

        // Verification 1 of S-3 — a video WAS read in Souvenirs. The hero starts
        // preparing when the moment appears, so this polls; the delta is the
        // evidence, because leg 1 already accounted for `beforeMemory` requests.
        let afterMemory = waitForPlaybackRequests(atLeast: beforeMemory + 2, timeout: 15)
        XCTAssertGreaterThanOrEqual(afterMemory, 2,
                                    "AC-3: fewer than two playback requests in the whole run (\(afterMemory))")
        XCTAssertGreaterThanOrEqual(afterMemory, beforeMemory + 2,
                                    "AC-3: the memory's hero video was never read "
                                    + "(playback requests \(beforeMemory) → \(afterMemory))")
    }
}
