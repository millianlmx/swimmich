import XCTest

/// End-to-end scenarios for the library of a partner (lot L-08): the partner
/// list opens a screen at their name with their photos grouped by date, whether
/// or not "Show in timeline" is on, and the main timeline stays what it was.
///
/// It drives the real app against `immich_stub_partners.py` and asserts on the
/// WIRE as well as on the screen: a library that listed "everything" would
/// still render a grid, so what the app asked for (`userId`, `visibility`, and
/// never `withPartners`) is what proves it. Targets identifiers and the stub's
/// data, never a localized label (the app is pinned to English only for the one
/// title read, a name that comes from the stub).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/partners.uitest.log \
///         UITests/stubs/immich_stub_partners.py PartnerLibraryUITests --erase
///
/// The helpers are copied from `TagsHierarchyUITests` on purpose: one file per
/// feature, helpers included.
final class PartnerLibraryUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    /// How many times a test raised "Columns": the teardown lowers it back.
    private var columnsRaised = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        columnsRaised = 0
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    private let partnerA = "aaaaaaaa-1111-4111-8111-111111111111"
    private let outgoing = "bbbbbbbb-2222-4222-8222-000000000002"

    /// My own photos, 2026-09-01: the first one is the newest of my timeline.
    private let myFirstPhoto = "aaaaaaaa-1111-4111-8111-000000000001"
    private func aSept(_ n: Int) -> String { String(format: "a5a5a5a5-1111-4111-8111-%012d", n) }
    private func aMay(_ n: Int) -> String { String(format: "a5a5a5a5-3333-4333-8333-%012d", n) }
    private let aArchived = "a5a5a5a5-9999-4999-8999-000000000001"
    private let bPhoto = "d4d4d4d4-1111-4111-8111-000000000001"

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-partner-library-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-partner-library-\(name).png")
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

    /// The partner screen's own scroll view: the main timeline stays under the
    /// sheet and carries the same `assetTile_<id>` identifiers, so every tile
    /// of the screen is looked up INSIDE it.
    private var libraryGrid: XCUIElement { app.scrollViews["partnerLibraryGrid"] }

    private func libraryTile(_ assetId: String) -> XCUIElement {
        libraryGrid.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    private func identifiers(startingWith prefix: String) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
    }

    /// A row of the "Me" hub, by identifier; scrolled into view first.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return condition()
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
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
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    private func timelineRequests(_ requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "GET" && ($0.path == "/api/timeline/buckets" || $0.path == "/api/timeline/bucket") }
    }

    // MARK: - Navigation

    /// Reset, arm the stub, launch, walk onboarding if the device is fresh, land
    /// on the timeline and wait for its first tile.
    ///
    /// The partner state is set AFTER the reset (which would erase it) and
    /// BEFORE the launch. The lazy grid does not instantiate my own first photo
    /// while A's 30 newer ones are above it, so the tile waited for is the
    /// newest one actually shown: A's when A is in my timeline, mine otherwise.
    private func launchSignedIn(partnerInTimeline: Bool = true, arguments: [String] = []) {
        reset()
        setProvider("manual")
        if !partnerInTimeline { get("/api/__partners/in-timeline?id=\(partnerA)&value=false") }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
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
        let first = partnerInTimeline ? aSept(1) : myFirstPhoto
        XCTAssertTrue(tile(first).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    /// Swipes the main timeline up until the tile exists, at most `maxSwipes` times.
    private func timelineTile(_ assetId: String, maxSwipes: Int = 6) -> XCUIElement {
        let target = tile(assetId)
        for _ in 0..<maxSwipes where !target.exists { app.swipeUp() }
        return target
    }

    private func scrollTimelineToTop(firstTile: String) {
        let first = tile(firstTile)
        for _ in 0..<6 where !(first.exists && first.isHittable) { app.swipeDown() }
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    private func openPartners() {
        openHub()
        let row = hubRow("partnersRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Partners row missing in the Me hub — \(screenText())")
        row.tap()
        XCTAssertTrue(element("invitePartner").waitForExistence(timeout: 15), "the Partners screen never opened")
    }

    /// Touches a partner's identity zone. `waitForGrid: false` for a scenario
    /// that watches the loading and error states before any grid exists.
    private func openLibrary(_ partnerId: String, waitForGrid: Bool = true) {
        let link = element("partnerLibraryLink-\(partnerId)")
        XCTAssertTrue(link.waitForExistence(timeout: 15), "no library link for \(partnerId) — \(screenText())")
        link.tap()
        if waitForGrid {
            XCTAssertTrue(libraryGrid.waitForExistence(timeout: 20),
                          "the partner's library never opened — \(screenText())\n\(describe(stubRequests()))")
        }
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back")
        back.tap()
        sleep(1)
    }

    /// From the partner list back to the timeline: back to the hub, then the
    /// sheet dragged down from its navigation bar (a drag inside the form would
    /// scroll the form instead). VERIFIED: the covered timeline stays in the
    /// accessibility tree, but its tab bar is only hittable once nothing covers it.
    private func leaveHub() {
        goBack()
        let photosTab = app.tabBars.buttons["Photos"]
        var dismissed = false
        for attempt in 0..<3 where !dismissed {
            let bar = app.navigationBars.firstMatch
            let start = bar.exists
                ? bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 0, dy: attempt == 0 ? 700 : 950)))
            dismissed = waitUntil(6) { photosTab.exists && photosTab.isHittable }
        }
        XCTAssertTrue(dismissed, "the Me sheet never dismissed: the timeline assertions would read the covered timeline")
    }

    /// The switch sits at the trailing edge of its row.
    private func tapTimelineSwitch(of partnerId: String) {
        let toggle = element("partnerTimelineToggle-\(partnerId)")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "no timeline switch for \(partnerId)")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    // MARK: - AC-18

    func test_AC_18() {
        launchSignedIn(partnerInTimeline: false)

        // The main timeline holds my photo and none of A's.
        XCTAssertTrue(tile(myFirstPhoto).exists, "my own first photo should lead the timeline — \(screenText())")
        XCTAssertFalse(tile(aSept(1)).exists, "A's photos must not be in the timeline while A is switched off")
        let main = timelineRequests(stubRequests()).filter { $0.path == "/api/timeline/buckets" && $0.params["userId"] == nil }
        XCTAssertFalse(main.isEmpty, "the timeline never listed its months")
        XCTAssertTrue(main.allSatisfy { $0.params["withPartners"] == "true" },
                      "the main timeline stopped asking for partners:\n\(describe(main))")

        openPartners()
        openLibrary(partnerA)
        XCTAssertTrue(app.navigationBars["Incoming Ivan"].waitForExistence(timeout: 10), "the screen is not titled with the partner's name")
        let photo = libraryTile(aSept(1))
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "A's newest photo is missing — \(screenText())")
        let header = libraryGrid.descendants(matching: .any).matching(identifier: "partnerLibraryDayHeader_2026-09-12").firstMatch
        XCTAssertTrue(header.exists, "the photo has no day header")
        XCTAssertLessThan(header.frame.minY, photo.frame.minY, "the day header must sit above its photos")
        shot("library")
    }

    // MARK: - AC-18.1

    func test_AC_18_1_inTimelineOnThenOff() {
        launchSignedIn()
        XCTAssertTrue(tile(aSept(1)).exists)

        openPartners()
        openLibrary(partnerA)
        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 20), "the library shows nothing while A is in the timeline")
        goBack()
        leaveHub()
        XCTAssertTrue(tile(aSept(1)).waitForExistence(timeout: 15), "A's photos left the timeline by themselves")
        XCTAssertTrue(timelineTile(myFirstPhoto).exists, "my own photos are mixed in, further down")

        openPartners()
        tapTimelineSwitch(of: partnerA)
        XCTAssertTrue(waitUntil(15) {
            self.stubRequests().contains { $0.method == "PUT" && $0.path == "/api/partners/\(self.partnerA)" }
        }, "switching off sent no PUT")
        leaveHub()

        scrollTimelineToTop(firstTile: aSept(1))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(waitUntil(25) { !self.tile(self.aSept(1)).exists },
                      "A's photos are still in the timeline after a refresh — \(screenText())")
        XCTAssertTrue(tile(myFirstPhoto).waitForExistence(timeout: 15), "my own photos must stay — \(screenText())")
    }

    // MARK: - AC-18.2

    func test_AC_18_2_switchAndSharingRowOpenNothing() {
        launchSignedIn()
        openPartners()

        let toggle = element("partnerTimelineToggle-\(partnerA)")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let before = toggle.value as? String
        tapTimelineSwitch(of: partnerA)
        XCTAssertTrue(waitUntil(15) {
            self.stubRequests().contains { $0.method == "PUT" && $0.path == "/api/partners/\(self.partnerA)" }
        }, "the switch sent no PUT /api/partners/<id>")
        XCTAssertTrue(waitUntil(10) { (toggle.value as? String) != before }, "the switch did not change value")
        XCTAssertFalse(libraryGrid.waitForExistence(timeout: 3), "the switch opened the library")

        let sharingRow = element("partnerName-\(outgoing)")
        XCTAssertTrue(sharingRow.waitForExistence(timeout: 10), "no row in the Sharing section — \(screenText())")
        sharingRow.tap()
        XCTAssertFalse(libraryGrid.waitForExistence(timeout: 3), "a Sharing row opened a library")
    }

    // MARK: - AC-18.3

    func test_AC_18_3_onlyPartnerNonArchivedPhotosAndWireFilters() {
        launchSignedIn()
        openPartners()
        let mark = stubRequests().count
        openLibrary(partnerA)

        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 20), "A's newest photo is missing — \(screenText())")
        XCTAssertFalse(libraryTile(aArchived).exists, "an archived photo of A is shown")
        XCTAssertFalse(libraryTile(bPhoto).exists, "a photo of B is shown on A's screen")
        XCTAssertFalse(libraryTile(myFirstPhoto).exists, "one of my photos is shown on A's screen")

        let requests = timelineRequests(Array(stubRequests().dropFirst(mark)))
        XCTAssertTrue(requests.contains { $0.path == "/api/timeline/buckets" }, "no bucket list was asked:\n\(describe(requests))")
        XCTAssertTrue(requests.contains { $0.path == "/api/timeline/bucket" }, "no bucket was asked:\n\(describe(requests))")
        for request in requests {
            XCTAssertEqual(request.params["userId"], partnerA, "\(request.path) lacks the partner's userId")
            XCTAssertEqual(request.params["visibility"], "timeline", "\(request.path) lacks an explicit visibility")
            for forbidden in ["withPartners", "isFavorite", "isTrashed"] {
                XCTAssertNil(request.params[forbidden], "\(request.path) must not send \(forbidden)")
            }
        }
    }

    // MARK: - AC-18.4

    func test_AC_18_4_scrollToOldestUnderDayHeader() {
        launchSignedIn()
        openPartners()
        openLibrary(partnerA)
        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 20))

        let oldest = libraryTile(aMay(2))
        for _ in 0..<15 where !oldest.exists { libraryGrid.swipeUp() }
        XCTAssertTrue(oldest.exists, "scrolling never reached A's oldest photo — \(screenText())")

        let header = libraryGrid.descendants(matching: .any).matching(identifier: "partnerLibraryDayHeader_2026-05-20").firstMatch
        XCTAssertTrue(header.exists, "the oldest photos have no day header")
        XCTAssertLessThan(header.frame.minY, oldest.frame.minY, "the day header must sit above its photos")

        let months = timelineRequests(stubRequests())
            .filter { $0.path == "/api/timeline/bucket" && $0.params["userId"] == partnerA }
            .compactMap { $0.params["timeBucket"] }
        XCTAssertEqual(months, ["2026-09-01", "2026-07-01", "2026-05-01"], "the months must be read newest first, one per page")
    }

    func test_AC_18_4_monthAndFlatGrouping() {
        launchSignedIn(arguments: ["-timelineGroupAssetsBy", "month"])
        openPartners()
        openLibrary(partnerA)
        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 20))
        XCTAssertTrue(element("partnerLibraryMonthHeader_2026-09").exists, "Group By month shows no month header")
        XCTAssertEqual(identifiers(startingWith: "partnerLibraryDayHeader_"), 0, "Group By month must show no day header")

        app.terminate()
        launchSignedIn(arguments: ["-timelineGroupAssetsBy", "none"])
        openPartners()
        openLibrary(partnerA)
        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 20), "Flat grouping shows no photo")
        XCTAssertEqual(identifiers(startingWith: "partnerLibraryDayHeader_"), 0, "Flat grouping must show no day header")
        XCTAssertEqual(identifiers(startingWith: "partnerLibraryMonthHeader_"), 0, "Flat grouping must show no month header")
    }

    func test_AC_18_4_columnsFollowPreference() {
        // Registered BEFORE the setting is touched, and run even when this test
        // fails on the way: no later scenario may read a 5-column preference.
        addTeardownBlock { [self] in
            guard columnsRaised > 0 else { return }
            app.terminate()
            launchSignedIn()
            openHub()
            let row = hubRow("preferencesRow")
            guard row.waitForExistence(timeout: 10) else { return }
            row.tap()
            let stepper = element("preferencesColumnsStepper")
            guard stepper.waitForExistence(timeout: 15) else { return }
            for _ in 0..<columnsRaised { stepper.buttons["Decrement"].tap() }
        }

        launchSignedIn()
        openHub()
        let preferences = hubRow("preferencesRow")
        XCTAssertTrue(preferences.waitForExistence(timeout: 10), "Preferences row missing — \(screenText())")
        preferences.tap()
        let stepper = element("preferencesColumnsStepper")
        XCTAssertTrue(stepper.waitForExistence(timeout: 15), "the Columns stepper is missing")
        for _ in 0..<2 {
            let increment = stepper.buttons["Increment"]
            XCTAssertTrue(increment.waitForExistence(timeout: 5), "no Increment button on the Columns stepper")
            increment.tap()
            columnsRaised += 1
        }
        goBack() // Preferences → the hub, still on screen

        let partners = hubRow("partnersRow")
        XCTAssertTrue(partners.waitForExistence(timeout: 10), "Partners row missing in the Me hub")
        partners.tap()
        openLibrary(partnerA)
        let first = libraryTile(aSept(1))
        XCTAssertTrue(first.waitForExistence(timeout: 20))

        let firstRow = (1...5).map { libraryTile(aSept($0)) }
        XCTAssertTrue(firstRow.allSatisfy { $0.exists }, "the first row of five tiles is not all there — \(screenText())")
        for cell in firstRow {
            XCTAssertEqual(cell.frame.minY, first.frame.minY, accuracy: 1, "five tiles must share one row")
        }
        let sixth = libraryTile(aSept(6))
        XCTAssertTrue(sixth.exists)
        XCTAssertGreaterThan(sixth.frame.minY, first.frame.minY, "the sixth tile must wrap to the next row")
    }

    // MARK: - AC-18.5

    func test_AC_18_5_viewerSwipesWithinLibraryShareOnly() {
        launchSignedIn()
        openPartners()
        openLibrary(partnerA)
        let photo = libraryTile(aSept(1))
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()

        let place = element("viewerBadgePlace")
        XCTAssertTrue(waitUntil(15) { place.exists && place.label == "A-sept-01" },
                      "the viewer did not open on A's newest photo — \(screenText())")
        XCTAssertTrue(element("viewerShareButton").waitForExistence(timeout: 10), "sharing is not offered")
        assertNoOwnerActions()

        app.swipeLeft()
        XCTAssertTrue(waitUntil(15) { place.exists && place.label == "A-sept-02" },
                      "swiping did not reach the next photo of A's library — \(screenText())")
        XCTAssertTrue(element("viewerShareButton").waitForExistence(timeout: 10))
        assertNoOwnerActions()
    }

    private func assertNoOwnerActions() {
        for id in ["viewerFavoriteButton", "viewerEditButton", "viewerArchiveButton", "viewerDeleteButton"] {
            XCTAssertFalse(element(id).exists, "\(id) must not be offered on another account's photo")
        }
    }

    // MARK: - AC-18.6

    func test_AC_18_6_errorEmptyThenPhotos() {
        launchSignedIn()
        get("/api/__partners/script?steps=500,empty,ok&delay=2")
        openPartners()
        openLibrary(partnerA, waitForGrid: false)

        // 500: loading, then the error with "Try Again".
        XCTAssertTrue(element("partnerLibraryLoading").waitForExistence(timeout: 5), "no loading indicator on opening")
        XCTAssertTrue(element("partnerLibraryError").waitForExistence(timeout: 20), "no error state — \(screenText())")
        let retry = element("partnerLibraryErrorRetry")
        XCTAssertTrue(retry.exists, "the error state has no Try Again")

        // 200 without photos: loading, then the empty state.
        retry.tap()
        XCTAssertTrue(element("partnerLibraryLoading").waitForExistence(timeout: 5), "no loading indicator on Try Again")
        XCTAssertTrue(element("partnerLibraryEmptyState").waitForExistence(timeout: 20), "no empty state — \(screenText())")

        // 200 with photos, from a pull down: the empty state stays while the
        // request waits, then the photos replace it.
        XCTAssertTrue(libraryGrid.waitForExistence(timeout: 5))
        libraryGrid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: libraryGrid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(element("partnerLibraryEmptyState").exists, "the content was torn down while the refresh was pending")
        XCTAssertTrue(libraryTile(aSept(1)).waitForExistence(timeout: 25), "the refresh never brought the photos — \(screenText())")
    }
}
