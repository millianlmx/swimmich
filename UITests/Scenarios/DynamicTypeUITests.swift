import UIKit
import XCTest

/// End-to-end scenarios for lot L-13 (AC-26 … AC-26.9): the text follows the text
/// size chosen in iOS settings, from the smallest size to AX5, without cutting an
/// essential label, shrinking it, or letting it run under another element; photo
/// grids and full-screen controls keep their layout.
///
/// Every scenario targets identifiers and the stub's data (long and short labels
/// side by side), never a localized label. "Shown whole" is measured as
/// "the long label is at least 1.8 times as tall as the short one and stays inside
/// the window"; "no overlap" as "no two visible texts / buttons / fields overlap by
/// more than 1 pt both ways, unless one contains the other".
///
/// Launch (stub first, then one test at a time):
///
///     python3 UITests/stubs/immich_stub_dynamic_type.py 8421
///
///     IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test \
///         -project ImmichSwiftUI.xcodeproj -scheme ImmichSwiftUI \
///         -destination 'platform=iOS Simulator,name=iPhone 17' \
///         -only-testing:ImmichSwiftUIUITests/DynamicTypeUITests/<test>
///
/// (`TEST_RUNNER_IMMICH_STUB_URL` is what the runner forwards to `IMMICH_STUB_URL`.)
/// The text size is an argument of the app's launch
/// (`-UIPreferredContentSizeCategoryName`), so it only reaches the app:
///
/// * `test_AC_26_4_appLock` runs on an ERASED device, like `AppLockUITests` (the Face ID
///   enrolment is a Darwin notification of the simulator, and a device that already
///   has a lock state would change the walk):
///
///       xcrun simctl erase <device>      # then boot it and run the test
///
/// * `test_AC_26_4_shareExtension` drives the share sheet of Photos, whose extension runs
///   in another process and follows the SIMULATOR's setting. Set it first, and seed a
///   photo whose file name is long (the sheet must show it whole):
///
///       xcrun simctl ui booted content_size accessibility-extra-extra-extra-large
///       xcrun simctl addmedia booted /tmp/Summer-holidays-in-the-Gorges-du-Verdon-with-the-whole-family.png
///
///   and put it back afterwards with `xcrun simctl ui booted content_size large`. Like
///   `ShareExtensionUITests`, the photo must be the newest one of the Photos library.
///
/// The CI runs every test of this class on its own freshly erased simulator, the
/// share extension with the prerequisites above (`Scripts/ci.sh`, one line per test
/// in `Scripts/ci-ui-scenarios.txt`); a test that skips itself fails it.
///
/// Helpers are copied from the other scenarios on purpose: one file per feature.
final class DynamicTypeUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        // `/__reset` puts the data back (the empty states of `/stub/dt-empty` included).
        reset()
    }

    // MARK: - The stub's data

    private let tiles = (1...6).map { String(format: "aaaaaaaa-1111-4111-8111-%012d", $0) }
    private let longAlbum = "dt-album-long"
    private let shortAlbum = "dt-album-short"
    private let longPartner = "dt-partner-long"
    private let shortPartner = "dt-partner-short"
    private let longUser = "dt-user-long"
    private let shortUser = "dt-user-short"
    private let longLink = "dt-link-long"
    private let shortLink = "dt-link-short"
    private let longPerson = "dt-person-long"
    private let shortPerson = "dt-person-short"
    private let longMemory = "dt-memory-long"
    private let shortMemory = "dt-memory-short"
    private let placeMemory = "dt-memory-place"

    /// `-UIPreferredContentSizeCategoryName` values.
    private enum TextSize: String {
        case xs = "UICTContentSizeCategoryXS"
        case l = "UICTContentSizeCategoryL"
        case xxxl = "UICTContentSizeCategoryXXXL"
        case ax2 = "UICTContentSizeCategoryAccessibilityL"
        case ax3 = "UICTContentSizeCategoryAccessibilityXL"
        case ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    // MARK: - Stub and generic helpers

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

    private func setEmptyCollections(_ on: Bool) { get("/stub/dt-empty?on=\(on ? 1 : 0)") }

    private func screenText() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(24))"
    }

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var windowFrame: CGRect { app.windows.firstMatch.frame }

    // MARK: - Measuring text

    /// The text of `identifier`: the static text carrying the id, else the first
    /// static text under the element carrying it (a button or a combined element
    /// hides the id of its text), else the element itself.
    private func textElement(_ identifier: String) -> XCUIElement {
        let direct = app.staticTexts.matching(identifier: identifier).firstMatch
        if direct.exists { return direct }
        let inner = element(identifier).staticTexts.firstMatch
        if inner.exists { return inner }
        return element(identifier)
    }

    /// Scrolls (down, then up) until `identifier` exists in the accessibility tree.
    @discardableResult
    private func reveal(_ identifier: String, timeout: TimeInterval = 6) -> Bool {
        let target = element(identifier)
        if target.waitForExistence(timeout: timeout) { return true }
        for goingDown in [true, false] {
            for _ in 0..<12 where !target.exists {
                if goingDown { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.4)
            }
            if target.exists { return true }
        }
        return false
    }

    /// The frame of the text `identifier`, read right after it was revealed
    /// (a lazy container forgets what scrolled away).
    private func textFrame(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        XCTAssertTrue(reveal(identifier), "no '\(identifier)' on screen — \(screenText())", file: file, line: line)
        return textElement(identifier).frame
    }

    private func textHeight(_ identifier: String) -> CGFloat { textFrame(identifier).height }

    /// The long label is shown whole: at least 1.8 times as tall as the short one
    /// (it wraps instead of being cut) and inside the window.
    private func assertFullyShown(long: String, short: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let longFrame = textFrame(long, file: file, line: line)
        let shortFrame = textFrame(short, file: file, line: line)
        XCTAssertGreaterThanOrEqual(longFrame.height, 1.8 * shortFrame.height,
                                    "\(long) (\(longFrame.height) pt) is not shown on more lines than \(short) (\(shortFrame.height) pt)",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(longFrame.minX, 0, "\(long) starts left of the window", file: file, line: line)
        XCTAssertLessThanOrEqual(longFrame.maxX, windowFrame.width + 0.5,
                                 "\(long) runs past the window's right edge", file: file, line: line)
    }

    /// The text is inside the window's width.
    private func assertInWindow(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let frame = textFrame(identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(identifier) starts left of the window", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, windowFrame.width + 0.5,
                                 "\(identifier) runs past the window's right edge", file: file, line: line)
    }

    /// Not smaller than the unconstrained reference text of the same screen.
    private func assertNotShrunk(_ identifier: String, reference: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let referenceHeight = textElement(reference).frame.height
        let height = textElement(identifier).frame.height
        XCTAssertGreaterThanOrEqual(height, referenceHeight - 0.5,
                                    "\(identifier) (\(height) pt) is smaller than \(reference) (\(referenceHeight) pt)",
                                    file: file, line: line)
    }

    /// A focused text field under the swipe's start point takes the drag for its
    /// cursor instead of scrolling: at AX5 the sign-in e-mail field, focused on
    /// appear, sits at the window's centre where `swipeUp()` starts. A drag from
    /// the top of the content scrolls instead, which dismisses the keyboard
    /// (`scrollDismissesKeyboard(.immediately)`) and frees the screen below it.
    private func dismissKeyboardByScrolling() {
        guard app.keyboards.count > 0 else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        _ = waitUntil(3) { app.keyboards.count == 0 }
    }

    /// Scrolls up until the element exists and is hittable.
    private func scrollToHittable(_ identifier: String, swipes: Int = 12,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        _ = target.waitForExistence(timeout: 6)
        if !(target.exists && target.isHittable) { dismissKeyboardByScrolling() }
        for _ in 0..<swipes where !(target.exists && target.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(target.exists && target.isHittable, "'\(identifier)' cannot be reached — \(screenText())",
                      file: file, line: line)
    }

    private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private func assertDisjoint(_ first: String, _ second: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let a = element(first), b = element(second)
        XCTAssertTrue(a.exists, "no '\(first)'", file: file, line: line)
        XCTAssertTrue(b.exists, "no '\(second)'", file: file, line: line)
        XCTAssertLessThanOrEqual(overlapArea(a.frame, b.frame), 1,
                                 "\(first) \(a.frame) overlaps \(second) \(b.frame)", file: file, line: line)
    }

    private func assertDisjointAndHittable(_ identifiers: [String],
                                           file: StaticString = #filePath, line: UInt = #line) {
        for (index, first) in identifiers.enumerated() {
            XCTAssertTrue(element(first).exists, "no '\(first)'", file: file, line: line)
            XCTAssertTrue(element(first).isHittable, "'\(first)' is not hittable", file: file, line: line)
            for second in identifiers[(index + 1)...] where element(second).exists {
                assertDisjoint(first, second, file: file, line: line)
            }
        }
    }

    /// Texts, buttons, fields and switches that are visible on the screen: no two
    /// overlap by more than 1 pt both ways, unless one contains the other (a text in
    /// its button).
    /// An element covered at its centre by a sheet is not hittable and is skipped.
    ///
    /// Content of a scroll view (`ScrollView`, `List`) that runs under fixed chrome
    /// (a floating bottom bar, a navigation bar, the tab bar) is not an overlap: at
    /// rest a long screen goes on under its translucent bar, and the bar's inset lets
    /// the content scroll clear of it (AC-26.3: "everything reachable by scrolling",
    /// proven by `scrollToHittable`). Overlaps inside the content, and inside the
    /// chrome, still fail. Only the app's main window is read (the keyboard lives
    /// in its own windows), and the tab bar and a sheet's grabber are skipped: they
    /// are the system's own controls, laid out by UIKit (the tab items' frames
    /// overlap by design; the grabber's frame is far larger than its drawn pill).
    private func assertNoOverlap(file: StaticString = #filePath, line: UInt = #line) {
        let main = app.windows.firstMatch
        let window = main.frame
        var seen: [(frame: CGRect, name: String, scrolls: Bool)] = []
        let types: [XCUIElement.ElementType] = [.staticText, .button, .textField, .secureTextField, .switch]
        let containers = [main.scrollViews, main.tables, main.collectionViews]
        func key(_ element: XCUIElement) -> String { "\(element.frame)|\(element.identifier)|\(element.label)" }
        for type in types {
            let scrolling = Set(containers.flatMap { $0.descendants(matching: type).allElementsBoundByIndex.map(key) })
            let skipped = Set(main.tabBars.descendants(matching: type).allElementsBoundByIndex.map(key))
            for candidate in main.descendants(matching: type).allElementsBoundByIndex {
                let frame = candidate.frame
                guard !frame.isEmpty, frame.intersects(window), candidate.isHittable else { continue }
                let id = key(candidate)
                guard !skipped.contains(id) else { continue }
                if type == .button && Self.sheetGrabberLabels.contains(candidate.label) { continue }
                // A button that carries a text is measured by that text (swept as a
                // static text): its own frame also spans an unclipped image, like
                // the album cards' filled covers, wider than what the card shows.
                if type == .button && candidate.staticTexts.count > 0 { continue }
                let name = candidate.identifier.isEmpty ? candidate.label : candidate.identifier
                seen.append((frame, name, scrolling.contains(id)))
            }
        }
        for (index, first) in seen.enumerated() {
            for second in seen[(index + 1)...] where first.scrolls == second.scrolls {
                // Neighbours stacked edge to edge share a sliver under 1 pt (rounded line
                // heights at the accessibility sizes): an overlap is more than 1 pt both ways.
                let shared = first.frame.intersection(second.frame)
                guard !shared.isNull, shared.width > 1, shared.height > 1 else { continue }
                let nested = first.frame.insetBy(dx: -1, dy: -1).contains(second.frame)
                    || second.frame.insetBy(dx: -1, dy: -1).contains(first.frame)
                XCTAssertTrue(nested,
                              "'\(first.name)' \(first.frame) overlaps '\(second.name)' \(second.frame)",
                              file: file, line: line)
            }
        }
    }

    /// The accessibility label of a sheet's system grabber, in the scenarios' languages.
    private static let sheetGrabberLabels: Set<String> = ["Sheet Grabber", "Aufzeichnungsblatt"]

    /// Height of one line of a UIKit text style at a size, for the single-line checks.
    private func lineHeight(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            .lineHeight
    }

    // MARK: - Sign-in

    /// The size and language of the last launch, so a helper can relaunch as is.
    private var launched: (size: TextSize, language: String) = (.l, "en")

    private func configure(_ size: TextSize, language: String) {
        launched = (size, language)
        let locale = language == "de" ? "de_DE" : "en_US"
        app.launchArguments = [
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            "-authServerURL", "()",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            // The slideshow opens paused: its chrome hides itself 3 s into a playing show.
            "-uiTestSlideshowAutoplayOff", "YES",
        ]
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

    /// The provider page loads in another process (`SafariViewService`): slow on a
    /// freshly erased device, so its "Authorize" link or button gets a long wait,
    /// during which the system's sign-in consent, when it shows late, is accepted.
    @discardableResult
    private func tapAuthorizeInProvider(timeout: TimeInterval = 60) -> Bool {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.alerts.buttons.matching(labelPredicate(["Continue", "Continuer"])).firstMatch
        let predicate = NSPredicate(format: "label CONTAINS 'Authorize'")
        let candidates = [safari.links.matching(predicate).firstMatch, safari.buttons.matching(predicate).firstMatch]
        let shown = waitUntil(timeout) {
            if consent.exists { consent.tap() }
            return candidates.contains { $0.exists }
        }
        guard shown, let authorize = candidates.first(where: { $0.exists }) else { return false }
        authorize.tap()
        return true
    }

    /// Welcome → server URL → login → SSO. `onScreen` is called with `welcomeTitle`,
    /// `serverURLTitle` and `loginTitle` once each screen is up.
    private func completeOnboarding(_ onScreen: ((String) -> Void)?) {
        XCTAssertTrue(element("welcomeTitle").waitForExistence(timeout: 30), "no welcome screen — \(screenText())")
        onScreen?("welcomeTitle")
        XCTAssertTrue(tapAnyButton(["Get Started", "Loslegen"], timeout: 30), "Welcome CTA missing")

        XCTAssertTrue(element("serverURLTitle").waitForExistence(timeout: 20), "no server URL screen — \(screenText())")
        onScreen?("serverURLTitle")
        let field = app.textFields["serverURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        field.tap()
        let seeded = (field.value as? String) ?? ""
        if !seeded.isEmpty && seeded != stub {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: seeded.count))
        }
        if (field.value as? String) != stub { field.typeText(stub) }

        // The same button checks the connection, then continues.
        var onLogin = false
        for _ in 0..<6 where !onLogin {
            if app.keyboards.count > 0 { app.swipeUp() }
            let cta = element("serverURLContinueButton")
            if cta.waitForExistence(timeout: 10), cta.isEnabled, cta.isHittable { cta.tap() }
            onLogin = element("loginTitle").waitForExistence(timeout: 8)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenText())")
        onScreen?("loginTitle")

        scrollToHittable("loginSSOButton")
        element("loginSSOButton").tap()
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
    }

    private func finishLaunch() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "the app never reached the shell — \(screenText())")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 8) {
            if !whatsNewDone.isHittable { scrollToHittable("whatsNewDoneButton") }
            whatsNewDone.tap()
        }
        XCTAssertTrue(element("assetTile_\(tiles[0])").waitForExistence(timeout: 40),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    /// Launches the app at `size`. On a signed-out device it walks the onboarding
    /// (`onScreen`, see `completeOnboarding`). With `onScreen` set while the session
    /// is still there, it signs out first, so the onboarding is on screen again.
    private func launchApp(_ size: TextSize, language: String = "en", onScreen: ((String) -> Void)? = nil) {
        app.terminate()
        configure(size, language: language)
        app.launch()
        var state = ""
        _ = waitUntil(45) {
            if element("welcomeTitle").exists { state = "onboarding"; return true }
            if app.tabBars.firstMatch.exists { state = "shell"; return true }
            return false
        }
        if state == "shell", onScreen != nil {
            signOut()
            state = "onboarding"
        }
        if state == "onboarding" || (state == "" && element("welcomeTitle").waitForExistence(timeout: 5)) {
            completeOnboarding(onScreen)
        }
        finishLaunch()
    }

    private func launchSignedIn(_ size: TextSize, language: String = "en") {
        reset()
        setProvider("manual")
        launchApp(size, language: language)
    }

    /// Cold relaunch at `size` (the session is kept).
    private func relaunch(_ size: TextSize, language: String = "en") {
        launchApp(size, language: language)
    }

    private func signOut() {
        openMe()
        scrollToHittable("logoutButton")
        element("logoutButton").tap()
        let confirm = element("logoutConfirmButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no logout confirmation — \(screenText())")
        confirm.tap()
        XCTAssertTrue(element("welcomeTitle").waitForExistence(timeout: 40), "logout did not reach the welcome screen")
    }

    // MARK: - Navigation

    private func selectTab(_ index: Int) {
        let tab = app.tabBars.firstMatch.buttons.element(boundBy: index)
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no tab \(index) — \(screenText())")
        tab.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func openPhotosTab() { selectTab(0) }
    private func openMemoriesTab() { selectTab(1) }
    private func openAlbumsTab() { selectTab(2) }
    private func openSharedTab() { selectTab(3) }
    private func openSearchTab() { selectTab(4) }

    private func tapElement(_ identifier: String, timeout: TimeInterval = 20) {
        let target = element(identifier)
        XCTAssertTrue(reveal(identifier, timeout: timeout), "no '\(identifier)' — \(screenText())")
        for _ in 0..<6 where !target.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        target.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Flips the switch `identifier`. A tap on a switch row's label does not flip it:
    /// at AX5 the switch is drawn under its label, on the left; at smaller sizes, at
    /// the row's right end. Done once the value changed, or once `done` holds (a
    /// system prompt that decides the value).
    private func flipSwitch(_ identifier: String, orUntil done: @escaping () -> Bool = { false }) {
        let toggle = element(identifier)
        XCTAssertTrue(reveal(identifier), "no '\(identifier)' — \(screenText())")
        scrollToHittable(identifier)
        let before = toggle.value as? String
        for point in [CGVector(dx: 0.5, dy: 0.5), CGVector(dx: 0.13, dy: 0.85), CGVector(dx: 0.95, dy: 0.5)] {
            toggle.coordinate(withNormalizedOffset: point).tap()
            if waitUntil(3, { (toggle.value as? String) != before || done() }) { return }
        }
        XCTFail("\(identifier) did not flip — \(screenText())")
    }

    private func openMe() {
        let avatar = element("profileAvatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "no profile avatar — \(screenText())")
        avatar.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20), "the Me hub never appeared")
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func openPreferences() {
        openMe()
        tapElement("preferencesRow")
        XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20),
                      "the Preferences form never appeared — \(screenText())")
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back")
        back.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Opens the Albums tab, then the Library tile `row` (`partnersRow`, `peopleRow`…).
    private func openLibraryRow(_ row: String) {
        openAlbumsTab()
        tapElement(row)
    }

    private func openViewer(_ index: Int = 0) {
        openPhotosTab()
        let tile = element("assetTile_\(tiles[index])")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "no tile \(index) — \(screenText())")
        tile.tap()
        XCTAssertTrue(element("viewerBackButton").waitForExistence(timeout: 20),
                      "the viewer never showed its top bar — \(screenText())")
    }

    private func openViewerInfo() {
        let direct = element("viewerDetailsButton")
        if direct.waitForExistence(timeout: 3) {
            direct.tap()
        } else {
            let overflow = element("viewerOverflowMenu")
            XCTAssertTrue(overflow.waitForExistence(timeout: 10), "no overflow pill — \(screenText())")
            overflow.tap()
            let details = element("viewerMenuDetails")
            XCTAssertTrue(details.waitForExistence(timeout: 10), "no Details in the ⋯ menu")
            details.tap()
        }
        XCTAssertTrue(element("viewerInfoClose").waitForExistence(timeout: 20), "the info panel never opened")
    }

    /// Picks an option of a menu picker of the Preferences form (English labels).
    private func select(_ option: String, inPicker identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        if !control.isHittable { scrollToHittable(identifier) }
        control.tap()
        let predicate = NSPredicate(format: "label == %@", option)
        for candidate in [app.buttons.matching(predicate).firstMatch,
                          app.descendants(matching: .any).matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: 6) {
            candidate.tap()
            return
        }
        XCTFail("the \(identifier) menu never offered '\(option)' — \(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    /// Preferences → the hub → the timeline; the Me sheet is dragged down from its bar.
    private func leavePreferencesAndHub() {
        goBack()
        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { !self.element("profileList").exists }
        }
        // At the largest sizes the hub's list takes the drag (it scrolls instead of
        // the sheet following): the preference is saved, a relaunch gets back home.
        if !dismissed {
            Thread.sleep(forTimeInterval: 1) // the picker's write reaches the defaults first
            relaunch(launched.size, language: launched.language)
            dismissed = !element("profileList").exists
        }
        XCTAssertTrue(dismissed, "the Me sheet never dismissed")
        XCTAssertTrue(element("assetTile_\(tiles[0])").waitForExistence(timeout: 15), "not back on the timeline")
    }

    private func setGrouping(_ option: String) {
        openPreferences()
        select(option, inPicker: "preferencesGroupPicker")
        leavePreferencesAndHub()
    }

    /// Sets the density to `columns` with the stepper of the Preferences form.
    private func setColumns(_ columns: Int) {
        let stepper = element("preferencesColumnsStepper")
        XCTAssertTrue(stepper.waitForExistence(timeout: 15), "no density stepper")
        for _ in 0..<6 where (stepper.value as? String) != String(columns) {
            let buttons = app.steppers["preferencesColumnsStepper"].buttons
            if buttons.count >= 2 {
                buttons.element(boundBy: 1).tap()
            } else {
                stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(stepper.value as? String, String(columns), "the density stepper did not reach \(columns)")
    }

    // MARK: - Test bodies shared by AC-26.3 and AC-26.8

    private func runAC26_3(language: String) {
        reset()
        setProvider("manual")

        // Onboarding: the SSO label is as long as the stub's sentence, the sign-in label one word.
        launchApp(.ax5, language: language) { screen in
            self.assertNoOverlap()
            if screen == "loginTitle" {
                self.assertFullyShown(long: "loginSSOLabel", short: "loginSignInButton")
            }
        }

        // Me hub and the screens below it.
        openMe()
        assertNoOverlap()
        assertInWindow("profileNameValue")
        scrollToHittable("logoutButton")
        relaunch(.ax5, language: language)
        openPreferences()
        assertNoOverlap()
        scrollToHittable("preferencesResetButton")
        goBack()
        tapElement("languageRow")
        XCTAssertTrue(element("languageRow.it").waitForExistence(timeout: 15), "no language list — \(screenText())")
        assertNoOverlap()
        scrollToHittable("languageRow.it")

        // Albums: the long and the short card, the last one reachable.
        relaunch(.ax5, language: language)
        openAlbumsTab()
        XCTAssertTrue(reveal("albumCard_\(shortAlbum)", timeout: 20), "no albums — \(screenText())")
        assertNoOverlap()
        assertFullyShown(long: "albumCardTitle_\(longAlbum)", short: "albumCardTitle_\(shortAlbum)")
        scrollToHittable("albumCard_\(shortAlbum)")

        // Album detail, its edit sheet and the shared-with sheet.
        relaunch(.ax5, language: language)
        openAlbumsTab()
        tapElement("albumCard_\(longAlbum)")
        XCTAssertTrue(element("albumActionsMenu").waitForExistence(timeout: 20), "no album detail — \(screenText())")
        assertNoOverlap()
        tapElement("albumActionsMenu")
        tapElement("albumEditAction")
        XCTAssertTrue(element("editAlbumNameField").waitForExistence(timeout: 15), "no edit-album sheet")
        assertNoOverlap()
        relaunch(.ax5, language: language)
        openAlbumsTab()
        tapElement("albumCard_\(longAlbum)")
        tapElement("albumActionsMenu")
        // At AX5 the menu runs past the screen: its last items exist once scrolled to.
        var sharedWith = tapAnyButton(["Shared With", "Geteilt mit"], timeout: 4)
        for _ in 0..<4 where !sharedWith {
            app.swipeUp()
            sharedWith = tapAnyButton(["Shared With", "Geteilt mit"], timeout: 2)
        }
        XCTAssertTrue(sharedWith, "no 'Shared With' in the album menu — \(app.buttons.allElementsBoundByIndex.map(\.label))")
        Thread.sleep(forTimeInterval: 1.5)
        assertNoOverlap()

        // Add to album (selection mode of the timeline).
        relaunch(.ax5, language: language)
        tapElement("selectButton")
        element("assetTile_\(tiles[0])").tap()
        tapElement("addToAlbumButton")
        XCTAssertTrue(element("addToAlbumRow_\(longAlbum)").waitForExistence(timeout: 15), "no add-to-album sheet")
        assertNoOverlap()
        assertFullyShown(long: "addToAlbumName_\(longAlbum)", short: "addToAlbumName_\(shortAlbum)")

        // Partners, and the invitation sheet.
        relaunch(.ax5, language: language)
        openLibraryRow("partnersRow")
        XCTAssertTrue(element("partnersScreen").waitForExistence(timeout: 20), "no partners screen")
        XCTAssertTrue(reveal("partnerRowName-\(shortPartner)", timeout: 20), "no partners — \(screenText())")
        assertNoOverlap()
        assertFullyShown(long: "partnerRowName-\(longPartner)", short: "partnerRowName-\(shortPartner)")
        scrollToHittable("invitePartner")
        element("invitePartner").tap()
        XCTAssertTrue(element("inviteCandidateEmail-\(shortUser)").waitForExistence(timeout: 20), "no invite sheet — \(screenText())")
        assertNoOverlap()
        assertFullyShown(long: "inviteCandidateEmail-\(longUser)", short: "inviteCandidateEmail-\(shortUser)")

        // Shared links, and the edit sheet of a link.
        relaunch(.ax5, language: language)
        openSharedTab()
        XCTAssertTrue(reveal("sharedLinkRow_\(shortLink)", timeout: 20), "no shared links — \(screenText())")
        assertNoOverlap()
        assertFullyShown(long: "sharedLinkTitle_\(longLink)", short: "sharedLinkTitle_\(shortLink)")
        scrollToHittable("sharedLinkRow_\(shortLink)")
        element("sharedLinkRow_\(shortLink)").press(forDuration: 1.2)
        if tapAnyButton(["Edit", "Bearbeiten"], timeout: 8) {
            XCTAssertTrue(element("confirmEditSharedLink").waitForExistence(timeout: 15), "no edit-link sheet")
            assertNoOverlap()
        } else {
            XCTFail("the context menu of a shared link has no Edit — \(screenText())")
        }

        // Create a link, from the empty state.
        setEmptyCollections(true)
        relaunch(.ax5, language: language)
        openSharedTab()
        tapElement("sharedLinksCreateButton")
        XCTAssertTrue(element("confirmCreateSharedLink").waitForExistence(timeout: 15), "no create-link sheet")
        assertNoOverlap()
        setEmptyCollections(false)

        // Search: filters sheet, then the mode bar against the "Filters" label.
        relaunch(.ax5, language: language)
        openSearchTab()
        XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "no search prompt — \(screenText())")
        assertNoOverlap()
        tapElement("searchFilterButton")
        XCTAssertTrue(element("searchFilterDone").waitForExistence(timeout: 15), "no filter sheet")
        assertInWindow("appBarTitleHeader")
        assertNoOverlap()
        flipSwitch("searchFilterFavorite")
        tapElement("searchFilterDone")
        XCTAssertTrue(element("searchActiveFiltersBar").waitForExistence(timeout: 20),
                      "the favourites filter shows no active-filters bar — \(screenText())")
        for segment in ["searchModeSegment_results", "searchModeSegment_explore", "searchModeSegment_map"] {
            XCTAssertTrue(element(segment).waitForExistence(timeout: 10), "no \(segment)")
            assertNotShrunk(segment, reference: "searchActiveFiltersBar")
            XCTAssertGreaterThanOrEqual(element(segment).frame.minX, 0, "\(segment) starts left of the window")
            XCTAssertLessThanOrEqual(element(segment).frame.maxX, windowFrame.width + 0.5, "\(segment) runs past the window")
        }
        assertNoOverlap()

        // Info panel of the viewer.
        relaunch(.ax5, language: language)
        openViewer()
        openViewerInfo()
        assertNoOverlap()
        scrollToHittable("viewerInfoClose")
    }

    // MARK: - Tests

    /// AC-26: the whole walk at the smallest and at the largest size.
    func test_AC_26() throws {
        for size in [TextSize.xs, .ax5] {
            if size == .xs { launchSignedIn(size) } else { relaunch(size) }
            let atAX5 = size == .ax5

            // Me hub, Preferences.
            openMe()
            assertNoOverlap()
            tapElement("preferencesRow")
            XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20), "no Preferences — \(screenText())")
            assertNoOverlap()

            // Albums, Partners.
            relaunch(size)
            openAlbumsTab()
            XCTAssertTrue(reveal("albumCard_\(shortAlbum)", timeout: 20), "no albums — \(screenText())")
            assertNoOverlap()
            if atAX5 { assertFullyShown(long: "albumCardTitle_\(longAlbum)", short: "albumCardTitle_\(shortAlbum)") }
            tapElement("partnersRow")
            XCTAssertTrue(reveal("partnerRowName-\(shortPartner)", timeout: 20), "no partners — \(screenText())")
            assertNoOverlap()
            if atAX5 { assertFullyShown(long: "partnerRowName-\(longPartner)", short: "partnerRowName-\(shortPartner)") }

            // Search.
            relaunch(size)
            openSearchTab()
            XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "no search prompt — \(screenText())")
            assertNoOverlap()

            // The create-album sheet, from the empty state.
            setEmptyCollections(true)
            relaunch(size)
            openAlbumsTab()
            tapElement("albumsCreateButton")
            XCTAssertTrue(element("createAlbumNameHeader").waitForExistence(timeout: 15), "no create-album sheet — \(screenText())")
            assertNoOverlap()
            assertInWindow("createAlbumNameHeader")
            setEmptyCollections(false)
        }
    }

    /// AC-26.1: the same landmarks at three sizes are strictly ordered XS < L < AX5.
    func test_AC_26_1() throws {
        reset()
        setProvider("manual")
        var heights: [String: [TextSize: CGFloat]] = [:]
        func record(_ marker: String, _ size: TextSize, _ identifier: String) {
            heights[marker, default: [:]][size] = textHeight(identifier)
        }

        for size in [TextSize.xs, .l, .ax5] {
            launchApp(size) { screen in
                record(screen, size, screen)
            }
            // Preferences: the row of the hub and the group picker.
            openMe()
            record("preferencesRow", size, "preferencesRow")
            tapElement("preferencesRow")
            XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20), "no Preferences")
            record("preferencesGroupPicker", size, "preferencesGroupPicker")

            relaunch(size)
            openAlbumsTab()
            XCTAssertTrue(reveal("albumCard_\(shortAlbum)", timeout: 20), "no albums")
            record("albumCardTitle", size, "albumCardTitle_\(shortAlbum)")
            openLibraryRow("partnersRow")
            XCTAssertTrue(reveal("partnerRowName-\(shortPartner)", timeout: 20), "no partners")
            record("partnerRowName", size, "partnerRowName-\(shortPartner)")

            relaunch(size)
            openSearchTab()
            XCTAssertTrue(element("searchPromptTitle").waitForExistence(timeout: 20), "no search prompt")
            record("searchPromptTitle", size, "searchPromptTitle")

            setEmptyCollections(true)
            relaunch(size)
            openAlbumsTab()
            tapElement("albumsCreateButton")
            XCTAssertTrue(element("createAlbumNameHeader").waitForExistence(timeout: 15), "no create-album sheet")
            record("createAlbumNameHeader", size, "createAlbumNameHeader")
            setEmptyCollections(false)
        }

        XCTAssertEqual(heights.count, 9, "landmarks measured: \(heights.keys.sorted())")
        for (marker, bySize) in heights {
            guard let xs = bySize[.xs], let l = bySize[.l], let ax5 = bySize[.ax5] else {
                XCTFail("\(marker) was not measured at the three sizes: \(bySize)")
                continue
            }
            XCTAssertLessThan(xs, l, "\(marker): XS (\(xs)) must be smaller than L (\(l))")
            XCTAssertLessThan(l, ax5, "\(marker): L (\(l)) must be smaller than AX5 (\(ax5))")
        }
    }

    /// AC-26.3: labels are shown whole and the screens stay free of overlaps at AX5.
    func test_AC_26_3() throws {
        runAC26_3(language: "en")
    }

    /// AC-26.8: the same walk in German, whose words are longer.
    func test_AC_26_8() throws {
        runAC26_3(language: "de")
    }

    /// AC-26.4: bars and panels reorganise instead of overlapping.
    func test_AC_26_4() throws {
        launchSignedIn(.xxxl)
        for size in [TextSize.xxxl, .ax5] {
            if size == .ax5 { relaunch(size) }
            for grouping in ["Day", "Month"] {
                setGrouping(grouping)
                XCTAssertTrue(element("selectButton").waitForExistence(timeout: 20), "no Select button — \(screenText())")
                let headers = grouping == "Day"
                    ? ["timelinePinnedYearHeader", "timelinePinnedDayHeader"]
                    : ["timelinePinnedMonthHeader"]
                let group = ["selectButton", "filterMenu", "syncStatusButton", "profileAvatar"]
                for header in headers {
                    XCTAssertTrue(element(header).waitForExistence(timeout: 20), "no \(header) at \(size) — \(screenText())")
                    for member in group where element(member).exists {
                        assertDisjoint(header, member)
                    }
                }
                XCTAssertGreaterThanOrEqual(element("selectButton").frame.minX, 0, "Select starts left of the window")
                XCTAssertLessThanOrEqual(element("selectButton").frame.maxX, windowFrame.width + 0.5, "Select runs past the window")
            }
        }

        // From here on, AX5 only.
        // Info panel: the place and every value of the grid whole.
        relaunch(.ax5)
        openViewer()
        openViewerInfo()
        assertInWindow("viewerInfoPlace")
        for index in 0..<8 where element("viewerInfoValue_\(index)").exists {
            assertInWindow("viewerInfoValue_\(index)")
        }

        // Backup and the upload details.
        relaunch(.ax5)
        openMe()
        tapElement("backupRow")
        XCTAssertTrue(element("appBarTitleHeader").waitForExistence(timeout: 20), "no title header in Backup — \(screenText())")
        assertInWindow("appBarTitleHeader")
        assertNoOverlap()
        scrollToHittable("uploadDetailRow")
        element("uploadDetailRow").tap()
        XCTAssertTrue(element("appBarTitleHeader").waitForExistence(timeout: 20), "no title header in the upload details — \(screenText())")
        assertInWindow("appBarTitleHeader")
        assertNoOverlap()

        // The locked folder's creation screen.
        relaunch(.ax5)
        openLibraryRow("lockedFolderRow")
        XCTAssertTrue(element("lockedFolderSetupTitle").waitForExistence(timeout: 25), "no locked-folder setup — \(screenText())")
        assertInWindow("lockedFolderSetupTitle")
        scrollToHittable("lockedFolderCreatePINButton")

        // The memories list: a long title whole, the card not cropped.
        relaunch(.ax5)
        openMemoriesTab()
        let card = element("memoryCard_\(longMemory)")
        XCTAssertTrue(reveal("memoryCard_\(longMemory)", timeout: 25), "no memory card — \(screenText())")
        XCTAssertGreaterThan(card.frame.height, 320, "the long memory's card did not grow past its old 320 pt")
        // The card's own frame spans its filled cover photo, unclipped (wider than the
        // window): what must stay inside the window is what the card writes.
        for text in card.staticTexts.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(text.frame.minX, -0.5, "'\(text.label)' starts left of the window")
            XCTAssertLessThanOrEqual(text.frame.maxX, windowFrame.width + 0.5, "'\(text.label)' runs past the window")
        }
        let cardTitle = element("memoryCardTitle_\(longMemory)")
        if cardTitle.exists {
            // The title may be hidden by the card's combined accessibility element.
            XCTAssertLessThanOrEqual(cardTitle.frame.maxY, card.frame.maxY, "the card is cropped under its title")
            assertInWindow("memoryCardTitle_\(longMemory)")
        }

        // People: the long name whole.
        relaunch(.ax5)
        openLibraryRow("peopleRow")
        // The row is one combined accessibility element (PeopleView `personRow`): the
        // name's own identifier is hidden, so the rows are compared (same caption line).
        XCTAssertTrue(reveal("personRow_\(shortPerson)", timeout: 25), "no people — \(screenText())")
        assertFullyShown(long: "personRow_\(longPerson)", short: "personRow_\(shortPerson)")

        // The map: the active-filter badge whole.
        relaunch(.ax5)
        openSearchTab()
        tapElement("searchModeSegment_map")
        tapElement("mapSettingsButton")
        // At AX5 the sheet opens at half height with the favourites switch under its
        // Done bar; the window-centre swipe of `scrollToHittable` would land on the
        // mode bar above the sheet. A drag from inside the sheet raises it first.
        XCTAssertTrue(element("mapSettingsDoneButton").waitForExistence(timeout: 15), "no map settings — \(screenText())")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        Thread.sleep(forTimeInterval: 1)
        flipSwitch("mapSettingsFavoritesToggle")
        tapElement("mapSettingsDoneButton")
        XCTAssertTrue(element("mapFilterActiveBadge").waitForExistence(timeout: 20), "no active-filter badge — \(screenText())")
        let badge = element("mapFilterActiveBadge").frame
        XCTAssertGreaterThanOrEqual(badge.minX, 0, "the badge starts left of the window")
        XCTAssertLessThanOrEqual(badge.maxX, windowFrame.width + 0.5, "the badge runs past the window")
        assertDisjoint("mapFilterActiveBadge", "mapSettingsButton")
    }

    /// AC-26.4: the lock screen at AX5 (Face ID is the simulator's own).
    func test_AC_26_4_appLock() throws {
        FaceID.enroll()
        launchSignedIn(.ax5)

        // Turn the lock on from the Me hub; a matching face concludes the prompt.
        openMe()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons.matching(labelPredicate(["Cancel", "Annuler", "Abbrechen"])).firstMatch
        flipSwitch("appLockToggle", orUntil: { cancel.exists })
        Thread.sleep(forTimeInterval: 2)
        FaceID.match()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10), "the activation prompt did not close")
        XCTAssertTrue(waitUntil(10) { (self.element("appLockToggle").value as? String) == "1" },
                      "Require Face ID did not turn on — \(screenText())")

        // Background, foreground: the lock shows, the system prompt is cancelled.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(element("AppLockOverlay").waitForExistence(timeout: 30), "the lock did not show — \(screenText())")
        sleep(2)
        FaceID.noMatch()
        if cancel.waitForExistence(timeout: 10) { cancel.tap() }
        sleep(1)

        XCTAssertTrue(element("appLockTitle").waitForExistence(timeout: 10), "no lock title — \(screenText())")
        assertInWindow("appLockTitle")
        scrollToHittable("appLockUnlockButton")
        assertNoOverlap()
    }

    /// AC-26.4: the share extension (system text size, see the file header).
    func test_AC_26_4_shareExtension() throws {
        reset()
        setProvider("manual")
        launchApp(.l)
        sleep(3) // the keychain write of the sign-in
        app.terminate()
        sleep(3)

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.launch()
        XCTAssertEqual(photos.state, .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        // Photos' own "What's New" sheet covers the library on a fresh device; at AX5
        // its button sits far below the fold (one word per line).
        let onboarding = photos.buttons.matching(
            NSPredicate(format: "label IN %@", ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"])
        ).firstMatch
        for _ in 0..<30 where onboarding.exists {
            if onboarding.isHittable {
                onboarding.tap()
                sleep(2)
            } else {
                photos.swipeUp(velocity: .fast)
            }
        }
        let grid = photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(grid.firstMatch.waitForExistence(timeout: 20), "the Photos library never published a tile")
        grid.element(boundBy: grid.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let share = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25), "no share button in the Photos viewer")
        share.tap()

        let predicate = NSPredicate(format: "label == 'Swimmich'")
        var activity: XCUIElement?
        for attempt in 0..<3 where activity == nil {
            for root in [photos as XCUIElement, springboard as XCUIElement] {
                let match = root.descendants(matching: .any).matching(predicate).firstMatch
                if match.exists { activity = match; break }
            }
            if activity == nil && attempt < 2 {
                let row = photos.collectionViews.firstMatch
                if row.exists { row.swipeLeft() } else { photos.swipeLeft() }
                sleep(2)
            }
        }
        guard let activity else { return XCTFail("the share sheet has no Swimmich activity") }
        activity.tap()

        // The row is ONE accessibility element (`.accessibilityElement(children: .combine)`
        // in ShareConfirmationView): its name text is not queryable on its own, so the
        // row's frame is measured. Its label carries the whole file name.
        let row = photos.buttons.matching(identifier: "shareExtensionItemRow_0").firstMatch
        let count = photos.staticTexts.matching(identifier: "shareExtensionHeaderCount").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the share sheet never listed the file")
        XCTAssertTrue(count.waitForExistence(timeout: 10), "no count in the sheet's header")
        XCTAssertTrue(row.label.contains("Gorges-du-Verdon"),
                      "the sheet is not showing the seeded long-named file — row reads \(row.label)")
        let screen = photos.windows.firstMatch.frame
        // A one-line name plus its size line is about twice the header's line at AX5;
        // three header lines or more means the name wraps over several lines.
        XCTAssertGreaterThanOrEqual(row.frame.height, 3 * count.frame.height,
                                    "the long file name is not shown on several lines (row: \(row.frame.height) pt, "
                                    + "count: \(count.frame.height) pt) — is the system text size at AX5?")
        XCTAssertGreaterThanOrEqual(row.frame.minX, 0, "the file row starts left of the sheet")
        XCTAssertLessThanOrEqual(row.frame.maxX, screen.width + 0.5, "the file row runs past the sheet")

        let upload = photos.buttons.matching(identifier: "shareExtensionUploadButton").firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: 15), "no upload button")
        for _ in 0..<12 where !upload.isHittable {
            photos.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(upload.isHittable, "the upload button cannot be reached")
    }

    /// AC-26.5: a long place stays whole, on several lines, inside the window.
    func test_AC_26_5() throws {
        launchSignedIn(.ax5)
        openMemoriesTab()
        let card = element("memoryCard_\(placeMemory)")
        // The third card of the lazy list: it only exists once scrolled to.
        XCTAssertTrue(reveal("memoryCard_\(placeMemory)", timeout: 25), "no memory card — \(screenText())")
        scrollToHittable("memoryCard_\(placeMemory)")
        let location = element("memoryCardLocation_\(placeMemory)")
        if location.exists {
            // The card's footer keeps one line (a cut is allowed there, decision #10).
            let oneLine = lineHeight(.footnote, .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(location.frame.height, 1.6 * oneLine,
                              "the card's place is \(location.frame.height) pt tall, more than one line (\(oneLine) pt)")
        }
        card.tap()
        XCTAssertTrue(element("memoryMomentClose").waitForExistence(timeout: 25), "the memory did not open — \(screenText())")
        XCTAssertTrue(element("memoryChipLocation").waitForExistence(timeout: 15), "no place chip — \(screenText())")
        assertFullyShown(long: "memoryChipLocation", short: "memoryChipCamera")
    }

    /// AC-26.6: icons follow the text, empty states do not overlap their button.
    func test_AC_26_6() throws {
        var iconHeights: [TextSize: CGFloat] = [:]
        launchSignedIn(.l)
        for size in [TextSize.l, .ax5] {
            if size == .ax5 { relaunch(size) }
            openMe()
            XCTAssertTrue(reveal("preferencesRow"), "no preferencesRow — \(screenText())")
            let icon = element("preferencesRow").images.firstMatch
            XCTAssertTrue(icon.exists, "no icon under preferencesRow — \(app.debugDescription)")
            iconHeights[size] = icon.frame.height
        }
        if let large = iconHeights[.l], let ax5 = iconHeights[.ax5] {
            XCTAssertGreaterThan(ax5, large, "the Preferences icon did not grow with the text (L \(large), AX5 \(ax5))")
        }

        setEmptyCollections(true)
        relaunch(.ax5)
        openAlbumsTab()
        assertEmptyState(glyph: "albumsEmptyGlyph", title: "albumsEmptyTitle", button: "albumsCreateButton")
        openSharedTab()
        assertEmptyState(glyph: "sharedLinksEmptyGlyph", title: "sharedLinksEmptyTitle", button: "sharedLinksCreateButton")
    }

    private func assertEmptyState(glyph: String, title: String, button: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        // The empty state sits under the Library tiles: at AX5 it is reached by scrolling.
        XCTAssertTrue(reveal(glyph, timeout: 20), "no \(glyph) — \(screenText())", file: file, line: line)
        scrollToHittable(button, file: file, line: line)
        XCTAssertTrue(element(title).exists, "no \(title)", file: file, line: line)
        XCTAssertLessThanOrEqual(overlapArea(element(glyph).frame, element(title).frame), 1,
                                 "\(glyph) overlaps \(title)", file: file, line: line)
        XCTAssertLessThanOrEqual(overlapArea(element(glyph).frame, element(button).frame), 1,
                                 "\(glyph) overlaps \(button)", file: file, line: line)
        XCTAssertTrue(element(button).isHittable, "\(button) is not hittable", file: file, line: line)
    }

    /// AC-26.7: tiles keep their default text size, the viewer's controls stay apart.
    func test_AC_26_7() throws {
        // First launch at L: density 4, the badges' reference heights.
        launchSignedIn(.l)
        openPreferences()
        setColumns(4)
        leavePreferencesAndHub()
        let badgeTiles = ["favoriteBadge": tiles[1], "videoBadge": tiles[2], "livePhotoBadge": tiles[3]]
        var reference: [String: CGFloat] = [:]
        for (badge, _) in badgeTiles {
            XCTAssertTrue(element(badge).waitForExistence(timeout: 20), "no \(badge) at L — \(screenText())")
            reference[badge] = element(badge).frame.height
        }

        // Then AX5: four tiles on the first row, the badges as before and inside their tile.
        relaunch(.ax5)
        let firstRow = tiles[0...3].map { element("assetTile_\($0)") }
        for tile in firstRow { XCTAssertTrue(tile.waitForExistence(timeout: 20), "a tile of the first row is missing") }
        let top = firstRow[0].frame.minY
        for tile in firstRow {
            XCTAssertEqual(tile.frame.minY, top, accuracy: 1, "the first row does not hold four tiles at AX5")
        }
        XCTAssertGreaterThan(element("assetTile_\(tiles[4])").frame.minY, top + 1, "a fifth tile is on the first row")
        for (badge, tileId) in badgeTiles {
            let frame = element(badge).frame
            XCTAssertEqual(frame.height, reference[badge] ?? 0, accuracy: 0.5, "\(badge) changed height at AX5")
            XCTAssertTrue(element("assetTile_\(tileId)").frame.insetBy(dx: -1, dy: -1).contains(frame),
                          "\(badge) \(frame) is not inside its tile \(element("assetTile_\(tileId)").frame)")
        }

        // The viewer, on the Live Photo (asset 4).
        openViewer(3)
        let controls = ["viewerBackButton", "viewerShareButton", "viewerFavoriteButton", "viewerOverflowMenu"]
        let badgeID = element("viewerBadgeSingleLine").exists ? "viewerBadgeSingleLine" : "viewerBadgePlace"
        XCTAssertTrue(element(badgeID).waitForExistence(timeout: 10), "no viewer badge — \(screenText())")
        XCTAssertTrue(element("viewerLiveButton").waitForExistence(timeout: 10), "no LIVE pill — \(screenText())")
        assertDisjointAndHittable(controls)
        for control in controls {
            assertDisjoint(control, badgeID)
            assertDisjoint(control, "viewerLiveButton")
        }
        let favorite = element("viewerFavoriteButton")
        let before = favorite.label
        favorite.tap()
        XCTAssertTrue(waitUntil(10) { favorite.label != before },
                      "tapping the favourite did not change its state (still '\(before)')")
    }

    /// AC-26.9: full-screen text stops at AX2, the controls keep their frames.
    func test_AC_26_9() throws {
        // Slideshow, at L then AX5.
        var counter: [TextSize: CGFloat] = [:]
        var speed: [TextSize: CGFloat] = [:]
        launchSignedIn(.l)
        for size in [TextSize.l, .ax5] {
            if size == .ax5 { relaunch(size) }
            openViewer()
            let direct = element("viewerSlideshowButton")
            if direct.waitForExistence(timeout: 3) {
                direct.tap()
            } else {
                tapElement("viewerOverflowMenu")
                tapElement("viewerMenuSlideshow")
            }
            XCTAssertTrue(element("slideshowCounter").waitForExistence(timeout: 20), "no slideshow — \(screenText())")
            // Launched with `-uiTestSlideshowAutoplayOff`: the show is paused, its chrome stays.
            XCTAssertEqual(element("slideshowPlayPauseButton").label, "Play", "the slideshow did not open paused")
            counter[size] = textElement("slideshowCounter").frame.height
            speed[size] = textElement("slideshowSpeedMenu").frame.height

            let squares: [(String, CGFloat)] = [
                ("slideshowCloseButton", 40), ("slideshowShuffleButton", 40), ("slideshowPreviousButton", 40),
                ("slideshowNextButton", 40), ("slideshowPlayPauseButton", 48),
            ]
            for (identifier, side) in squares {
                let frame = element(identifier).frame
                XCTAssertEqual(frame.width, side, accuracy: 1, "\(identifier) is not \(side) pt wide at \(size)")
                XCTAssertEqual(frame.height, side, accuracy: 1, "\(identifier) is not \(side) pt tall at \(size)")
                XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(frame), "\(identifier) leaves the window")
            }
            assertDisjointAndHittable(squares.map(\.0) + ["slideshowCounter", "slideshowSpeedMenu"])
        }
        if let large = counter[.l], let ax5 = counter[.ax5] {
            XCTAssertGreaterThan(ax5, large, "the slideshow counter did not grow (L \(large), AX5 \(ax5))")
        }
        if let large = speed[.l], let ax5 = speed[.ax5] {
            XCTAssertGreaterThan(ax5, large, "the speed label did not grow (L \(large), AX5 \(ax5))")
        }

        // Memory titles: the long birthday title is at least 2.7 times the short one (same size).
        var titleHeights: [String: CGFloat] = [:]
        for memory in [shortMemory, longMemory] {
            relaunch(.ax5)
            openMemory(memory)
            XCTAssertTrue(element("memoryTitle_\(memory)").waitForExistence(timeout: 20), "no title for \(memory) — \(screenText())")
            titleHeights[memory] = textElement("memoryTitle_\(memory)").frame.height
        }
        if let long = titleHeights[longMemory], let short = titleHeights[shortMemory] {
            XCTAssertGreaterThanOrEqual(long, 2.7 * short, "the long title (\(long) pt) is not whole next to the short one (\(short) pt)")
        }

        // Badge and chips of the long-camera and long-place memories.
        for memory in [longMemory, placeMemory] {
            relaunch(.ax5)
            openMemory(memory)
            XCTAssertTrue(element("memoryMomentBadge").waitForExistence(timeout: 20), "no type badge — \(screenText())")
            let chips = ["memoryChipLocation", "memoryChipCamera", "memoryChipPeople", "memoryChipTags", "memoryChipSaved"]
            // The bottom panel scrolls when it does not fit.
            for chip in chips where element(chip).exists { _ = reveal(chip, timeout: 1) }
            for identifier in ["memoryMomentBadge"] + chips where element(identifier).exists {
                let frame = element(identifier).frame
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(identifier) of \(memory) starts left of the window")
                XCTAssertLessThanOrEqual(frame.maxX, windowFrame.width + 0.5, "\(identifier) of \(memory) runs past the window")
                assertDisjoint(identifier, "memoryMomentClose")
                assertDisjoint(identifier, "memoryMomentViewInTimeline")
            }
            for button in ["memoryMomentClose", "memoryMomentViewInTimeline"] {
                let frame = element(button).frame
                XCTAssertEqual(frame.width, 44, accuracy: 1, "\(button) is not 44 pt wide")
                XCTAssertEqual(frame.height, 44, accuracy: 1, "\(button) is not 44 pt tall")
                XCTAssertTrue(windowFrame.contains(frame), "\(button) leaves the window")
            }
            // `isHittable` read false here although the button showed in place: the proof
            // that it is reachable is a tap that closes the memory.
            element("memoryMomentClose").tap()
            XCTAssertTrue(element("memoryMomentClose").waitForNonExistence(timeout: 10),
                          "a tap on memoryMomentClose did not close \(memory)")
        }
    }

    private func openMemory(_ id: String) {
        openMemoriesTab()
        let card = element("memoryCard_\(id)")
        XCTAssertTrue(reveal("memoryCard_\(id)", timeout: 25), "no memory card \(id) — \(screenText())")
        for _ in 0..<6 where !card.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        card.tap()
        XCTAssertTrue(element("memoryMomentClose").waitForExistence(timeout: 25), "the memory \(id) did not open — \(screenText())")
    }

    // MARK: - Face ID (simulator Darwin notifications, copied from AppLockUITests)

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
}
