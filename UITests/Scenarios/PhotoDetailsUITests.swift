import XCTest

/// Lot L-24 — the info panel of a photo shows each person's age on the photo's
/// day and, for another account's photo, a "Shared by <name>" row.
///
/// Needs `UITests/stubs/immich_stub_photo_details.py` (label `photo_details`) on
/// the port in `IMMICH_STUB_URL` (default `http://127.0.0.1:8421`). Launch:
/// `.omp/orchestration/uitest.sh <worktree> <log> UITests/stubs/immich_stub_photo_details.py PhotoDetailsUITests/<test>`.
///
/// What is asserted: the `label` and `value` of the face button
/// `viewerInfoFace_<faceId>` (the age is exposed as its value, because the
/// button fuses its content into one accessibility element), the `label` of
/// `viewerInfoOwner`, `viewerInfoDate`, and the wire (`/__requests`). The
/// language is pinned to English, as in the sibling scenarios; person and user
/// names are the stub's data.
final class PhotoDetailsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // Keep in step with immich_stub_photo_details.py.
    private let p1 = "22222222-2222-4222-8222-000000000001"
    private let p2 = "22222222-2222-4222-8222-000000000002"
    private let nina = "33333333-3333-4333-8333-00000000a001"
    private let mine = "24000000-0000-4000-8000-000000000001"
    private let mineNoBirth = "24000000-0000-4000-8000-000000000002"
    private let tokyo = "24000000-0000-4000-8000-000000000003"
    private let p1Photo = "24000000-0000-4000-8000-000000000004"
    private let p2Photo = "24000000-0000-4000-8000-000000000005"
    private let pNoOwner = "24000000-0000-4000-8000-000000000006"
    private let pFail = "24000000-0000-4000-8000-000000000007"
    private let noExif = "24000000-0000-4000-8000-000000000008"
    private let albumM1Photo = "24000000-0000-4000-8000-0000000000a1"
    private let albumMyPhoto = "24000000-0000-4000-8000-0000000000a2"
    private let album = "55555555-5555-4555-8555-0000000000a1"
    private let faceOfMine = "f0000000-0000-4000-8000-000000000001"
    private let faceOfOmar = "f0000000-0000-4000-8000-000000000002"
    private let faceOfTokyo = "f0000000-0000-4000-8000-000000000003"
    private let faceOfNoExif = "f0000000-0000-4000-8000-000000000004"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - AC-45

    func test_AC_45() {
        launchSignedIn()
        openDetails(of: mine)
        let nina = element("viewerInfoFace_\(faceOfMine)")
        XCTAssertTrue(nina.waitForExistence(timeout: 20), "the face of Nina is missing — \(screenText())")
        XCTAssertEqual(nina.label, "Nina")
        XCTAssertEqual(nina.value as? String, "19 years old", "born 2000-06-15, photo of 2020-06-14")
        shot("ac45-age")

        closeDetailsAndViewer()
        openDetails(of: mineNoBirth)
        let omar = element("viewerInfoFace_\(faceOfOmar)")
        XCTAssertTrue(omar.waitForExistence(timeout: 20), "the face of Omar is missing — \(screenText())")
        XCTAssertEqual(omar.label, "Omar")
        XCTAssertTrue(((omar.value as? String) ?? "").isEmpty, "no birthday, no age — got \(String(describing: omar.value))")
    }

    // MARK: - AC-46

    func test_AC_46() {
        launchSignedIn()
        openDetails(of: p1Photo)
        let owner = element("viewerInfoOwner")
        XCTAssertTrue(owner.waitForExistence(timeout: 20), "a partner's photo must show who shared it — \(screenText())")
        XCTAssertEqual(owner.label, "Shared by Alice Partner")
        shot("ac46-owner")

        closeDetailsAndViewer()
        openDetails(of: mine)
        XCTAssertTrue(element("viewerInfoFace_\(faceOfMine)").waitForExistence(timeout: 20), "the details never loaded")
        XCTAssertFalse(element("viewerInfoOwner").exists, "the user's own photo has no Shared by row")
    }

    // MARK: - AC-222

    func test_AC_222() {
        launchSignedIn(timeZone: "America/New_York")
        openDetails(of: tokyo)
        var face = element("viewerInfoFace_\(faceOfTokyo)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertTrue(element("viewerInfoDate").label.contains("Jun 14, 2020"),
                      "New York shows the 14th — header: \(element("viewerInfoDate").label)")
        XCTAssertEqual(face.value as? String, "19 years old")

        closeDetailsAndViewer()
        openDetails(of: noExif)
        face = element("viewerInfoFace_\(faceOfNoExif)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertTrue(element("viewerInfoDate").label.contains("June 14, 2020"),
                      "without EXIF the header is the file's day — header: \(element("viewerInfoDate").label)")
        XCTAssertEqual(face.value as? String, "19 years old")

        app.terminate()
        launchSignedIn(timeZone: "Asia/Tokyo")
        openDetails(of: tokyo)
        face = element("viewerInfoFace_\(faceOfTokyo)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertTrue(element("viewerInfoDate").label.contains("Jun 15, 2020"),
                      "Tokyo shows the 15th — header: \(element("viewerInfoDate").label)")
        XCTAssertEqual(face.value as? String, "20 years old")

        closeDetailsAndViewer()
        openDetails(of: noExif)
        face = element("viewerInfoFace_\(faceOfNoExif)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertTrue(element("viewerInfoDate").label.contains("June 14, 2020"))
        XCTAssertEqual(face.value as? String, "19 years old", "the file's day is the same in every zone")
    }

    // MARK: - AC-223

    func test_AC_223() {
        launchSignedIn()
        openDetails(of: mineNoBirth)
        let face = element("viewerInfoFace_\(faceOfOmar)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertEqual(face.label, "Omar")
        face.tap()
        XCTAssertTrue(tapButton(containing: "Nina"), "the assignment sheet does not offer Nina — \(screenText())")

        let reassigned = element("viewerInfoFace_\(faceOfOmar)")
        XCTAssertTrue(element("viewerInfoClose").waitForExistence(timeout: 20), "the panel must stay open")
        let deadline = Date().addingTimeInterval(20)
        while (reassigned.value as? String) != "19 years old" && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertEqual(reassigned.label, "Nina")
        XCTAssertEqual(reassigned.value as? String, "19 years old")
        let put = stubRequests().first { $0.method == "PUT" && $0.path == "/api/faces/\(nina)" }
        XCTAssertEqual(put?.faceId, faceOfOmar, "requests: \(describe(stubRequests()))")
    }

    // MARK: - AC-224

    func test_AC_224() {
        launchSignedIn()
        openAlbumsTab()
        let card = element("albumCard_\(album)")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the shared album is missing — \(screenText())")
        card.tap()

        openDetails(of: albumM1Photo)
        let owner = element("viewerInfoOwner")
        XCTAssertTrue(owner.waitForExistence(timeout: 20), "the member's photo must show who shared it — \(screenText())")
        XCTAssertEqual(owner.label, "Shared by Carla Member")

        closeDetailsAndViewer()
        openDetails(of: albumMyPhoto)
        let closeButton = element("viewerInfoClose")
        XCTAssertTrue(closeButton.waitForExistence(timeout: 20))
        waitForDetail(of: albumMyPhoto)
        XCTAssertFalse(element("viewerInfoOwner").exists, "the user's photo in the same album has no Shared by row")
    }

    // MARK: - AC-225

    func test_AC_225() {
        launchSignedIn()
        openDetails(of: p1Photo)
        XCTAssertTrue(element("viewerInfoOwner").waitForExistence(timeout: 20), "owner row missing — \(screenText())")
        let deadline = Date().addingTimeInterval(20)
        var read: StubRequest?
        while read == nil && Date() < deadline {
            read = stubRequests().first { $0.method == "GET" && $0.path == "/api/users/\(p1)/profile-image" }
            if read == nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertNotNil(read, "P1 has a profile photo: it must be read — \(describe(stubRequests()))")
        XCTAssertEqual(read?.bearer, true, "the token must travel in the Authorization header")
        XCTAssertTrue(read?.params.isEmpty ?? false, "the token must never be in the URL — \(String(describing: read?.params))")

        closeDetailsAndViewer()
        openDetails(of: p2Photo)
        let owner = element("viewerInfoOwner")
        XCTAssertTrue(owner.waitForExistence(timeout: 20), "owner row missing — \(screenText())")
        XCTAssertEqual(owner.label, "Shared by Bob Partner")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(stubRequests().contains { $0.path == "/api/users/\(p2)/profile-image" },
                       "P2 has no profile photo: initials, no request")
    }

    // MARK: - AC-226

    func test_AC_226() {
        launchSignedIn()
        openDetails(of: pNoOwner)
        waitForDetail(of: pNoOwner)
        XCTAssertFalse(element("viewerInfoOwner").exists, "no owner in the response, no Shared by row")
        let tags = element("editTagsButton")
        for _ in 0..<8 where !tags.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(tags.exists, "the rest of the details must still show — \(screenText())")

        closeDetailsAndViewer()
        openDetails(of: pFail)
        let deadline = Date().addingTimeInterval(20)
        while !stubRequests().contains(where: { $0.path == "/api/assets/\(pFail)" }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(element("viewerInfoOwner").exists, "a failed detail read shows no Shared by row")
    }

    // MARK: - AC-227

    func test_AC_227() {
        launchSignedIn()
        openDetails(of: mine)
        let face = element("viewerInfoFace_\(faceOfMine)")
        XCTAssertTrue(face.waitForExistence(timeout: 20), "missing face — \(screenText())")
        XCTAssertEqual(face.label, "Nina", "VoiceOver reads the name…")
        XCTAssertEqual(face.value as? String, "19 years old", "…then the age")

        closeDetailsAndViewer()
        openDetails(of: p1Photo)
        let owner = element("viewerInfoOwner")
        XCTAssertTrue(owner.waitForExistence(timeout: 20))
        XCTAssertEqual(owner.label, "Shared by Alice Partner", "one element, read as a single phrase")
        app.terminate()

        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchSignedIn()
        openDetails(of: p1Photo)
        let bigOwner = element("viewerInfoOwner")
        XCTAssertTrue(bigOwner.waitForExistence(timeout: 20), "owner row missing at AX5 — \(screenText())")
        assertInsideWindow(bigOwner, "owner row at AX5")

        closeDetailsAndViewer()
        openDetails(of: mine)
        let bigFace = element("viewerInfoFace_\(faceOfMine)")
        for _ in 0..<8 where !bigFace.exists || !bigFace.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(bigFace.waitForExistence(timeout: 10), "face missing at AX5 — \(screenText())")
        XCTAssertEqual(bigFace.value as? String, "19 years old")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(bigFace.frame.minX, window.minX - 1, "the face tile starts left of the window")
        shot("ac227-ax5")
    }

    // MARK: - Helpers (copied from the sibling scenarios: one file per feature)

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
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-photo-details-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-photo-details-\(name).png")
    }

    private func get(_ path: String) {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

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

    private func assertInsideWindow(_ target: XCUIElement, _ what: String) {
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(target.frame.minX, window.minX - 1, "\(what) starts left of the window")
        XCTAssertLessThanOrEqual(target.frame.maxX, window.maxX + 1, "\(what) runs past the window")
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let bearer: Bool?
        let faceId: String?
        let personId: String?
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

    // MARK: - Navigation

    /// Reset the stub, launch (with an optional device time zone), walk
    /// onboarding on a fresh device, land on the timeline.
    private func launchSignedIn(timeZone: String? = nil) {
        get("/__reset")
        get("/__provider?mode=manual")
        if let timeZone { app.launchEnvironment["TZ"] = timeZone }
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
        XCTAssertTrue(tile(mine).waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func openAlbumsTab() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15), "Albums tab missing — \(screenText())")
        albums.tap()
    }

    /// Tile → viewer → Details (a row button on wide screens, the ⋯ menu otherwise).
    private func openDetails(of assetId: String) {
        let photo = tile(assetId)
        XCTAssertTrue(photo.waitForExistence(timeout: 30), "tile \(assetId) missing — \(screenText())")
        photo.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the viewer never showed its top bar — \(screenText())")
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

    /// The detail read answered (the panel's content comes from it): a negative
    /// assertion is only meaningful once it has.
    private func waitForDetail(of assetId: String) {
        let deadline = Date().addingTimeInterval(20)
        while !stubRequests().contains(where: { $0.method == "GET" && $0.path == "/api/assets/\(assetId)" })
            && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 2)
    }

    private func closeDetailsAndViewer() {
        let close = element("viewerInfoClose")
        if close.exists { close.tap() }
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the viewer's back button is missing — \(screenText())")
        back.tap()
    }
}
