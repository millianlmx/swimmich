import XCTest

/// End-to-end scenario for the tag hierarchy (lot L-03): the Tags screen shows
/// the tree, creates a tag under a parent, opens the photos of any tag; the tag
/// sheet of a photo names each tag by its full path.
///
/// It drives the real app against `immich_stub_tags.py` and asserts on the WIRE
/// as well as on the screen: a tag screen that listed "everything" would still
/// render a grid, so what the app asked for (`tagId`, `visibility`, `parentId`)
/// is what proves it. Targets identifiers and the stub's data, never a
/// localized label.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/tags.uitest.log \
///         UITests/stubs/immich_stub_tags.py TagsHierarchyUITests --erase
///
/// The helpers are copied from `RecentlyTakenUITests` and `AppLockUITests` on
/// purpose: one file per feature, helpers included.
final class TagsHierarchyUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The stub's data

    /// `7a000000-0000-4000-8000-0000000000NN`, NN as the stub's table writes it.
    private func tag(_ nn: String) -> String { "7a000000-0000-4000-8000-0000000000\(nn)" }

    private let voyages = "01", japon = "02", tokyo = "03", famille = "04", orphelin = "05"
    private let cuisineJapon = "07", vide = "08", panne = "09", plage = "0a"

    private let timelinePhoto = "aaaaaaaa-1111-4111-8111-000000000001"
    private let japonPhotos = (1...3).map { "bbbbbbbb-1111-4111-8111-00000000000\($0)" }
    private let voyagesOnlyPhoto = "cccccccc-1111-4111-8111-000000000001"
    private let panneFirstPhoto = "eeeeeeee-1111-4111-8111-000000000001"
    private let plageFirstPhoto = "ffffffff-1111-4111-8111-000000000001"
    private let plageLastPhoto = "ffffffff-2222-4222-8222-000000000003"

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-tags-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-tags-\(name).png")
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

    // MARK: - Wire helpers

    /// One entry of the stub's request log, with the fields this stub notes.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let name: String?
        let hasParentId: Bool?
        let parentId: String?
        let createdId: String?
        let tagId: String?
        let ids: [String]?
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

    private func creations() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/tags" }
    }

    // MARK: - Navigation

    /// Reset, launch, walk onboarding if the device is fresh, land on the timeline.
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
        XCTAssertTrue(tile(timelinePhoto).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    /// Albums tab → Library section → Tags tile. A Me sheet still on screen is
    /// pulled down first: it covers the tab bar. The Albums ScrollView is scrolled
    /// only when the tile is not hittable.
    private func openTags() {
        for _ in 0..<4 {
            if app.buttons.matching(identifier: "profileAvatar").firstMatch.isHittable { break }
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            top.press(forDuration: 0.1, thenDragTo: bottom)
            sleep(1)
        }
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15), "Albums tab missing — \(screenText())")
        albums.tap()
        let row = app.buttons.matching(identifier: "tagsRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Tags tile missing in the Albums library — \(screenText())")
        for _ in 0..<4 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        row.tap()
        XCTAssertTrue(element("createTagButton").waitForExistence(timeout: 15), "the Tags screen never opened")
    }

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back")
        back.tap()
        sleep(1)
    }

    private func row(_ parent: String, _ id: String) -> XCUIElement {
        element("tagRow_\(parent)_\(id)")
    }

    /// The name inside a row — what the indent is read on.
    private func nameText(_ row: XCUIElement) -> XCUIElement {
        let text = row.staticTexts.firstMatch
        return text.exists ? text : row
    }

    private func tagRowIdentifiers() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'tagRow_'"))
            .allElementsBoundByIndex.map(\.identifier).sorted()
    }

    /// Fills the creation sheet. The parent is picked BEFORE typing: the keyboard
    /// would otherwise cover the parent list.
    private func createTag(named name: String, under parent: String) {
        element("createTagButton").tap()
        let parentRow = element(parent == "root" ? "createTagParent_root" : "createTagParent_\(parent)")
        XCTAssertTrue(parentRow.waitForExistence(timeout: 10), "creation sheet missing its parent list — \(screenText())")
        parentRow.tap()
        let field = app.textFields.matching(identifier: "createTagName").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "creation sheet missing its name field")
        field.tap()
        field.typeText(name)
        let confirm = element("createTagConfirm")
        XCTAssertTrue(confirm.isEnabled, "Create must be enabled for \"\(name)\"")
        confirm.tap()
    }

    // MARK: - Scenarios

    func test_AC_12_childUnderParentAndOnlyItsPhotos() {
        launchSignedIn()
        openTags()

        let parent = row("root", tag(voyages))
        let child = row(tag(voyages), tag(japon))
        XCTAssertTrue(parent.waitForExistence(timeout: 15), "Voyages row missing — \(screenText())")
        XCTAssertTrue(child.exists, "Japon is not listed under Voyages — ids: \(tagRowIdentifiers())")
        XCTAssertGreaterThan(child.frame.minY, parent.frame.minY, "Japon must sit below Voyages")
        XCTAssertGreaterThan(nameText(child).frame.minX, nameText(parent).frame.minX,
                             "Japon must be indented under Voyages")
        shot("ac12-tree")

        let logged = stubRequests().count
        child.tap()

        for photo in japonPhotos {
            XCTAssertTrue(tile(photo).waitForExistence(timeout: 20), "Japon's photo \(photo) missing")
        }
        XCTAssertFalse(tile(voyagesOnlyPhoto).exists, "a photo of Voyages alone leaked into Japon")
        XCTAssertFalse(tile(timelinePhoto).exists, "an untagged photo leaked into Japon")
        shot("ac12-japon-photos")

        let after = Array(stubRequests().dropFirst(logged))
        let timeline = after.filter { $0.path == "/api/timeline/buckets" || $0.path == "/api/timeline/bucket" }
        XCTAssertTrue(timeline.contains { $0.path == "/api/timeline/buckets" }
                      && timeline.contains { $0.path == "/api/timeline/bucket" },
                      "opening Japon must read both timeline routes — got:\n\(describe(after))")
        for request in timeline {
            XCTAssertEqual(request.params["tagId"], tag(japon), "\(request.path) lost the tag — got:\n\(describe(after))")
            XCTAssertEqual(request.params["visibility"], "timeline", "\(request.path) lost visibility=timeline")
        }
    }

    func test_AC_13_createUnderParent() {
        launchSignedIn()
        openTags()
        XCTAssertTrue(row("root", tag(voyages)).waitForExistence(timeout: 15), "Voyages row missing")

        createTag(named: "Italie", under: tag(voyages))

        let created = creations()
        XCTAssertEqual(created.count, 1, "one creation expected — got:\n\(describe(stubRequests()))")
        XCTAssertEqual(created.first?.name, "Italie")
        XCTAssertEqual(created.first?.parentId, tag(voyages))
        guard let createdId = created.first?.createdId else { return XCTFail("the stub created nothing") }
        // No pull-to-refresh: the row must be there on its own.
        XCTAssertTrue(row(tag(voyages), createdId).waitForExistence(timeout: 10),
                      "Italie did not appear under Voyages — ids: \(tagRowIdentifiers())")
        shot("ac13-created")
    }

    func test_AC_76_threeLevelsAndOrphan() {
        launchSignedIn()
        openTags()

        let rootVoyages = row("root", tag(voyages))
        XCTAssertTrue(rootVoyages.waitForExistence(timeout: 15), "Voyages row missing — \(screenText())")
        let japonRow = row(tag(voyages), tag(japon))
        let tokyoRow = row(tag(japon), tag(tokyo))
        for expected in [japonRow, tokyoRow, row("root", tag(famille)), row("root", tag(orphelin))] {
            XCTAssertTrue(expected.exists, "missing row — ids: \(tagRowIdentifiers())")
        }
        XCTAssertLessThan(rootVoyages.frame.minY, japonRow.frame.minY)
        XCTAssertLessThan(japonRow.frame.minY, tokyoRow.frame.minY)
        XCTAssertLessThan(nameText(rootVoyages).frame.minX, nameText(japonRow).frame.minX)
        XCTAssertLessThan(nameText(japonRow).frame.minX, nameText(tokyoRow).frame.minX)
        XCTAssertEqual(nameText(tokyoRow).label, "Tokyo", "a row shows the short name, not the path")
        shot("ac76-three-levels")
    }

    func test_AC_77_rootCreationAndBlankName() {
        launchSignedIn()
        openTags()
        XCTAssertTrue(row("root", tag(voyages)).waitForExistence(timeout: 15), "Voyages row missing")

        createTag(named: "Animaux", under: "root")

        let created = creations()
        XCTAssertEqual(created.count, 1, "one creation expected")
        XCTAssertEqual(created.first?.name, "Animaux")
        XCTAssertEqual(created.first?.hasParentId, false, "a root creation must not carry parentId")
        guard let createdId = created.first?.createdId else { return XCTFail("the stub created nothing") }
        XCTAssertTrue(row("root", createdId).waitForExistence(timeout: 10),
                      "Animaux did not appear at the root — ids: \(tagRowIdentifiers())")

        element("createTagButton").tap()
        let field = app.textFields.matching(identifier: "createTagName").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "creation sheet missing its name field")
        field.tap()
        field.typeText("   ")
        XCTAssertFalse(element("createTagConfirm").isEnabled, "Create must stay disabled for a blank name")
        XCTAssertEqual(creations().count, 1, "a blank name must send nothing")
        element("createTagCancel").tap()
    }

    func test_AC_78_readOnlyAndServerError() {
        launchSignedIn()

        // Read-only on: the refusal is client-side, nothing reaches the server.
        openHub()
        let toggle = app.switches.matching(identifier: "readOnlyModeToggle").firstMatch
        for _ in 0..<8 where !toggle.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 15), "no Read-only Mode switch in the Me hub")
        if (toggle.value as? String) != "1" {
            toggle.tap()
            if (toggle.value as? String) != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
        }
        XCTAssertEqual(toggle.value as? String, "1", "read-only mode did not turn on")
        openTags()
        XCTAssertTrue(row("root", tag(voyages)).waitForExistence(timeout: 15), "Voyages row missing")
        let before = tagRowIdentifiers()

        createTag(named: "Italie", under: tag(voyages))

        XCTAssertTrue(element("createTagError").waitForExistence(timeout: 10),
                      "read-only creation must explain its refusal — \(screenText())")
        XCTAssertTrue(creations().isEmpty, "read-only creation must not reach the server")
        element("createTagCancel").tap()
        XCTAssertEqual(tagRowIdentifiers(), before, "the tree changed after a refusal")
        shot("ac78-read-only")

        // Read-only off, server in error.
        goBack() // the Tags screen → the Albums tab
        openHub()
        let toggleAgain = app.switches.matching(identifier: "readOnlyModeToggle").firstMatch
        for _ in 0..<8 where !toggleAgain.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 15), "no Read-only Mode switch after coming back")
        toggleAgain.tap()
        if (toggleAgain.value as? String) != "0" {
            toggleAgain.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggleAgain.value as? String, "0", "read-only mode did not turn off")
        get("/api/__tags/fail-create")
        openTags()
        XCTAssertTrue(row("root", tag(voyages)).waitForExistence(timeout: 15), "Voyages row missing")

        createTag(named: "Italie", under: tag(voyages))

        XCTAssertTrue(element("createTagError").waitForExistence(timeout: 10),
                      "a failed creation must show its error — \(screenText())")
        XCTAssertEqual(creations().count, 1, "the failing call is made once")
        element("createTagCancel").tap()
        XCTAssertEqual(tagRowIdentifiers(), before, "the tree changed after a server error")
        shot("ac78-server-error")
    }

    func test_AC_79_emptyErrorRetryAndViewer() {
        launchSignedIn()
        openTags()

        let empty = row("root", tag(vide))
        XCTAssertTrue(empty.waitForExistence(timeout: 15), "Vide row missing — \(screenText())")
        empty.tap()
        XCTAssertTrue(element("tagAssetsEmptyState").waitForExistence(timeout: 20),
                      "an empty tag must say so — \(screenText())")
        goBack()

        row("root", tag(panne)).tap()
        let retry = element("tagAssetsErrorRetry")
        XCTAssertTrue(retry.waitForExistence(timeout: 20), "the first read answers 500: expected the retry — \(screenText())")
        XCTAssertTrue(element("tagAssetsError").exists, "the error message is missing")
        shot("ac79-error")
        retry.tap()

        let photo = tile(panneFirstPhoto)
        XCTAssertTrue(photo.waitForExistence(timeout: 20), "Try Again did not show the tag's photos — \(screenText())")
        photo.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the photo did not open in the viewer — \(screenText())")
    }

    func test_AC_80_sheetShowsPathsAndTagsRightOne() {
        launchSignedIn()
        let photoTile = tile(timelinePhoto)
        XCTAssertTrue(photoTile.waitForExistence(timeout: 30), "timeline tile missing")
        photoTile.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the viewer never showed its top bar — \(screenText())")

        // Details live on the row on wide screens, behind the ⋯ menu at 402 pt.
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

        let editTags = element("editTagsButton")
        for _ in 0..<8 where !editTags.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(editTags.waitForExistence(timeout: 10), "no Edit Tags button in the info panel")
        editTags.tap()

        let voyagesJapon = element("assetTagRow_\(tag(japon))")
        let cuisine = element("assetTagRow_\(tag(cuisineJapon))")
        XCTAssertTrue(voyagesJapon.waitForExistence(timeout: 15), "tag sheet missing Voyages/Japon — \(screenText())")
        XCTAssertTrue(cuisine.exists, "tag sheet missing Cuisine/Japon")
        XCTAssertTrue(voyagesJapon.label.contains("Voyages/Japon"), "label reads \(voyagesJapon.label)")
        XCTAssertTrue(cuisine.label.contains("Cuisine/Japon"), "label reads \(cuisine.label)")
        shot("ac80-sheet")

        voyagesJapon.tap()

        let deadline = Date().addingTimeInterval(15)
        var tagged: StubRequest?
        while tagged == nil && Date() < deadline {
            tagged = stubRequests().first { $0.method == "PUT" && $0.path == "/api/tags/\(tag(japon))/assets" }
            if tagged == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertNotNil(tagged, "ticking Voyages/Japon sent no PUT — got:\n\(describe(stubRequests()))")
        XCTAssertEqual(tagged?.ids, [timelinePhoto])
        XCTAssertFalse(stubRequests().contains { $0.path.contains(tag(cuisineJapon)) && $0.path.hasSuffix("/assets") },
                       "Cuisine/Japon must stay untouched")
    }

    func test_AC_81_secondPeriodReachedByScrolling() {
        launchSignedIn()
        openTags()

        let beach = row("root", tag(plage))
        XCTAssertTrue(beach.waitForExistence(timeout: 15), "Plage row missing — \(screenText())")
        beach.tap()
        XCTAssertTrue(tile(plageFirstPhoto).waitForExistence(timeout: 20), "Plage's first period never rendered")

        let last = tile(plageLastPhoto)
        for _ in 0..<20 where !last.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(last.waitForExistence(timeout: 15), "the second period never loaded by scrolling")
        shot("ac81-second-period")

        let buckets = stubRequests().filter { $0.path == "/api/timeline/bucket" && $0.params["tagId"] != nil }
        XCTAssertEqual(buckets.map { $0.params["timeBucket"] }, ["2026-07-01", "2025-07-01"],
                       "one read per period, newest first — got:\n\(describe(buckets))")
        for request in buckets {
            XCTAssertEqual(request.params["tagId"], tag(plage))
            XCTAssertEqual(request.params["visibility"], "timeline")
        }
    }
}
