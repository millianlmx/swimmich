import XCTest

/// End-to-end scenario for the album detail's pagination: scrolling the grid to
/// the bottom asks for page 2, on the wire, in the FLAT search shape, against a
/// server that announces v3.2.0.
///
/// The feature under test is « Album : tout charger au-delà de 1000 photos »:
/// `POST /api/search/metadata` is paged with `albumIds`, `page`, `size` and the
/// album's `order`; the last cell of the grid (`AlbumDetailView`) calls
/// `AlbumDetailViewModel.loadMore()`. The unit tests of the view model cannot
/// prove that the grid ever asks. This scenario can, and it is RED until the
/// feature is integrated: without `loadMore()` the app sends one request
/// (`size` 1000, no `page`) and the page-2 tile never appears.
///
/// What it proves:
///
/// 1. the stub answers 60 photos with `nextPage` "2" and 6 more on page 2;
/// 2. with the first page on screen and before any swipe, no page 2 was asked
///    for — it is the scroll that triggers it;
/// 3. after scrolling, `assetTile_<a page-2 id>` exists, and a
///    `POST /api/search/metadata` carries `albumIds` = [the album], `page` = 2
///    (a JSON number) and `order` "asc";
/// 4. no search request carries `filter`, `orderBy` or `cursor`: the stub
///    announces 3.2.0 (and answers 400 to a mixed body), so a pagination that
///    chose its shape from the version would be caught.
///
/// The `test_AC1…`/`test_AC14…` methods check the STUB's own contract over HTTP
/// and never launch the app.
///
/// It runs on a macOS host (Xcode, an iOS 26 simulator, python3), never in the
/// Linux harness. A skipped test counts as a failure, and this scenario fails
/// by itself — it never skips — when the stub is unreachable. Run it with the
/// launcher, never by hand (it owns the slot's simulator, DerivedData and stub
/// port):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/album-pagination.uitest.log \
///         UITests/stubs/immich_stub_album_pagination.py \
///         AlbumPaginationUITests/test_AC6_albumDetailLoadsPageTwoOnScroll --erase
///
/// The same with a stub contract test in place of `test_AC6…`:
/// `test_AC1_albumListServesOnePagedAlbum`, `test_AC2_albumDetailRouteServesTheAlbum`,
/// `test_AC3_firstPageAnnouncesPageTwo`, `test_AC4_secondPageIsLastAndDisjoint`,
/// `test_AC5_searchBodiesAreLoggedVerbatim`, `test_AC14_serverIsV32AndRejectsMixedBody`.
///
/// By hand: `python3 UITests/stubs/immich_stub_album_pagination.py 8421 &`, then
/// `TEST_RUNNER_IMMICH_STUB_URL=http://127.0.0.1:8421 xcodebuild test
/// -scheme ImmichSwiftUI -destination '<an iOS 26 simulator>'
/// -only-testing:ImmichSwiftUIUITests/AlbumPaginationUITests`.
///
/// The only green verdict is the log line
/// `Test Case '-[ImmichSwiftUIUITests.AlbumPaginationUITests test_AC6_albumDetailLoadsPageTwoOnScroll]' passed`.
final class AlbumPaginationUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's constants, copied from `immich_stub_album_pagination.py`
    // (`ALBUM`, `ALBUM_NAME`, `PAGE_1`, `PAGE_2`): keep the two in step.
    private let albumId = "22222222-2222-4222-8222-000000000101"
    private let albumName = "Paged Album"
    private let firstPageTile = "bbbbbbbb-1111-4111-8111-000000000001"
    private let lastFirstPageId = "bbbbbbbb-1111-4111-8111-000000000060"
    /// The last photo of page 2: below everything page 1 shows.
    private let secondPageWitness = "bbbbbbbb-2222-4222-8222-000000000006"
    private let secondPageIds = (1...6).map { "bbbbbbbb-2222-4222-8222-" + String(format: "%012d", $0) }
    private var firstPageIds: [String] {
        (1...60).map { "bbbbbbbb-1111-4111-8111-" + String(format: "%012d", $0) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The scenario's onboarding and `app.tabBars.buttons["Albums"]` only
        // know English labels (French too for the onboarding): pin the language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Fails, never skips: under the launcher a skipped scenario is a failure
        // anyway, and a full-scheme run must not hide a missing stub.
        guard stubIsReachable() else { throw StubUnreachable(url: stub) }
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

    // MARK: - The scenario

    func test_AC6_albumDetailLoadsPageTwoOnScroll() {
        // 1. The server the app talks to is a v3.2 one.
        let version = stubCall("GET", "/api/server/version")
        let versionJSON = version.json as? [String: Any]
        let versionMessage = "the stub must announce a v3.2 server so the flat shape is a choice, got \(version.json ?? "nothing")"
        XCTAssertEqual((versionJSON?["major"] as? NSNumber)?.intValue, 3, versionMessage)
        XCTAssertEqual((versionJSON?["minor"] as? NSNumber)?.intValue, 2, versionMessage)

        // 2. Clean stub, authenticated shell.
        reset()
        setProvider("manual")
        reachAuthenticatedShell()

        // 3. The Albums tab.
        let tab = app.tabBars.buttons["Albums"].firstMatch
        guard tab.waitForExistence(timeout: 30) else {
            return XCTFail("the Albums tab is missing — tab bar buttons: "
                           + "\(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        }
        tab.tap()

        // 4. The album's card, by its name.
        XCTAssertTrue(tapAnyButton([albumName], timeout: 30),
                      "no card named \(albumName) — buttons on screen: "
                      + "\(app.buttons.allElementsBoundByIndex.map(\.label))")

        // 5. Page 1 is on screen.
        XCTAssertTrue(tile(firstPageTile).waitForExistence(timeout: 30),
                      "the album detail never showed assetTile_\(firstPageTile) — tiles: "
                      + "\(visibleTileIdentifiers()); search requests:\n\(describe(metadataRequests()))")

        // 6. Before any swipe: page 1 was fetched, page 2 was not.
        let before = waitForMetadata(timeout: 30) { requests in
            requests.contains { $0.albumIds == [self.albumId] }
        }
        XCTAssertFalse(before.contains(where: isPageTwo),
                       "page 2 was requested before the first scroll — search requests:\n\(describe(before))")
        XCTAssertFalse(tile(secondPageWitness).exists,
                       "assetTile_\(secondPageWitness) (page 2) is already on screen before any scroll")

        // 7. Scroll to the bottom: the last cell asks for page 2.
        let witness = scrollTo(id: "assetTile_\(secondPageWitness)", swipes: 25)
        XCTAssertTrue(witness.exists,
                      "assetTile_\(secondPageWitness) (page 2) never appeared after 25 swipes — tiles on screen: "
                      + "\(visibleTileIdentifiers()); search requests:\n\(describe(metadataRequests()))")

        // 8. On the wire: flat shape, page 2, the album's order.
        let requests = waitForMetadata(timeout: 10) { $0.contains(where: self.isPageTwo) }
        let pageTwo = requests.filter(isPageTwo)
        XCTAssertFalse(pageTwo.isEmpty,
                       "no POST /api/search/metadata carried page = 2 — search requests:\n\(describe(requests))")
        if let first = pageTwo.first {
            XCTAssertEqual(first.albumIds, [albumId],
                           "the page-2 request must target the album — search requests:\n\(describe(requests))")
            XCTAssertEqual(first.string("order"), "asc",
                           "the page-2 request must carry the album's order — search requests:\n\(describe(requests))")
        }
        for request in requests {
            XCTAssertTrue(request.structuredKeys.isEmpty,
                          "a search request carried \(request.structuredKeys) next to the flat fields — "
                          + "search requests:\n\(describe(requests))")
        }
    }

    // MARK: - The stub's own contract (no app launched)

    private let searchPath = "/api/search/metadata"

    private func searchBody(page: Any? = 1) -> [String: Any] {
        var body: [String: Any] = ["albumIds": [albumId], "size": 1000, "order": "asc"]
        if let page { body["page"] = page }
        return body
    }

    private func assetsPage(_ json: Any?) -> [String: Any]? { (json as? [String: Any])?["assets"] as? [String: Any] }

    private func itemIds(_ json: Any?) -> [String]? {
        (assetsPage(json)?["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    }

    private func intValue(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    func test_AC1_albumListServesOnePagedAlbum() {
        reset()
        let list = stubCall("GET", "/api/albums")
        let message = "GET /api/albums → status \(list.status ?? -1), json \(list.json ?? "nothing")"
        XCTAssertEqual(list.status, 200, message)
        let albums = list.json as? [[String: Any]]
        XCTAssertEqual(albums?.count, 1, message)
        guard let album = albums?.first else { return }
        XCTAssertEqual(album["order"] as? String, "asc", message)
        XCTAssertEqual(intValue(album["assetCount"]), 66, message)
        let required: Set<String> = ["id", "albumName", "description", "createdAt", "updatedAt",
                                     "albumThumbnailAssetId", "shared", "hasSharedLink",
                                     "assetCount", "isActivityEnabled", "order", "albumUsers"]
        XCTAssertTrue(required.isSubset(of: Set(album.keys)),
                      "missing keys \(required.subtracting(album.keys)) — \(message)")
    }

    func test_AC2_albumDetailRouteServesTheAlbum() {
        reset()
        let list = (stubCall("GET", "/api/albums").json as? [[String: Any]])?.first
        let detail = stubCall("GET", "/api/albums/\(albumId)")
        let message = "GET /api/albums/\(albumId) → status \(detail.status ?? -1), json \(detail.json ?? "nothing")"
        XCTAssertEqual(detail.status, 200, message)
        guard let object = detail.json as? [String: Any] else {
            return XCTFail("the album detail must be an object, not an array — \(message)")
        }
        XCTAssertEqual(object["id"] as? String, list?["id"] as? String, message)
        XCTAssertEqual(object["albumName"] as? String, list?["albumName"] as? String, message)
        XCTAssertEqual(object["order"] as? String, list?["order"] as? String, message)
        XCTAssertEqual(intValue(object["assetCount"]), intValue(list?["assetCount"]), message)
        XCTAssertNotNil(intValue(object["assetCount"]), message)

        let unknown = stubCall("GET", "/api/albums/00000000-0000-4000-8000-000000000000")
        XCTAssertEqual(unknown.status, 404, "an unknown album must be a 404, got \(unknown.status ?? -1)")
    }

    func test_AC3_firstPageAnnouncesPageTwo() {
        reset()
        var answers: [[String]] = []
        for body in [searchBody(page: 1), searchBody(page: nil)] {
            let response = stubCall("POST", searchPath, json: body)
            let message = "POST \(searchPath) \(body) → status \(response.status ?? -1), json \(response.json ?? "nothing")"
            XCTAssertEqual(response.status, 200, message)
            let ids = itemIds(response.json) ?? []
            XCTAssertEqual(ids, firstPageIds, message)
            XCTAssertEqual(ids.last, lastFirstPageId, message)
            XCTAssertEqual(intValue(assetsPage(response.json)?["count"]), 60, message)
            XCTAssertEqual(assetsPage(response.json)?["nextPage"] as? String, "2", message)
            answers.append(ids)
        }
        XCTAssertEqual(answers.first, answers.last, "page 1 with and without `page` must be the same assets")
    }

    func test_AC4_secondPageIsLastAndDisjoint() {
        reset()
        let first = itemIds(stubCall("POST", searchPath, json: searchBody(page: 1)).json) ?? []

        let two = stubCall("POST", searchPath, json: searchBody(page: 2))
        let twoMessage = "page 2 → status \(two.status ?? -1), json \(two.json ?? "nothing")"
        let twoIds = itemIds(two.json) ?? []
        XCTAssertEqual(twoIds, secondPageIds, twoMessage)
        XCTAssertTrue(Set(twoIds).isDisjoint(with: first), "page 2 repeats a page-1 id — \(twoMessage)")
        XCTAssertTrue(assetsPage(two.json)?["nextPage"] is NSNull, twoMessage)

        let three = stubCall("POST", searchPath, json: searchBody(page: 3))
        let threeMessage = "page 3 → status \(three.status ?? -1), json \(three.json ?? "nothing")"
        XCTAssertEqual(itemIds(three.json), [], threeMessage)
        XCTAssertTrue(assetsPage(three.json)?["nextPage"] is NSNull, threeMessage)

        let asString = stubCall("POST", searchPath, json: searchBody(page: "2"))
        XCTAssertEqual(itemIds(asString.json), [],
                       "`page` as a string must not be served as a page — json \(asString.json ?? "nothing")")
    }

    func test_AC5_searchBodiesAreLoggedVerbatim() {
        reset()
        _ = stubCall("POST", searchPath, json: searchBody(page: 2))
        guard let logged = stubRequests().last(where: { $0.method == "POST" && $0.path == searchPath }) else {
            return XCTFail("the stub's log has no POST \(searchPath)")
        }
        let message = "logged body: \(logged.bodyJSON)"
        XCTAssertEqual(logged.albumIds, [albumId], message)
        XCTAssertTrue(isJSONInt(logged.body["page"], 2), message)
        XCTAssertEqual(logged.string("order"), "asc", message)
        XCTAssertTrue(isJSONInt(logged.body["size"], 1000), message)
    }

    func test_AC14_serverIsV32AndRejectsMixedBody() {
        reset()
        let version = stubCall("GET", "/api/server/version")
        let versionJSON = version.json as? [String: Any]
        XCTAssertEqual(intValue(versionJSON?["major"]), 3, "version → \(version.json ?? "nothing")")
        XCTAssertEqual(intValue(versionJSON?["minor"]), 2, "version → \(version.json ?? "nothing")")

        let mixed = stubCall("POST", searchPath,
                             json: ["albumIds": [albumId], "page": 1, "filter": ["isFavorite": ["eq": true]]])
        let mixedJSON = mixed.json as? [String: Any]
        let mixedMessage = "mixed body → status \(mixed.status ?? -1), json \(mixed.json ?? "nothing")"
        XCTAssertEqual(mixed.status, 400, mixedMessage)
        XCTAssertEqual(intValue(mixedJSON?["statusCode"]), 400, mixedMessage)
        XCTAssertNil(mixedJSON?["assets"], mixedMessage)

        let structured = stubCall("POST", searchPath,
                                  json: ["albumIds": [albumId], "filter": ["isFavorite": ["eq": true]]])
        XCTAssertEqual(structured.status, 200, "structured body → status \(structured.status ?? -1)")
        XCTAssertEqual(itemIds(structured.json), [],
                       "a structured body must get an empty page — json \(structured.json ?? "nothing")")

        let unscoped = stubCall("POST", searchPath, json: ["page": 1, "size": 1000])
        XCTAssertEqual(unscoped.status, 200, "unscoped body → status \(unscoped.status ?? -1)")
        XCTAssertEqual(itemIds(unscoped.json), [],
                       "a body without albumIds must get an empty page — json \(unscoped.json ?? "nothing")")
    }

    // MARK: - Helpers
    //
    // Copied from `SearchFiltersUITests` / `AlbumSyncUITests` /
    // `FavoritesFilterUITests` on purpose: they are `private` there, and the
    // repository's rule is one file per feature, helpers included — no shared
    // UI-test support file.

    private struct StubUnreachable: Error, CustomStringConvertible {
        let url: String
        var description: String {
            "Local Immich stub not running on \(url) — a skipped or unreachable run is a failure"
        }
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// One GET against the stub, with a bounded wait: nil means it never
    /// answered (and the caller fails with the reason it asked).
    private func stubGET(_ path: String, timeout: TimeInterval = 10) -> String? {
        guard let url = URL(string: "\(stub)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let done = DispatchSemaphore(value: 0)
        var body: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else { return nil }
        return body
    }

    /// One request against the stub with an optional JSON body. `(nil, nil)`
    /// means it never answered; `json` is nil when the body is not JSON.
    private func stubCall(_ method: String, _ path: String, json: [String: Any]? = nil,
                          timeout: TimeInterval = 10) -> (status: Int?, json: Any?) {
        guard let url = URL(string: "\(stub)\(path)") else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        var payload: Any?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if let data { payload = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else { return (nil, nil) }
        return (status, payload)
    }

    /// True only for a JSON number equal to `expected`: `"2"` and `true` are not.
    private func isJSONInt(_ value: Any?, _ expected: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(expected)
    }

    /// Puts the stub back to its initial state and empties the request log, so
    /// no assertion below can be satisfied by a previous run.
    private func reset() {
        let body = stubGET("/__reset")
        XCTAssertEqual(body?.contains("\"reset\"") ?? false, true,
                       "the stub did not answer /__reset (got \(body ?? "nothing"))")
    }

    /// `manual` = the provider page waits for a click; `auto` = it redirects
    /// itself. This scenario clicks.
    private func setProvider(_ mode: String) {
        let body = stubGET("/__provider?mode=\(mode)")
        XCTAssertEqual(body, "{\"provider\": \"\(mode)\"}", "Stub did not answer /__provider")
    }

    /// Waits for any button whose label contains `text` and taps it. Case
    /// sensitive on purpose: the keyboard's return key is labelled "continuer"
    /// in lowercase and would shadow the "Continuer" CTA.
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

    /// The onboarding copy is localized, and the repo's own simulator is in
    /// German while the runs use English slots: a walk accepts both, never one
    /// hard-coded language.
    private func labelPredicate(_ labels: [String]) -> NSPredicate {
        NSPredicate(format: labels.map { _ in "label CONTAINS %@" }.joined(separator: " OR "),
                    argumentArray: labels)
    }

    private func waitForStaticText(_ labels: [String], timeout: TimeInterval) -> Bool {
        app.staticTexts.matching(labelPredicate(labels)).firstMatch.waitForExistence(timeout: timeout)
    }

    /// The two screens a launch can open on. Named rather than boolean so a
    /// third state ("neither", a launch that never got anywhere) cannot be
    /// mistaken for a pass.
    private enum Launch: Equatable { case welcome, shell, neither }

    private func welcomeOrShell() -> Launch {
        let shell = app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"])).firstMatch
        if shell.exists { return .shell }
        if app.staticTexts.matching(labelPredicate(["Your photo library", "Votre photothèque"])).firstMatch.exists {
            return .welcome
        }
        return .neither
    }

    /// Polls until `probe` stops saying `neither`, or the budget runs out.
    private func waitForEither(timeout: TimeInterval, _ probe: () -> Launch) -> Launch {
        let deadline = Date().addingTimeInterval(timeout)
        var state = probe()
        while state == .neither && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            state = probe()
        }
        return state
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
        // flow never leaves this screen. Scrolling dismisses the keyboard, so
        // the CTA is really hittable when it is tapped, and a bounded retry
        // covers the frame the keyboard was still animating over.
        let loginCopy = ["Sign in to Immich", "Connectez-vous à Immich"]
        var onLogin = false
        for _ in 0..<3 where !onLogin {
            app.swipeUp()
            XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
            onLogin = waitForStaticText(loginCopy, timeout: 10)
        }
        if !onLogin {
            shot("s90b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// Launch → the authenticated shell, whatever state the device is in.
    private func reachAuthenticatedShell() {
        app.launch()
        // Whichever comes first: a device without a session shows the welcome,
        // a relaunch over the Keychain's session opens on the shell directly.
        if waitForEither(timeout: 30, welcomeOrShell) == .welcome {
            shot("s01-welcome")
            walkOnboardingToLogin()
            shot("s02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30),
                      "the authenticated shell never appeared — screen reads: "
                      + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")

        // The app must be talking to THIS stub: a session persisted against
        // another slot's port restores the shell just as happily.
        XCTAssertFalse(stubRequests().isEmpty,
                       "the app has sent \(stub) nothing — a session restored from another slot's port?")

        // A fresh install presents "What's New" over the shell, and a modal
        // swallows every tap: the Albums tab would never be reachable under it.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("s03-whats-new")
            whatsNewDone.tap()
        }
    }

    /// An element of the grid, scrolled into view by swiping up until it exists.
    private func scrollTo(id: String, downwards: Bool = true, swipes: Int = 8) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<swipes where !element.exists {
            if downwards { app.swipeUp() } else { app.swipeDown() }
            sleep(1)
        }
        return element
    }

    private func tile(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "assetTile_\(assetId)").firstMatch
    }

    private func visibleTileIdentifiers() -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'assetTile_'"))
            .allElementsBoundByIndex.map(\.identifier)
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log. `body` is kept as raw JSON on
    /// purpose: the whole scenario is about WHICH KEYS a body carries, and a
    /// typed DTO would silently drop the very key an assertion is about.
    private struct StubRequest {
        let method: String
        let path: String
        let params: [String: String]
        let body: [String: Any]

        var bodyJSON: String {
            let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        func string(_ key: String) -> String? { body[key] as? String }
        var albumIds: [String]? { body["albumIds"] as? [String] }
        /// The structured-shape keys this body carries: none is ever expected.
        var structuredKeys: [String] { ["filter", "orderBy", "cursor"].filter { body[$0] != nil } }
    }

    private func isPageTwo(_ request: StubRequest) -> Bool { isJSONInt(request.body["page"], 2) }

    private func stubRequests() -> [StubRequest] {
        guard let raw = stubGET("/__requests") else {
            XCTFail("stub did not answer /__requests")
            return []
        }
        guard let entries = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
            XCTFail("the stub's request log is not JSON — got: \(raw.prefix(400))")
            return []
        }
        return entries.map { entry in
            StubRequest(method: entry["method"] as? String ?? "",
                        path: entry["path"] as? String ?? "",
                        params: (entry["params"] as? [String: String]) ?? [:],
                        body: (entry["body"] as? [String: Any]) ?? [:])
        }
    }

    /// Every `POST /api/search/metadata` the app sent, in order.
    private func metadataRequests() -> [StubRequest] {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/search/metadata" }
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.isEmpty ? "(none)" : requests.map { "\($0.method) \($0.path) body=\($0.bodyJSON)" }
            .joined(separator: "\n")
    }

    /// Polls the stub's log until `condition` holds, never sleeping past the
    /// budget: what is awaited here is a server round-trip, not a fixed delay.
    private func waitForMetadata(timeout: TimeInterval = 40,
                                 _ condition: ([StubRequest]) -> Bool) -> [StubRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var requests = metadataRequests()
        while !condition(requests) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            requests = metadataRequests()
        }
        return requests
    }
}
