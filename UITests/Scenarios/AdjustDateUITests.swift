import XCTest

/// End-to-end scenario for the adjust-date sheet with a time zone (L-33, B-38):
/// the photo's own zone is proposed, the picker shows the photo's wall-clock
/// time (never the device's), the zone is chosen from a searchable list, and the
/// `PUT /api/assets/:id` carries `yyyy-MM-ddTHH:mm:ss±HH:MM`. Drives the real app
/// against `UITests/stubs/immich_stub_adjust_date.py`, with the DEVICE set to
/// Asia/Tokyo (`TZ`) so a picker that read the device zone would show 19:00.
///
/// Every touch goes through accessibility identifiers; the only rendered text
/// read is the locale-fixed date and time of the picker (`10:00`, `14 July`,
/// locale `en_GB`, 24 h). One `XCTestCase` per feature, helpers copied from
/// `AdjustLocationUITests` (private there).
final class AdjustDateUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!
    private let photo = "aaaaaaaa-1111-4111-8111-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
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

    // MARK: - Tests

    /// AC-66: the zone proposed first is the photo's; 10:00 in Tokyo is sent as `+09:00`.
    func test_AC_66() throws {
        signIn()
        openAdjustDate()
        assertOpensOnParis()

        element("adjustDateZoneButton").tap()
        XCTAssertTrue(element("adjustDateZoneRow_Europe/Paris").waitForExistence(timeout: 10),
                      "the zone list never opened")
        XCTAssertTrue(element("adjustDateZoneRow_Europe/Paris").isHittable, "the chosen zone is not visible on opening")
        search("Tokyo")
        XCTAssertTrue(element("adjustDateZoneRow_Asia/Tokyo").waitForExistence(timeout: 10))
        XCTAssertFalse(element("adjustDateZoneRow_Europe/Paris").exists, "the filter kept a non-matching zone")
        element("adjustDateZoneRow_Asia/Tokyo").tap()

        XCTAssertTrue(waitForValue(element("adjustDateZoneButton"), "Asia/Tokyo, +09:00"))
        XCTAssertTrue(pickerShows("10:00"), "the time moved when the zone changed")
        XCTAssertTrue(pickerSelectedDay("14 July"))

        element("adjustDateSaveButton").tap()
        let writes = waitForWrites(count: 1)
        XCTAssertEqual(writes.last?.dateTimeOriginalSent, "2024-07-14T10:00:00+09:00")
        XCTAssertTrue(waitForGone(element("adjustDateSaveButton")), "the sheet stayed open after a successful save")
    }

    /// AC-66.4: the time the user sets is the time shown and the time sent.
    func test_AC_66_4_editedTimeIsWallClock() throws {
        signIn()
        openAdjustDate()
        assertOpensOnParis()

        // Touch the time, set the hours wheel to 11, then touch the sheet's header
        // (above the picker) to close the time popover.
        let time = element("adjustDatePicker").descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '10:00'")).firstMatch
        XCTAssertTrue(time.waitForExistence(timeout: 10), "the picker has no time control")
        time.tap()
        let hours = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(hours.waitForExistence(timeout: 5), "touching the time did not open the hour wheel")
        hours.adjust(toPickerWheelValue: "11")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(pickerShows("11:00"), "the picker does not show the time the user set")
        XCTAssertTrue(pickerSelectedDay("14 July"))

        element("adjustDateZoneButton").tap()
        XCTAssertTrue(element("adjustDateZoneRow_Europe/Paris").waitForExistence(timeout: 10))
        search("Tokyo")
        element("adjustDateZoneRow_Asia/Tokyo").tap()
        XCTAssertTrue(pickerShows("11:00"), "the edited time changed with the zone")
        XCTAssertTrue(pickerSelectedDay("14 July"))

        element("adjustDateSaveButton").tap()
        XCTAssertEqual(waitForWrites(count: 1).last?.dateTimeOriginalSent, "2024-07-14T11:00:00+09:00",
                       "a picker that ignored the UTC environment would send T02:00 here")
    }

    /// AC-66.6: after a save, reopening shows the saved zone and time (the stub
    /// answers like a v2.0–2.4 server: instant moved, `timeZone` still Europe/Paris).
    func test_AC_66_6_reopenAfterSave() throws {
        signIn()
        openAdjustDate()
        element("adjustDateZoneButton").tap()
        XCTAssertTrue(element("adjustDateZoneRow_Europe/Paris").waitForExistence(timeout: 10))
        search("Tokyo")
        element("adjustDateZoneRow_Asia/Tokyo").tap()
        element("adjustDateSaveButton").tap()
        XCTAssertEqual(waitForWrites(count: 1).last?.dateTimeOriginalSent, "2024-07-14T10:00:00+09:00")
        XCTAssertTrue(waitForGone(element("adjustDateSaveButton")))

        element("adjustDateButton").tap()
        XCTAssertTrue(element("adjustDateSaveButton").waitForExistence(timeout: 15), "the sheet did not reopen")
        XCTAssertTrue(waitForValue(element("adjustDateZoneButton"), "Asia/Tokyo, +09:00"))
        XCTAssertTrue(pickerShows("10:00"))
        XCTAssertTrue(pickerSelectedDay("14 July"))

        element("adjustDateSaveButton").tap()
        XCTAssertEqual(waitForWrites(count: 2).last?.dateTimeOriginalSent, "2024-07-14T10:00:00+09:00")
    }

    // MARK: - Assertions shared by the scenarios

    /// AC-66.1 on screen: Europe/Paris, 14 July 10:00 although the device is in Tokyo.
    private func assertOpensOnParis() {
        XCTAssertTrue(waitForValue(element("adjustDateZoneButton"), "Europe/Paris, +02:00"),
                      "the photo's zone was not proposed first")
        XCTAssertTrue(pickerShows("10:00"), "the picker does not show the photo's own time")
        XCTAssertFalse(pickerShows("19:00", timeout: 1), "the picker shows the device's time")
        XCTAssertTrue(pickerSelectedDay("14 July"))
    }

    // MARK: - Picker reading

    private func pickerDescendants() -> [XCUIElement] {
        element("adjustDatePicker").descendants(matching: .any).allElementsBoundByIndex
    }

    private func pickerShows(_ text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if pickerDescendants().contains(where: {
                $0.label.contains(text) || (($0.value as? String)?.contains(text) ?? false)
            }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    private func pickerSelectedDay(_ text: String) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if pickerDescendants().contains(where: { $0.isSelected && $0.label.contains(text) }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    // MARK: - Wire helpers

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let dateTimeOriginalSent: String?
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

    private func writes() -> [StubRequest] {
        stubRequests().filter { $0.method == "PUT" && $0.path == "/api/assets/\(photo)" }
    }

    private func waitForWrites(count: Int, timeout: TimeInterval = 20) -> [StubRequest] {
        var found = writes()
        let deadline = Date().addingTimeInterval(timeout)
        while found.count < count, Date() < deadline {
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "stub poll")], timeout: 0.5)
            found = writes()
        }
        return found
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

    // MARK: - Screen helpers

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitForValue(_ target: XCUIElement, _ expected: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)],
                                timeout: timeout) == .completed
    }

    private func waitForGone(_ target: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: target)],
                                timeout: timeout) == .completed
    }

    private func search(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the zone list has no search field")
        field.tap()
        field.typeText(text)
    }

    /// The session the stub's SSO sign-in hands out (`POST /api/oauth/callback`), as the launch
    /// arguments of `AuthViewModel`'s keys: the app starts signed in without the onboarding and the
    /// SSO sheet (SafariViewService), a walk this scenario does not test and that fails on a loaded
    /// CI Mac (same approach as `AssetEditsUITests.sessionArguments`).
    private func sessionArguments() -> [String] {
        var request = URLRequest(url: URL(string: "\(stub)/api/oauth/callback")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var login: [String: Any] = [:]
        URLSession.shared.dataTask(with: request) { data, _, _ in
            login = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        guard let token = login["accessToken"] as? String else {
            XCTFail("the stub's /api/oauth/callback gave no session: \(login)")
            return []
        }
        return [
            "-uiTestSessionToken", token,
            "-authServerURL", stub,
            "-authUserId", login["userId"] as? String ?? "",
            "-authUserName", login["name"] as? String ?? "",
            "-authUserEmail", login["userEmail"] as? String ?? "",
            "-authIsAdmin", (login["isAdmin"] as? Bool ?? false) ? "YES" : "NO",
        ]
    }

    /// Reset, launch already signed in (device in Tokyo, English, 24 h `en_GB`), wait for the timeline.
    private func signIn() {
        reset()
        setProvider("manual")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"] + sessionArguments()
        app.launchEnvironment["TZ"] = "Asia/Tokyo"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "the app did not start signed in")
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
    }

    /// Opens the viewer on the first tile, its details, and the adjust-date sheet.
    private func openAdjustDate() {
        let tile = element("assetTile_\(photo)")
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the timeline never rendered the photo")
        if tile.isHittable {
            tile.tap()
        } else {
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.buttons.matching(identifier: "viewerBackButton").firstMatch.waitForExistence(timeout: 20),
                      "the viewer never showed its chrome")
        openDetails()
        let button = element("adjustDateButton")
        for _ in 0..<6 {
            if button.waitForExistence(timeout: 3), button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.exists, "adjustDateButton never appeared in the info panel")
        button.tap()
        XCTAssertTrue(element("adjustDateSaveButton").waitForExistence(timeout: 15), "the adjust-date sheet did not open")
    }

    /// The viewer's details action: its pill when the row carries it, else the ⋯ menu.
    private func openDetails() {
        let pill = app.buttons.matching(identifier: "viewerDetailsButton").firstMatch
        if pill.exists {
            pill.tap()
            return
        }
        let overflow = app.buttons.matching(identifier: "viewerOverflowMenu").firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 15), "viewerDetailsButton is neither on the row nor behind ⋯")
        overflow.tap()
        let anyElement = app.descendants(matching: .any)
        var item = anyElement.matching(identifier: "viewerMenuDetails").firstMatch
        if !item.waitForExistence(timeout: 5) {
            item = anyElement.matching(NSPredicate(format: "label IN %@", ["Détails", "Details"])).firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "⋯ holds no details action")
        item.tap()
    }
}
