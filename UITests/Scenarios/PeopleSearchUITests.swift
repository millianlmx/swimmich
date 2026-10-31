import XCTest

/// End-to-end scenario for "People: search by name": the "Search people" field of
/// the People screen sends `GET /api/search/person` after a debounce, and the
/// answer REPLACES the paged list.
///
/// It drives the real app (onboarding → SSO → Me hub → People) against
/// `immich_stub_people_search.py` and asserts on BOTH surfaces: the rows
/// (`personRow_<id>`) and the states (`peopleSearchEmpty`, `peopleSearchError`) on
/// screen, and what really crossed the wire, read back from the stub's request log
/// (`GET /__requests`). One test method per acceptance criterion AC-73…AC-80, each
/// independent of the others (each resets the stub and relaunches the app).
///
/// Run it on a macOS host with Xcode, an iOS 26 simulator and `python3`, never on
/// the Linux harness. There is no launcher in a worktree (`.omp/orchestration/
/// uitest.sh` is absent and gitignored), so by hand:
///
///     python3 -u UITests/stubs/immich_stub_people_search.py 8421 &
///     TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test-without-building \
///         -scheme ImmichSwiftUI -destination 'platform=iOS Simulator,id=<UDID>' \
///         -only-testing:ImmichSwiftUIUITests/PeopleSearchUITests
///
/// after `xcodebuild build-for-testing` on the same destination. The scenario
/// asserts a FIRST launch (the onboarding walk only exists on a device with no
/// persisted session): `xcrun simctl erase <UDID>` first. Green looks like
/// `Test Case '-[ImmichSwiftUIUITests.PeopleSearchUITests test_People_AC_<n>_…]' passed`
/// for the eight methods.
///
/// KEYBOARD. AC-74 types "␠␠ali␠" and reads the raw value of the field back before
/// it reads the wire: the iOS keyboard must not rewrite it. The app is not changed
/// for that (no `.autocorrectionDisabled()`); the simulator is prepared instead,
/// after `simctl boot` and before the run:
///
///     xcrun simctl spawn <UDID> defaults write com.apple.Preferences KeyboardAutocorrection -bool NO
///     xcrun simctl spawn <UDID> defaults write com.apple.Preferences KeyboardAutocapitalization -bool NO
///     xcrun simctl spawn <UDID> defaults write com.apple.Preferences KeyboardPrediction -bool NO
///
/// A rewritten value fails AC-74 with its own message, which tells an environment
/// red from a trimming red.
///
/// NOT PROVEN here, and worth saying:
///
/// 1. The debounce ("a burst of keystrokes sends ONE request"): intermediate
///    requests are tolerated, only the last one counts. It is proven in unit tests
///    only (`test_People_AC_42_…`).
/// 2. A stale response being dropped (generation counter): unit tests only
///    (`test_People_AC_14_…`, `AC_47`, `AC_48`).
/// 3. The label of a row after the round trip to a person's card: it is empty
///    (the row republishes as a cell), so AC-78 reads the order from frames and
///    the identity from identifiers.
final class PeopleSearchUITests: XCTestCase {

