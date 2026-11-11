import XCTest

/// End-to-end scenario for the three diagnostic instruments of the "Me" hub's
/// Advanced section (gap G24) — **App Logs**, **Media Stats**, **Download
/// Info** — and for the one thing a log screen must never do: carry a secret.
///
/// It drives the real app: onboarding → SSO → the timeline (traffic), then the
/// hub, whose Advanced section must expose its three rows. Every instrument is
/// then asserted on BOTH surfaces — the screen and the wire:
///
/// * App Logs lists the requests THIS run made (the timeline's day call, whose
///   query the transport keeps on the wire and must NOT keep in the entry), its
///   free-text filter finds one of them, its level filter partitions the list,
///   and its export is real text.
/// * No line it renders — nor its export — contains the access token the stub
///   handed the app. The stub notes that the token really was presented as an
///   `Authorization: Bearer …` header, so the scan cannot pass by the credential
///   being absent from the session.
/// * Media Stats shows the counters `GET /api/assets/statistics` served (values
///   that exist nowhere else) plus the ledger's local half, and its `severe`
///   line reaches the log only after the stub is armed to fail that route (a 5xx
///   is the one outcome the transport maps to `severe`).
/// * Download Info, empty, says so: zero files, the empty-state copy, no purge —
///   and it asks the server for nothing.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, refuses a scenario that skipped itself, and states
/// the device it needs):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/app-utilities.uitest.log \
///         UITests/stubs/immich_stub_app_utilities.py \
///         AppUtilitiesUITests/test_appUtilities --erase
///
/// `--erase` is required: an empty log, an empty ledger, an empty offline cache
/// and a first onboarding are what the assertions below read.
final class AppUtilitiesUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    /// The access token `immich_stub_app_utilities.py` hands the app at the end
    /// of the handshake. Both files own this literal; change them together.
    private let token = "stub-apputilities-token-8f31c2d9"
    /// The counters only that stub serves.
    private let photos = "4242"
    private let videos = "7317"
    /// The day the shell's timeline answers with — and therefore the query the
    /// transport must drop from the entry while keeping its path.
    private let timelineDay = "2026-09-01"

    private var app: XCUIApplication!

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
    // Copied from `ImmichRenderScreenshots` on purpose: these are `private`
    // there, and the shared file is frozen (its scenarios are green against its
    // current text). Extracting them into a shared support file would be a
    // second convention next to the existing one — the harness rule is one file
    // per feature, helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state (statistics disarmed) and empties
    /// its request log, so no assertion below can be satisfied by a previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Arms or disarms the stub's 500 on `GET /api/assets/statistics`. A plain
    /// request to the stub, not a UI action: the failure has to be in place
    /// before a screen asks, and only the stub can answer it.
    private func setStatisticsFailing(_ failing: Bool) {
        var request = URLRequest(url: URL(string: "\(stub)/control/statistics?fail=\(failing ? 1 : 0)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "Stub did not answer the control route")
        XCTAssertTrue(body.contains(failing ? "true" : "false"),
                      "Stub did not arm/disarm the statistics failure (answer: \(body))")
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks, like `test_01` of the shared class.
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
        // Scrolling dismisses the keyboard (`.scrollDismissesKeyboard(.immediately)`),
        // so the CTA is really hittable when it is tapped, and a bounded retry
        // covers the frame the keyboard was still animating over.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("au00b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// One timeline tile, by the identity the grid gives it.
    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    /// Any element carrying `identifier` — the rows, the lists and the buttons
    /// of this feature publish one, precisely so a scenario never has to match a
    /// translated label.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized: "App Logs"
    /// / "Journaux de l'app"). A `Form` only publishes what it rendered, and the
    /// Advanced section sits below the fold, so the row is scrolled into view
    /// first, letting each swipe settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<14 where !row.exists {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.7)
        }
        return row
    }

    /// Pops one level of the hub's stack. The bar being left is the one carrying
    /// the SCREEN's title — taken as a substring, since the title is translated
    /// ("App Logs" / "Journaux de l'app") — and its first button is the back
    /// button. Without the title, `firstMatch` could hand back the hub's own bar,
    /// whose first button dismisses the whole sheet instead of popping.
    private func goBack(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        let titled = app.navigationBars.matching(labelPredicate(titles)).firstMatch
        let bar = titled.waitForExistence(timeout: 10) ? titled : app.navigationBars.firstMatch
        let back = bar.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "no way back from this screen — bars: "
                      + "\(app.navigationBars.allElementsBoundByIndex.map(\.label))",
                      file: file, line: line)
        back.tap()
        Thread.sleep(forTimeInterval: 0.9)
    }

    // MARK: - The screens of the instruments

    /// The character `AppLogEntry.message` puts between a call and its outcome.
    private let arrow = "\u{2192}"

    /// Every string the instruments' screens publish: the values, the titles,
    /// the toolbar, and the log's rows (which `AppLogRow` combines into single
    /// accessibility elements, so they are collected separately). `List` CELLS
    /// carry no label at all on these screens — a scan that stopped at them read
    /// eleven empty strings on Media Stats (measured) — hence the static texts.
    /// The system keyboard is deliberately NOT a source: a key cap labelled "?"
    /// would be read as a leaked query, which is why `assertLogCarriesNoSecret`
    /// first proves that no keyboard is up.
    private func screenStrings() -> [String] {
        var strings: [String] = []
        for query in [app.staticTexts, app.cells, app.navigationBars,
                      app.segmentedControls, app.buttons] {
            for element in query.allElementsBoundByIndex {
                strings.append(element.label)
                if let value = element.value as? String, !value.isEmpty { strings.append(value) }
            }
        }
        strings.append(contentsOf: logRows())
        return strings
    }

    /// The log screen's ROWS. `AppLogRow` combines its children into ONE
    /// accessibility element labelled `"<level> <method> <path> → <outcome>"`, so
    /// the arrow is what tells a row apart from the picker, the toolbar and the
    /// titles — and everything a row carries is in that one string.
    private func logRows() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", arrow))
            .allElementsBoundByIndex
            .map(\.label)
    }

    /// The refusal itself: no string the log screen renders may carry a request's
    /// query (`?`) nor the credential the app presents in a header. Scanned
    /// rather than spot-checked, because a leak would be in whichever line the
    /// app happened to render, and the point is that there is none to find.
    private func assertLogCarriesNoSecret(_ context: String) {
        XCTAssertEqual(app.keyboards.count, 0,
                       "\(context): the screen-wide scan reads what the screen publishes, so no keyboard "
                       + "may be up — a key cap's « ? » would read as a leaked query")
        let strings = screenStrings()
        let withQuery = strings.filter { $0.contains("?") }
        XCTAssertTrue(withQuery.isEmpty,
                      "\(context): the log must carry no request's query — found: \(withQuery)")
        let withToken = strings.filter { $0.contains(token) }
        XCTAssertTrue(withToken.isEmpty,
                      "\(context): the log must carry no credential — found: \(withToken)")
        let withHeader = strings.filter { $0.localizedCaseInsensitiveContains("bearer") }
        XCTAssertTrue(withHeader.isEmpty,
                      "\(context): the log must carry no request header — found: \(withHeader)")
    }

    /// Brings a row carrying `needle` into the rendered part of the list by
    /// scrolling, and returns its label (or "").
    ///
    /// Deliberately NOT through the screen's own free-text field: `.searchable`
    /// takes the whole navigation bar over while it is active — its screenshot
    /// shows the field, its Cancel, and no title and no back button at all — so
    /// a scenario that searched here then had no way out of the screen (measured,
    /// in the run this replaced). The list is newest-first and short, so the
    /// requests of this run are a few swipes down.
    private func revealLogRow(containing needle: String) -> String {
        for _ in 0..<12 {
            if let hit = logRows().first(where: { $0.contains(needle) }) { return hit }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }
        return logRows().first(where: { $0.contains(needle) }) ?? ""
    }

    /// The first rendered row the predicate accepts, scrolling a bounded number
    /// of times — for a row the free-text field could not reach anyway (the level
    /// is not part of what it searches).
    private func firstRenderedRow(swipes: Int = 8, where accepts: (String) -> Bool) -> String {
        for _ in 0..<swipes {
            if let hit = logRows().first(where: accepts) { return hit }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }
        return logRows().first(where: accepts) ?? ""
    }

    /// One segment of the level picker, read from the picker itself (its labels
    /// are translated: "Severe" / "Grave" / "Kritisch"). The picker lives in the
    /// list's first section and the list renders lazily, so it is scrolled back
    /// into reach first — a filtered list may have been left scrolled.
    @discardableResult
    private func tapLogLevel(_ labels: [String], timeout: TimeInterval = 10) -> Bool {
        let picker = app.segmentedControls.matching(identifier: "appLogLevelPicker").firstMatch
        for _ in 0..<4 where !picker.isHittable {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.6)
        }
        let root = picker.waitForExistence(timeout: timeout) ? picker : app.segmentedControls.firstMatch
        let segment = root.buttons.matching(labelPredicate(labels)).firstMatch
        guard segment.waitForExistence(timeout: timeout) else { return false }
        segment.tap()
        Thread.sleep(forTimeInterval: 0.9)
        return true
    }

    /// The picker's own proof: with `level` selected the list still shows that
    /// level's lines, has dropped every line of `otherLevel`, and has dropped
    /// `hides` (a line only the other level carries). The list renders lazily, so
    /// the expected line is scrolled into view first — bounded, and the four
    /// checks then read the same window.
    private func assertLevelFilter(_ segments: [String], level: String, shows: String,
                                   otherLevel: String, hides otherNeedle: String,
                                   context: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(tapLogLevel(segments), "the level picker has no \(segments) segment",
                      file: file, line: line)
        var rows = logRows()
        for _ in 0..<4 where !rows.contains(where: { $0.contains(shows) }) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            rows = logRows()
        }
        XCTAssertTrue(rows.contains { $0.lowercased().hasPrefix(level) },
                      "\(context): \(level) lists none of its own lines — rows:\n"
                      + rows.joined(separator: "\n"), file: file, line: line)
        XCTAssertTrue(rows.contains { $0.contains(shows) },
                      "\(context): \(level) no longer lists \(shows) — rows:\n"
                      + rows.joined(separator: "\n"), file: file, line: line)
        XCTAssertFalse(rows.contains { $0.lowercased().hasPrefix(otherLevel) },
                       "\(context): \(level) still lists \(otherLevel) lines — rows:\n"
                       + rows.joined(separator: "\n"), file: file, line: line)
        XCTAssertFalse(rows.contains { $0.contains(otherNeedle) },
                       "\(context): \(level) still lists \(otherNeedle) — rows:\n"
                       + rows.joined(separator: "\n"), file: file, line: line)
    }

    /// Waits until the screen publishes `value`.
    private func waitForValue(_ value: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if screenStrings().contains(where: { $0.contains(value) }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// A `List` row of an instrument: `LabeledContent` publishes its title and
    /// its value either as one combined row label ("Tracked assets, 0") or as
    /// two separate strings, so the title pins the row and the value is accepted
    /// on the row or anywhere on the screen.
    private func assertRow(_ titles: [String], shows value: String, context: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        let predicate = labelPredicate(titles)
        let cell = app.cells.matching(predicate).firstMatch
        let text = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15) || text.exists,
                      "\(context): no row titled \(titles) — screen reads: \(screenStrings())",
                      file: file, line: line)
        let row = cell.exists ? cell : text
        if row.exists, row.label.contains(value) { return }
        XCTAssertTrue(screenStrings().contains { $0.contains(value) },
                      "\(context): the row \(titles) does not read \(value) — screen reads: \(screenStrings())",
                      file: file, line: line)
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `params` is the decoded query string;
    /// `bearerMatches` is the boolean the statistics route notes when the caller
    /// presented the credential — never the credential itself.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        let bearerMatches: Bool?
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

    // MARK: - Scenario

    func test_appUtilities() throws {
        reset()
        setProvider("manual")
        app.launch()

        // MARK: Onboarding → OAuth, then TRAFFIC
        //
        // Everything the log asserts below has to have been done by this run: a
        // wiped device is what makes the walk deterministic, and the timeline's
        // own day call is the request whose query the entry must not keep.

        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("au01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap: the hub would never open under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            whatsNewDone.tap()
        }

        let firstTile = tile("aaaaaaaa-1111-4111-8111-000000000001")
        if !firstTile.waitForExistence(timeout: 30) {
            shot("au02b-empty-timeline")
            XCTFail("the timeline never rendered against \(stub); screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
        shot("au02-timeline")

        // ON THE WIRE: the day call really did carry a query, so the log line for
        // it — asserted below — is a line the transport had to strip.
        let dayCalls = stubRequests().filter { $0.path == "/api/timeline/bucket" }
        XCTAssertTrue(dayCalls.contains { $0.params["timeBucket"] == timelineDay },
                      "the timeline never asked for a day with timeBucket=\(timelineDay) — got:\n"
                      + describe(stubRequests()))

        // MARK: The hub's Advanced section — three rows, by identifier
        //
        // Labels are translated ("App Logs" / "Journaux de l'app"), so the rows
        // are matched by the identifiers the hub publishes on the links.

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
        hub.tap()
        Thread.sleep(forTimeInterval: 3.5) // the sheet animates in; nothing is hittable before it does

        for identifier in ["appLogsRow", "mediaStatsRow", "downloadInfoRow"] {
            if !hubRow(identifier).waitForExistence(timeout: 5) {
                shot("au03b-advanced-\(identifier)-missing")
                XCTFail("the Advanced section does not expose \(identifier):\n\(app.debugDescription)")
            }
        }
        shot("au03-advanced")

        // MARK: App Logs — the requests of THIS run, path only

        hubRow("appLogsRow").tap()
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "the App Logs screen never loaded")
        Thread.sleep(forTimeInterval: 1.2)

        var rows = logRows()
        if rows.isEmpty {
            shot("au04b-empty-app-logs")
            XCTFail("the log rendered no entry although this run booted the app and drew a timeline — "
                    + "screen reads: \(screenStrings())")
        }
        for row in rows {
            XCTAssertTrue(row.contains("/api/"), "a log row without a request path: \(row)")
            XCTAssertFalse(row.contains("?"), "a log row carrying a request's query: \(row)")
        }

        // The day call is the query-bearing request of this run: its row must be
        // there, by its PATH alone — `timeBucket=` must not have followed it.
        let dayRow = revealLogRow(containing: "/api/timeline/bucket")
        XCTAssertTrue(dayRow.contains("/api/timeline/bucket"),
                      "the log does not show the request this scenario just made — rows:\n"
                      + logRows().joined(separator: "\n"))
        XCTAssertFalse(dayRow.contains("timeBucket"),
                       "the entry kept the request's query: \(dayRow)")
        shot("au04-app-logs-day-call")
        assertLogCarriesNoSecret("App Logs, nominal traffic")

        // MARK: Media Stats — the wire's counters, and a level to filter on

        goBack(["App Logs", "Journaux"])
        // Armed BEFORE the screen asks: the 500 is what puts a `severe` line in
        // the log, and a 5xx is the only outcome the transport maps to it.
        setStatisticsFailing(true)
        XCTAssertTrue(hubRow("mediaStatsRow").waitForExistence(timeout: 5), "Media Stats row lost")
        hubRow("mediaStatsRow").tap()
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Try Again", "Réessayer"]))
            .firstMatch.waitForExistence(timeout: 20),
                      "the dispatched 500 never surfaced on Media Stats — screen reads: "
                      + "\(screenStrings())")
        shot("au05-media-stats-error")

        setStatisticsFailing(false)
        // The banner's own retry; the list's pull-to-refresh re-runs the same
        // load if the banner is not there to tap.
        let retry = app.buttons.matching(labelPredicate(["Try Again", "Réessayer"])).firstMatch
        if retry.exists {
            retry.tap()
        } else {
            app.swipeDown()
        }
        XCTAssertTrue(waitForValue(photos, timeout: 25),
                      "Media Stats never showed the server's photo count (\(photos)) — screen reads: "
                      + "\(screenStrings())")
        XCTAssertTrue(waitForValue(videos, timeout: 10),
                      "Media Stats never showed the server's video count (\(videos)) — screen reads: "
                      + "\(screenStrings())")
        XCTAssertTrue(element("mediaStatsServerPhotos").exists,
                      "the server counters lost their identifier")
        assertRow(["Tracked assets", "Éléments suivis"], shows: "0",
                  context: "Media Stats, the ledger's local half")
        assertRow(["Cached offline", "En cache hors ligne"], shows: "0",
                  context: "Media Stats, the offline cache's local half")
        XCTAssertTrue(screenStrings().contains { $0.contains("Never") || $0.contains("Jamais") },
                      "the ledger's reconciliation date is not the empty ledger's own reading — "
                      + "screen reads: \(screenStrings())")
        shot("au06-media-stats")

        // ON THE WIRE: the screen's numbers came from `GET /api/assets/statistics`
        // (the 500 first, the counters after), and the credential the scan above
        // looks for really was presented — in the Authorization HEADER, which is
        // exactly what an entry must not record.
        let stats = stubRequests().filter { $0.path == "/api/assets/statistics" }
        XCTAssertGreaterThanOrEqual(stats.count, 2,
                                    "the armed failure and the retry must be two calls — got:\n"
                                    + describe(stubRequests()))
        XCTAssertTrue(stats.contains { $0.bearerMatches == true },
                      "the app never presented the token as a bearer header — got:\n"
                      + describe(stats))

        // MARK: App Logs again — the new line, and the level filter

        goBack(["Media Stats", "Statistiques"])
        hubRow("appLogsRow").tap()
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "the App Logs screen never reloaded")
        Thread.sleep(forTimeInterval: 1.2)

        let failingRow = firstRenderedRow { $0.lowercased().hasPrefix("severe") }
        XCTAssertTrue(failingRow.hasPrefix("severe"),
                      "the log did not follow the traffic: no severe line for the 5xx — rows:\n"
                      + logRows().joined(separator: "\n"))
        XCTAssertTrue(failingRow.contains("/api/assets/statistics"),
                      "the severe line is not the failed statistics call: \(failingRow)")
        XCTAssertTrue(logRows().contains { $0.lowercased().hasPrefix("info") },
                      "an unarmed call is missing from the log — rows:\n"
                      + logRows().joined(separator: "\n"))
        shot("au07-app-logs-levels")

        // The picker PARTITIONS the list: the same screen, filtered, keeps the
        // severe line and drops the info ones, then the other way round.
        assertLevelFilter(["Severe", "Grave", "Kritisch"], level: "severe",
                          shows: "/api/assets/statistics", otherLevel: "info",
                          hides: "/api/users/me", context: "App Logs, level filter")
        assertLevelFilter(["Info"], level: "info",
                          shows: "/api/assets/statistics", otherLevel: "severe",
                          hides: "500", context: "App Logs, level filter")
        XCTAssertTrue(tapLogLevel(["All", "Tout", "Alle"]), "the level picker lost its All segment")
        rows = logRows()
        XCTAssertTrue(rows.contains { $0.lowercased().hasPrefix("severe") }
                        && rows.contains { $0.lowercased().hasPrefix("info") },
                      "All must list both levels — rows:\n" + rows.joined(separator: "\n"))

        // MARK: Download Info — an empty inventory that says so

        goBack(["App Logs", "Journaux"])
        hubRow("downloadInfoRow").tap()
        XCTAssertTrue(waitForStaticText(["No downloaded files", "Aucun fichier téléchargé"], timeout: 20),
                      "the empty inventory does not say it is empty — screen reads: "
                      + "\(screenStrings())")
        assertRow(["Files", "Fichiers"], shows: "0", context: "Download Info, empty")
        XCTAssertFalse(element("downloadInfoPurgeButton").exists,
                       "an empty inventory offers to purge what it does not hold")
        shot("au08-download-info")
        let downloadCalls = stubRequests().filter { $0.path.contains("/download") }
        XCTAssertTrue(downloadCalls.isEmpty,
                      "the inventory is read from the device; the server must not answer it — got:\n"
                      + describe(downloadCalls))

        // MARK: The export — last, because the sheet it raises is never left
        //
        // The system share sheet is a surface this harness can raise but not
        // drive: on iOS 26 the app never reports idle again while it is up, so the
        // tap that would press one of its activities hangs XCUITest until the run
        // is killed (measured once, on the sheet's `actionGroupCell`; the same
        // attempt on the activity itself is not worth a second run). What the
        // export CONTAINS is therefore proved where it is written — the entries'
        // paths on the screen above, and the screen-wide refusal below — and the
        // export is proved to be the log's text by what the sheet itself renders
        // of the item it was handed.

        goBack(["Download Info", "Infos de téléchargement"])
        hubRow("appLogsRow").tap()
        XCTAssertTrue(element("appLogList").waitForExistence(timeout: 20), "the App Logs screen never reopened")
        Thread.sleep(forTimeInterval: 1.2)
        assertLogCarriesNoSecret("App Logs, after the failure")

        let share = element("appLogShareButton")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the log screen offers no export action")
        share.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("au09-share-sheet")

        // Read by PREDICATE, never by walking the tree: the sheet re-lays out
        // while it settles, and an index-based walk of it aborts the run with
        // "Failed to get matching snapshot" (measured twice).
        //
        // The preview carries the export's own line shape — `date | level |
        // category | method path | status …` — which nothing else in this app
        // builds (the log's own rows read `<level> <method> <path> → <status>`),
        // so an element publishing it is the export itself, not the screen under
        // it. Which KIND publishes it is not knowable in advance (the sheet's
        // preview is a text view on one system, a static text on another, and its
        // container aggregates what it holds), so every kind is probed.
        let shape = NSPredicate(format: "label CONTAINS %@", "| HTTP |")
        let kinds: [(String, XCUIElementQuery)] = [("staticText", app.staticTexts),
                                                   ("textView", app.textViews),
                                                   ("cell", app.cells),
                                                   ("other", app.otherElements),
                                                   ("button", app.buttons)]
        var preview: String?
        for (_, query) in kinds {
            let hit = query.matching(shape).firstMatch
            if hit.waitForExistence(timeout: 3) {
                preview = hit.label
                break
            }
        }
        print("AUSHAPE \(preview.map { String($0.prefix(200)) } ?? "none")")

        // …and it offers to copy it. An item that is text is the only reason this
        // sheet has a Copy activity at all, which is what makes this an assertion
        // about the export rather than about the sheet.
        let copyActivity = NSPredicate(format: "label CONTAINS 'Copier' OR label CONTAINS 'Copy'")
        let copyHolder = app.cells.matching(copyActivity).firstMatch
        if copyHolder.exists { print("AUCOPY \(copyHolder.label.prefix(300))") }
        XCTAssertTrue(copyHolder.exists || app.buttons.matching(copyActivity).firstMatch.exists,
                      "the export raised no share sheet offering to copy a text — sheet reads: "
                      + "\(app.debugDescription)")

        XCTAssertNotNil(preview,
                        "the share sheet publishes no element carrying the export's line shape — "
                        + "the sheet's own labels are: \(copyHolder.exists ? String(copyHolder.label.prefix(300)) : "none")")

        // The same refusal, on what the system was handed.
        for (kind, query) in kinds {
            XCTAssertFalse(query.matching(NSPredicate(format: "label CONTAINS '?'")).firstMatch.exists,
                           "the \(kind) the sheet publishes carries a request's query")
            XCTAssertFalse(query.matching(NSPredicate(format: "label CONTAINS %@", token))
                .firstMatch.exists,
                           "the \(kind) the sheet publishes carries the credential")
        }
    }
}
