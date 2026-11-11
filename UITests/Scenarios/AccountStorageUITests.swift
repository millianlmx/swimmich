import XCTest

/// Account storage (L-01, B-3): the Me hub, Media Stats and "On this device"
/// show the SIGNED-IN ACCOUNT's usage, quota and photo/video counts, and only the
/// Administration screen shows the instance totals.
///
/// Against `immich_stub_account_storage.py`, which serves the account's numbers
/// (`GET /api/users/me`, `GET /api/assets/statistics`) and, for an administrator,
/// DIFFERENT instance totals (`GET /api/server/statistics`: 900 photos, 90
/// videos, another user owning 772 + 83). A screen reading the wrong route shows
/// 900, 9999 (`POST /api/search/statistics`, partners included) or a 403.
///
/// Every value is read by `accessibilityIdentifier`, as DIGITS only
/// (`label + value`, `filter(\.isNumber)`), and compared with what
/// `ByteCountFormatter` yields in the test: the scenario neither hard-codes a
/// locale's "21,47 Go" nor ever targets a localized label (the only exceptions
/// are the words "Unlimited" and "Unavailable", which are the feature's own copy).
///
/// SESSION. The status "administrator" is read at sign-in and never again at
/// restore (`AuthViewModel.restoreSession`), and every scenario skips the
/// onboarding when a session exists: a session left behind would leak its
/// administrator status into another class (`UserApiKeysUITests` demands NO admin
/// row). So every launch passes `-authServerURL ()` (restore finds no server and
/// wipes the token: the onboarding is guaranteed and sign-in runs each time), and
/// `tearDown` relaunches once the same way, which erases the session even when a
/// method failed halfway.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/account-storage.uitest.log \
///         UITests/stubs/immich_stub_account_storage.py AccountStorageUITests --erase
final class AccountStorageUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private let hundredGiB: Int64 = 107_374_182_400
    private let twentyGiB: Int64 = 21_474_836_480
    private let instanceUsage: Int64 = 999_000_000_000

    private static let welcome = ["Your photo library", "Votre photothèque"]
    private static let unlimited = ["Unlimited", "Illimité"]
    private static let unavailable = ["Unavailable", "Indisponible"]
    private static let allowAccess = ["Allow access", "Autoriser l'accès", "Zugriff erlauben"]
    private static let allowFullAccess = ["Allow Full Access", "Allow Access to All Photos", "Allow All Photos",
                                          "Full Access", "accès complet", "accès à toutes les photos",
                                          "Vollen Zugriff"]

    private let launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-authServerURL", "()"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    override func tearDownWithError() throws {
        guard stubIsReachable() else { return }
        // Erases the session (see the type's doc), whatever state the method died in.
        app.terminate()
        app.launchArguments = launchArguments
        app.launch()
        XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                      "the cleanup launch did not reach the onboarding: the session may have survived")
        app.terminate()
    }

    // MARK: - The scenarios

    /// AC-5: a non-administrator sees their own usage, quota and counts on the
    /// three screens, with no error banner, and the app never reads the instance
    /// totals.
    func test_AC_5() throws {
        try start(Account())
        XCTAssertFalse(adminRowExists(), "a non-administrator was offered Administration")
        visitScreens { screen in
            self.assertNoError(screen)
            self.assertUsage(screen, used: self.twentyGiB, quota: self.hundredGiB)
            self.assertCounts(screen, photos: 128, videos: 7)
        }
        let instanceReads = stubRequests().filter { $0.method == "GET" && $0.path == "/api/server/statistics" }
        XCTAssertTrue(instanceReads.isEmpty, "the app read the instance totals:\n\(describe(instanceReads))")
    }

    /// AC-6: an administrator's profile shows their own counts, and Administration
    /// shows the instance totals.
    func test_AC_6() throws {
        try start(Account(admin: true))
        XCTAssertTrue(adminRowExists(), "the administrator has no Administration row")
        reveal("profileStoragePhotos")
        assertCounts(.hub, photos: 128, videos: 7)
        XCTAssertNotEqual(digits("profileStoragePhotos"), "900")
        openAdministration()
        XCTAssertTrue(waitUntil(timeout: 20) { self.digits("adminInstancePhotos") == "900" },
                      "Administration does not show the instance photos — \(screenReads())")
        XCTAssertEqual(digits("adminInstanceVideos"), "90")
        XCTAssertEqual(digits("adminInstanceUsage"), formatted(instanceUsage))
    }

    /// AC-67: the same usage and quota strings on the three screens, a 20 % bar
    /// on the profile, and the counts of the account.
    func test_AC_67() throws {
        try start(Account())
        visitScreens { screen in
            self.assertUsage(screen, used: self.twentyGiB, quota: self.hundredGiB)
            self.assertCounts(screen, photos: 128, videos: 7)
            if screen == .hub {
                let bar = self.element("profileStorageQuotaBar")
                XCTAssertTrue(bar.exists, "the profile has no quota bar")
                let value = (bar.value as? String ?? "") + bar.label
                XCTAssertEqual(value.filter(\.isNumber), "20", "the quota bar does not read 20 %: \(value)")
            }
        }
    }

    /// AC-68: no quota means "Unlimited", with no bar and no "0".
    func test_AC_68() throws {
        try start(Account(quota: "null"))
        visitScreens { screen in
            let quota = self.reading(screen.quotaId)
            XCTAssertTrue(Self.unlimited.contains { quota.contains($0) },
                          "\(screen) does not say the quota is unlimited: \(quota)")
            if screen == .hub {
                XCTAssertFalse(self.element("profileStorageQuotaBar").exists, "a bar was drawn without a quota")
            }
            XCTAssertEqual(self.digits(screen.usageId), self.formatted(self.twentyGiB))
        }
    }

    /// AC-69: the counts are the account's (128 / 7), never the partner-inclusive
    /// search statistics (9999), which the app must not even call.
    func test_AC_69() throws {
        try start(Account())
        visitScreens { screen in
            self.assertCounts(screen, photos: 128, videos: 7)
        }
        let searchReads = stubRequests().filter { $0.path == "/api/search/statistics" }
        XCTAssertTrue(searchReads.isEmpty, "the app read the partner-inclusive statistics:\n\(describe(searchReads))")
    }

    /// AC-70: one half failing leaves the other shown, "Unavailable" with Try
    /// Again replaces the failed half (never a zero), and the retry reads it.
    func test_AC_70() throws {
        let deviceTitle = ["On this device", "Sur cet appareil", "Auf diesem Gerät"]
        try start(Account(failCounts: true))
        visitScreens { screen in
            XCTAssertTrue(self.element(screen.countsErrorId).exists, "\(screen) has no counts error")
            self.assertUsage(screen, used: self.twentyGiB, quota: self.hundredGiB)
            if screen != .device {
                XCTAssertTrue(self.reading(screen.photosId).contains(anyOf: Self.unavailable),
                              "\(screen) shows something other than \"Unavailable\" for the counts")
            }
            XCTAssertFalse(self.element(screen.usageErrorId).exists, "\(screen) flags the usage that was read")
        }
        // The retry, on the hub (its view model kept the failure): the read comes back.
        goBack(deviceTitle)
        control("fail?counts=0")
        reveal("profileStorageCountsError")
        tapRetry("profileStorageCountsError")
        XCTAssertTrue(waitUntil(timeout: 20) { self.digits("profileStoragePhotos") == "128" },
                      "the retry did not bring the counts back — \(screenReads())")

        // The other way round: the usage fails, the counts are shown.
        try start(Account(failMe: true))
        visitScreens { screen in
            XCTAssertTrue(self.element(screen.usageErrorId).exists, "\(screen) has no usage error")
            XCTAssertTrue(self.reading(screen.usageId).contains(anyOf: Self.unavailable),
                          "\(screen) shows something other than \"Unavailable\" for the usage")
            self.assertCounts(screen, photos: 128, videos: 7)
            XCTAssertFalse(self.element(screen.countsErrorId).exists, "\(screen) flags the counts that were read")
        }
        goBack(deviceTitle)
        control("fail?me=0")
        reveal("profileStorageUsageError")
        tapRetry("profileStorageUsageError")
        XCTAssertTrue(waitUntil(timeout: 20) { self.digits("profileStorageUsage") == self.formatted(self.twentyGiB) },
                      "the retry did not bring the usage back — \(screenReads())")
    }

    /// AC-72: with the server entirely down, "On this device" keeps its device
    /// column and flags only the server column; Media Stats keeps its local half.
    func test_AC_72() throws {
        try start(Account(failMe: true, failCounts: true))
        reveal("mediaStatsRow")
        openRow("mediaStatsRow")
        XCTAssertTrue(waitUntil(timeout: 20) { self.element("mediaStatsServerUsageError").exists },
                      "Media Stats never flagged the usage — \(screenReads())")
        XCTAssertTrue(element("mediaStatsServerCountsError").exists)
        assertRow(["Tracked assets", "Éléments suivis"], shows: "0")
        assertRow(["Cached offline", "En cache hors ligne"], shows: "0")
        goBack(["Media Stats", "Statistiques"])

        openLocalLibrary()
        XCTAssertTrue(element("localLibrarySummary").waitForExistence(timeout: 20),
                      "the device column disappeared with the server")
        XCTAssertTrue(waitUntil(timeout: 20) { self.element("localLibraryServerUsageError").exists },
                      "the server column never flagged the usage — \(screenReads())")
        XCTAssertTrue(element("localLibraryServerCountsError").exists)
    }

    /// AC-73: Administration shows the instance totals, and a failing read leaves
    /// users, jobs and libraries usable and retryable.
    func test_AC_73() throws {
        try start(Account(admin: true, failInstance: true))
        openAdministration()
        XCTAssertTrue(app.buttons.matching(identifier: "adminInstanceStatsError").firstMatch
            .waitForExistence(timeout: 20), "the failing instance read shows no retry — \(screenReads())")
        XCTAssertTrue(app.staticTexts["Other User"].waitForExistence(timeout: 20), "the users section is gone")
        XCTAssertTrue(app.staticTexts["Thumbnail Generation"].exists, "the jobs section is gone")
        XCTAssertTrue(app.staticTexts["Stub Library"].exists, "the libraries section is gone")
        let paths = Set(stubRequests().filter { $0.method == "GET" }.map(\.path))
        for path in ["/api/admin/users", "/api/jobs", "/api/libraries"] {
            XCTAssertTrue(paths.contains(path), "Administration never read \(path)")
        }

        control("fail?instance=0")
        tapRetry("adminInstanceStatsError")
        XCTAssertTrue(waitUntil(timeout: 20) { self.digits("adminInstancePhotos") == "900" },
                      "the retry did not bring the instance totals — \(screenReads())")
        XCTAssertEqual(digits("adminInstanceUsage"), formatted(instanceUsage))
        XCTAssertTrue(app.staticTexts["Other User"].exists, "the retry dropped the users section")
    }

    /// AC-74: the same numbers, without errors, against a v2.0.0 and a v3.4.0 server.
    func test_AC_74() throws {
        for version in ["2.0.0", "3.4.0"] {
            try start(Account(version: version))
            visitScreens { screen in
                self.assertNoError(screen)
                self.assertUsage(screen, used: self.twentyGiB, quota: self.hundredGiB)
                self.assertCounts(screen, photos: 128, videos: 7)
            }
        }
    }

    // MARK: - Scenario setup

    private struct Account {
        var admin = false
        var quota = "107374182400"
        var usage = "21474836480"
        var failMe = false
        var failCounts = false
        var failInstance = false
        var version = "3.4.0"
    }

    private enum Screen: CustomStringConvertible {
        case hub, mediaStats, device

        var prefix: String {
            switch self {
            case .hub: "profileStorage"
            case .mediaStats: "mediaStatsServer"
            case .device: "localLibraryServer"
            }
        }
        var usageId: String { prefix + "Usage" }
        var quotaId: String { prefix + "Quota" }
        var photosId: String { prefix + "Photos" }
        var videosId: String { prefix + "Videos" }
        var countsErrorId: String { prefix + "CountsError" }
        var usageErrorId: String { prefix + "UsageError" }
        var description: String {
            switch self {
            case .hub: "the profile"
            case .mediaStats: "Media Stats"
            case .device: "On this device"
            }
        }
    }

    /// A fresh stub, the account the method needs, a fresh onboarding and a
    /// sign-in, then the hub open on top of the shell.
    private func start(_ account: Account) throws {
        if app.state != .notRunning { app.terminate() }
        reset()
        control("account?admin=\(account.admin ? 1 : 0)&quota=\(account.quota)&usage=\(account.usage)")
        control("fail?me=\(account.failMe ? 1 : 0)&counts=\(account.failCounts ? 1 : 0)&instance=\(account.failInstance ? 1 : 0)")
        control("version?v=\(account.version)")
        setProvider("manual")
        installPhotoPromptHandler()
        app.launchArguments = launchArguments
        app.launch()
        signIn()
        settleOnShell()
        openHub()
    }

    /// Walks the three screens in turn — the hub, Media Stats, "On this device" —
    /// and lets `check` read each one once its storage has settled.
    private func visitScreens(_ check: (Screen) -> Void) {
        settle(.hub)
        check(.hub)

        reveal("mediaStatsRow")
        openRow("mediaStatsRow")
        settle(.mediaStats)
        check(.mediaStats)
        goBack(["Media Stats", "Statistiques"])

        openLocalLibrary()
        settle(.device)
        check(.device)
    }

    /// Waits for the screen's storage to have answered: the usage rows exist in
    /// every outcome (a value, or "Unavailable").
    private func settle(_ screen: Screen) {
        reveal(screen.usageId)
        XCTAssertTrue(waitUntil(timeout: 25) { self.element(screen.usageId).exists },
                      "\(screen) never showed its usage — \(screenReads())")
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Assertions

    private func assertNoError(_ screen: Screen) {
        XCTAssertFalse(element(screen.countsErrorId).exists, "\(screen) shows an error for the counts")
        XCTAssertFalse(element(screen.usageErrorId).exists, "\(screen) shows an error for the usage")
    }

    private func assertUsage(_ screen: Screen, used: Int64, quota: Int64) {
        XCTAssertEqual(digits(screen.usageId), formatted(used), "\(screen) usage: \(reading(screen.usageId))")
        XCTAssertEqual(digits(screen.quotaId), formatted(quota), "\(screen) quota: \(reading(screen.quotaId))")
    }

    private func assertCounts(_ screen: Screen, photos: Int, videos: Int) {
        switch screen {
        case .device:
            // "128 photos · 7 videos" — digits only: "1287".
            XCTAssertEqual(digits("localLibraryServerCounts"), "\(photos)\(videos)",
                           "\(screen) counts: \(reading("localLibraryServerCounts"))")
            XCTAssertEqual(digits("localLibraryRemoteSummary"), "\(photos + videos)",
                           "the server total is not photos + videos (the stub's `total` is higher)")
        case .hub, .mediaStats:
            XCTAssertEqual(digits(screen.photosId), "\(photos)", "\(screen) photos: \(reading(screen.photosId))")
            XCTAssertEqual(digits(screen.videosId), "\(videos)", "\(screen) videos: \(reading(screen.videosId))")
        }
    }

    /// A row of a `List`, found by its (localized) title, whose value is checked.
    /// Used only for the two LOCAL rows of Media Stats, which have no identifier.
    private func assertRow(_ titles: [String], shows value: String) {
        let predicate = labelPredicate(titles)
        let cell = app.cells.matching(predicate).firstMatch
        let text = app.staticTexts.matching(predicate).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15) || text.exists, "no row titled \(titles) — \(screenReads())")
        let row = cell.exists ? cell : text
        if row.label.contains(value) { return }
        XCTAssertTrue(screenStrings().contains { $0 == value }, "the row \(titles) does not read \(value) — \(screenReads())")
    }

    // MARK: - Reading the screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reading(_ identifier: String) -> String {
        let element = element(identifier)
        guard element.exists else { return "" }
        return element.label + " " + ((element.value as? String) ?? "")
    }

    private func digits(_ identifier: String) -> String {
        reading(identifier).filter(\.isNumber)
    }

    /// What `ByteCountFormatter` makes of a size: the oracle, computed here, of the
    /// app's shared decimal formatter. Compared as digits, so no locale is assumed.
    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file).filter(\.isNumber)
    }

    private func screenStrings() -> [String] {
        var strings: [String] = []
        for query in [app.staticTexts, app.cells, app.navigationBars, app.buttons] {
            for element in query.allElementsBoundByIndex {
                strings.append(element.label)
                if let value = element.value as? String, !value.isEmpty { strings.append(value) }
            }
        }
        return strings
    }

    private func screenReads() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label))"
    }

    // MARK: - Navigation

    private func adminRowExists() -> Bool {
        // The Account section sits below the fold: scroll to the very bottom first.
        for _ in 0..<14 { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.7)
        return element("adminRow").exists
    }

    private func openAdministration() {
        reveal("adminRow")
        openRow("adminRow")
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.element("adminInstancePhotos").exists || self.element("adminInstanceStatsError").exists
        }, "Administration never showed its instance statistics — \(screenReads())")
    }

    private func openHub() {
        for _ in 0..<2 {
            dismissWhatsNewIfPresent()
            let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
            XCTAssertTrue(hub.waitForExistence(timeout: 15), "Profile avatar missing")
            hub.tap()
            // The sheet animates in; its Form is not published before it does.
            Thread.sleep(forTimeInterval: 4)
            if !whatsNewDone.exists { return }
        }
    }

    /// Scrolls a `Form` (which only publishes what it rendered) until the element
    /// exists — down first, then back up.
    private func reveal(_ identifier: String) {
        let target = element(identifier)
        for direction in [true, false] {
            for _ in 0..<14 where !target.exists {
                if direction { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.7)
            }
        }
    }

    private func openRow(_ identifier: String) {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row \(identifier) — \(screenReads())")
        row.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    private func openLocalLibrary() {
        reveal("localLibraryRow")
        openRow("localLibraryRow")
        // The screen asks for Photos access when it opens: a system alert left
        // unanswered blocks everything behind it.
        allowPhotosIfAsked()
        XCTAssertTrue(element("localLibrarySummary").waitForExistence(timeout: 30),
                      "the On this device screen never loaded — \(screenReads())")
    }

    private func tapRetry(_ identifier: String) {
        let retry = app.buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "no retry button on \(identifier) — \(screenReads())")
        retry.tap()
    }

    /// Pops one level; the bar being left carries the screen's (translated) title.
    private func goBack(_ titles: [String]) {
        let titled = app.navigationBars.matching(labelPredicate(titles)).firstMatch
        let bar = titled.waitForExistence(timeout: 10) ? titled : app.navigationBars.firstMatch
        let back = bar.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back from this screen — \(screenReads())")
        back.tap()
        Thread.sleep(forTimeInterval: 0.9)
    }

    // MARK: - Sign-in

    private func signIn() {
        XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                      "the onboarding did not appear — the scenario would start from a stale session")
        walkOnboardingToLogin()
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell")
    }

    private func settleOnShell() {
        XCTAssertTrue(element("assetTile_aaaaaaaa-1111-4111-8111-000000000001").waitForExistence(timeout: 40),
                      "the timeline never rendered — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    private var whatsNewDone: XCUIElement {
        app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
    }

    private func dismissWhatsNewIfPresent() {
        guard whatsNewDone.waitForExistence(timeout: 5) else { return }
        whatsNewDone.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.whatsNewDone.exists }, "What's New never closed")
    }

    /// Welcome → server URL → login. Leaves the app on the login screen.
    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
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
        // The CTA sits under the keyboard the typing raised: scrolling dismisses it.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        XCTAssertTrue(onLogin, "Login screen did not appear — \(screenReads())")
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

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return condition()
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

    // MARK: - Photos permission ("On this device" asks for it when it opens)

    /// XCUITest's own interruption handler answers the Photos alert with its
    /// DEFAULT button ("add only", no read access): a registered monitor is
    /// consulted first, so this one answers with full access.
    private func installPhotoPromptHandler() {
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            let button = alert.buttons.matching(self.labelPredicate(Self.allowFullAccess)).firstMatch
            guard button.exists else { return false }
            button.tap()
            return true
        }
    }

    private func allowPhotosIfAsked() {
        let allow = app.buttons.matching(labelPredicate(Self.allowAccess)).firstMatch
        guard allow.waitForExistence(timeout: 8) else { return }
        allow.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [springboard, app] {
            let alert = host.alerts.firstMatch
            guard alert.waitForExistence(timeout: 8) else { continue }
            let button = alert.buttons.matching(labelPredicate(Self.allowFullAccess)).firstMatch
            if button.exists { button.tap() }
            return
        }
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

    private func reset() {
        stubGet("/__reset")
    }

    private func control(_ path: String) {
        let body = stubGet("/control/\(path)")
        XCTAssertTrue(body.contains("admin"), "the stub rejected the control /control/\(path): \(body)")
    }

    private func setProvider(_ mode: String) {
        XCTAssertEqual(stubGet("/__provider?mode=\(mode)"), "{\"provider\": \"\(mode)\"}")
    }

    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
    }

    private func stubRequests() -> [StubRequest] {
        (try? JSONDecoder().decode([StubRequest].self, from: Data(stubGet("/__requests").utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }
}

private extension String {
    func contains(anyOf words: [String]) -> Bool {
        words.contains { contains($0) }
    }
}
