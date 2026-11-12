import XCTest

/// End-to-end scenario for the person-birthday editor (gap G15): the fifth
/// action button of a person card opens a date sheet whose Save and Clear both
/// write through ONE route, `PUT /api/people/{id}`.
///
/// It drives the real app (onboarding → SSO → Albums tab → People → a person) and
/// asserts on BOTH surfaces, because a screen cannot tell the three write
/// shapes apart: set, erase, and the silent do-nothing this card was raised for
/// (`PersonUpdateDto(birthDate: nil)` omits the key instead of sending an
/// explicit `null`, so the server has nothing to update). The body of every
/// write is therefore read back from the stub, and the stub deliberately
/// answers a DIFFERENT day than the one it received — the header must show the
/// server's answer, not the draft the sheet held.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/person-birthday.uitest.log \
///         UITests/stubs/immich_stub_person_birthday.py \
///         PersonBirthdayUITests/test_personBirthday --erase
///
/// `--erase` is not optional here: the scenario asserts a FIRST launch (the
/// onboarding walk only exists on a device with no persisted session) and the
/// device is shared with every other scenario of the wave.
///
/// NOT PROVEN, and worth saying:
///
/// 1. The day CELLS of the graphical `DatePicker` are never tapped or moved —
///    their labels are localized ("Saturday, May 12" / "Samstag, 12. Mai"), so a
///    selector for one is a bet on the simulator's language. The draft the picker
///    holds is exercised end to end (it reaches the wire as a date-only string,
///    and the day that comes back is the server's), but "the user moved the
///    picker to another day" is asserted nowhere.
///
/// 2. BLOCKER — entering the drill-down does not work under XCUITest here. A row
///    of the people list is a `NavigationLink(value:)`, and no synthesized
///    gesture activates it: two app-level coordinate touches, an AX tap and a
///    0.4 s press per round, eight rounds across two list instances (before and
///    after a relaunch), row hittable at a sane frame, screens unmoved. A
///    CONTROL tap on the same screen — the list's own refresh button,
///    `arrow.clockwise` — does reach the app and puts a `GET /api/people` on the
///    wire, so the screen is not deaf: the row is inert. Removing the row's
///    `.accessibilityElement(children: .combine)` changes nothing (measured), so
///    it is not that either. Runs of 2026-09-15 reached the card TWICE before the
///    blocker became systematic (see the wire assertion below), which is when the
///    whole birthday contract was proven: `{"birthDate":"1990-05-12"}` on Save —
///    that single key, nothing else — the header then showing the day the SERVER
///    answered (`2001`), and `{"birthDate":null}` on Clear with the line gone.
///    Everything past the list — the person without a birthday, the refused write
///    and the list's error row — is written but unreached.
final class PersonBirthdayUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port of a by-hand run.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8423"
    private var app: XCUIApplication!

    // The fixture of `immich_stub_person_birthday.py`: two people, one with a
    // birthday and one without. Names are not localized, and the two days are
    // what ties a screen to a request.
    private let adaId = "dddddddd-1111-4111-8111-000000000001"
    private let alanId = "dddddddd-1111-4111-8111-000000000002"
    private let adaName = "Ada Lovelace"
    private let alanName = "Alan Turing"
    private let seededDay = "1990-05-12"
    /// The years of the two days above. Only the YEAR is asserted on screen: a
    /// birthday label is localized ("May 12, 1990" / "12 mai 1990" / "12. Mai
    /// 1990") and digits are the one part that reads the same in every language.
    private let seededYear = "1990"
    private let answeredYear = "2001"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip-vs-run only, so a full-scheme run without a stub stays green.
        // `uitest.sh` starts the stub first and treats a skip as a failure, so
        // this never masks anything under the launcher.
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

    // MARK: - Helpers
    //
    // Copied from `RecentlyTakenUITests` on purpose: these are `private` there,
    // and the harness rule is one file per feature, helpers included. Extracting
    // them into a shared support file would be a second convention next to the
    // existing one.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state (two people, no failing write)
    /// and empties its request log, so no assertion below can be satisfied by a
    /// previous run.
    private func reset() {
        control("/__reset")
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks, like the reference one.
    private func setProvider(_ mode: String) {
        XCTAssertEqual(control("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    /// GETs a control path on the stub and returns its body verbatim.
    /// `/__…` paths are the shell's (`reset`, the provider page), `/control/…`
    /// is the one route this feature's stub adds: a feature control route
    /// cannot live under `/__`, the shell answers that prefix before the router.
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

    /// Waits for any button whose label contains `text` and taps it. Case
    /// sensitive on purpose: the keyboard's return key is labelled "continuer"
    /// in lowercase and would shadow the "Continuer" CTA.
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

    /// The onboarding copy is localized (issue #21), and the repo's own
    /// simulator is in German while the runs use English slots: a walk accepts
    /// both, never one hard-coded language.
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

    /// The provider page lives in `SafariViewService`, a separate process, so
    /// its "Authorize" link is not in the app's own accessibility tree.
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
        // The field can hold the PREVIOUS run's URL — a warm slot seeds it — and
        // `typeText` APPENDS. With a random stub port per run that value is
        // always stale, so it is cleared before typing rather than trusted.
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
        // Typing the URL raised the keyboard, and the CTA sits under it: a tap
        // computed from the button's frame then lands on the keyboard and the
        // flow never leaves this screen (measured — it cost one run in two).
        // Scrolling dismisses the keyboard, so the CTA is really hittable when
        // it is tapped, and a bounded retry covers the animation.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("pb01b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized: "People" /
    /// "Personnes" / "Personen"). A `Form` only publishes what it rendered, so
    /// the row is scrolled into view first, letting each swipe settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// A tile of the Albums tab's Library section, by IDENTIFIER (its label is
    /// localized: "People" / "Personnes" / "Personen"). The Albums ScrollView is
    /// scrolled only when the tile is not hittable.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        _ = row.waitForExistence(timeout: 10)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// A person row of the list, by the identifier `PeopleView` gives it
    /// (`personRow_<id>` — added for this scenario, since the row is interactive
    /// and the harness puts identifiers on interactive elements).
    ///
    /// Not by label: the row's label is a concatenation of its children ("Ada
    /// Lovelace, 3 photos"), and once the drill-down has been popped back the same
    /// row publishes as a CELL whose own label is empty — measured, with the two
    /// rows plainly on screen in the run's own UI snapshot, as a label query that
    /// had matched a minute earlier stopped matching. The identifier the view
    /// carries does not have that problem.
    private func personRow(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "personRow_\(id)").firstMatch
    }

    /// The card is up when its fifth action button is: it exists only on the
    /// drill-down, and its identifier spares the caller a translated label.
    private func waitForCard(timeout: TimeInterval) -> Bool {
        sheetButton("personBirthdayAction").waitForExistence(timeout: timeout)
    }

    /// Timeline → Albums tab → People, all by identifier. Used to enter the list
    /// the first time and again after a relaunch.
    private func enterPeopleList(expecting id: String) {
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "the app is not on the authenticated shell")
        // A fresh install presents "What's New" over the shell, and a modal
        // swallows every tap: the tab would never be selected under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 5) {
            shot("pb02-whats-new")
            whatsNewDone.tap()
        }
        app.tabBars.buttons["Albums"].tap()
        let peopleRow = libraryRow("peopleRow")
        if !peopleRow.waitForExistence(timeout: 15) {
            shot("pb03b-albums-without-people-row")
            XCTFail("People tile missing in the Albums library:\n\(app.debugDescription)")
        }
        shot("pb03-albums-library")
        peopleRow.tap()
        XCTAssertTrue(personRow(id).waitForExistence(timeout: 30),
                      "the people list never rendered `personRow_\(id)`:\n\(app.debugDescription)")
    }

    /// One attempt at opening a card, by gesture number.
    ///
    /// The first two are touches dispatched through the APPLICATION, not through
    /// the row: measured, `XCUIElement.tap()` AND `row.coordinate(...).tap()` on
    /// this row both report the row's own element as the thing being tapped (the
    /// log names it), and the row is a `NavigationLink` whose label COMBINES its
    /// children — so the accessibility element is not the link, and an activation
    /// aimed at it does nothing: eight attempts in a row, row hittable, frame on
    /// screen, screen unmoved. `app.coordinate(...)` has no control to activate,
    /// so it is a plain touch at a point.
    private func tapRowOnce(_ id: String, attempt: Int) -> Bool {
        let row = personRow(id)
        guard row.exists else {
            print("openCard(\(id)) #\(attempt): no row on screen")
            return false
        }
        let frame = row.frame
        switch attempt % 4 {
        case 1: touchApp(at: CGPoint(x: frame.midX, y: frame.midY))
        case 2: touchApp(at: CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY))
        case 3: row.tap()
        default: row.press(forDuration: 0.4)
        }
        if waitForCard(timeout: 25) { return true }
        print("openCard(\(id)) #\(attempt) (\(frame)): the card is not up — nav bars "
              + "\(app.navigationBars.allElementsBoundByIndex.map(\.identifier))")
        return false
    }

    /// A plain touch at a point of the app's frame — see `tapRowOnce`.
    private func touchApp(at point: CGPoint) {
        let bounds = app.frame
        app.coordinate(withNormalizedOffset: CGVector(
            dx: (point.x - bounds.minX) / bounds.width,
            dy: (point.y - bounds.minY) / bounds.height)).tap()
    }

    /// Diagnostic, never an assertion: does a touch reach this screen AT ALL?
    /// The list's refresh button is identified (`arrow.clockwise`) and its effect
    /// is on the wire (`GET /api/people`), so this answers the question without
    /// relying on any screen state — it makes the failure message say whether the
    /// row is inert or the screen is deaf.
    private func touchReachesTheList() -> Bool {
        let count = { self.stubRequests().filter { $0.method == "GET" && $0.path == "/api/people" }.count }
        let before = count()
        app.buttons.matching(identifier: "arrow.clockwise").firstMatch.tap()
        for _ in 0..<10 {
            if count() > before { return true }
            sleep(1)
        }
        return false
    }

    /// Opens a person's card, and waits for it to be really up.
    ///
    /// Two rounds, because the first one is measured to be unreliable: four
    /// gestures on a list that has been on screen for a while all did nothing,
    /// and the same row opened the card on other runs. The second round starts
    /// from a FRESH list (the app is relaunched and walked back in by
    /// identifier), which is what a user does when a row does not respond. The
    /// outcome is asserted in both rounds — no gesture can make a card that never
    /// opened look open.
    @discardableResult
    private func openCard(_ id: String, name: String) -> Bool {
        guard personRow(id).waitForExistence(timeout: 30) else {
            shot("pb00-person-row-missing")
            XCTFail("no row `personRow_\(id)` (\(name)) in the people list:\n\(app.debugDescription)")
            return false
        }
        for attempt in 1...4 {
            if tapRowOnce(id, attempt: attempt) { return true }
        }
        print("openCard(\(name)): nothing opened the card on this list — relaunching and re-entering")
        app.terminate()
        app.launch()
        enterPeopleList(expecting: id)
        for attempt in 5...8 {
            if tapRowOnce(id, attempt: attempt) { return true }
        }

        shot("pb00-person-card-never-opened")
        print("openCard(\(name)): a touch DOES reach this screen: \(touchReachesTheList()) "
              + "(the row never opened the card)")
        XCTFail("tapping \(name) never opened the person card (its `personBirthdayAction` button, the "
                + "card's fifth action, never appeared), on the first list and on a fresh one — screen "
                + "reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        return false
    }

    /// Back to the people list, from a card, with the list waited for.
    ///
    /// Scoped to the card's OWN navigation bar, by its title — the person's name,
    /// not a translated string. And the pop is measured to settle on the list OR
    /// on the Albums library, so the library is a second real step — never an
    /// assumption: whichever way it went, the list is entered through its tile
    /// and its rows are asserted back.
    private func backToPeopleList(from person: String, expecting id: String) {
        let bar = app.navigationBars[person]
        XCTAssertTrue(bar.waitForExistence(timeout: 20),
                      "no navigation bar titled \"\(person)\" — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        bar.buttons.firstMatch.tap()
        if personRow(id).waitForExistence(timeout: 20) { return }

        print("backToPeopleList(\(person)): the pop did not land on the list — nav bars "
              + "\(app.navigationBars.allElementsBoundByIndex.map(\.identifier)), screen reads: "
              + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        let peopleRow = libraryRow("peopleRow")
        XCTAssertTrue(peopleRow.waitForExistence(timeout: 20),
                      "neither the people list nor the Albums library came back after leaving \(person)'s card")
        peopleRow.tap()
        XCTAssertTrue(personRow(id).waitForExistence(timeout: 30),
                      "the people list is on screen but has no row `personRow_\(id)`: "
                      + "\(app.debugDescription)")
    }

    /// The birthday line the drill-down draws under the person's name — the one
    /// element of the card whose identity is not a translated label.
    private var birthdayLine: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "personBirthdayValue").firstMatch
    }

    /// The header must end up READING `year` — the day the SERVER answered.
    ///
    /// A bounded PREDICATE wait on the value, not on existence right after the
    /// sheet closes: the call site runs `setBirthday` in a `Task` concurrent with
    /// the dismissal, so the header legitimately still shows the old day for a
    /// moment, and an existence wait would accept the day that was SENT.
    private func assertHeaderShows(year: String, _ what: String) {
        let matched = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", year),
            object: birthdayLine)], timeout: 25)
        guard matched == .completed else {
            XCTFail("the person card never displayed the year \(year) (\(what)):\n\(app.debugDescription)")
            return
        }
    }

    /// The header must end up drawing NO birthday line at all.
    ///
    /// An absence, so it is only asserted on a card whose line was SEEN earlier
    /// in the same run (`assertHeaderShows` is the first thing the scenario does
    /// on the drill-down, and it requires the very same identifier): without
    /// that, "the query never matched" and "the line is gone" would look alike.
    /// The screen behind a modal is not addressable either, so every call site
    /// waits for the sheet to close first.
    private func assertNoBirthdayLine(_ what: String) {
        let gone = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: birthdayLine)], timeout: 25)
        XCTAssertEqual(gone, .completed,
                       "the header still draws a birthday line (\(what)): \"\(birthdayLine.label)\"\n"
                       + app.debugDescription)
    }

    /// A button of the editor sheet, by identifier (its label is translated).
    private func sheetButton(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    /// Waits for the sheet to be gone. Every absence assertion on the screen
    /// behind it goes through here: while a modal is up its presenting screen is
    /// not in the accessibility tree, so "the line is not there" would be true
    /// for the wrong reason.
    private func waitForSheetToClose(_ what: String) {
        XCTAssertTrue(sheetButton("birthdaySave").waitForNonExistence(timeout: 20),
                      "the birthday sheet never closed (\(what))")
    }

    // MARK: - Wire helpers

    /// One value of a logged request body. Only the two shapes this feature can
    /// send are modelled — a string (the date) and an explicit `null` (the
    /// erase) — because those are exactly what the card's assertions turn on:
    /// an absent key and a `null` must not be confused. Anything else is
    /// `.other`, which every assertion below rejects.
    private enum BodyValue: Decodable, Equatable, CustomStringConvertible {
        case string(String)
        case null
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let text = try? container.decode(String.self) {
                self = .string(text)
            } else {
                self = .other
            }
        }

        var description: String {
            switch self {
            case .string(let text): return "\"\(text)\""
            case .null: return "null"
            case .other: return "<not a string>"
            }
        }
    }

    /// One entry of the stub's request log. The `body` is the parsed JSON the
    /// app sent — `["birthDate": .null]` is a body with the key and an explicit
    /// null, `[:]` is a body with no key at all.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: BodyValue]
    }

    private func stubRequests() -> [StubRequest] {
        let body = control("/__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    /// Every write the app sent to `PUT /api/people/{id}` — the ONE route the
    /// whole feature hangs on.
    private func birthdayWrites() -> [StubRequest] {
        stubRequests().filter { $0.method == "PUT" && $0.path.hasPrefix("/api/people/") }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) body={\($0.body.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "))}" }
            .joined(separator: "\n")
    }

    private func bodyText(_ request: StubRequest) -> String {
        request.body.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
    }

    /// Today as the wire spells a date — the draft of a person with no birthday
    /// (`BirthdayEditorSheet` falls back to `Date()`). Same simulator, same
    /// calendar, so the test can compute what the app must have sent.
    private var todayWire: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Scenario

    func test_personBirthday() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. `--erase` makes this a first launch every time; the
        // guard keeps a by-hand re-run on a warm slot useful.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("pb01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // MARK: The "Me" hub → People
        //
        // (`enterPeopleList` dismisses "What's New" on the way: a fresh install
        // presents it over the shell, and a modal swallows every tap.)

        enterPeopleList(expecting: adaId)

        // MARK: The list — the birthday is the field this feature reads

        XCTAssertTrue(personRow(alanId).exists, "the people list is missing \(alanName)")
        shot("pb04-people-list")
        // Nothing has been written yet: an empty log is what makes the counts
        // below mean "one write per action" rather than "one write in this run".
        XCTAssertTrue(birthdayWrites().isEmpty,
                      "no birthday was touched yet, nothing may have been written — got:\n\(describe(birthdayWrites()))")

        openCard(adaId, name: adaName)

        // MARK: The drill-down header, seeded from the server's list

        assertHeaderShows(year: seededYear, "seeded with \(seededDay) by the stub's list")
        shot("pb05-person-card-with-birthday")

        // MARK: Save — one field, and the screen follows the SERVER's answer

        sheetButton("personBirthdayAction").tap()

        let picker = app.descendants(matching: .any).matching(identifier: "birthdayPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15),
                      "the editor sheet has no birthday picker:\n\(app.debugDescription)")
        // A person who HAS a birthday must offer the erase.
        XCTAssertTrue(sheetButton("birthdayClear").exists,
                      "a person with a birthday must be offered \"Clear Birthday\"")
        shot("pb06-birthday-sheet")

        XCTAssertTrue(sheetButton("birthdaySave").isHittable, "the sheet's Save button is not hittable")
        sheetButton("birthdaySave").tap()
        waitForSheetToClose("after Save")

        let afterSave = birthdayWrites()
        XCTAssertEqual(afterSave.count, 1,
                       "one Save must send exactly one write — got:\n\(describe(afterSave))")
        if let saved = afterSave.last {
            XCTAssertEqual(saved.path, "/api/people/\(adaId)", "the write went to the wrong path")
            XCTAssertEqual(Set(saved.body.keys), Set(["birthDate"]),
                           "a birthday write must carry `birthDate` and NOTHING else — never the name, "
                           + "the colour, the cover or the hidden flag; the body was {\(bodyText(saved))}")
            // Date-only, unpadded-free `YYYY-MM-DD`: a timestamp or a shifted day
            // would be caught here.
            XCTAssertEqual(saved.body["birthDate"], .string(seededDay),
                           "the drafted day must reach the wire as \(seededDay) — body was {\(bodyText(saved))}")
        }
        // The stub answers a DIFFERENT day than the one it received: a header
        // painted from the draft (or from the request) would still read 1990, so
        // this is where "the screen comes from the server's answer" is pinned.
        assertHeaderShows(year: answeredYear, "the stub answered 2001-12-31 for good")
        shot("pb07-after-save-server-answer")

        // MARK: Clear — the erase that `PersonUpdateDto` cannot express

        sheetButton("personBirthdayAction").tap()
        XCTAssertTrue(sheetButton("birthdayClear").waitForExistence(timeout: 15),
                      "a person with a birthday must be offered \"Clear Birthday\"")
        sheetButton("birthdayClear").tap()
        waitForSheetToClose("after Clear")

        let afterClear = birthdayWrites()
        XCTAssertEqual(afterClear.count, 2,
                       "the erase must be its own write — got:\n\(describe(afterClear))")
        if let erased = afterClear.last {
            XCTAssertEqual(erased.path, "/api/people/\(adaId)", "the erase went to the wrong path")
            XCTAssertEqual(Set(erased.body.keys), Set(["birthDate"]),
                           "the erase must send the `birthDate` key: a body WITHOUT it is the trap this "
                           + "feature exists for (the server has nothing to update and silently keeps the "
                           + "birthday) — body was {\(bodyText(erased))}")
            XCTAssertEqual(erased.body["birthDate"], .null,
                           "the erase must send an explicit null (the field is `format: date`, so \"\" is "
                           + "refused) — body was {\(bodyText(erased))}")
        }
        assertNoBirthdayLine("after the erase the server answered null")
        shot("pb08-after-clear")

        // MARK: A person with no birthday is not offered the erase

        backToPeopleList(from: adaName, expecting: adaId)
        openCard(alanId, name: alanName)
        // The line is driven by a lookup in `vm.people`, so a card still showing
        // the OTHER person's day would be caught here.
        assertNoBirthdayLine("\(alanName) has no birthday in the list")
        sheetButton("personBirthdayAction").tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the editor sheet never opened for \(alanName)")
        XCTAssertFalse(sheetButton("birthdayClear").exists,
                       "someone with no birthday has nothing to erase, so \"Clear Birthday\" must not be "
                       + "drawn at all — sheet reads: "
                       + "\(app.buttons.allElementsBoundByIndex.map(\.identifier))")
        shot("pb09-no-clear-without-birthday")
        // Cancel, not Save: this step must leave no write behind, which is also
        // what keeps the third write below unambiguous.
        app.buttons.matching(labelPredicate(["Cancel", "Annuler", "Abbrechen"])).firstMatch.tap()
        waitForSheetToClose("after Cancel")
        XCTAssertEqual(birthdayWrites().count, 2,
                       "Cancel must not write anything — got:\n\(describe(birthdayWrites()))")

        // MARK: The negative control — the server refuses the write

        backToPeopleList(from: alanName, expecting: alanId)
        XCTAssertEqual(control("/control/birthday?fail=1"), "{\"fail\": true}")

        openCard(adaId, name: adaName)
        assertNoBirthdayLine("\(adaName)'s birthday was erased, not replaced")
        sheetButton("personBirthdayAction").tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "the editor sheet never opened")
        sheetButton("birthdaySave").tap()
        waitForSheetToClose("after the refused Save")

        let afterRefusal = birthdayWrites()
        XCTAssertEqual(afterRefusal.count, 3,
                       "the refused Save must still have reached the server (no local-only refusal) — "
                       + "got:\n\(describe(afterRefusal))")
        if let refused = afterRefusal.last {
            XCTAssertEqual(Set(refused.body.keys), Set(["birthDate"]),
                           "the refused write is still the same mono-field body — body was {\(bodyText(refused))}")
            XCTAssertEqual(refused.body["birthDate"], .string(todayWire),
                           "a person with no birthday opens on today's draft, so the refused write carries "
                           + "\(todayWire) — body was {\(bodyText(refused))}")
        }
        // The UI must not lie about the state: the write was refused, so the
        // header still shows NO birthday — an optimistic `people[i] = draft`
        // would paint TODAY's day here, and the line was there before the erase.
        assertNoBirthdayLine("the write was refused with a 400")
        shot("pb10-after-refused-write")

        // …and the refusal is visible in the app.
        //
        // MEASURED, and the reason this does not read the people list's own error
        // row: `setBirthday` lands its failure in `PeopleViewModel.errorMessage`,
        // which the list renders — but popping the card RE-CREATES the list, whose
        // `.task` then runs `load()`, and a successful load clears that message
        // before any query can see it (the failed run's own screenshot of the list
        // shows no error line at all). The client's log is the surface that keeps
        // it: one entry per request, carrying the verb, the path and the server's
        // answer, on a screen the Me hub owns (`appLogsRow`).
        backToPeopleList(from: adaName, expecting: adaId)
        XCTAssertTrue(personRow(adaId).exists, "the list lost \(adaName) after the refused write")

        // People is pushed on the Albums tab's stack: one back tap lands on the
        // Albums library, and the avatar (an identifier) is the way into the Me
        // sheet, which owns the App Logs row.
        let back = app.buttons.matching(identifier: "BackButton").firstMatch
        if back.waitForExistence(timeout: 15) { back.tap() }
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20),
                      "the avatar is missing after leaving People:\n\(app.debugDescription)")
        avatar.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "profilePictureRow").firstMatch
            .waitForExistence(timeout: 20), "the Me hub never opened after touching the avatar")
        let logsRow = hubRow("appLogsRow")
        XCTAssertTrue(logsRow.waitForExistence(timeout: 20),
                      "the App Logs row is missing in the Me hub:\n\(app.debugDescription)")
        logsRow.tap()

        // The entry reads `warning PUT /api/people/<id> → 400` — the client logs
        // the STATUS, not the message it raises from it. Read off the failed run's
        // own accessibility dump, whose other entries read
        // `info GET /api/timeline/buckets → 200`.
        let refusal = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "/api/people/", "→ 400")).firstMatch
        for _ in 0..<4 where !refusal.exists {
            app.swipeUp()
            sleep(1)
        }
        if !refusal.waitForExistence(timeout: 10) {
            shot("pb11b-no-log-entry")
            XCTFail("the refused write left no `PUT /api/people/… → 400` entry in the app log:\n\(app.debugDescription)")
        }
        shot("pb11-refused-write-in-app-log")
    }
}
