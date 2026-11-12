import XCTest

/// End-to-end scenarios for the loading, empty, error and refresh states of the
/// list screens (lot L-16, B-20).
///
/// The server answers 500, then an empty list, then data (`immich_stub_list_states.py`,
/// `GET /control/script?route=…&steps=500,empty,ok&delay=2`), and the scenario
/// checks what each screen shows at each step: an indicator while the request
/// runs, an error with "Try Again", an empty state, then the data. Every
/// assertion targets an `accessibilityIdentifier`, never a localized text (the app
/// is pinned to English only for the one VoiceOver label read in AC-142).
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/list-states.uitest.log \
///         UITests/stubs/immich_stub_list_states.py ListStatesUITests --erase
///
/// The helpers are copied from `PartnerLibraryUITests` on purpose: one file per
/// feature, helpers included.
final class ListStatesUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // MARK: - The stub's data

    private let incomingPartner = "aaaaaaaa-1111-4111-8111-111111111111"
    private let apiKey = "44444444-4444-4444-8444-000000000001"
    private let firstPhoto = "aaaaaaaa-1111-4111-8111-000000000001"
    private let searchText = "liststates"

    /// The retry buttons the scenario reached: every one must be a button.
    private var retryIdentifiersReached: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        retryIdentifiersReached = []
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    // MARK: - The scenarios

    /// AC-31: 500, then an empty list, then data, on Partners, the search
    /// results, Media Stats, Download Info and API keys, pulling down each time.
    func test_AC_31() throws {
        launchSignedIn()

        // Partners
        arm("partners")
        openPartners()
        expectLoading("partnersLoading")
        expectRetry("partnersErrorRetry")
        pull()
        XCTAssertTrue(element("partnersEmptyState").waitForExistence(timeout: 20),
                      "Partners shows no empty state after a pull on an empty list — \(screenText())")
        pull()
        XCTAssertTrue(element("partnerLibraryLink-\(incomingPartner)").waitForExistence(timeout: 20),
                      "Partners shows no data after the last pull — \(screenText())")
        goBack()

        // Search results
        arm("search")
        search()
        expectLoading("searchLoading")
        expectRetry("searchErrorRetry")
        pull()
        XCTAssertTrue(element("searchEmptyState").waitForExistence(timeout: 20),
                      "the search shows no empty state after a pull — \(screenText())")
        pull()
        XCTAssertTrue(element("assetTile_\(firstPhoto)").waitForExistence(timeout: 20),
                      "the search shows no results after the last pull — \(screenText())")
        leaveSearch()

        // API keys
        openHub()
        arm("apiKeys")
        hubRow("apiKeysRow").tap()
        expectLoading("apiKeysLoading")
        expectRetry("apiKeysErrorRetry")
        pull()
        XCTAssertTrue(element("apiKeysEmptyState").waitForExistence(timeout: 20),
                      "API keys shows no empty state after a pull — \(screenText())")
        pull()
        XCTAssertTrue(element("apiKeyRow_\(apiKey)").waitForExistence(timeout: 20),
                      "API keys shows no key after the last pull — \(screenText())")
        goBack()

        // Media Stats (the Me hub read the counts in its `.task`: arm after it)
        XCTAssertTrue(element("profileStoragePhotos").waitForExistence(timeout: 20),
                      "the Me hub never finished reading the counts — \(screenText())")
        arm("assetStatistics")
        hubRow("mediaStatsRow").tap()
        expectLoading("mediaStatsServerLoading")
        expectReached("mediaStatsServerCountsError")
        pull()
        XCTAssertTrue(element("mediaStatsServerEmptyState").waitForExistence(timeout: 20),
                      "Media Stats shows no empty state for 0 / 0 — \(screenText())")
        pull()
        XCTAssertTrue(element("mediaStatsServerPhotos").waitForExistence(timeout: 20),
                      "Media Stats shows no counts after the last pull — \(screenText())")
        goBack()

        // Download Info: the cache is read from the disk, never from the server.
        hubRow("downloadInfoRow").tap()
        XCTAssertTrue(element("downloadInfoLoading").exists || element("downloadInfoEmptyState")
            .waitForExistence(timeout: 20), "Download Info shows neither an indicator nor an empty state")
        XCTAssertTrue(element("downloadInfoEmptyState").waitForExistence(timeout: 20),
                      "an empty cache is not an empty state — \(screenText())")
        XCTAssertEqual(identifiers(startingWith: "downloadInfoRow_"), 0, "a file is listed before any download")
        goBack()
        closeHub()
        downloadFirstPhotoForOffline()
        openHub()
        hubRow("downloadInfoRow").tap()
        pull()
        XCTAssertTrue(element("downloadInfoRow_\(firstPhoto)").waitForExistence(timeout: 20),
                      "Download Info does not list the downloaded photo — \(screenText())")

        assertRetriesAreButtons()
    }

    /// AC-142: an indicator, labelled for VoiceOver, until the first answer; no
    /// empty state and no error before it.
    func test_AC_142() throws {
        launchSignedIn()

        arm("partners", steps: "ok", delay: 3)
        openPartners()
        assertLoadingOnly("partnersLoading", forbidden: ["partnersEmptyState", "partnersError"])
        XCTAssertTrue(element("partnerLibraryLink-\(incomingPartner)").waitForExistence(timeout: 20))
        goBack()

        arm("search", steps: "ok", delay: 3)
        search()
        assertLoadingOnly("searchLoading", forbidden: ["searchEmptyState", "searchError"])
        XCTAssertTrue(element("assetTile_\(firstPhoto)").waitForExistence(timeout: 20))
        leaveSearch()

        openHub()
        arm("apiKeys", steps: "ok", delay: 3)
        hubRow("apiKeysRow").tap()
        assertLoadingOnly("apiKeysLoading", forbidden: ["apiKeysEmptyState", "apiKeysError"])
        XCTAssertTrue(element("apiKeyRow_\(apiKey)").waitForExistence(timeout: 20))
    }

    /// AC-153: the "Try Again" of an error state is a button with an identifier
    /// of its own.
    func test_AC_153() throws {
        launchSignedIn()
        openHub()
        arm("apiKeys", steps: "500", delay: 0)
        hubRow("apiKeysRow").tap()
        expectRetry("apiKeysErrorRetry")
        assertRetriesAreButtons()
    }

    /// AC-154: from the error state, then from the empty state, a pull sends one
    /// more request and the screen ends on the data.
    func test_AC_154() throws {
        launchSignedIn()
        openHub()
        arm("apiKeys")
        hubRow("apiKeysRow").tap()
        expectRetry("apiKeysErrorRetry")
        let afterError = apiKeyReads()
        XCTAssertGreaterThanOrEqual(afterError, 1, "the first read never reached the stub")

        pull()
        XCTAssertTrue(element("apiKeysEmptyState").waitForExistence(timeout: 20),
                      "no empty state after a pull from the error — \(screenText())")
        XCTAssertGreaterThan(apiKeyReads(), afterError, "a pull from the error sent no request")
        let afterEmpty = apiKeyReads()

        pull()
        XCTAssertTrue(element("apiKeyRow_\(apiKey)").waitForExistence(timeout: 20),
                      "no data after a pull from the empty state — \(screenText())")
        XCTAssertGreaterThan(apiKeyReads(), afterEmpty, "a pull from the empty state sent no request")
    }

    // MARK: - Scenario steps

    private func arm(_ route: String, steps: String = "500,empty,ok", delay: Int = 2) {
        get("/control/script?route=\(route)&steps=\(steps)&delay=\(delay)")
    }

    private func expectLoading(_ identifier: String) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 15),
                      "no loading indicator \(identifier) during the request — \(screenText())")
    }

    private func expectRetry(_ identifier: String) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 30),
                      "no \"Try Again\" \(identifier) after the 500 — \(screenText())")
        retryIdentifiersReached.append(identifier)
    }

    /// An error state that is a badge, not a `PVErrorStateView`: not part of AC-153.
    private func expectReached(_ identifier: String) {
        XCTAssertTrue(element(identifier).waitForExistence(timeout: 30),
                      "no error state \(identifier) after the 500 — \(screenText())")
    }

    private func assertLoadingOnly(_ loading: String, forbidden: [String]) {
        let indicator = element(loading)
        XCTAssertTrue(indicator.waitForExistence(timeout: 15), "no loading indicator \(loading)")
        XCTAssertEqual(indicator.label, "Loading…", "the indicator carries no VoiceOver label")
        for identifier in forbidden {
            XCTAssertFalse(element(identifier).exists, "\(identifier) is shown before the first answer")
        }
    }

    private func assertRetriesAreButtons() {
        for identifier in retryIdentifiersReached {
            XCTAssertTrue(app.buttons.matching(identifier: identifier).firstMatch.exists,
                          "\(identifier) is not a button")
        }
    }

    private func openPartners() {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15), "Albums tab missing — \(screenText())")
        albums.tap()
        let row = app.buttons.matching(identifier: "partnersRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Partners tile missing — \(screenText())")
        for _ in 0..<4 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        row.tap()
    }

    private func search() {
        let tab = app.tabBars.buttons["Search"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "Search tab missing — \(screenText())")
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("\(searchText)\n")
    }

    private func leaveSearch() {
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists { clear.tap() }
        app.tabBars.buttons["Photos"].tap()
    }

    private func downloadFirstPhotoForOffline() {
        let tile = element("assetTile_\(firstPhoto)")
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "no timeline tile — \(screenText())")
        tile.tap()
        let share = app.buttons.matching(identifier: "viewerShareButton").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25), "the viewer's bottom bar never appeared")
        share.tap()
        let download = app.buttons.matching(identifier: "downloadForOfflineButton").firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 20), "no \"Download for offline\" — \(screenText())")
        download.tap()
        XCTAssertTrue(element("offlineAvailableRow").waitForExistence(timeout: 60),
                      "the offline copy never became available — \(screenText())")
        let close = app.buttons.matching(identifier: "closeShareSheet").firstMatch
        if close.waitForExistence(timeout: 5) { close.tap() }
        let back = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the viewer did not come back")
        back.tap()
    }

    private func apiKeyReads() -> Int {
        stubRequests().filter { $0.method == "GET" && $0.path == "/api/api-keys" }.count
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

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func identifiers(startingWith prefix: String) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).count
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
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenText())")
    }

    /// Reset, launch, walk the onboarding if the device is fresh, land on the
    /// timeline and wait for its first tile.
    private func launchSignedIn() {
        get("/__reset")
        get("/__provider?mode=manual")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapAnyButton(["Immich SSO"]), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        let whatsNewDone = element("whatsNewDoneButton")
        if whatsNewDone.waitForExistence(timeout: 10) { whatsNewDone.tap() }
        XCTAssertTrue(element("assetTile_\(firstPhoto)").waitForExistence(timeout: 30),
                      "the timeline never rendered against \(stub) — \(screenText())")
    }

    private func openHub() {
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
    }

    private func closeHub() {
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        top.press(forDuration: 0.1, thenDragTo: bottom)
        sleep(1)
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

    private func goBack() {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back")
        back.tap()
        sleep(1)
    }

    /// Pull-to-refresh: a drag from the upper third to the lower part of the screen.
    private func pull() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    // MARK: - Wire helpers

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
}
