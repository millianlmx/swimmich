import XCTest

/// End-to-end scenarios for **App Lock covering everything the app presents**
/// (the lock is a dedicated UIWindow above the whole scene, not an overlay of
/// `RootView`).
///
/// "Covered" is proven by PIXELS, never by the accessibility tree: while the
/// lock shows, the controller hides every other window from accessibility, so
/// "element absent / not hittable" would hold even if the lock did nothing.
/// The frames of what must be hidden are read BEFORE backgrounding, then the
/// screenshot taken once the lock is up must be pure `BgPrimary` (white, the
/// appearance is forced light) over those frames.
///
/// Face ID is driven through the simulator's own Darwin notifications, posted
/// from this process (it runs inside the simulator); the app keeps the real
/// `LAContext`. Run each test with the launcher, on an erased device:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/app-lock.uitest.log \
///         UITests/stubs/immich_stub_locked_folder.py AppLockUITests/<test> --erase
final class AppLockUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"
    private let pin = "123456"
    private let lockedAsset = "dddddddd-1111-4111-8111-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
        FaceID.enroll()
    }

    // MARK: - Face ID (simulator Darwin notifications, undocumented)

    private enum FaceID {
        private typealias Post = @convention(c) (UnsafePointer<CChar>) -> UInt32
        private typealias Register = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> UInt32
        private typealias SetState = @convention(c) (Int32, UInt64) -> UInt32

        private static func symbol<T>(_ name: String, as type: T.Type) -> T {
            let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
            return unsafeBitCast(dlsym(rtldDefault, name)!, to: type)
        }

        private static func post(_ name: String) {
            _ = symbol("notify_post", as: Post.self)(name)
        }

        static func enroll() {
            let name = "com.apple.BiometricKit.enrollmentChanged"
            var token: Int32 = 0
            _ = symbol("notify_register_check", as: Register.self)(name, &token)
            _ = symbol("notify_set_state", as: SetState.self)(token, 1)
            post(name)
        }

        static func match() { post("com.apple.BiometricKit_Sim.pearl.match") }
        static func noMatch() { post("com.apple.BiometricKit_Sim.pearl.nomatch") }
    }

    // MARK: - Stub + generic helpers (copied per feature, see ReadOnlyModeUITests)

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

    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func tapAnyButton(_ labels: [String], timeout: TimeInterval = 20) -> Bool {
        let predicate = labelPredicate(labels)
        for candidate in [app.buttons.matching(predicate).firstMatch, app.buttons.containing(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screenText() -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(24).joined(separator: " | ")
    }

    // MARK: - Sign-in walk

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

    private func tapAuthorizeInProvider(timeout: TimeInterval = 20) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        for candidate in [safari.links.matching(predicate).firstMatch, safari.buttons.matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
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
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(["Sign in to Immich", "Connectez-vous à Immich"], timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — screen reads: \(screenText())")
    }

    /// Onboarding → OAuth → shell, "What's New" cleared, timeline rendered.
    private func reachShell() {
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — screen reads: \(screenText())")
    }

    // MARK: - Navigation helpers

    /// Opens the Me sheet and scrolls the hub until `identifier` exists.
    private func openMe(scrollingTo identifier: String) -> XCUIElement {
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "Profile avatar missing")
        avatar.tap()
        sleep(4) // the sheet animates in; its Form publishes rows only after
        let target = element(identifier)
        for _ in 0..<8 where !target.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "no '\(identifier)' in the Me hub — \(screenText())")
        return target
    }

    /// The Me sheet's bar: the lowest one on screen (the timeline's sits under it).
    private func sheetNavigationBar() -> XCUIElement {
        let bars = app.navigationBars.allElementsBoundByIndex
        return bars.max { $0.frame.minY < $1.frame.minY } ?? app.navigationBars.firstMatch
    }

    private func regions(_ screen: CGRect, plus rects: [CGRect], step: CGFloat) -> [(rect: CGRect, step: CGFloat)] {
        [(rect: screen, step: 16)] + rects.map { (rect: $0, step: step) }
    }

    private func closeMeSheet() {
        let start = sheetNavigationBar().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        for _ in 0..<3 where element("appLockToggle").exists {
            start.press(forDuration: 0.1, thenDragTo: end)
            sleep(1)
        }
    }

    /// Turns "Require Face ID" on and concludes the activation prompt with a
    /// matching face (the Me sheet stays open).
    private func enableAppLock() {
        let toggle = openMe(scrollingTo: "appLockToggle")
        if (toggle.value as? String) != "1" {
            tapAppLockToggle()
            sleep(2) // the activation prompt is presented
            FaceID.match()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            XCTAssertTrue(promptButton(springboard).waitForNonExistence(timeout: 10), "the activation prompt did not close")
        }
        XCTAssertTrue(waitUntil(10) { (toggle.value as? String) == "1" }, "Require Face ID did not turn on")
    }

    /// Taps the toggle without concluding any prompt. Falls back to the switch
    /// itself when tapping the row did not flip the value.
    private func tapAppLockToggle() {
        let toggle = element("appLockToggle")
        let before = toggle.value as? String
        toggle.tap()
        if !waitUntil(3, { (toggle.value as? String) != before }) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
    }

    /// Home, back, and the lock must NOT appear.
    private func backgroundAndBackExpectingNoLock() {
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertFalse(element("AppLockOverlay").waitForExistence(timeout: 5), "the lock showed although the setting is off")
    }

    /// Cold relaunch (the session stays signed in). The onboarding walk only
    /// knows en/fr, so readiness is the profile avatar, not a tab label.
    private func relaunch(language: String?) {
        app.terminate()
        app.launchArguments = language.map { ["-AppleLanguages", "(\($0))", "-AppleLocale", "\($0)_\($0.uppercased())"] } ?? []
        app.launch()
        XCTAssertTrue(app.buttons.matching(identifier: "profileAvatar").firstMatch.waitForExistence(timeout: 30),
                      "the relaunch did not reach the shell — \(screenText())")
    }

    private func openViewer() {
        let tile = element("assetTile_\(photo)")
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "timeline tile missing")
        tile.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the viewer never showed its top bar — \(screenText())")
    }

    /// Details live on the row on wide screens, behind the ⋯ menu at 402 pt.
    private func openViewerInfo() {
        let direct = app.buttons.matching(identifier: "viewerDetailsButton").firstMatch
        if direct.waitForExistence(timeout: 3) {
            direct.tap()
        } else {
            let overflow = app.buttons.matching(identifier: "viewerOverflowMenu").firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 10), "no overflow pill — \(screenText())")
            overflow.tap()
            let details = element("viewerMenuDetails")
            XCTAssertTrue(details.waitForExistence(timeout: 10), "no Details in the ⋯ menu")
            details.tap()
        }
        XCTAssertTrue(element("viewerInfoClose").waitForExistence(timeout: 20), "the info panel never opened")
    }

    /// What the Info panel reads, below its close button.
    private func infoLabels() -> [String] {
        let top = element("viewerInfoClose").frame.minY
        return app.staticTexts.allElementsBoundByIndex
            .filter { $0.frame.minY >= top && !$0.label.isEmpty }
            .map(\.label).sorted()
    }

    // MARK: - Background / prompt helpers

    private func sendToBackgroundAndBack() {
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(element("AppLockOverlay").waitForExistence(timeout: 30),
                      "the lock did not show on return — \(screenText())")
    }

    private func promptButton(_ springboard: XCUIApplication) -> XCUIElement {
        springboard.buttons.matching(labelPredicate(["Cancel", "Annuler", "Abbrechen"])).firstMatch
    }

    /// Face not recognised, then the system prompt cancelled: the lock stays.
    private func failAndCancelPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        sleep(2) // the prompt is launched automatically on return
        FaceID.noMatch()
        let cancel = promptButton(springboard)
        if !cancel.waitForExistence(timeout: 10) {
            // Process hosting the prompt on iOS 26 is an inference: record what was seen.
            XCTFail("no Cancel button in the Face ID prompt — springboard reads:\n\(springboard.debugDescription)")
            return
        }
        cancel.tap()
        sleep(1)
    }

    /// "Unlock" → prompt → face recognised.
    private func unlockWithFaceID() {
        let button = element("appLockUnlockButton")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Unlock button on the lock")
        button.tap()
        sleep(2)
        FaceID.match()
        XCTAssertTrue(element("AppLockOverlay").waitForNonExistence(timeout: 20), "the lock did not lift")
    }

    // MARK: - Pixels

    /// Every sampled point of every region must be pure `BgPrimary` (white, light
    /// appearance) outside the status bar, the home indicator and the lock's own
    /// controls (+8 pt). Frames MUST have been read before backgrounding.
    private func assertCoveredByLock(_ regions: [(rect: CGRect, step: CGFloat)],
                                     file: StaticString = #filePath, line: UInt = #line) {
        let overlay = element("AppLockOverlay")
        XCTAssertTrue(overlay.waitForExistence(timeout: 30), "no lock on screen", file: file, line: line)
        XCTAssertTrue(waitUntil(10) { overlay.frame == self.app.frame },
                      "the lock is not full screen: \(overlay.frame) vs \(app.frame)", file: file, line: line)
        Thread.sleep(forTimeInterval: 0.5)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let cg = screenshot.image.cgImage else {
            return XCTFail("screenshot has no bitmap", file: file, line: line)
        }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not read the screenshot pixels", file: file, line: line)

        let scale = CGFloat(width) / app.frame.width
        let ownControls = overlay.descendants(matching: .any).allElementsBoundByIndex
            .map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        var offenders: [String] = []
        var sampled = 0
        for (rect, step) in regions {
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    defer { x += step }
                    let point = CGPoint(x: x, y: y)
                    guard y >= 56, y <= app.frame.height - 40, !ownControls.contains(point),
                          x >= 0, y >= 0, x < app.frame.width else { continue }
                    let px = min(width - 1, Int(x * scale)), py = min(height - 1, Int(y * scale))
                    let base = (py * width + px) * 4
                    sampled += 1
                    let white = (0..<3).allSatisfy { abs(Int(pixels[base + $0]) - 255) <= 6 }
                    if !white, offenders.count < 6 {
                        offenders.append("(\(Int(x)),\(Int(y)))=\(pixels[base]),\(pixels[base + 1]),\(pixels[base + 2])")
                    }
                }
                y += step
            }
        }
        XCTAssertGreaterThan(sampled, 0, "no point was sampled", file: file, line: line)
        XCTAssertTrue(offenders.isEmpty, "content visible through the lock at \(offenders)", file: file, line: line)
    }

    private func launchSignedIn() {
        reset()
        setProvider("manual")
        app.launch()
        reachShell()
    }

    // MARK: - Scenarios

    /// AC-1 (B-1): the full-screen viewer is covered after background → foreground.
    func test_AC_1_viewerCoveredAfterBackground() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        openViewer()
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch.frame

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        assertCoveredByLock([(app.frame, 16), (back, 2)])
    }

    /// AC-2 (B-1): the Me sheet, handle included, is covered.
    func test_AC_2_meSheetCovered() throws {
        launchSignedIn()
        enableAppLock()
        let toggle = element("appLockToggle").frame
        let bar = sheetNavigationBar().frame
        let handle = CGRect(x: app.frame.midX - 24, y: bar.minY - 16, width: 48, height: 16)

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        assertCoveredByLock([(app.frame, 16), (toggle, 4), (bar, 4), (handle, 2)])
    }

    /// AC-3 (B-1): the open locked folder is covered; after unlock it shows its PIN door.
    func test_AC_3_lockedFolderCoveredThenPinDoor() throws {
        launchSignedIn()
        enableAppLock()
        let row = openMe(scrollingTo: "lockedFolderRow")
        row.tap()
        let create = element("lockedFolderCreatePINButton")
        XCTAssertTrue(create.waitForExistence(timeout: 25), "no create-PIN door — \(screenText())")
        for field in ["lockedFolderPINField", "lockedFolderConfirmPINField"] {
            let secure = app.secureTextFields[field]
            XCTAssertTrue(secure.waitForExistence(timeout: 15), "\(field) missing")
            secure.tap()
            secure.typeText(pin)
        }
        create.tap()
        XCTAssertTrue(element("lockNowButton").waitForExistence(timeout: 30), "the folder did not open")
        XCTAssertTrue(element("assetTile_\(lockedAsset)").waitForExistence(timeout: 20), "no locked tile")
        let tiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_dddddddd'"))
            .allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        assertCoveredByLock(regions(app.frame, plus: tiles, step: 4))

        unlockWithFaceID()
        XCTAssertTrue(app.secureTextFields["lockedFolderPINField"].waitForExistence(timeout: 15),
                      "the folder must re-lock behind App Lock and show its PIN door")
    }

    /// AC-4 (B-1): the viewer's Info sheet and the viewer behind it are covered.
    func test_AC_4_viewerInfoSheetCovered() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        openViewer()
        openViewerInfo()
        let close = element("viewerInfoClose").frame
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch.frame
        let sheet = CGRect(x: 0, y: close.minY - 16, width: app.frame.width,
                           height: app.frame.height - close.minY + 16)

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        assertCoveredByLock([(app.frame, 16), (close, 2), (back, 2), (sheet, 8)])
    }

    /// AC-7 (B-2): taps and swipes on the lock do not reach the viewer behind.
    func test_AC_7_tapsAndSwipesDoNotReachViewer() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        openViewer()
        openViewerInfo()
        let before = infoLabels()

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        let overlay = element("AppLockOverlay")
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.12)).tap()
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.85)))
        XCTAssertTrue(overlay.exists, "the lock must still be up")

        unlockWithFaceID()
        XCTAssertEqual(infoLabels(), before, "the Info panel changed behind the lock")
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.exists,
                      "the viewer was closed behind the lock")
    }

    /// AC-9 (B-3): viewer + Info sheet come back exactly as they were.
    func test_AC_9_stateRestoredAfterUnlock() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        openViewer()
        openViewerInfo()
        let before = infoLabels()

        sendToBackgroundAndBack()
        sleep(2) // the automatic prompt is up
        FaceID.match()
        XCTAssertTrue(element("AppLockOverlay").waitForNonExistence(timeout: 20), "the lock did not lift")
        XCTAssertTrue(element("viewerInfoClose").waitForExistence(timeout: 10), "the Info panel was closed")
        XCTAssertEqual(infoLabels(), before)
    }

    /// AC-10 (B-3): a cancelled prompt is not relaunched; Unlock retries.
    func test_AC_10_cancelledPromptStaysOnLock() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        openViewer()

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<5 {
            XCTAssertFalse(promptButton(springboard).exists, "the prompt was relaunched on its own")
            XCTAssertTrue(element("appLockUnlockButton").exists, "Unlock vanished")
            sleep(1)
        }
        unlockWithFaceID()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.isHittable,
                      "the content is not usable after unlock")
    }

    /// AC-17 (B-7): a cold launch is locked before any content, and prompts by itself.
    func test_AC_17_coldLaunchCoveredAndPrompted() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        let tiles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty && $0.minY > 0 }

        app.terminate()
        app.launch()
        XCTAssertTrue(element("AppLockOverlay").waitForExistence(timeout: 30), "no lock at cold launch")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(promptButton(springboard).waitForExistence(timeout: 15),
                      "the prompt was not launched automatically — springboard reads:\n\(springboard.debugDescription)")

        failAndCancelPrompt()
        assertCoveredByLock(regions(app.frame, plus: tiles, step: 4))
        unlockWithFaceID()
        XCTAssertTrue(element("assetTile_\(photo)").waitForExistence(timeout: 20), "timeline not reachable after unlock")
    }

    /// AC-21 (B-2, B-3): no keyboard over the lock; typed text survives.
    func test_AC_21_searchKeyboardNotOverLock() throws {
        launchSignedIn()
        enableAppLock()
        closeMeSheet()
        let tab = app.tabBars.buttons.matching(labelPredicate(["Search", "Recherch", "Suche"])).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Search tab")
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("plage")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "no keyboard")
        let keyboardFrame = keyboard.frame

        sendToBackgroundAndBack()
        failAndCancelPrompt()
        assertCoveredByLock([(app.frame, 16), (keyboardFrame, 8)])

        unlockWithFaceID()
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "plage", "the typed text was lost")
    }

    // MARK: - Activation conditioned on authentication
    //
    // Prefixed `test_Activation_AC_` (not `test_AC_`): the sister feature owns
    // AC-1…AC-22 above. The three "incapable device" scenarios (AC-14 UI part,
    // AC-33, AC-34 UI part) are NOT written: whether an erased simulator with
    // no enrolled Face ID fails `canEvaluatePolicy` was never measured (the
    // repo comment and an iOS 9.2 report say it passes with a passcode screen),
    // and the app has no test hook to force the probe. Their unit-level proof
    // is `AppLockViewModelTests.test_Activation_AC_14_…` + the catalog test.

    /// AC-15 (B-6): a failed then cancelled activation prompt turns off, silently.
    func test_Activation_AC_15_failedPromptTurnsOffSilently() throws {
        launchSignedIn()
        let toggle = openMe(scrollingTo: "appLockToggle")
        tapAppLockToggle()
        failAndCancelPrompt()
        XCTAssertTrue(waitUntil(10) { (toggle.value as? String) == "0" }, "the toggle did not go back to off")
        XCTAssertFalse(element("appLockUnavailableNotice").exists, "a cancelled prompt must stay silent")
        closeMeSheet()
        backgroundAndBackExpectingNoLock()
    }

    /// AC-16 (B-6): a matched face keeps the toggle on, and the next return locks.
    func test_Activation_AC_16_successKeepsOnAndLocksNextReturn() throws {
        launchSignedIn()
        enableAppLock()
        XCTAssertEqual(element("appLockToggle").value as? String, "1")
        closeMeSheet()
        sendToBackgroundAndBack()
    }

    /// AC-30 (B-6): neither the mask nor the lock shows while the prompt is up, or after.
    func test_Activation_AC_30_noCoverDuringActivationPrompt() throws {
        launchSignedIn()
        _ = openMe(scrollingTo: "appLockToggle")
        tapAppLockToggle()
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(promptButton(springboard).waitForExistence(timeout: 10), "no activation prompt")
        XCTAssertFalse(element("AppLockPrivacyMask").exists, "mask shown during the activation prompt")
        XCTAssertFalse(element("AppLockOverlay").exists, "lock shown during the activation prompt")

        FaceID.match()
        XCTAssertTrue(promptButton(springboard).waitForNonExistence(timeout: 10), "the prompt did not close")
        XCTAssertFalse(element("AppLockPrivacyMask").waitForExistence(timeout: 3), "mask shown after activation")
        XCTAssertFalse(element("AppLockOverlay").exists, "lock shown after activation")
        XCTAssertTrue(element("appLockToggle").isHittable, "the Me sheet is not usable after activation")
    }

    /// AC-31 (B-30): turning off needs no prompt and nothing locks afterwards.
    func test_Activation_AC_31_disableWithoutPrompt() throws {
        launchSignedIn()
        enableAppLock()
        tapAppLockToggle()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(promptButton(springboard).waitForExistence(timeout: 4), "disabling must not prompt")
        XCTAssertTrue(waitUntil(10) { (self.element("appLockToggle").value as? String) == "0" },
                      "the toggle did not turn off")
        closeMeSheet()
        backgroundAndBackExpectingNoLock()
    }

    /// AC-32 (B-31): killed during the activation prompt, the app relaunches unlocked and off.
    func test_Activation_AC_32_killDuringPromptRelaunchesUnlockedAndOff() throws {
        launchSignedIn()
        _ = openMe(scrollingTo: "appLockToggle")
        tapAppLockToggle()
        sleep(2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(promptButton(springboard).waitForExistence(timeout: 10), "no activation prompt")

        relaunch(language: nil)
        XCTAssertFalse(element("AppLockOverlay").waitForExistence(timeout: 10), "the relaunch came up locked")
        let toggle = openMe(scrollingTo: "appLockToggle")
        XCTAssertEqual(toggle.value as? String, "0", "the setting survived the kill")
    }
}