    /// The stub's URL, as `xcodebuild` forwards it (`TEST_RUNNER_IMMICH_STUB_URL`).
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The fixture of `immich_stub_people_search.py`: keep the two in step.
    private let adaId = "eeeeeeee-3333-4333-8333-000000000001"
    private let alanId = "eeeeeeee-3333-4333-8333-000000000002"
    private let aliceId = "eeeeeeee-3333-4333-8333-000000000003"
    private let alinaId = "eeeeeeee-3333-4333-8333-000000000004"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The scenario only knows English labels ("Featured", "Retry", …).
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Fails, never skips: a missing stub must not look like a pass.
        guard stubIsReachable() else { throw StubUnreachable(url: stub) }
    }

    private struct StubUnreachable: Error, CustomStringConvertible {
        let url: String
        var description: String {
            "Local Immich stub not running on \(url) — a skipped or unreachable run is a failure"
        }
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
    // Copied from `PersonBirthdayUITests` on purpose: one file per feature, helpers
    // included, no shared support file.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log, so no
    /// assertion can be satisfied by an earlier request.
    private func reset() {
        control("/__reset")
    }

    private func setProvider(_ mode: String) {
        XCTAssertEqual(control("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    /// GETs a control path on the stub and returns its body verbatim.
    @discardableResult
    private func control(_ path: String) -> String {
        let done = DispatchSemaphore(value: 0)
        var body = ""
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 12), .success, "stub did not answer \(path)")
        return body
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

    /// The provider page lives in `SafariViewService`, a separate process.
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
        // The field can hold the PREVIOUS run's URL and `typeText` APPENDS.
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
        // The keyboard covers the CTA: scrolling dismisses it, and a bounded retry
        // covers the animation.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("ps01b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// A row of the "Me" hub, by IDENTIFIER. A `Form` only publishes what it
    /// rendered, so the row is scrolled into view first.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// A person row, by the identifier `PeopleView` gives it. Never by label: after
    /// a round trip to the card the row publishes as a cell with an empty label.
    private func personRow(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "personRow_\(id)").firstMatch
    }

    /// Timeline → Me hub → People, all by identifier.
    private func enterPeopleList(expecting id: String) {
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "the app is not on the authenticated shell")
        // A fresh install presents "What's New" over the shell, and a modal
        // swallows every tap.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 5) {
            shot("ps02-whats-new")
            whatsNewDone.tap()
        }
        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "Profile avatar missing")
        hub.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "profilePictureRow").firstMatch.waitForExistence(timeout: 20),
                      "the Me hub never opened:\n\(app.debugDescription)")
        let peopleRow = hubRow("peopleRow")
        if !peopleRow.waitForExistence(timeout: 15) {
            shot("ps03b-me-hub-without-people-row")
            XCTFail("People row missing in the Me hub:\n\(app.debugDescription)")
        }
        peopleRow.tap()
        XCTAssertTrue(personRow(id).waitForExistence(timeout: 30),
                      "the people list never rendered `personRow_\(id)`:\n\(app.debugDescription)")
    }

    /// Reset, launch, walk the onboarding when it is there, open People.
    private func launchIntoPeopleList() {
        reset()
        setProvider("manual")
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("ps01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        enterPeopleList(expecting: adaId)
    }

    // MARK: - Screen helpers

    private var searchField: XCUIElement {
        app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", "Search people")).firstMatch
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var personRowQuery: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'personRow_'"))
    }

    private var personRowCount: Int { personRowQuery.count }

    /// The rows on screen as a SET of identifiers: after a round trip a row can be
    /// published twice, and an id carried by two elements must not skew a compare.
    private func personRowIDs() -> Set<String> {
        Set(personRowQuery.allElementsBoundByIndex.map(\.identifier))
    }

    private func rowIDs(_ ids: [String]) -> Set<String> {
        Set(ids.map { "personRow_\($0)" })
    }

    private func staticText(caseInsensitive text: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", text))
    }

    /// The row must READ `text` ("7 photos"): a bounded predicate wait, because a
    /// row says "0 photos" until its statistic arrives.
    @discardableResult
    private func waitForLabel(of row: XCUIElement, containing text: String, timeout: TimeInterval = 20) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text),
            object: row)], timeout: timeout) == .completed
    }

    private func assertTopToBottom(_ ids: [String]) {
        let frames = ids.map { personRow($0).frame }
        for index in 0..<(ids.count - 1) {
            XCTAssertLessThan(frames[index].minY, frames[index + 1].minY,
                              "\(ids[index]) must sit above \(ids[index + 1]) — minY of the rows: "
                              + "\(frames.map(\.minY))")
        }
    }

    private func typeQuery(_ text: String) {
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "the \"Search people\" field is missing")
        searchField.tap()
        searchField.typeText(text)
    }

    /// Return key: leaves the keyboard up without touching the text (the app has
    /// no `onSubmit` action).
    private func dismissKeyboard() {
        searchField.typeText("\n")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log: the verb, the path WITHOUT its query,
    /// and the query parameters exactly as the app sent them.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
    }

    private func stubRequests() -> [StubRequest] {
        let body = control("/__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func searchRequests() -> [StubRequest] {
        stubRequests().filter { $0.method == "GET" && $0.path == "/api/search/person" }
    }

    /// Strict equality on the path: `/api/people/{id}/statistics` does not count.
    private func peopleListRequests() -> [StubRequest] {
        stubRequests().filter { $0.method == "GET" && $0.path == "/api/people" }
    }

    /// Waits (10 s) for a search request after the first `after` ones whose LAST
    /// entry carries exactly these parameters.
    @discardableResult
    private func waitForSearch(name: String, withHidden: String, after: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let requests = searchRequests()
            if requests.count > after, requests.last?.params == ["name": name, "withHidden": withHidden] {
                return true
            }
            sleep(1)
        }
        return false
    }

    // MARK: - Shared steps

    /// What the screen must show for the search "ali" without hidden people.
    private func assertAliceAndAlanOnScreen() {
        XCTAssertTrue(personRow(aliceId).waitForExistence(timeout: 20), "no row for Alice")
        XCTAssertTrue(personRow(alanId).waitForExistence(timeout: 20), "no row for Alan")
        XCTAssertTrue(waitForLabel(of: personRow(aliceId), containing: "7 photos"), "Alice never read \"7 photos\"")
        XCTAssertTrue(waitForLabel(of: personRow(alanId), containing: "3 photos"), "Alan never read \"3 photos\"")
        // After the counts: a row without its statistic reads "0 photos", and a
        // sort by photos would not have moved it yet.
        assertTopToBottom([aliceId, alanId])
        XCTAssertEqual(personRowIDs(), rowIDs([aliceId, alanId]),
                       "the results must be exactly Alice and Alan — got \(personRowIDs().sorted())")
        // Alan is a favourite and is among the results: a Featured/People split
        // would draw this header.
        XCTAssertEqual(staticText(caseInsensitive: "Featured").count, 0,
                       "search results are ONE list, with no \"Featured\" header")
    }

    /// Opens People, types "ali" and checks S-6 on screen and on the wire.
    private func searchAliAndAwaitResults() {
        launchIntoPeopleList()
        typeQuery("ali")
        XCTAssertTrue(waitForSearch(name: "ali", withHidden: "false", after: 0),
                      "no `GET /api/search/person?name=ali&withHidden=false` — requests: \(searchRequests().map(\.params))")
        assertAliceAndAlanOnScreen()
        XCTAssertEqual(searchRequests().last?.params, ["name": "ali", "withHidden": "false"],
                       "the last search must be `name=ali&withHidden=false`")
    }

    // MARK: - Scenarios

    /// AC-73: typing shows the server's rows, in the server's order, in one list.
    func test_People_AC_73_typingShowsResultsInServerOrder() throws {
        searchAliAndAwaitResults()
        shot("ps73-results")
    }

    /// AC-74: the name goes out trimmed. The field starts empty, the log is empty.
    func test_People_AC_74_blankEdgesAreTrimmedOnTheWire() throws {
        launchIntoPeopleList()
        reset()
        typeQuery("  ali ")
        XCTAssertEqual(searchField.value as? String, "  ali ",
                       "the keyboard rewrote the query (autocorrection/autocapitalisation): "
                       + "\(String(describing: searchField.value))")
        XCTAssertTrue(waitForSearch(name: "ali", withHidden: "false", after: 0),
                      "no NEW `GET /api/search/person` with name == \"ali\" — requests: "
                      + "\(searchRequests().map(\.params))")
        for request in searchRequests() {
            let name = request.params["name"] ?? ""
            XCTAssertEqual(name, name.trimmingCharacters(in: .whitespacesAndNewlines),
                           "a search went out with a blank at an edge: \"\(name)\"")
        }
        assertAliceAndAlanOnScreen()
        shot("ps74-trimmed")
    }

    /// AC-75: no result is its own screen, not "No people yet".
    func test_People_AC_75_noResultShowsSearchEmpty() throws {
        launchIntoPeopleList()
        typeQuery("zzz")
        XCTAssertTrue(waitForSearch(name: "zzz", withHidden: "false", after: 0),
                      "no `name=zzz` search — requests: \(searchRequests().map(\.params))")
        XCTAssertTrue(element("peopleSearchEmpty").waitForExistence(timeout: 20), "no `peopleSearchEmpty`")
        XCTAssertEqual(personRowCount, 0, "no row may remain")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No people yet")).count, 0,
                       "\"No people yet\" is the empty library, not an empty search")
        shot("ps75-empty")
    }

    /// AC-76: a 500 shows the user-facing text only; Retry searches again.
    func test_People_AC_76_serverErrorThenRetryShowsResult() throws {
        launchIntoPeopleList()
        typeQuery("err")
        XCTAssertTrue(waitForSearch(name: "err", withHidden: "false", after: 0),
                      "no `name=err` search — requests: \(searchRequests().map(\.params))")
        XCTAssertTrue(element("peopleSearchError").waitForExistence(timeout: 20), "no `peopleSearchError`")
        XCTAssertTrue(staticText(caseInsensitive: "Couldn't search people").firstMatch.exists,
                      "the failure title is missing")
        XCTAssertTrue(staticText(caseInsensitive: "The server ran into a problem. Please try again.").firstMatch.exists,
                      "the user-facing text of a 500 is missing")
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "STUB-500-BODY")).count, 0,
                       "the body of the server's answer reached the screen")
        XCTAssertEqual(personRowCount, 0, "no row may remain behind the error")
        shot("ps76-error")

        dismissKeyboard()
        let before = searchRequests().count
        app.buttons.matching(NSPredicate(format: "label == %@", "Retry")).firstMatch.tap()
        XCTAssertTrue(waitForSearch(name: "err", withHidden: "false", after: before),
                      "Retry sent no new `name=err` search — requests: \(searchRequests().map(\.params))")
        XCTAssertTrue(personRow(adaId).waitForExistence(timeout: 20), "Retry never showed Ada")
        XCTAssertTrue(element("peopleSearchError").waitForNonExistence(timeout: 10),
                      "the error is still on screen after Retry")
        XCTAssertEqual(searchRequests().filter { $0.params["name"] == "err" }.count, 2,
                       "exactly two `name=err` searches: the failed one and the retry")
        shot("ps76-retry")
    }

    /// AC-77: clearing the field restores the paged list, with no new search.
    func test_People_AC_77_clearingRestoresPagedListWithoutSearch() throws {
        searchAliAndAwaitResults()
        let before = searchRequests().count

        let clear = searchField.buttons.firstMatch
        if clear.exists {
            clear.tap()
        } else {
            searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        }

        for id in [adaId, aliceId, alanId] {
            XCTAssertTrue(personRow(id).waitForExistence(timeout: 20), "the paged list lost \(id)")
        }
        XCTAssertEqual(personRowIDs(), rowIDs([adaId, aliceId, alanId]), "the paged list shows its three rows")
        XCTAssertTrue(waitForLabel(of: personRow(aliceId), containing: "7 photos"), "Alice never read \"7 photos\"")
        XCTAssertTrue(waitForLabel(of: personRow(adaId), containing: "5 photos"), "Ada never read \"5 photos\"")
        let alan = personRow(alanId).frame
        let alice = personRow(aliceId).frame
        let ada = personRow(adaId).frame
        XCTAssertTrue(staticText(caseInsensitive: "Featured").allElementsBoundByIndex
            .contains { $0.frame.maxY <= alan.minY },
                      "no \"Featured\" header above Alan")
        XCTAssertTrue(staticText(caseInsensitive: "People").allElementsBoundByIndex
            .contains { $0.frame.minY >= alan.maxY && $0.frame.minY <= min(alice.minY, ada.minY) },
                      "no \"People\" section header between Alan and the others")
        for id in ["peopleSearchLoading", "peopleSearchEmpty", "peopleSearchError"] {
            XCTAssertFalse(element(id).exists, "`\(id)` is still on screen")
        }
        sleep(2)
        XCTAssertEqual(searchRequests().count, before, "clearing the field must not search")
        shot("ps77-cleared")
    }

    /// AC-78: a round trip to a result's card keeps the query and the results.
    func test_People_AC_78_detailRoundTripKeepsQueryAndResults() throws {
        searchAliAndAwaitResults()
        let searches = searchRequests().count
        let lists = peopleListRequests().count

        personRow(aliceId).tap()
        let bar = app.navigationBars["Alice"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20),
                      "no navigation bar titled \"Alice\" — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        let back = bar.buttons.firstMatch
        print("AC-78 back button: label=\"\(back.label)\" identifier=\"\(back.identifier)\"")
        back.tap()

        if !personRow(aliceId).waitForExistence(timeout: 20) {
            shot("ps78-pop-not-on-results")
            print("AC-78 navigation bars: \(app.navigationBars.allElementsBoundByIndex.map(\.identifier))")
            print("AC-78 screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
            let onHub = app.buttons.matching(identifier: "peopleRow").firstMatch.exists
            print("AC-78 hub row present: \(onHub)")
            XCTFail(onHub
                ? "the pop from Alice's card landed on the Me hub, not on the search results"
                : "the pop from Alice's card landed on an unknown screen, not on the search results")
            return
        }

        XCTAssertEqual(searchField.value as? String, "ali", "the query did not survive the round trip")
        XCTAssertEqual(personRowIDs(), rowIDs([aliceId, alanId]),
                       "the results must still be Alice and Alan — got \(personRowIDs().sorted())")
        XCTAssertEqual(staticText(caseInsensitive: "Featured").count, 0, "no \"Featured\" header in search results")
        assertTopToBottom([aliceId, alanId])
        // The card's `POST /api/search/metadata` is not a people search.
        XCTAssertEqual(searchRequests().count, searches, "the round trip must not search again")
        XCTAssertEqual(peopleListRequests().count, lists, "the same visit must not reload the paged list")
        shot("ps78-back-on-results")
    }

    /// AC-79: leaving for the Me hub and coming back is a NEW visit: empty field.
    func test_People_AC_79_newVisitFromMeStartsEmpty() throws {
        searchAliAndAwaitResults()
        dismissKeyboard()
        XCTAssertEqual(searchField.value as? String, "ali", "the query is not \"ali\" before leaving")
        let firstPages = { self.peopleListRequests().filter { $0.params["page"] == "1" }.count }
        let pagesBefore = firstPages()
        let searches = searchRequests().count

        // Leave without touching the field: Cancel and the clear button would
        // empty it themselves. Strategies in order, the next only if the hub row
        // did not show up.
        let hubPeopleRow = app.buttons.matching(identifier: "peopleRow").firstMatch
        var strategy = "(a) BackButton"
        let backButton = app.buttons.matching(identifier: "BackButton").firstMatch
        if backButton.exists && backButton.isHittable { backButton.tap() }
        if !hubPeopleRow.waitForExistence(timeout: 10) {
            strategy = "(b) edge swipe"
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        if !hubPeopleRow.waitForExistence(timeout: 10) {
            strategy = "(c) avatar -> profile picture row"
            let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 20),
                          "neither the Me hub nor the timeline is on screen:\n\(app.debugDescription)")
            avatar.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "profilePictureRow").firstMatch.waitForExistence(timeout: 20),
                          "the Me hub never opened after touching the avatar")
        }
        print("AC-79 way out of People: \(strategy)")

        let peopleRow = hubRow("peopleRow")
        XCTAssertTrue(peopleRow.waitForExistence(timeout: 20), "the People row is missing in the Me hub")
        peopleRow.tap()

        XCTAssertTrue(personRow(adaId).waitForExistence(timeout: 30), "the paged list never came back")
        let value = (searchField.value as? String) ?? ""
        XCTAssertTrue(value.isEmpty || value == "Search people",
                      "a new visit must start with an empty field — it reads \"\(value)\"")
        XCTAssertGreaterThanOrEqual(staticText(caseInsensitive: "Featured").count, 1,
                                    "the paged list shows its \"Featured\" header")
        for id in ["peopleSearchLoading", "peopleSearchEmpty", "peopleSearchError"] {
            XCTAssertFalse(element(id).exists, "`\(id)` is still on screen")
        }
        XCTAssertGreaterThan(firstPages(), pagesBefore, "no new `GET /api/people?page=1` for the new visit")
        XCTAssertEqual(searchRequests().count, searches, "a new visit must not search")
        shot("ps79-new-visit")
    }

    /// AC-80: toggling the hidden people during a search relaunches it.
    func test_People_AC_80_showHiddenRelaunchesSearchWithHidden() throws {
        searchAliAndAwaitResults()
        dismissKeyboard()
        let before = searchRequests().count

        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Show 1 hidden people")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no \"Show 1 hidden people\" button")
        if !toggle.isHittable { app.swipeUp() }
        toggle.tap()

        let deadline = Date().addingTimeInterval(10)
        var listReloaded = false
        while Date() < deadline, !listReloaded {
            listReloaded = peopleListRequests().contains {
                $0.params["page"] == "1" && $0.params["withHidden"] == "true"
            }
            if !listReloaded { sleep(1) }
        }
        XCTAssertTrue(listReloaded, "no `GET /api/people?page=1&withHidden=true` — requests: "
                      + "\(peopleListRequests().map(\.params))")
        XCTAssertTrue(waitForSearch(name: "ali", withHidden: "true", after: before),
                      "no `name=ali&withHidden=true` search — requests: \(searchRequests().map(\.params))")

        XCTAssertTrue(personRow(alinaId).waitForExistence(timeout: 20), "Alina never appeared")
        XCTAssertTrue(waitForLabel(of: personRow(alinaId), containing: "9 photos"), "Alina never read \"9 photos\"")
        XCTAssertEqual(personRowIDs(), rowIDs([aliceId, alanId, alinaId]),
                       "the results must be Alice, Alan and Alina — got \(personRowIDs().sorted())")
        XCTAssertEqual(staticText(caseInsensitive: "Featured").count, 0, "no \"Featured\" header in search results")
        // The server's order: a sort by photos would lead with Alina (9), and the
        // paged list would put Alan under "Featured".
        assertTopToBottom([aliceId, alanId, alinaId])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hide hidden people"))
            .firstMatch.waitForExistence(timeout: 10), "the toggle must now offer \"Hide hidden people\"")
        XCTAssertEqual(searchField.value as? String, "ali", "the query changed with the toggle")
        shot("ps80-hidden-shown")
    }
}
