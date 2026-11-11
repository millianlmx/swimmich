import XCTest

/// End-to-end scenario for the Timeline's date scrubber (L-04): a handle on the
/// trailing edge that jumps the grid to any month of the library.
///
/// What the scenarios prove, on the WIRE and on the screen:
///
/// 1. Dragging the handle to a month and releasing shows that month's photos,
///    and the bubble beside the handle names the targeted month in the app's
///    language (AC-14, AC-90).
/// 2. The scrubber is there for every filter and grouping, never over an empty
///    or failed timeline (AC-86).
/// 3. A release sends ONE `GET /api/timeline/bucket` for the targeted month, with
///    the filters of the month list; the months crossed by the drag send none
///    (AC-87, AC-88, AC-92). A failed month is retried alone (AC-89) and a
///    release made while another month is in flight wins (AC-95).
/// 4. The handle follows the finger-scrolled grid (AC-91), snaps to the first
///    photo of the month by default and to the exact spot with "Smooth
///    Scrubbing" (AC-92), is adjustable for VoiceOver (AC-93), and "Scroll to
///    top" brings back the newest month (AC-96).
///
/// The stub is `immich_stub_timeline_scrubber.py`: 36 months from 2025-12 (index
/// 0, 60 photos) to 2023-01 (index 35), 21 photos in 2024-06, six elsewhere.
/// Every photo id carries its month and its rank in grid order:
/// `5c7ab000-<yyyy>-4<mm>-8111-<rank>`.
///
/// One `XCTestCase` per feature, in its own file, against its own committed
/// stub. The helpers are copied from `FavoritesFilterUITests` and
/// `SettingsParityUITests` on purpose (the repository's rule: no shared UI-test
/// support file).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/timeline-scrubber.uitest.log \
///         UITests/stubs/immich_stub_timeline_scrubber.py \
///         TimelineScrubberUITests/test_AC_14
final class TimelineScrubberUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private let favoritesLabels = ["Favorites", "Favoris", "Favoriten", "Favoritos", "Preferiti"]
    private let allLabels = ["All", "Tout", "Alle", "Todos", "Tutti"]
    private let archivedLabels = ["Archived", "Archivés", "Archiviert", "Archivados", "Archiviati"]
    private let resetLabels = ["Reset", "Zurücksetzen", "Restablecer", "Réinitialiser", "Reimposta"]

    /// Where the tiles start being "visible": below the status bar and the row
    /// of floating buttons (Select, sync, avatar) that rides over the grid.
    private let topInset: CGFloat = 110

    private let enUS = Locale(identifier: "en_US")
    private let frFR = Locale(identifier: "fr_FR")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The scenario's onboarding only knows English labels (French too, for
        // AC-90, which re-pins the language itself): pin the language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

    // MARK: - Helpers (copied from FavoritesFilterUITests / SettingsParityUITests)

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
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

    /// `GET /stub/timeline?mode=normal|empty|error`: what the month list answers.
    private func setTimelineMode(_ mode: String) {
        let url = URL(string: "\(stub)/stub/timeline?mode=\(mode)")!
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "Stub did not answer")
        XCTAssertTrue(body.contains(mode), "the stub did not switch the timeline to \(mode): \(body)")
    }

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
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("s02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One element by IDENTIFIER, whatever its type.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Bounded poll on a UI predicate: the caller's message can say what was on
    /// screen when the budget ran out, and a NEGATIVE assertion gets a real
    /// budget instead of a bare sleep.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    // MARK: - Launch

    /// Launches the app and walks it to the authenticated timeline. A kept
    /// session (relaunch, second language of AC-90) skips the walk. Everything
    /// is matched language-neutrally: the tab bar, not the "Photos" label.
    private func launchAndEnter() {
        app.launch()
        let welcome = app.staticTexts.matching(labelPredicate(["Your photo library", "Votre photothèque"])).firstMatch
        let tabs = app.tabBars.firstMatch
        _ = waitUntil(40) { welcome.exists || tabs.exists }
        if welcome.exists {
            shot("s01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 8) {
            whatsNewDone.tap()
        }
    }

    /// Fresh stub, fresh sign-in, the 36-month timeline on screen.
    private func startFresh() {
        reset()
        setProvider("manual")
        launchAndEnter()
        waitForTimeline()
    }

    /// Terminates and relaunches on the kept session, under `language`.
    private func relaunch(language: String = "en", locale: String = "en_US") {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        launchAndEnter()
    }

    // MARK: - Scrubber tools

    private var scrubber: XCUIElement { element("timelineScrubber") }
    private var track: XCUIElement { element("timelineScrubberTrack") }
    private var bubble: XCUIElement { element("timelineScrubberLabel") }
    private var scrollToTopButton: XCUIElement { element("timelineScrollToTopButton") }

    private func waitForTimeline(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrubber.waitForExistence(timeout: 40),
                      "the timeline never showed its date scrubber — tiles: \(visibleTileIdentifiers().count), "
                      + "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))",
                      file: file, line: line)
    }

    /// The month the handle reports (its accessibility value).
    private var scrubberValue: String { (scrubber.value as? String) ?? "" }

    /// Press the handle, drag it to the point of the track at `p` (0 = top,
    /// 1 = bottom) and release. The handle centre follows the finger, so its x
    /// is kept and only y is aimed.
    private func dragScrubber(toTrackFraction p: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrubber.waitForExistence(timeout: 30), "no date scrubber to drag", file: file, line: line)
        XCTAssertTrue(track.exists, "the scrubber has no track", file: file, line: line)
        let trackFrame = track.frame
        let targetY: CGFloat = trackFrame.minY + CGFloat(p) * trackFrame.height
        let target = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: scrubber.frame.midX, dy: targetY))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: target)
    }

    /// The share of the track that sits in the middle of month `index` of `count`.
    private func fraction(ofMonthIndex index: Int, of count: Int) -> Double {
        (Double(index) + 0.5) / Double(count)
    }

    // MARK: - Grid tools

    private func visibleTileIdentifiers() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    /// The tile identifier of the cell at the top of the grid: among the
    /// `assetTile_*` elements whose centre is on screen below the top safe zone,
    /// the one with the smallest `(minY, minX)`.
    private func firstVisibleTile() -> String? {
        let screen = app.windows.firstMatch.frame
        let top = screen.minY + topInset
        var best: (id: String, minY: CGFloat, minX: CGFloat)?
        for tile in app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex {
            let frame = tile.frame
            guard !frame.isEmpty, frame.midY > top, frame.minY < screen.maxY,
                  frame.maxX > screen.minX, frame.minX < screen.maxX else { continue }
            let key = (frame.minY.rounded(), frame.minX)
            if let current = best, (current.minY, current.minX) <= key { continue }
            best = (tile.identifier, key.0, key.1)
        }
        return best?.id
    }

    /// `assetTile_5c7ab000-2024-4006-8111-000000000001` → (2024, 6, 1).
    private func monthAndRank(fromTileId identifier: String) -> (yyyy: Int, mm: Int, rank: Int)? {
        let id = identifier.hasPrefix("assetTile_") ? String(identifier.dropFirst("assetTile_".count)) : identifier
        let parts = id.split(separator: "-")
        guard parts.count == 5, let yyyy = Int(parts[1]), let mm = Int(parts[2].dropFirst()),
              let rank = Int(parts[4]) else { return nil }
        return (yyyy, mm, rank)
    }

    private func monthKey(_ yyyy: Int, _ mm: Int) -> String {
        String(format: "%04d-%02d-01", yyyy, mm)
    }

    /// Index of a month key in the "All" list (2025-12-01 = 0 … 2023-01-01 = 35).
    private func monthIndex(_ key: String) -> Int {
        let yyyy = Int(key.prefix(4)) ?? 0
        let mm = Int(key.dropFirst(5).prefix(2)) ?? 0
        return (2025 - yyyy) * 12 + (12 - mm)
    }

    /// "MMMM yyyy" in `locale`, the app's own bubble/value format. Comparing to
    /// the formatter (not to a literal) is what lets AC-90 run in two languages.
    private func expectedLabel(_ yyyy: Int, _ mm: Int, _ locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: yyyy, month: mm, day: 15, hour: 12))!
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    private func firstVisibleMonthAndRank() -> (yyyy: Int, mm: Int, rank: Int)? {
        firstVisibleTile().flatMap(monthAndRank(fromTileId:))
    }

    /// Waits until the top of the grid is rank `rank` (any rank when nil) of the
    /// month `yyyy-mm`.
    private func waitForTop(_ yyyy: Int, _ mm: Int, rank: Int? = nil, timeout: TimeInterval = 40,
                            file: StaticString = #filePath, line: UInt = #line) {
        let reached = waitUntil(timeout) {
            guard let top = self.firstVisibleMonthAndRank() else { return false }
            return top.yyyy == yyyy && top.mm == mm && (rank == nil || top.rank == rank)
        }
        guard !reached else { return }
        let wantedRank: String = rank.map { String($0) } ?? "any"
        let seenTile: String = firstVisibleTile() ?? "none"
        let message: String = "the grid never started on \(monthKey(yyyy, mm)) rank \(wantedRank) — "
            + "first visible tile: \(seenTile), scrubber reads '\(scrubberValue)'"
        XCTFail(message, file: file, line: line)
    }

    private func waitForScrubberValue(_ expected: String, timeout: TimeInterval = 30,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let reached = waitUntil(timeout) { self.scrubberValue == expected }
        XCTAssertTrue(reached, "the scrubber reads '\(scrubberValue)', expected '\(expected)'", file: file, line: line)
    }

    /// Adds the months of the tiles on screen to `seen`, asserting that no photo
    /// shows twice in the grid.
    private func collectMonths(into seen: inout Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        let ids = visibleTileIdentifiers()
        XCTAssertEqual(ids.count, Set(ids).count, "a photo shows twice in the grid: \(ids)", file: file, line: line)
        for id in ids {
            if let found = monthAndRank(fromTileId: id) { seen.insert(monthKey(found.yyyy, found.mm)) }
        }
    }

    /// The months seen form one run of consecutive months: none was skipped.
    private func assertContiguous(_ seen: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        let indices = seen.map(monthIndex).sorted()
        guard let first = indices.first, let last = indices.last else {
            return XCTFail("no month seen", file: file, line: line)
        }
        XCTAssertEqual(last - first + 1, indices.count,
                       "a month was skipped between the neighbours — months seen: \(seen.sorted())",
                       file: file, line: line)
    }

    /// Finger-scrolls (`up` = towards newer photos) until a tile of `target`
    /// shows, collecting what each screen holds. Bounded.
    private func scroll(towards target: String, newer: Bool, collecting seen: inout Set<String>, maxSwipes: Int = 25,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<maxSwipes {
            collectMonths(into: &seen, file: file, line: line)
            if seen.contains(target) { return }
            if newer { app.swipeDown() } else { app.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        collectMonths(into: &seen, file: file, line: line)
        XCTAssertTrue(seen.contains(target), "scrolling never reached \(target) — months seen: \(seen.sorted())",
                      file: file, line: line)
    }

    private func chooseFilter(_ labels: [String], file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.buttons.matching(identifier: "filterMenu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "the filter menu is missing", file: file, line: line)
        menu.tap()
        let exact = NSPredicate(format: "label IN %@", labels)
        let item = app.descendants(matching: .any).matching(exact).firstMatch
        guard item.waitForExistence(timeout: 10) else {
            return XCTFail("the filter menu has no entry among \(labels) — screen reads: "
                           + "\(app.descendants(matching: .any).allElementsBoundByIndex.map(\.label))",
                           file: file, line: line)
        }
        item.tap()
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let month: String?
    }

    private func stubRequests() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.isEmpty ? "(nothing)" : requests.map {
            "\($0.method) \($0.path) params=\($0.params) month=\($0.month ?? "-")"
        }.joined(separator: "\n")
    }

    /// Waits for the journal to hold still for one second (the timeline is at
    /// rest: pages, thumbnails and neighbours all loaded) and returns its size.
    @discardableResult
    private func waitForWire(timeout: TimeInterval = 40) -> Int {
        var last = stubRequests().count
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let count = stubRequests().count
            if count != last {
                last = count
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1 {
                break
            }
        }
        return last
    }

    /// The journal's size, taken once the timeline is at rest: the "mark" a
    /// gesture's requests are counted from.
    private func requestMark() -> Int { waitForWire() }

    private func bucketRequests(after mark: Int) -> [StubRequest] {
        stubRequests().dropFirst(mark).filter { $0.method == "GET" && $0.path == "/api/timeline/bucket" }
    }

    /// The months of the `GET /api/timeline/bucket` received after `mark`, in
    /// arrival order (the stub journals on arrival, before it answers).
    private func bucketMonths(after mark: Int) -> [String] {
        bucketRequests(after: mark).compactMap(\.month)
    }

    /// The months of the `GET /api/timeline/bucket` that ARRIVED after `mark`:
    /// read from the query (`params`), journaled on arrival — unlike `month`,
    /// which `req.note` only merges once the handler has answered (so, for the
    /// slow month, 3 s late).
    private func bucketArrivals(after mark: Int) -> [String] {
        bucketRequests(after: mark).compactMap { $0.params["timeBucket"] }
    }

    // MARK: - Preferences (copied from SettingsParityUITests)

    private func scrolledRow(_ identifier: String) -> XCUIElement {
        let row = element(identifier)
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    private func scrollFormToTop() {
        let deadline = Date().addingTimeInterval(10)
        while !element("preferencesGroupPicker").exists && Date() < deadline {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(element("preferencesGroupPicker").exists, "the Preferences form never scrolled back to its top")
    }

    /// Timeline → Me sheet → Preferences. Leaves the app on the Preferences form.
    private func openPreferences() {
        let avatar = element("profileAvatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "the timeline has no profile avatar")
        avatar.tap()
        let row = scrolledRow("preferencesRow")
        if !row.waitForExistence(timeout: 10) {
            shot("p06b-me-hub-without-preferences-row")
            XCTFail("Preferences row missing in the Me hub:\n\(app.debugDescription)")
        }
        row.tap()
        XCTAssertTrue(element("preferencesGroupPicker").waitForExistence(timeout: 20),
                      "the Preferences form never appeared — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    /// Preferences → the hub → the timeline (the sheet dragged down from its
    /// navigation bar, the dismissal verified).
    private func leavePreferencesAndHub() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "no way back from the Preferences screen")
        back.tap()

        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { !self.element("preferencesGroupPicker").exists }
        }
        XCTAssertTrue(dismissed,
                      "the Me sheet never dismissed: the timeline assertions below would read the covered timeline")
        waitForTimeline()
    }

    private func select(_ option: String, inPicker identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        control.tap()
        let predicate = NSPredicate(format: "label == %@", option)
        for candidate in [app.buttons.matching(predicate).firstMatch,
                          app.descendants(matching: .any).matching(predicate).firstMatch]
        where candidate.waitForExistence(timeout: 6) {
            candidate.tap()
            return
        }
        XCTFail("the \(identifier) menu never offered '\(option)' — buttons on screen: "
                + "\(app.buttons.allElementsBoundByIndex.map(\.label))")
    }

    private func assertSwitch(_ identifier: String, is expected: String, _ comment: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let actual = (control.value as? String) ?? ""
        XCTAssertEqual(actual, expected,
                       "\(identifier) reads '\(actual)', expected '\(expected)' — \(comment). "
                       + "Element: \(control.debugDescription)")
    }

    /// Flips a switch and waits for its value to move (tapped on its own
    /// control, at the trailing edge of the row).
    private func flip(_ identifier: String) {
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 15), "\(identifier) is not on the Preferences form")
        let before = control.value as? String
        for _ in 0..<3 {
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            if waitUntil(4) { (control.value as? String) != before } { return }
        }
        XCTFail("\(identifier) never flipped, even tapped on its own control (value stayed \(before ?? "nil"))")
    }

    /// Preferences → Reset (confirmed), back to the timeline. The way the
    /// settings return to their defaults: never a launch argument, which would
    /// mask the write of the setting.
    private func resetPreferencesToDefaults() {
        openPreferences()
        let resetRow = scrolledRow("preferencesResetButton")
        if !resetRow.waitForExistence(timeout: 10) {
            shot("s20b-reset-row-missing")
            XCTFail("the Preferences form has no Reset row:\n\(app.debugDescription)")
        }
        resetRow.tap()
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Reset did not raise a confirmation")
        let confirm = dialog.buttons.matching(labelPredicate(resetLabels)).firstMatch
        if !confirm.waitForExistence(timeout: 10) {
            XCTFail("no Reset button in the confirmation dialog — its buttons are: "
                    + "\(dialog.buttons.allElementsBoundByIndex.map(\.label))")
        }
        confirm.tap()
        XCTAssertTrue(waitUntil(10) { !dialog.exists }, "the confirmation stayed up after Reset")
        scrollFormToTop()
        leavePreferencesAndHub()
    }

    // MARK: - Scenarios

    /// AC-14: drag to the oldest month; the bubble names it, the grid shows it.
    func test_AC_14() throws {
        startFresh()
        XCTAssertEqual(scrubberValue, expectedLabel(2025, 12, enUS), "the handle starts on the newest month")
        let mark = requestMark()

        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 35, of: 36))

        // The bubble lingers 1.5 s after the release: read it at once.
        XCTAssertTrue(bubble.waitForExistence(timeout: 2), "the bubble is not on screen after the release")
        XCTAssertEqual(bubble.label, expectedLabel(2023, 1, enUS), "the bubble does not name the targeted month")

        waitForTop(2023, 1, rank: 1)
        waitForScrubberValue(expectedLabel(2023, 1, enUS))
        XCTAssertEqual(bucketMonths(after: mark).first, "2023-01-01",
                       "the release must ask for the oldest month — got:\n\(describe(bucketRequests(after: mark)))")
        shot("s14-oldest-month")
    }

    /// AC-86: the scrubber is there for every filter and grouping and does not
    /// get in the way of its neighbours; never over an empty or failed timeline.
    func test_AC_86() throws {
        startFresh()

        func checkNeighboursStillWork(_ state: String) {
            XCTAssertTrue(scrubber.waitForExistence(timeout: 30), "[\(state)] no date scrubber")
            let startValue = scrubberValue
            XCTAssertFalse(startValue.isEmpty, "[\(state)] the handle reports no month")

            // Pinch: the cells change size.
            let before = firstVisibleTile().map { app.descendants(matching: .any).matching(identifier: $0).firstMatch.frame.width }
            app.pinch(withScale: 1.8, velocity: 2)
            let pinched = waitUntil(10) {
                guard let id = self.firstVisibleTile() else { return false }
                return self.app.descendants(matching: .any).matching(identifier: id).firstMatch.frame.width != before
            }
            XCTAssertTrue(pinched, "[\(state)] the pinch no longer resizes the grid")
            app.pinch(withScale: 0.5, velocity: -2)
            RunLoop.current.run(until: Date().addingTimeInterval(1))

            // Scroll to top: reachable after a jump, brings the handle back.
            dragScrubber(toTrackFraction: 0.5)
            XCTAssertTrue(scrollToTopButton.waitForExistence(timeout: 20), "[\(state)] no scroll-to-top button after a jump")
            scrollToTopButton.tap()
            waitForScrubberValue(startValue)
            XCTAssertTrue(waitUntil(10) { !self.scrollToTopButton.exists },
                          "[\(state)] the scroll-to-top button stayed after going back to the top")
            XCTAssertTrue(scrubber.exists, "[\(state)] the scrubber vanished after scroll-to-top")

            // Select: the pill works, the scrubber leaves selection mode alone.
            let select = element("selectButton")
            XCTAssertTrue(select.waitForExistence(timeout: 10), "[\(state)] no Select button")
            select.tap()
            XCTAssertTrue(waitUntil(10) { !self.scrubber.exists }, "[\(state)] the scrubber stayed in selection mode")
            XCTAssertTrue(tapAnyButton(["Cancel"], timeout: 10), "[\(state)] no way out of selection mode")
            XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "[\(state)] the scrubber did not come back")
        }

        // Filters, grouping by day (the default).
        checkNeighboursStillWork("All / day")
        chooseFilter(favoritesLabels)
        waitForScrubberValue(expectedLabel(2025, 11, enUS))
        checkNeighboursStillWork("Favorites / day")
        chooseFilter(archivedLabels)
        waitForScrubberValue(expectedLabel(2025, 10, enUS))
        checkNeighboursStillWork("Archived / day")
        chooseFilter(allLabels)
        waitForScrubberValue(expectedLabel(2025, 12, enUS))

        // Groupings.
        for grouping in ["Month", "Flat"] {
            openPreferences()
            select(grouping, inPicker: "preferencesGroupPicker")
            leavePreferencesAndHub()
            waitForScrubberValue(expectedLabel(2025, 12, enUS))
            checkNeighboursStillWork("All / \(grouping)")
        }

        // Empty timeline: no scrubber.
        app.terminate()
        setTimelineMode("empty")
        launchAndEnter()
        XCTAssertTrue(waitForStaticText(["No Photos"], timeout: 40), "the empty timeline never showed its empty state")
        XCTAssertFalse(scrubber.exists, "an empty timeline must not show the scrubber")

        // First load in error: no scrubber either.
        app.terminate()
        setTimelineMode("error")
        launchAndEnter()
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Try Again"])).firstMatch.waitForExistence(timeout: 40),
                      "the failed timeline never showed its error")
        XCTAssertFalse(scrubber.exists, "a timeline that failed to load must not show the scrubber")

        // Back to a normal server, and the grouping back to its default for the next scenario.
        setTimelineMode("normal")
        XCTAssertTrue(tapAnyButton(["Try Again"]), "no Try Again button")
        waitForTimeline()
        resetPreferencesToDefaults()
    }

    /// AC-87: only the newest month loaded; one jump, one request for the
    /// targeted month, same filters as the month list; neighbours in order.
    func test_AC_87() throws {
        startFresh()
        // Given: the 60-photo newest month is the only one loaded.
        XCTAssertEqual(bucketMonths(after: 0), ["2025-12-01"],
                       "at launch only the newest month must be loaded — got:\n\(describe(stubRequests()))")
        let mark = requestMark()

        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 18, of: 36))
        waitForTop(2024, 6, rank: 1)

        let requests = bucketRequests(after: mark)
        XCTAssertEqual(requests.first?.month, "2024-06-01",
                       "the first month asked after the gesture must be the one targeted — got:\n\(describe(requests))")
        let list = stubRequests().last { $0.method == "GET" && $0.path == "/api/timeline/buckets" }
        XCTAssertNotNil(list, "the app never asked for the month list")
        XCTAssertEqual(requests.first?.params["visibility"], "timeline",
                       "the month request must carry visibility=timeline for the All filter")
        for (key, value) in list?.params ?? [:] {
            XCTAssertEqual(requests.first?.params[key], value,
                           "the month request must carry the month list's filter \(key)=\(value)")
        }

        // Neighbours: up, then down; in order, nothing twice, nothing skipped.
        var seen = Set<String>()
        scroll(towards: "2024-07-01", newer: true, collecting: &seen)
        scroll(towards: "2024-05-01", newer: false, collecting: &seen)
        XCTAssertTrue(seen.contains("2024-06-01") && seen.contains("2024-07-01") && seen.contains("2024-05-01"),
                      "the neighbours of 2024-06 did not both show — months seen: \(seen.sorted())")
        assertContiguous(seen)
        shot("s87-neighbours")
    }

    /// AC-88: Favorites; the bottom of the track is the oldest favorite month.
    func test_AC_88() throws {
        startFresh()
        chooseFilter(favoritesLabels)
        waitForScrubberValue(expectedLabel(2025, 11, enUS))
        let mark = requestMark()

        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 21, of: 22))
        waitForTop(2024, 2, rank: 1)

        let requests = bucketRequests(after: mark)
        XCTAssertEqual(requests.first?.month, "2024-02-01",
                       "the release must ask for the oldest favorite month — got:\n\(describe(requests))")
        XCTAssertEqual(requests.first?.params["isFavorite"], "true",
                       "the month request must carry isFavorite=true — got:\n\(describe(requests))")
        waitForScrubberValue(expectedLabel(2024, 2, enUS))
        shot("s88-oldest-favorite")
    }

    /// AC-89: a failed month shows the banner; the scrubber stays usable; Try
    /// Again reloads that month alone.
    func test_AC_89() throws {
        startFresh()
        let mark = requestMark()

        // 2024-03-01 (index 21) answers 500 to its first request.
        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 21, of: 36))
        let retry = app.buttons.matching(labelPredicate(["Try Again"])).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 30), "the failed month never showed its error banner")
        XCTAssertTrue(scrubber.exists, "the scrubber must stay on screen during the error")
        XCTAssertTrue(scrubber.isHittable, "the scrubber must stay usable during the error")
        shot("s89-banner")

        retry.tap()
        waitForTop(2024, 3, rank: 1)
        XCTAssertTrue(waitUntil(10) { !retry.exists }, "the banner stayed after a successful retry")

        let all = stubRequests().dropFirst(mark)
        let months = bucketMonths(after: mark)
        XCTAssertEqual(Array(months.prefix(2)), ["2024-03-01", "2024-03-01"],
                       "the failed month must be asked twice, back to back — got:\n\(describe(Array(all)))")
        XCTAssertFalse(all.contains { $0.method == "GET" && $0.path == "/api/timeline/buckets" },
                       "Try Again must not reload the month list — got:\n\(describe(Array(all)))")
        XCTAssertFalse(months.contains("2025-12-01"),
                       "Try Again must not reload the newest month — got:\n\(describe(Array(all)))")
    }

    /// AC-90: the bubble names the month in the app's language, then fades.
    func test_AC_90() throws {
        reset()
        setProvider("manual")
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        launchAndEnter()
        waitForTimeline()

        // March 2023 is index 33 of the 36 months.
        for (language, locale, formatterLocale) in [("fr", "fr_FR", frFR), ("en", "en_US", enUS)] {
            if language == "en" { relaunch(language: language, locale: locale); waitForTimeline() }
            let expected = expectedLabel(2023, 3, formatterLocale)

            dragScrubber(toTrackFraction: fraction(ofMonthIndex: 33, of: 36))
            XCTAssertTrue(bubble.waitForExistence(timeout: 2), "[\(language)] the bubble is not on screen after the release")
            XCTAssertEqual(bubble.label, expected, "[\(language)] the bubble must name the month in the app's language")
            XCTAssertTrue(expected.contains("2023"), "[\(language)] the expected label carries the year: \(expected)")
            shot("s90-\(language)")

            XCTAssertTrue(waitUntil(5) { !self.bubble.exists },
                          "[\(language)] the bubble must be gone 1.5 s after the release")
            waitForTop(2023, 3, rank: 1)
            waitForScrubberValue(expected)
        }
        XCTAssertNotEqual(expectedLabel(2023, 3, frFR), expectedLabel(2023, 3, enUS),
                          "the two languages must not read the same")
    }

    /// AC-91: finger-scrolled grid → the handle follows (value and position),
    /// for each grouping.
    func test_AC_91() throws {
        startFresh()
        let newest = expectedLabel(2025, 12, enUS)

        for grouping in ["Day", "Month", "Flat"] {
            if grouping != "Day" {
                openPreferences()
                select(grouping, inPicker: "preferencesGroupPicker")
                leavePreferencesAndHub()
            }
            // At the top.
            if scrubberValue != newest, scrollToTopButton.exists {
                scrollToTopButton.tap()
            }
            waitForScrubberValue(newest)
            let topY = scrubber.frame.midY

            // Finger-scroll to an older month.
            var older: (yyyy: Int, mm: Int, rank: Int)?
            for _ in 0..<30 {
                app.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                if let top = firstVisibleMonthAndRank(), (top.yyyy, top.mm) != (2025, 12) {
                    older = top
                    break
                }
            }
            guard older != nil else {
                return XCTFail("[\(grouping)] finger scrolling never left the newest month")
            }
            // Read at rest: the value is the month of the first visible tile.
            let followed = waitUntil(15) {
                guard let top = self.firstVisibleMonthAndRank() else { return false }
                return self.scrubberValue == self.expectedLabel(top.yyyy, top.mm, self.enUS)
                    && self.scrubberValue != newest
            }
            XCTAssertTrue(followed,
                          "[\(grouping)] the handle reads '\(scrubberValue)' while the grid starts on "
                          + "\(firstVisibleTile() ?? "none")")
            XCTAssertGreaterThan(scrubber.frame.midY, topY, "[\(grouping)] the handle did not move down")
            shot("s91-\(grouping)")

            // Back at the top.
            XCTAssertTrue(scrollToTopButton.waitForExistence(timeout: 10), "[\(grouping)] no scroll-to-top button")
            scrollToTopButton.tap()
            waitForScrubberValue(newest)
        }
        resetPreferencesToDefaults()
    }

    /// AC-92: default snaps to the first photo; Smooth Scrubbing lands in the
    /// middle of the month; one request for the gesture; the setting persists.
    func test_AC_92() throws {
        startFresh()
        resetPreferencesToDefaults()
        let middle = fraction(ofMonthIndex: 18, of: 36)

        // Default: the first photo of the 21-photo month.
        var mark = requestMark()
        dragScrubber(toTrackFraction: middle)
        waitForTop(2024, 6, rank: 1)
        XCTAssertEqual(bucketMonths(after: mark).first, "2024-06-01",
                       "the gesture must send one request, for the targeted month — got:\n"
                       + "\(describe(bucketRequests(after: mark)))")

        // Smooth Scrubbing on, without relaunching.
        openPreferences()
        assertSwitch("preferencesSmoothScrubbingToggle", is: "0", "Smooth Scrubbing must default to off")
        flip("preferencesSmoothScrubbingToggle")
        assertSwitch("preferencesSmoothScrubbingToggle", is: "1", "the toggle must read back the state just set")
        leavePreferencesAndHub()

        XCTAssertTrue(scrollToTopButton.waitForExistence(timeout: 20), "no scroll-to-top button after the jump")
        scrollToTopButton.tap()
        waitForTop(2025, 12, rank: 1)
        mark = requestMark()
        dragScrubber(toTrackFraction: middle)
        XCTAssertTrue(waitUntil(40) {
            guard let top = self.firstVisibleMonthAndRank() else { return false }
            return top.yyyy == 2024 && top.mm == 6
        }, "the grid never reached 2024-06 — first visible tile: \(firstVisibleTile() ?? "none")")
        let top = firstVisibleMonthAndRank()
        XCTAssertNotEqual(top?.rank, 1, "with Smooth Scrubbing on the grid must not start on the first photo")
        let seenRank: String = top.map { String($0.rank) } ?? "none"
        XCTAssertTrue((7...13).contains(top?.rank ?? 0),
                      "the first visible cell must be around the middle of the month (rank 7 to 13), got \(seenRank)")
        XCTAssertEqual(bucketMonths(after: mark).first, "2024-06-01",
                       "the gesture must send one request, for the targeted month — got:\n"
                       + "\(describe(bucketRequests(after: mark)))")
        shot("s92-smooth")

        // Relaunch: still on.
        relaunch()
        waitForTimeline()
        openPreferences()
        assertSwitch("preferencesSmoothScrubbingToggle", is: "1", "the setting must survive a relaunch")
        leavePreferencesAndHub()

        // Back to the defaults.
        resetPreferencesToDefaults()
    }

    /// AC-93: VoiceOver adjustment, one month at a time. The handle is exposed
    /// to accessibility as a slider from the oldest month (0) to the newest (1);
    /// XCUITest on iOS cannot swipe an adjustable element, so the slider is set
    /// one step at a time, which is what a VoiceOver swipe does.
    func test_AC_93() throws {
        startFresh()
        XCTAssertEqual(scrubber.label, "Date scrubber", "the handle must announce its (localized) label")
        XCTAssertEqual(scrubberValue, expectedLabel(2025, 12, enUS), "the handle must announce the month as value")

        // One step older (swipe down): month 1 of the 36.
        scrubber.adjust(toNormalizedSliderPosition: sliderPosition(ofMonthIndex: 1, of: 36))
        waitForScrubberValue(expectedLabel(2025, 11, enUS))
        waitForTop(2025, 11, rank: 1)

        // One step newer (swipe up): back to month 0.
        scrubber.adjust(toNormalizedSliderPosition: sliderPosition(ofMonthIndex: 0, of: 36))
        waitForScrubberValue(expectedLabel(2025, 12, enUS))
        waitForTop(2025, 12, rank: 1)
    }

    /// Normalized position of the accessibility slider for month `index` of `count`
    /// (newest = 1, oldest = 0).
    private func sliderPosition(ofMonthIndex index: Int, of count: Int) -> CGFloat {
        CGFloat(count - 1 - index) / CGFloat(count - 1)
    }

    /// AC-95: a release on A (slow), then at once on B: B wins, whenever A answers.
    func test_AC_95() throws {
        startFresh()
        let mark = requestMark()

        // A = 2023-09 (index 27, answers after 3 s), B = 2023-05 (index 31).
        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 27, of: 36))
        XCTAssertTrue(waitUntil(15) { self.bucketArrivals(after: mark).contains("2023-09-01") },
                      "the release on A never reached the server")
        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 31, of: 36))
        waitForTop(2023, 5, rank: 1)
        waitForScrubberValue(expectedLabel(2023, 5, enUS))

        // A's answer arrives after B's: it must change nothing.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        waitForTop(2023, 5, rank: 1)
        XCTAssertEqual(scrubberValue, expectedLabel(2023, 5, enUS), "the handle must still indicate B")
        let months = visibleTileIdentifiers().compactMap(monthAndRank(fromTileId:)).map { monthKey($0.yyyy, $0.mm) }
        XCTAssertFalse(months.contains("2023-09-01"), "a photo of A appeared on screen: \(months)")

        // The neighbours of B still load, newer then older, and A does not show up out of order.
        var seen = Set<String>()
        scroll(towards: "2023-06-01", newer: true, collecting: &seen, maxSwipes: 8)
        scroll(towards: "2023-04-01", newer: false, collecting: &seen, maxSwipes: 12)
        assertContiguous(seen)
        shot("s95-after-b")
    }

    /// AC-96: from the oldest month, "Scroll to top" brings the newest back.
    func test_AC_96() throws {
        startFresh()
        dragScrubber(toTrackFraction: fraction(ofMonthIndex: 35, of: 36))
        waitForTop(2023, 1, rank: 1)

        XCTAssertTrue(scrollToTopButton.waitForExistence(timeout: 20), "no scroll-to-top button after the jump")
        scrollToTopButton.tap()
        waitForTop(2025, 12, rank: 1)
        waitForScrubberValue(expectedLabel(2025, 12, enUS))
    }
}
