import XCTest

/// B-21: counters and the selection title agree with their number in every
/// shipped language, read on the real screens against `immich_stub_plurals.py`
/// (two albums, of one photo and of two, on a server older than 3.2.0).
///
/// Elements are found by identifier; only their label is read. The expected
/// words are the catalog's own plural forms, written out per language
/// (`Resources/Localizable.xcstrings`: "%lld photos", "%lld selected",
/// "Detected text search requires Immich %@ or later.").
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/plurals.uitest.log \
///         UITests/stubs/immich_stub_plurals.py PluralsUITests --erase
final class PluralsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's fixtures (recopied from immich_stub_plurals.py).
    private let one = "33333333-3333-4333-8333-000000000001"
    private let two = "33333333-3333-4333-8333-000000000002"
    private let twoFirst = "a1a1a1a1-3333-4333-8333-000000000002"
    private let twoSecond = "a1a1a1a1-3333-4333-8333-000000000003"
    private let timeline = ["aaaaaaaa-1111-4111-8111-000000000001", "aaaaaaaa-1111-4111-8111-000000000002"]

    private struct Words {
        let code: String
        let locale: String
        let photoOne: String, photoMany: String
        let selectedOne: String, selectedMany: String
        let versionNotice: String
    }

    private static let english = Words(
        code: "en", locale: "en_US", photoOne: "1 photo", photoMany: "2 photos",
        selectedOne: "1 selected", selectedMany: "2 selected",
        versionNotice: "Detected text search requires Immich 3.2 or later."
    )

    private static let shipped = [
        Words(code: "fr", locale: "fr_FR", photoOne: "1 photo", photoMany: "2 photos",
              selectedOne: "1 sélectionné", selectedMany: "2 sélectionnés",
              versionNotice: "La recherche par texte détecté nécessite Immich 3.2 ou une version ultérieure."),
        Words(code: "de", locale: "de_DE", photoOne: "1 Foto", photoMany: "2 Fotos",
              selectedOne: "1 ausgewählt", selectedMany: "2 ausgewählt",
              versionNotice: "Die Suche nach erkanntem Text erfordert Immich 3.2 oder neuer."),
        Words(code: "es", locale: "es_ES", photoOne: "1 foto", photoMany: "2 fotos",
              selectedOne: "1 seleccionado", selectedMany: "2 seleccionados",
              versionNotice: "La búsqueda por texto detectado requiere Immich 3.2 o posterior."),
        Words(code: "it", locale: "it_IT", photoOne: "1 foto", photoMany: "2 foto",
              selectedOne: "1 selezionato", selectedMany: "2 selezionati",
              versionNotice: "La ricerca per testo rilevato richiede Immich 3.2 o successivo."),
    ]

    private let launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-authServerURL", "()"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    /// One last launch in the clean-session shape, so no session survives the test.
    override func tearDownWithError() throws {
        guard stubIsReachable() else { return }
        app.terminate()
        app.launchArguments = launchArguments
        app.launch()
        XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                      "the cleanup launch did not reach the onboarding: the session may have survived")
        app.terminate()
    }

    // MARK: - AC-32

    func test_AC_32_albumCountsAndSelectionInFourLanguages() throws {
        try start()
        for words in Self.shipped {
            relaunch(words)
            openAlbumsTab(words)

            // The albums list: the card of each album carries its own count.
            let cardOne = scrolled("albumCard_\(one)")
            let cardTwo = scrolled("albumCard_\(two)")
            XCTAssertTrue(cardOne.label.contains(words.photoOne), "\(words.code): \(cardOne.label)")
            XCTAssertTrue(cardTwo.label.contains(words.photoMany), "\(words.code): \(cardTwo.label)")
            assertNoEnglish(words, cardOne.label, cardTwo.label)

            // The album of two: the header counter, then the selection title.
            cardTwo.tap()
            let heroCount = element("albumHeroCount")
            XCTAssertTrue(heroCount.waitForExistence(timeout: 20), "\(words.code): no header counter")
            XCTAssertEqual(heroCount.label, words.photoMany, "\(words.code): header of two")
            assertNoEnglish(words, heroCount.label)

            element("albumActionsMenu").tap()
            let select = element("albumSelectAction")
            XCTAssertTrue(select.waitForExistence(timeout: 10), "\(words.code): no Select action")
            select.tap()
            element("assetTile_\(twoFirst)").tap()
            XCTAssertTrue(app.navigationBars.staticTexts[words.selectedOne].waitForExistence(timeout: 10),
                          "\(words.code): the title for one is not \(words.selectedOne) — \(screenReads())")
            element("assetTile_\(twoSecond)").tap()
            XCTAssertTrue(app.navigationBars.staticTexts[words.selectedMany].waitForExistence(timeout: 10),
                          "\(words.code): the title for two is not \(words.selectedMany) — \(screenReads())")

            // The album of one: a fresh launch in the same language.
            relaunch(words)
            openAlbumsTab(words)
            scrolled("albumCard_\(one)").tap()
            let heroOne = element("albumHeroCount")
            XCTAssertTrue(heroOne.waitForExistence(timeout: 20), "\(words.code): no header counter")
            XCTAssertEqual(heroOne.label, words.photoOne, "\(words.code): header of one")
        }
    }

    // MARK: - AC-32.1

    func test_AC_32_1_timelineSelectionTitle() throws {
        try start()
        let french = Self.shipped[0]
        let expected: [(Words, [String])] = [
            (french, ["0 sélectionné", french.selectedOne, french.selectedMany]),
            (Self.english, ["0 selected", Self.english.selectedOne, Self.english.selectedMany]),
        ]
        for (words, titles) in expected {
            relaunch(words)
            let select = element("selectButton")
            XCTAssertTrue(select.waitForExistence(timeout: 20), "\(words.code): no Select button")
            select.tap()
            XCTAssertTrue(app.navigationBars.staticTexts[titles[0]].waitForExistence(timeout: 10),
                          "\(words.code): the title with nothing chosen is not \(titles[0]) — \(screenReads())")
            element("assetTile_\(timeline[0])").tap()
            XCTAssertTrue(app.navigationBars.staticTexts[titles[1]].waitForExistence(timeout: 10),
                          "\(words.code): the title for one is not \(titles[1]) — \(screenReads())")
            element("assetTile_\(timeline[1])").tap()
            XCTAssertTrue(app.navigationBars.staticTexts[titles[2]].waitForExistence(timeout: 10),
                          "\(words.code): the title for two is not \(titles[2]) — \(screenReads())")
        }
    }

    // MARK: - AC-32.6

    func test_AC_32_6_versionNoticeInFiveLanguages() throws {
        try start()
        for words in [Self.english] + Self.shipped {
            relaunch(words)
            app.tabBars.buttons.element(boundBy: 4).tap()
            let filters = element("searchFilterButton")
            XCTAssertTrue(filters.waitForExistence(timeout: 20), "\(words.code): no Filters button")
            filters.tap()
            let notice = scrolled("searchFilterVersionNotice")
            XCTAssertTrue(notice.label.contains("3.2"), "\(words.code): the notice does not cite 3.2: \(notice.label)")
            XCTAssertEqual(notice.label, words.versionNotice, "\(words.code)")
        }
    }

    // MARK: - Helpers

    /// A relaunch in another language; the session is kept (no `-authServerURL`).
    private func relaunch(_ words: Words) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(\(words.code))", "-AppleLocale", words.locale]
        app.launch()
        dismissWhatsNewIfPresent()
    }

    private func openAlbumsTab(_ words: Words) {
        let tab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(tab.waitForExistence(timeout: 40), "\(words.code): no tab bar — \(screenReads())")
        tab.tap()
    }

    /// Never an English word in a label read in de, es or it.
    private func assertNoEnglish(_ words: Words, _ labels: String...) {
        guard words.code != "fr" else { return }
        for label in labels {
            XCTAssertFalse(label.lowercased().contains("photo"), "\(words.code): English residue in \(label)")
            XCTAssertFalse(label.lowercased().contains("selected"), "\(words.code): English residue in \(label)")
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The element, scrolled into the tree when a lazy container has not built it yet.
    private func scrolled(_ identifier: String) -> XCUIElement {
        let target = element(identifier)
        var attempts = 0
        while !target.waitForExistence(timeout: 3) && attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(target.exists, "no \(identifier) — \(screenReads())")
        return target
    }

    private func screenReads() -> String {
        app.staticTexts.allElementsBoundByIndex.prefix(25).map(\.label).joined(separator: " | ")
    }

    // MARK: - Sign-in (the same OAuth walk as the other scenarios)

    private func start() throws {
        if app.state != .notRunning { app.terminate() }
        stubGet("/__reset")
        stubGet("/__provider?mode=manual")
        app.launchArguments = launchArguments
        app.launch()
        XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                      "the onboarding did not appear — the scenario would start from a stale session")
        walkOnboardingToLogin()
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        XCTAssertTrue(element("assetTile_\(timeline[0])").waitForExistence(timeout: 40),
                      "the timeline never rendered — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    private var whatsNewDone: XCUIElement {
        app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
    }

    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        whatsNewDone.tap()
    }

    private func walkOnboardingToLogin() {
        _ = tapAnyButton(["Get Started", "Commencer"], timeout: 15)
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
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(["Sign in to Immich", "Connectez-vous à Immich"], timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenReads())")
    }

    @discardableResult
    private func tapButton(containing text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let direct = app.buttons.matching(predicate).firstMatch
        let contained = app.buttons.containing(predicate).firstMatch
        for candidate in [direct, contained] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
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

    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
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
                          safari.buttons.matching(predicate).firstMatch] where candidate.waitForExistence(timeout: timeout) {
            candidate.tap()
            return true
        }
        return false
    }

    // MARK: - The stub

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

    @discardableResult
    private func stubGet(_ path: String) -> String {
        var request = URLRequest(url: URL(string: "\(stub)\(path)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "the stub did not answer \(path)")
        return body
    }
}
