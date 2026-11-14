import XCTest

/// End-to-end scenario for the album mirror (gap G2) — the one-way
/// device-album → server-album sync `BackupEngine` drives during a backup run,
/// plus its catch-up action "Reorganize into album".
///
/// WHAT THE CARD PROMISES, AND WHAT THIS SCENARIO CAN REACH
///
/// The mirror's whole observable effect is a request to `/api/albums` (the list
/// and the create) or to `/api/albums/{id}/assets` (the write that files an
/// asset into it). Both are driven by ONE setting: `BackupSettings
/// .syncedAlbumIDs`, filled from the "Mirror into albums" picker. The reachable
/// half in a simulator is the OFF half, and it is the one that protects an
/// existing user — default empty, no behaviour change:
///
///  1. the Backup screen's Albums section carries the mirror row, and with
///     nothing chosen it says "None" (the explicit empty selection);
///  2. the mirror picker opens and shows its EMPTY STATE in words — a blank
///     `List` would read as a loading failure. (Smart albums are filtered out
///     at the call site: the resolution ignores them, so offering them would be
///     a setting with no effect. This scenario also shows the SAME library HAS
///     an album — the seeded video's smart album — which is what makes the
///     empty mirror picker an exclusion rather than a broken enumeration: the
///     scope picker, built from the same `vm.albums`, lists it.)
///  3. a FULL backup run, which really talks to the server (a dedup
///     `bulk-upload-check` and an upload per accepted asset) and really fills
///     the ledger, never touches the album API. `GET /api/albums` is not "not
///     called yet" — it is not called by a run that had every opportunity to;
///  4. "Reorganize into album" — the catch-up that recovers a ledger's server
///     ids with a `bulk-upload-check` and then writes them into the mirrored
///     albums — is guarded by `canReorganize`. After that run the ledger half
///     is satisfied on the wire and the button is STILL disabled: the album
///     half is what blocks it, so the catch-up cannot fire without a mirrored
///     album.
///
/// WHAT IS OUT OF REACH, AND SAID PLAINLY
///
/// The ON half needs a device album in `PHAssetCollection.fetchAssetCollections
/// (with: .album, ...)` — a USER album. A simulator cannot be given one: `simctl
/// addmedia` fills the camera roll (and its smart albums), never a user album,
/// and neither the app nor any command in this harness can create one. So the
/// path "an album is picked → the mirror lists/creates server albums → the run
/// files each uploaded asset", and with it the positive `GET /api/albums`, stays
/// a MANUAL check on a device with a real album. Faking it (writing
/// `photoBackupSyncedAlbums` by hand, or a stub album for an id Photos does not
/// have) would prove nothing: the resolution matches on device ids the engine
/// reads from Photos, so a fabricated selection resolves to an empty map and the
/// assertion would pass without the feature.
///
/// THE ONE `Sources/` CHANGE THIS BRANCH CARRIES
///
/// `AlbumPickerView` (in `Sources/Features/Upload/UploadViewModel.swift`) drew a
/// blank `List` when it had no album to offer — the mirror picker on a library
/// with no user album, which is every simulator run AND a real user's first
/// launch. It now has an explicit empty state carrying the identifier
/// `albumPickerEmptyState`, which is what step 2 asserts. Additive: with albums
/// the screen is the same `List` it always was, and the wording reuses the
/// catalogue's existing "No albums yet" key, so no translation was added.
///
/// HOW TO RUN IT (all three options are required)
///
///     cp "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/BentoGalleryIntroduction-RTL.mov" \
///        /tmp/immich-orchestration/media/album-sync-clip.mov
///     python3 - <<'EOF'
///     import zlib, struct
///     w = h = 16
///     raw = b"".join(b"\x00" + bytes((200, 30, 30)) * w for _ in range(h))
///     def chunk(t, d):
///         c = t + d
///         return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
///     open("/tmp/immich-orchestration/media/album-sync-photo.png", "wb").write(
///         b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
///         + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
///     EOF
///     .omp/orchestration/uitest.sh <worktree> /tmp/immich-orchestration/album-sync.uitest.log \
///         UITests/stubs/immich_stub_album_sync.py AlbumSyncUITests/test_albumMirror \
///         --erase --media /tmp/immich-orchestration/media/album-sync-clip.mov \
///         --media /tmp/immich-orchestration/media/album-sync-photo.png
///
/// `--erase` is not optional: this scenario reads the LEDGER (the run must find
/// nothing already backed up, or the "Tracked photos" half of the guard would be
/// whatever a neighbour left there) and the first-launch state (a persisted
/// Keychain session would skip the onboarding walk). The video is not optional
/// either: it is what gives the slot's Photos library a non-empty smart album,
/// and the `Videos` row in the scope picker is the proof that the album list on
/// screen really comes from the device.
final class AlbumSyncUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // Localized titles of the surfaces this scenario touches that carry no
    // accessibility identifier. A `Form` row's label follows the simulator's
    // language, and after `--erase` a slot follows the HOST's (measured: French
    // on this machine, English on a fresh runner) — so every title is looked for
    // in several languages, never pinned to one. The identifier, not the label,
    // is what the assertions above prefer.
    private let mirrorRowValue = ["None", "Aucun album", "Kein Album", "Ninguno", "Nessuno"]
    private let scopeRowTitles = ["All albums", "Tous les albums", "Alle Alben"]
    private let selectedScopeTitles = ["Only selected albums", "Seulement les albums sélectionnés",
                                       "Nur ausgewählte Alben"]
    private let backUpRowTitles = ["Albums to back up", "Albums à sauvegarder", "Alben für das Backup"]
    /// The smart album the seeded video lands in. Photos names it in the
    /// system's language, so the substring is checked in every one of them:
    /// "Videos" (en/de/it), "Vidéos" (fr), "Vídeos" (es).
    private let videoAlbumTitles = ["Video", "Vidéo", "Vídeo"]
    private let backupCompleteTitles = ["Backup complete", "Finished with errors",
                                        "Sauvegarde terminée", "Backup abgeschlossen"]
    /// The Photos question's "full access" answer, matched as a SUBSTRING and
    /// WITHOUT the apostrophe: the system's French label is "Autoriser l’accès
    /// complet" with a typographic ’ (U+2019), so a literal "l'accès" with an
    /// ASCII quote matches nothing — measured, it cost one run, and the alert
    /// came with exactly three answers: "Limiter l’accès…", "Autoriser l’accès
    /// complet", "Ajout uniquement".
    private let photoFullAccessTitles = ["Access to All Photos", "Full Access", "Allow Full",
                                         "accès complet", "Accès à toutes les photos",
                                         "Zugriff auf alle Fotos", "Voller Zugriff"]
    /// The answers that would leave the library unreadable, and with it every
    /// assertion below.
    private let photoRefusedTitles = ["Limiter", "Limit Access", "Add Only", "Ajout uniquement",
                                      "Nur hinzufügen", "Don't Allow", "Do Not Allow",
                                      "Ne pas autoriser", "Nicht erlauben"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // XCUITest answers an unexpected system alert with its FIRST button, and
        // on the Photos question that one is "Ajout uniquement" (Add Only) — a
        // library the app cannot read, which would quietly turn every assertion
        // below into a statement about an empty one. This monitor runs before
        // that default handler and grants FULL access instead. It is
        // deliberately NOT load-bearing: the launcher installs the app and
        // grants Photos before the test starts (so the question normally never
        // comes), and nothing here asserts that it did. The labels are tried in
        // every language a slot can be in, host language included.
        addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            let button = alert.buttons.matching(self.labelPredicate(self.photoFullAccessTitles)).firstMatch
            if button.exists {
                button.tap()
                return true
            }
            return false
        }
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
    // Copied from `ImmichRenderScreenshots` / `RecentlyTakenUITests` on purpose:
    // these are `private` there, and the shared file is frozen (11 committed
    // scenarios are green against its current text). Extracting them into a
    // shared support file would be a second convention next to the existing one
    // — the harness rule is one file per feature, helpers included.

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
    }

    /// Puts the stub back to its initial state and empties its request log, so
    /// no assertion below can be satisfied by a previous run.
    private func reset() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
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

    /// The Photos access question — the one alert that decides whether
    /// ANYTHING below works. iOS asks it on the app's first READ of the library,
    /// which here is `loadAlbums()` as the Backup screen appears, and its
    /// answers are not equivalent: "Limiter l'accès…" and "Ajout uniquement"
    /// both leave the library unreadable, so the album list stays empty and
    /// `ensurePhotoAccess()` refuses the run. Worse, XCUITest's own alert
    /// handling clicks the FIRST button of an unexpected alert (measured by the
    /// free-up-space scenario: "Ajout uniquement" on this host), so the
    /// scenario answers the question itself, before any other query can hand it
    /// over. A refused question is not a soft failure: it is a red.
    @discardableResult
    private func allowPhotoAccessIfAsked(timeout: TimeInterval = 3) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let fullAccess = labelPredicate(photoFullAccessTitles)
        // The answers that would silently turn every assertion below into a
        // statement about a library the app cannot read.
        let refused = photoRefusedTitles
        for host in [springboard.alerts, app.alerts] {
            guard host.firstMatch.waitForExistence(timeout: timeout) else { continue }
            let grant = host.buttons.matching(fullAccess).firstMatch
            if grant.exists {
                grant.tap()
                return true
            }
            let offered = host.buttons.allElementsBoundByIndex.map(\.label)
            if offered.contains(where: { label in
                refused.contains { label.localizedCaseInsensitiveContains($0) }
            }) {
                shot("a00b-photo-access-unanswerable")
                XCTFail("iOS asked for Photos access and offered no way to grant full access "
                        + "(\(offered)) — the album list and the run below would both be about a "
                        + "library this app cannot read")
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
            shot("a02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: \(screenTexts())")
        }
    }

    /// A row of the "Me" hub, by IDENTIFIER (its label is localized). A `Form`
    /// only publishes what it rendered, so the row is scrolled into view first,
    /// letting each swipe settle.
    private func hubRow(_ identifier: String) -> XCUIElement {
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    /// A row of the Backup screen's `Form`, scrolled into view. `downwards`
    /// picks the direction: the screen is entered at its top, and a run only
    /// ever moves further down the form, but re-reading a row ABOVE the current
    /// position (the reorganize button after the run pushed it off screen) needs
    /// the opposite swipe.
    private func scrollTo(id: String, downwards: Bool = true, swipes: Int = 8) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<swipes where !element.exists {
            if downwards { app.swipeUp() } else { app.swipeDown() }
            sleep(1)
        }
        return element
    }

    /// Returns to the previous screen. Written as a loop over every navigation
    /// bar, most recently added first, because the tree can hold more than the
    /// hub's bar: measured by the sync-badge scenario, inside the "Me" sheet
    /// `app.navigationBars.firstMatch` can be the COVERED timeline's bar, so a
    /// plain "tap the first bar's first button" taps the timeline's "Select"
    /// instead and leaves the scenario debugging a ghost.
    private func goBack() {
        for bar in app.navigationBars.allElementsBoundByIndex.reversed() {
            let back = bar.buttons.firstMatch
            if back.exists && back.isHittable {
                back.tap()
                sleep(1)
                return
            }
        }
        app.swipeRight() // the same gesture the OS offers on its own
        sleep(1)
    }

    /// An album row (or any leaf carrying one of `labels`) — searched over
    /// buttons, cells and static texts, never over containers: a container's
    /// aggregated label would match text that is not on screen as a row.
    ///
    /// It takes every localization of the text, not one: a menu-style `Picker`
    /// publishes its SELECTED VALUE as its own static text ("Tous les albums"
    /// on the repo host's French simulator, "All albums" on an English one), so
    /// matching the English string alone finds nothing — measured, it cost a
    /// run.
    private func rowContaining(_ labels: [String], timeout: TimeInterval = 15) -> XCUIElement {
        let predicate = labelPredicate(labels)
        let candidates = [app.buttons.matching(predicate).firstMatch,
                          app.cells.matching(predicate).firstMatch,
                          app.staticTexts.matching(predicate).firstMatch]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for candidate in candidates where candidate.exists { return candidate }
            usleep(500_000)
        } while Date() < deadline
        return candidates[0]
    }

    /// The same, scrolled into view. A `Form` renders only what it is about to
    /// show, so a row just below the fold does not exist for XCUITest until the
    /// form is scrolled — measured on "Albums to back up", which sits directly
    /// under the scope picker and still was not published while the picker's own
    /// value was. That row carries no identifier (it belongs to the album-scope
    /// work, not to this scenario's surface), so it is found by title.
    private func scrollToRow(_ labels: [String], downwards: Bool = true, swipes: Int = 6) -> XCUIElement {
        var found = rowContaining(labels, timeout: 1)
        for _ in 0..<swipes where !found.exists {
            if downwards { app.swipeUp() } else { app.swipeDown() }
            sleep(1)
            found = rowContaining(labels, timeout: 1)
        }
        return found
    }

    /// Every static text on screen, for a failure message that says what the app
    /// actually showed instead of only what was expected.
    private func screenTexts() -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    // MARK: - Wire helpers

    /// One entry of the stub's request log.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let params: [String: String]
        /// Set by the stub's `bulk-upload-check` route: the device ids it was
        /// asked about. A dedup pass that carried no id would mean the run
        /// checked nothing, which would make the silence below meaningless.
        let ids: [String]?
    }

    private func stubRequests() -> [StubRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 20
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([StubRequest].self, from: Data(body.utf8))) ?? []
    }

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    /// The mirror's ONLY visible effect: the server album list, the create, and
    /// the write that files assets into an album. A mirror that is off must
    /// leave this list empty — for the whole run, not just until the first
    /// upload.
    private func albumRequests(in requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.path == "/api/albums" || $0.path.hasPrefix("/api/albums/") }
    }

    private func assertNoAlbumRequest(_ stage: String) {
        let albums = albumRequests(in: stubRequests())
        XCTAssertTrue(albums.isEmpty,
                      "the album API is the mirror's only effect on the wire and no album is "
                      + "selected as mirrored (\(stage)) — got:\n\(describe(albums))")
    }

    private func dedupChecks(in requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/assets/bulk-upload-check" }
    }

    private func uploads(in requests: [StubRequest]) -> [StubRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/assets" }
    }

    // MARK: - Scenario

    func test_albumMirror() throws {
        reset()
        setProvider("manual")
        app.launch()

        // MARK: Onboarding → OAuth

        // A persisted Keychain session skips the walk instead of failing, so a
        // re-running on a warm slot stays useful; the launcher's refusal of
        // `skipped` only concerns the stub being absent.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("a01-welcome")
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("a02-whats-new")
            whatsNewDone.tap()
        }

        // MARK: The "Me" hub → Backup

        let hub = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(hub.waitForExistence(timeout: 20), "Profile avatar missing")
        hub.tap()
        sleep(4)

        let backupRow = hubRow("backupRow")
        if !backupRow.waitForExistence(timeout: 10) {
            shot("a03b-me-hub-without-backup-row")
            XCTFail("the Backup row (identifier backupRow) is missing in the Me hub:\n\(screenTexts())")
        }
        shot("a03-me-hub")
        backupRow.tap()

        // The Backup screen's first act is `loadAlbums()`, i.e. the app's first
        // READ of the photo library — and that is where iOS asks its access
        // question. Answering it here is answered BEFORE the screen's own
        // queries, or XCUITest's alert handling clicks the wrong button.
        allowPhotoAccessIfAsked(timeout: 4)

        // `autoBackupToggle` is the Backup form's first control: the anchor that
        // says this screen — and not the hub it was pushed from — is up.
        let autoBackup = app.descendants(matching: .any).matching(identifier: "autoBackupToggle").firstMatch
        if !autoBackup.waitForExistence(timeout: 25) {
            shot("a04b-backup-screen-not-loaded")
            XCTFail("the Backup screen never loaded:\n\(screenTexts())\n\(app.debugDescription.prefix(4000))")
        }
        allowPhotoAccessIfAsked(timeout: 3)
        shot("a04-backup-screen")

        // MARK: The device album list, read with access actually granted

        // `loadAlbums()` is the screen's `.task` and it ran WHILE the access
        // question was up, so `vm.albums` — the list both pickers are built
        // from — holds whatever the library answered then (an empty list: a
        // read before the answer sees nothing). Leaving and re-entering is what
        // makes the screen read the library again, now that the app may read it.
        // Without this step the empty mirror picker below would be
        // indistinguishable from a list that was never loaded.
        goBack()
        if !app.buttons.matching(identifier: "backupRow").firstMatch.waitForExistence(timeout: 10) {
            shot("a05b-stuck-on-backup-screen")
            XCTFail("no way back from the Backup screen to the Me hub, so the album list cannot be "
                    + "re-read after the access answer:\n\(screenTexts())")
        }
        hubRow("backupRow").tap()
        if !app.descendants(matching: .any).matching(identifier: "autoBackupToggle")
            .firstMatch.waitForExistence(timeout: 25) {
            shot("a05c-backup-screen-not-reloaded")
            XCTFail("the Backup screen did not come back after the hub:\n\(screenTexts())")
        }
        allowPhotoAccessIfAsked(timeout: 3)
        shot("a05-backup-screen-reread")

        // The same `vm.albums` feeds both pickers, so this half is what stops
        // the empty mirror picker below from being an enumeration that returns
        // nothing at all: the seeded video gives the slot's Photos library a
        // non-empty `Videos` smart album, and the scope picker lists it.
        let scopeRow = rowContaining(scopeRowTitles)
        if !scopeRow.waitForExistence(timeout: 15) {
            shot("a06b-scope-picker-missing")
            XCTFail("the Albums section's scope picker is not on screen:\n\(screenTexts())")
        }
        var pickedScope = false
        for _ in 0..<2 where !pickedScope {
            scopeRow.tap()
            pickedScope = tapAnyButton(selectedScopeTitles, timeout: 12)
        }
        if !pickedScope {
            shot("a06c-scope-menu-missing")
            XCTFail("the scope picker opened no menu offering \"Only selected albums\":\n\(screenTexts())")
        }
        let backUpRow = scrollToRow(backUpRowTitles)
        if !backUpRow.exists {
            shot("a06d-back-up-row-missing")
            XCTFail("picking \"Only selected albums\" did not reveal the album picker row:\n\(screenTexts())")
        }
        backUpRow.tap()

        let videoAlbum = rowContaining(videoAlbumTitles)
        if !videoAlbum.waitForExistence(timeout: 20) {
            shot("a07b-device-albums-empty")
            XCTFail("the seeded video's smart album is not listed: either the slot's Photos library "
                    + "was not seeded (--media .../album-sync-clip.mov), or the app was not granted "
                    + "read access, or the album list does not come from the device. Screen reads:\n"
                    + screenTexts())
        }
        shot("a07-device-albums-listed")

        goBack() // → the Backup screen

        // MARK: The mirror row — the empty selection is explicit

        let mirrorRow = scrollTo(id: "backupMirrorAlbumsRow")
        if !mirrorRow.exists {
            shot("a08b-mirror-row-missing")
            XCTFail("the Albums section carries no \"Mirror into albums\" row "
                    + "(identifier backupMirrorAlbumsRow):\n\(screenTexts())")
        }
        // The value is `albumCount(_:_:)`'s English "None" (the `LabeledContent`
        // value is a plain `String`, never a `LocalizedStringKey`), but the
        // catalogue carries translations of the same word, so every language is
        // accepted rather than one pinned.
        XCTAssertTrue(mirrorRowValue.contains { mirrorRow.label.contains($0) },
                      "nothing is mirrored, so the row must say \"None\" — it reads "
                      + "\"\(mirrorRow.label)\":\n\(screenTexts())")
        shot("a08-albums-section")

        // Nothing has asked for a server album yet — not even the screen that
        // offers them.
        assertNoAlbumRequest("the Backup screen and the device album picker")

        // MARK: The mirror picker — an EXPLICIT empty state, and no smart album

        mirrorRow.tap()
        let emptyState = app.descendants(matching: .any)
            .matching(identifier: "albumPickerEmptyState").firstMatch
        if !emptyState.waitForExistence(timeout: 15) {
            shot("a09b-mirror-picker-without-empty-state")
            XCTFail("the mirror picker drew no empty state — a blank List reads as a loading "
                    + "failure, not as \"your library has no album\". Screen reads:\n\(screenTexts())")
        }
        // The library HAS an album (the video, listed by the scope picker a
        // moment ago) and the mirror picker must not offer it: smart albums are
        // excluded at the call site, and a resolution that ignores them would
        // make the option a setting with no effect.
        XCTAssertFalse(rowContaining(videoAlbumTitles, timeout: 2).exists,
                       "a smart album is offered as a mirror target — the resolution ignores them:"
                       + "\n\(screenTexts())")
        shot("a09-mirror-picker-empty")
        assertNoAlbumRequest("the mirror's own picker")

        goBack() // → the Backup screen

        // MARK: The catch-up button exists, and its guard holds

        let reorganize = scrollTo(id: "backupReorganizeButton")
        if !reorganize.exists {
            shot("a10b-reorganize-button-missing")
            XCTFail("the \"Album mirror\" section carries no reorganize button "
                    + "(identifier backupReorganizeButton):\n\(screenTexts())")
        }
        XCTAssertFalse(reorganize.isEnabled,
                       "\"Reorganize into album\" is live with no album mirrored (nothing to file into):\n"
                       + screenTexts())
        shot("a10-reorganize-disabled")

        // MARK: A real run — the mirror stays silent through all of it

        let runButton = scrollTo(id: "runBackupButton")
        if !runButton.exists {
            shot("a11b-run-button-missing")
            XCTFail("the Progress section carries no \"Run now\" button:\n\(screenTexts())")
        }
        XCTAssertTrue(runButton.isHittable,
                      "the \"Run now\" button exists but cannot be tapped where the form is scrolled to:"
                      + "\n\(screenTexts())")
        runButton.tap()

        // The run enters through `ensurePhotoAccess()`, so a Photos question can
        // still be raised here; the loop answers it while it waits. "Backup
        // complete" and "Finished with errors" are not the same claim, so they
        // are told apart instead of waited for as one.
        let errored = ["Finished with errors", "Terminé avec des erreurs", "Mit Fehlern beendet"]
        let deadline = Date().addingTimeInterval(240)
        var runFailed = false
        var runFinished = false
        while Date() < deadline && !runFinished && !runFailed {
            runFinished = waitForStaticText(backupCompleteTitles, timeout: 2)
            if !runFinished { runFailed = waitForStaticText(errored, timeout: 1) }
            if !runFinished && !runFailed { allowPhotoAccessIfAsked(timeout: 0.5) }
        }
        if !runFinished {
            shot("a11c-run-never-finished")
            XCTFail("the backup run " + (runFailed ? "finished with errors" : "never finished")
                    + " — the album assertions below would describe a run that did nothing. "
                    + "Screen reads:\n\(screenTexts())")
        }
        shot("a11-run-finished")

        // MARK: On the wire: the run really talked, and never about albums

        let after = stubRequests()
        let dedup = dedupChecks(in: after)
        let uploadsWritten = uploads(in: after)
        XCTAssertTrue(dedup.contains { !($0.ids ?? []).isEmpty },
                      "the run made no dedup pass carrying a device id — a run that scans nothing "
                      + "would leave the album API silent for the wrong reason:\n\(describe(after))")
        XCTAssertFalse(uploadsWritten.isEmpty,
                       "the run uploaded nothing: the ledger stays empty, so the disabled catch-up "
                       + "button below proves nothing about its album guard:\n\(describe(after))")
        assertNoAlbumRequest("a full backup run that uploaded \(uploadsWritten.count) asset(s) and "
                             + "filled the ledger")

        // The ledger now has entries (the uploads above are what writes them),
        // so `canReorganize`'s ledger half is satisfied — and its album half is
        // empty. The button must therefore still be disabled, which is what
        // keeps the catch-up from ever firing without a mirrored album.
        let reorganizeAfter = scrollTo(id: "backupReorganizeButton", downwards: false)
        XCTAssertTrue(reorganizeAfter.exists,
                      "the reorganize button vanished from the Backup screen after the run:\n\(screenTexts())")
        XCTAssertFalse(reorganizeAfter.isEnabled,
                       "\"Reorganize into album\" became live through the run: the ledger half of its "
                       + "guard was satisfied (uploads on the wire) and the album half is still empty, "
                       + "so this run must not have unlocked it:\n\(screenTexts())")
        shot("a12-reorganize-still-disabled")
    }
}
