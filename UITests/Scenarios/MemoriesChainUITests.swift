import XCTest

/// End-to-end scenarios for the memories of Immich v3.3+ and their chaining
/// (lot L-07, B-11 and B-34): a birthday memory and an unknown type are listed
/// with a title of their own, and the full-screen playback goes from one memory
/// to the next up to an end screen with "Start Over", with a haptic on every
/// photo and memory change the user makes.
///
/// It drives the real app against `immich_stub_memories.py`, which serves named
/// data sets: `/__reset?fixture=chain` (a birthday and two "on this day"
/// memories, served out of order) and `?fixture=types`. The app is launched with
/// `-uiTestMemoryPlaybackProbe YES`, which adds one `memoryPlaybackProbe`
/// element whose accessibility VALUE reads
/// `page=<memory id|end> photo=<index> haptic=<none|selection#n|medium#n>
/// autoplay=<on|off>`, `haptic` being what the haptic gate really returned to
/// SwiftUI. `-uiTestMemoryAutoplayOff YES` (every scenario but the auto-play one)
/// keeps the playback still until a gesture of the test moves it, so each step
/// waits for an exact probe value.
///
/// Targets identifiers and the stub's data, never a localized label.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/memories-chain.uitest.log \
///         UITests/stubs/immich_stub_memories.py MemoriesChainUITests --erase
///
/// The helpers are copied from `JpegXLUITests` on purpose: one file per feature,
/// helpers included.
final class MemoriesChainUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-authServerURL", "()",
            "-uiTestMemoryPlaybackProbe", "YES",
        ]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    private let birthday = "eeeeeeee-5555-4555-8555-000000000001"
    private let otd2023 = "eeeeeeee-5555-4555-8555-000000000002"
    private let otd2022 = "eeeeeeee-5555-4555-8555-000000000003"

    private let typesOtd = "ffffffff-6666-4666-8666-000000000001"
    private let typesTrip = "ffffffff-6666-4666-8666-000000000002"
    private let typesUnnamedBirthday = "ffffffff-6666-4666-8666-000000000003"

    private let libraryPhoto = "aaaaaaaa-1111-4111-8111-000000000001"

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-memories-chain-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-memories-chain-\(name).png")
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

    private func reset(fixture: String) {
        let reply = get("/__reset?fixture=\(fixture)")
        XCTAssertEqual(reply.status, 200, "the stub refused the fixture \(fixture): \(reply.body)")
    }

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

    /// One entry of the stub's request log (the memory routes log flat).
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let isSaved: Bool?
        let ids: [String]?
    }

    private func stubRequests() -> [StubRequest] {
        let body = get("/__requests").body
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) isSaved=\($0.isSaved.map(String.init) ?? "-") ids=\($0.ids ?? [])" }
            .joined(separator: "\n")
    }

    private func assertStubWrote(method: String, path: String, isSaved: Bool? = nil) {
        let requests = stubRequests()
        let match = requests.contains {
            $0.method == method && $0.path == path && (isSaved == nil || $0.isSaved == isSaved)
        }
        XCTAssertTrue(match, "no \(method) \(path) isSaved=\(isSaved.map(String.init) ?? "-") on the wire — got:\n\(describe(requests))")
    }

    // MARK: - Navigation

    /// Reset the stub on `fixture`, launch on a fresh session, walk onboarding and
    /// land on the Memories tab. `autoplay` keeps the playback's auto-play on.
    private func launchSignedIn(fixture: String = "chain", autoplay: Bool = false) {
        reset(fixture: fixture)
        setProvider("manual")
        if !autoplay { app.launchArguments += ["-uiTestMemoryAutoplayOff", "YES"] }
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
        openMemoriesTab()
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

    private func card(_ id: String) -> XCUIElement { element("memoryCard_\(id)") }

    /// Scrolls the list until the card is hittable, then opens the playback on it.
    private func openCard(_ id: String, expectAutoplay: String = "off") {
        let target = card(id)
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no card \(id) — \(screenText())")
        for _ in 0..<6 where !target.isHittable {
            app.swipeUp()
            sleep(1)
        }
        target.tap()
        XCTAssertTrue(element("memoryPlaybackProbe").waitForExistence(timeout: 20),
                      "the playback did not open — \(screenText())")
        waitForProbe(["page": id, "photo": "0", "autoplay": expectAutoplay])
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    /// The Me hub → Preferences → "Haptic Feedback" set to `on` → back to the tab.
    private func setHaptics(on: Bool) {
        openHub()
        let row = hubRow("preferencesRow")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Preferences row missing — \(screenText())")
        row.tap()
        let toggle = element("preferencesHapticsToggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "the Haptic Feedback toggle is missing")
        let wanted = on ? "1" : "0"
        for _ in 0..<3 where (toggle.value as? String) != wanted {
            // The element is the whole row: its own control sits at the trailing edge.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let deadline = Date().addingTimeInterval(4)
            while (toggle.value as? String) != wanted && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        }
        XCTAssertEqual(toggle.value as? String, wanted, "Haptic Feedback never reached \(wanted)")
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        app.swipeDown()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 20), "the Me sheet did not close")
    }

    // MARK: - The probe

    /// The probe's fields, or [:] when the element is missing.
    private func probe() -> [String: String] {
        let probe = element("memoryPlaybackProbe")
        guard probe.exists, let value = probe.value as? String else { return [:] }
        var fields: [String: String] = [:]
        for part in value.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    /// Polls until every expected field of the probe matches exactly (10 s at
    /// most by default). A failure quotes the last read, the screen and the log.
    @discardableResult
    private func waitForProbe(_ expected: [String: String], timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: String] = [:]
        repeat {
            last = probe()
            if expected.allSatisfy({ last[$0.key] == $0.value }) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("the probe never read \(expected) — last read: \(last); \(screenText()); stub log:\n\(describe(stubRequests()))")
        return false
    }

    /// Polls until the label of `identifier` satisfies `check`.
    @discardableResult
    private func waitForLabel(_ identifier: String, timeout: TimeInterval = 10, _ check: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            let candidate = element(identifier)
            if candidate.exists {
                last = candidate.label
                if check(last) { return last }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        XCTFail("\(identifier) never matched — last label: “\(last)”; \(screenText())")
        return last
    }

    private func tapHeroPhoto() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    }

    // MARK: - AC-17

    func test_AC_17_birthdayAndOnThisDayListedWithOwnTitles() {
        launchSignedIn()

        let birthdayCard = card(birthday)
        XCTAssertTrue(birthdayCard.waitForExistence(timeout: 30), "no birthday card — \(screenText())")
        XCTAssertTrue(card(otd2023).waitForExistence(timeout: 10), "no 2023 card")
        XCTAssertFalse(element("memoriesRefreshErrorBanner").exists, "the list shows an error banner")

        // Order (AC-17.7): the birthday first, then 2023, then 2022 — read off the
        // order of the realized cards, the third one after scrolling to it.
        for _ in 0..<6 where !card(otd2022).exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(card(otd2022).exists, "no 2022 card")
        let realized = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'memoryCard_'"))
            .allElementsBoundByIndex.map(\.identifier)
        let expected = [birthday, otd2023, otd2022].map { "memoryCard_\($0)" }
        XCTAssertEqual(realized.filter(expected.contains), expected.filter(realized.contains),
                       "the cards are not in memoryAt order")

        for _ in 0..<6 where !birthdayCard.isHittable {
            app.swipeDown()
            sleep(1)
        }
        let birthdayLabel = birthdayCard.label
        XCTAssertTrue(birthdayLabel.contains("Alice"), "the birthday card does not name Alice: \(birthdayLabel)")
        XCTAssertFalse(birthdayLabel.contains("1990"), "the birthday card shows the birth year: \(birthdayLabel)")
        XCTAssertFalse(birthdayLabel.contains("36"), "the birthday card shows an elapsed count: \(birthdayLabel)")

        let label2023 = card(otd2023).label
        XCTAssertFalse(label2023.isEmpty)
        XCTAssertTrue(label2023.contains("2023"), "the 2023 card lost its year: \(label2023)")
        for _ in 0..<6 where !card(otd2022).isHittable {
            app.swipeUp()
            sleep(1)
        }
        let label2022 = card(otd2022).label
        XCTAssertFalse(label2022.isEmpty)
        XCTAssertTrue(label2022.contains("2022"), "the 2022 card lost its year: \(label2022)")
    }

    func test_AC_17_1_2_birthdayTitleFollowsDisplayedPhoto() {
        launchSignedIn()
        openCard(birthday)

        let first = waitForLabel("memoryTitle_\(birthday)") { $0.contains("Alice") && $0.contains("30") }
        XCTAssertFalse(first.contains("1990"), "the title shows the birth year: \(first)")

        app.swipeLeft()
        waitForProbe(["photo": "1"])
        waitForLabel("memoryTitle_\(birthday)") { $0.contains("Alice") && $0.contains("31") }
    }

    func test_AC_17_3_4_unnamedBirthdayAndUnknownTypeListed() {
        launchSignedIn(fixture: "types")

        // Sorted by memoryAt: the unnamed birthday, the 2023 memory, the trip.
        XCTAssertTrue(card(typesUnnamedBirthday).waitForExistence(timeout: 30),
                      "the unnamed birthday is not listed — \(screenText())")
        XCTAssertFalse(element("memoriesRefreshErrorBanner").exists, "the list shows an error banner")
        XCTAssertFalse(card(typesUnnamedBirthday).label.isEmpty, "the unnamed birthday has no title")
        XCTAssertTrue(card(typesOtd).waitForExistence(timeout: 10), "the on-this-day memory is not listed")

        for _ in 0..<6 where !card(typesTrip).isHittable {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(card(typesTrip).waitForExistence(timeout: 10), "the unknown-type memory is not listed")
        XCTAssertTrue(card(typesTrip).label.contains("2021"), "its title does not come from its date")
        openCard(typesTrip)
        let title = element("memoryTitle_\(typesTrip)")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the unknown-type memory did not open")
        XCTAssertFalse(title.label.isEmpty, "its title is empty")
    }

    func test_AC_17_6_birthdayActionsKeepTitle() {
        launchSignedIn()

        let bookmark = app.buttons["memoryBookmark_\(birthday)"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 30), "no bookmark on the birthday card")
        let before = bookmark.label
        bookmark.tap()
        let flipped = NSPredicate(format: "label != %@", before)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: flipped, evaluatedWith: bookmark)], timeout: 15),
                       .completed, "saving the birthday did not flip its bookmark")
        bookmark.tap()
        let restored = NSPredicate(format: "label == %@", before)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: restored, evaluatedWith: bookmark)], timeout: 15),
                       .completed, "unsaving the birthday did not flip its bookmark back")

        openCard(birthday)
        let add = app.buttons["memoryMomentAddPhotos"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "no add-photos action")
        add.tap()
        let picked = element("pickerAsset_\(libraryPhoto)")
        XCTAssertTrue(picked.waitForExistence(timeout: 20), "the add-photos picker did not load")
        picked.tap()
        app.buttons["confirmAddPhotosToMemory"].tap()
        sleep(4)
        let remove = app.buttons["memoryMomentRemovePhoto"]
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "no remove-photo action")
        remove.tap()
        sleep(3)

        let requests = stubRequests()
        let saves = requests.filter { $0.method == "PUT" && $0.path == "/api/memories/\(birthday)" }.map(\.isSaved)
        XCTAssertEqual(saves, [true, false], "the save/unsave round trip is not on the wire — got:\n\(describe(requests))")
        assertStubWrote(method: "PUT", path: "/api/memories/\(birthday)/assets")
        assertStubWrote(method: "DELETE", path: "/api/memories/\(birthday)/assets")
        waitForLabel("memoryTitle_\(birthday)") { $0.contains("Alice") }
    }

    // MARK: - AC-60

    /// The manual walk of the chain, shared by the haptics-on and haptics-off
    /// scenarios: only the expected `haptic` field differs.
    private func walkChain(hapticsOn: Bool) {
        func haptic(_ value: String) -> String { hapticsOn ? value : "none" }

        openCard(birthday)
        waitForProbe(["page": birthday, "photo": "0", "haptic": "none", "autoplay": "off"])

        app.swipeLeft()
        waitForProbe(["page": birthday, "photo": "1", "haptic": haptic("selection#1")])

        app.swipeLeft() // the passage after the last photo
        waitForProbe(["page": otd2023, "photo": "0", "haptic": haptic("medium#2")])

        app.swipeLeft() // its only photo, then the passage
        waitForProbe(["page": otd2022, "photo": "0", "haptic": haptic("medium#3")])

        app.swipeUp()
        waitForProbe(["page": "end", "haptic": haptic("medium#4")])
        XCTAssertTrue(element("memoriesEpilogue").waitForExistence(timeout: 10), "no end screen")
        let startOver = element("memoriesStartOverButton")
        XCTAssertTrue(startOver.waitForExistence(timeout: 10), "no Start Over on the end screen")
        shot(hapticsOn ? "end-screen" : "end-screen-haptics-off")

        startOver.tap()
        waitForProbe(["page": birthday, "photo": "0", "haptic": haptic("medium#5"), "autoplay": "off"])

        tapHeroPhoto()
        let back = element("viewerBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: 15), "touching a photo did not open the viewer")
        back.tap()
        waitForProbe(["page": birthday, "photo": "0"])

        let close = element("memoryMomentClose")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no close button on the memory")
        close.tap()
        XCTAssertTrue(card(birthday).waitForExistence(timeout: 15), "closing did not come back to the list")
    }

    func test_AC_60_manualChainEndScreenAndHaptics() {
        launchSignedIn()
        walkChain(hapticsOn: true)
    }

    func test_AC_60_1_autoplayCrossesMemoriesSilently() {
        launchSignedIn(autoplay: true)
        openCard(birthday, expectAutoplay: "on")

        var seen: [String: String] = [:]
        var pages: [String] = []
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            seen = probe()
            if let page = seen["page"], pages.last != page { pages.append(page) }
            if let haptic = seen["haptic"] {
                XCTAssertEqual(haptic, "none", "the auto-play emitted a haptic: \(seen)")
            }
            if seen["page"] == "end" { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(seen["page"], "end", "the auto-play never reached the end screen — pages seen: \(pages)")
        XCTAssertTrue(pages.contains(otd2023), "the auto-play skipped the second memory — pages seen: \(pages)")
        XCTAssertEqual(seen["haptic"], "none")
    }

    func test_AC_60_2_swipeDownReturnsToPreviousMemory() {
        launchSignedIn()
        openCard(otd2023)

        app.swipeDown()

        waitForProbe(["page": birthday, "photo": "0"])
        XCTAssertFalse(card(birthday).isHittable, "the list is showing: the swipe went back to the list")
    }

    func test_AC_60_3_startOverFromSecondAndClose() {
        launchSignedIn()
        openCard(otd2023)

        app.swipeLeft() // its only photo → the passage → the 2022 memory
        waitForProbe(["page": otd2022, "photo": "0"])
        app.swipeLeft() // 2022 has two photos
        waitForProbe(["page": otd2022, "photo": "1"])
        app.swipeLeft()
        waitForProbe(["page": "end"])

        let startOver = element("memoriesStartOverButton")
        XCTAssertTrue(startOver.waitForExistence(timeout: 10), "no Start Over on the end screen")
        startOver.tap()
        waitForProbe(["page": birthday, "photo": "0"])

        for expected in [otd2023, otd2022, "end"] {
            app.swipeUp()
            waitForProbe(["page": expected])
        }
        let close = element("memoriesEpilogueClose")
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no close button on the end screen")
        close.tap()
        XCTAssertTrue(card(birthday).waitForExistence(timeout: 15), "closing the end screen did not come back to the list")
    }

    /// A one-photo memory left by its passage shows its photo again, not the
    /// passage, when the user comes back to it (S-7). Reads the horizontal pager
    /// itself (`memoryPagerProbe_<id>`), not the model.
    func test_AC_60_7_returningToAOnePhotoMemoryShowsItsPhoto() {
        launchSignedIn()
        openCard(otd2023)
        let pager = element("memoryPagerProbe_\(otd2023)")
        let photo = "bbbbbbbb-2222-4222-8222-000000000003"
        XCTAssertTrue(pager.waitForExistence(timeout: 10), "no pager probe on the 2023 memory — \(screenText())")
        XCTAssertEqual(pager.value as? String, photo)

        app.swipeLeft() // its only photo, then the passage → the 2022 memory
        waitForProbe(["page": otd2022, "photo": "0"])

        app.swipeDown() // back to the 2023 memory
        waitForProbe(["page": otd2023, "photo": "0"])
        let deadline = Date().addingTimeInterval(10)
        while (pager.value as? String) != photo && Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        XCTAssertEqual(pager.value as? String, photo,
                       "the 2023 memory came back on its passage instead of its photo")
    }

    func test_AC_60_4_hapticsOffEmitsNothing() {
        launchSignedIn()
        // Registered BEFORE the setting is touched, and run even when this test
        // fails on the way: no later scenario may read a haptics-off setting.
        addTeardownBlock { [self] in
            app.terminate()
            launchSignedIn()
            openHub()
            let row = hubRow("preferencesRow")
            guard row.waitForExistence(timeout: 10) else { return }
            row.tap()
            let toggle = element("preferencesHapticsToggle")
            guard toggle.waitForExistence(timeout: 15), (toggle.value as? String) == "0" else { return }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }

        setHaptics(on: false)
        openMemoriesTab()
        walkChain(hapticsOn: false)
    }

    func test_AC_60_5_deleteAndEmptyMoveToNext() {
        launchSignedIn()
        openCard(otd2023)

        let delete = app.buttons["memoryMomentDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15), "no delete action")
        delete.tap()
        // The confirmation is an alert: its button is queried inside it.
        let confirm = app.alerts.firstMatch.buttons
            .matching(NSPredicate(format: "label == %@", "Delete Memory")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no confirmation for the delete")
        confirm.tap()
        waitForProbe(["page": otd2022, "photo": "0"])
        assertStubWrote(method: "DELETE", path: "/api/memories/\(otd2023)")

        for _ in 0..<2 {
            let remove = app.buttons["memoryMomentRemovePhoto"]
            XCTAssertTrue(remove.waitForExistence(timeout: 10), "remove action missing")
            remove.tap()
            sleep(3)
        }
        waitForProbe(["page": "end"])
    }

    func test_AC_60_6_epilogueAccessible() {
        launchSignedIn()
        openCard(otd2023)
        app.swipeUp()
        waitForProbe(["page": otd2022])
        app.swipeUp()
        waitForProbe(["page": "end"])

        let startOver = element("memoriesStartOverButton")
        XCTAssertTrue(startOver.waitForExistence(timeout: 10), "no Start Over on the end screen")
        XCTAssertFalse(startOver.label.isEmpty, "Start Over has no label")
        XCTAssertNotEqual(startOver.label, "memoriesStartOverButton", "Start Over is announced by its identifier")

        let epilogue = element("memoriesEpilogue")
        XCTAssertTrue(epilogue.exists, "no end screen container")
        let texts = epilogue.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label)
        XCTAssertGreaterThanOrEqual(texts.filter { !$0.isEmpty }.count, 2, "title and message missing: \(texts)")
    }
}
