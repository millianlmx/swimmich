import XCTest

/// End-to-end scenario for the download queue (gap G10) — the viewer's
/// "Download to Files", the floating panel, and the info screen.
///
/// It drives the real app: onboarding → SSO → the timeline → the viewer →
/// the share sheet → "Download to Files", and asserts BOTH what the screen
/// shows and what the app asked the server for. The two are equally
/// load-bearing: a panel that appears over a request the feature never sent,
/// or a row that reads "done" over an error response, is exactly the bug this
/// scenario exists to catch.
///
/// Run it with the launcher, never by hand (it owns the slot's simulator,
/// DerivedData and stub port, and refuses a scenario that skipped itself):
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/download-panel.uitest.log \
///         UITests/stubs/immich_stub_download_panel.py DownloadPanelUITests/test_downloadPanel
///
/// The stub inherits `immich_stub_base` (OAuth handshake, server config, user,
/// ordinary timeline, real PNG thumbnails, `/api/assets/{id}`, `/thumbnail`)
/// and overrides ONE route: `GET /api/assets/{id}/original`, served as a real
/// 77 KiB PNG in 16 chunks half a second apart (~10 s). That delay is the
/// scenario's clock — the panel only exists while a row is in flight, so a
/// transfer that completed in one frame could not be observed at all. See the
/// stub's docstring, including the `ORIGINAL_STATUS` lever the negative
/// control uses.
final class DownloadPanelUITests: XCTestCase {

    /// The stub's URL, as `uitest.sh` hands it over (it forwards
    /// `TEST_RUNNER_IMMICH_STUB_URL`). The fallback is the port a by-hand run
    /// starts under.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    /// The first photo of the shell's own day: the one the scenario downloads.
    private let target = "aaaaaaaa-1111-4111-8111-000000000001"
    /// The name the STUB gives that asset (`AssetResponseDto.originalFileName`),
    /// which is the whole point of the "Download to Files" path: the file is
    /// named like the server names it, not like the asset id the offline cache
    /// uses (`<assetId>.<ext>`). A row labelled with the id would be a bug this
    /// assertion catches.
    private let serverFileName = "aaaa-01.jpg"

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
    // and the shared scenario file is frozen. Extracting them into a shared
    // support file would be a second convention next to the existing one — the
    // harness rule is one file per feature, helpers included.

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

    /// Waits for any button whose label contains `text` and taps it.
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
            shot("d02b-not-on-login-screen")
            XCTFail("Login screen did not appear — screen reads: "
                    + "\(app.staticTexts.allElementsBoundByIndex.map(\.label))")
        }
    }

    /// Any element carrying `identifier`, whatever its type: `DownloadProgressPanel`
    /// merges itself into ONE accessibility element (so VoiceOver reads a single
    /// sentence), which is precisely why its type is not assumed here.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tile(_ assetId: String) -> XCUIElement {
        element("assetTile_\(assetId)")
    }

    /// Everything on screen, for a failure message. A scenario that fails with
    /// "the panel never appeared" and nothing else costs a whole re-run — and
    /// the progress indicators are listed for the same reason: whether a bar
    /// exists at all, and what it reads, is the difference between "the queue
    /// is not told about the bytes" and "there is no bar to read".
    private func screenDump() -> String {
        let bars = app.progressIndicators.allElementsBoundByIndex
            .map { "[\($0.identifier): \(String(describing: $0.value))]" }
        return "screen reads: \(app.staticTexts.allElementsBoundByIndex.map(\.label)) "
            + "buttons: \(app.buttons.allElementsBoundByIndex.map(\.identifier)) "
            + "bars: \(bars)"
    }

    /// Waits (bounded) for an element to leave the accessibility tree. The
    /// completion signal of the scenario: a row that stops offering `Cancel`
    /// has left `running`.
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// A determinate bar's value as a 0...100 percentage, or `nil` when it
    /// carries none (an indeterminate `ProgressView` reports no value).
    ///
    /// XCUITest surfaces a determinate bar as a localized percentage ("42 %"),
    /// which is why the number — never the sentence — is what this reads: the
    /// same rule as the info screen's "N of M" summary.
    private func percentage(_ bar: XCUIElement) -> Double? {
        guard let value = bar.value as? String else { return nil }
        if value.contains("%") {
            return value.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }.last
        }
        // No sign: a plain fraction (`0.42`) — normalized to the same scale.
        guard let fraction = Double(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return fraction <= 1 ? fraction * 100 : fraction
    }

    /// The bar's percentage once it has moved past `from`, or the last value
    /// seen before the deadline (never below `from`), so a caller can assert
    /// "it advanced" and print both ends.
    ///
    /// A bounded observation window, not a `sleep` waiting on a server result:
    /// the stub paces the original over ~24 s, so the window is what makes the
    /// movement observable at all.
    private func waitForProgress(_ bar: XCUIElement, beyond from: Double, timeout: TimeInterval) -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = percentage(bar) ?? from
        while seen <= from && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            seen = percentage(bar) ?? from
        }
        return seen
    }

    /// The integers of a label, in order. The info screen's summary is
    /// "N of M" ("N sur M", "N von M"…): only the digits read the same in every
    /// language, so the localization rule of this harness is honoured by
    /// comparing the numbers rather than the sentence.
    private func summaryCounts() -> [Int] {
        let label = app.staticTexts.matching(identifier: "downloadInfoSummary").firstMatch.label
        return label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The summary, once it reads `expected` — SwiftUI renders a frame behind
    /// the state change that flipped the row to `.completed`.
    private func settledSummary(_ expected: [Int], timeout: TimeInterval = 15) -> [Int] {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = summaryCounts()
        while seen != expected && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            seen = summaryCounts()
        }
        return seen
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

    private func describe(_ requests: [StubRequest]) -> String {
        requests.map { "\($0.method) \($0.path) params=\($0.params)" }.joined(separator: "\n")
    }

    // MARK: - Scenario

    func test_downloadPanel() throws {
        reset()
        setProvider("manual")
        app.launch()

        // Onboarding → OAuth. A persisted Keychain session skips the walk
        // instead of failing, so re-running on a warm slot stays useful.
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            shot("d01-welcome")
            walkOnboardingToLogin()
            shot("d02-login-sso")
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")

        // A fresh install presents "What's New" (gap G23) over the shell, and a
        // modal swallows every tap. Its Done button carries an identifier
        // because its label is translated.
        let whatsNewDone = app.buttons.matching(identifier: "whatsNewDoneButton").firstMatch
        if whatsNewDone.waitForExistence(timeout: 10) {
            shot("d03-whats-new")
            whatsNewDone.tap()
        }

        XCTAssertTrue(tile(target).waitForExistence(timeout: 30),
                      "the timeline never rendered the stub's first tile against \(stub); \(screenDump())")
        shot("d04-timeline")

        // MARK: The panel is CONDITIONAL, before anything is asked for
        //
        // Asserted first, and on purpose: a panel that is always on screen would
        // satisfy every later "the panel is there" assertion while telling the
        // user nothing about their queue.
        let panel = element("downloadPanel")
        XCTAssertFalse(panel.waitForExistence(timeout: 3),
                       "the download panel is on screen before a single download was asked for; \(screenDump())")

        // MARK: Viewer → "Download to Files"

        tile(target).tap()
        let share = app.buttons.matching(identifier: "viewerShareButton").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25),
                      "the viewer's bottom bar never appeared after tapping a tile; \(screenDump())")
        shot("d05-viewer")
        share.tap()

        let downloadToFiles = app.buttons.matching(identifier: "downloadToFilesButton").firstMatch
        XCTAssertTrue(downloadToFiles.waitForExistence(timeout: 25),
                      "'Download to Files' is missing from the viewer's share sheet; \(screenDump())")
        shot("d06-share-sheet")
        downloadToFiles.tap()

        // The sheet is closed immediately, and so is the viewer: the queue is
        // process-wide, and the panel is drawn by the root — which both the
        // sheet and the full-screen viewer sit ON TOP of. Backing out is what
        // makes the panel visible, and the transfer must still be running when
        // it reappears (that is the feature's claim: the file outlives the
        // surface that asked for it).
        let closeSheet = app.buttons.matching(identifier: "closeShareSheet").firstMatch
        XCTAssertTrue(closeSheet.waitForExistence(timeout: 15),
                      "the share sheet never offered its Close button; \(screenDump())")
        closeSheet.tap()

        let viewerBack = app.buttons.matching(identifier: "viewerBackButton").firstMatch
        XCTAssertTrue(viewerBack.waitForExistence(timeout: 20),
                      "the viewer did not come back after the share sheet closed; \(screenDump())")
        viewerBack.tap()

        XCTAssertTrue(panel.waitForExistence(timeout: 25),
                      "the download panel never appeared after 'Download to Files' and leaving the viewer "
                        + "— the transfer must keep running with the sheet that started it closed; \(screenDump())")
        shot("d07-panel")

        // MARK: The info screen, while the transfer RUNS
        //
        // Tapping the panel is the queue's only way in, and it is the panel's
        // whole action (a button nested in a button is inert).

        panel.tap()

        let row = element("downloadInfoRow_\(target)")
        XCTAssertTrue(row.waitForExistence(timeout: 25),
                      "the info screen does not list the queued asset; \(screenDump())")
        XCTAssertTrue(row.label.contains(serverFileName),
                      "the row is not named like the server names the file (\(serverFileName)) — it reads "
                        + "'\(row.label)'; a name derived from the asset id would mean the queue never asked "
                        + "the server for the asset")

        let cancel = app.buttons.matching(identifier: "downloadInfoCancel_\(target)").firstMatch
        let retry = app.buttons.matching(identifier: "downloadInfoRetry_\(target)").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15),
                      "the row is not offered a Cancel while its transfer runs; \(screenDump())")
        XCTAssertFalse(retry.exists, "the row offers a Retry while its transfer is still running")
        XCTAssertEqual(settledSummary([0, 1], timeout: 5), [0, 1],
                       "the info screen does not read '0 of 1' while the transfer runs; \(screenDump())")

        // MARK: The bar MOVES — the point of the transfer being slow
        //
        // The stub paces the original over ~24 s, so a bar that reads the same
        // fraction 15 s later is not "a bar that had no time to move": it is a
        // queue that never hears about the bytes. This is the assertion that
        // caught the transport's dead progress path (the async
        // `session.download(for:delegate:)` delivered no `didWriteData` at all,
        // so `receivedBytes` stayed 0 from the first byte to the last).

        let bar = app.progressIndicators.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15),
                      "the running row draws no progress bar at all; \(screenDump())")
        guard let start = percentage(bar) else {
            return XCTFail("the running row's progress bar reports no readable value "
                           + "(value: \(String(describing: bar.value))); \(screenDump())")
        }
        shot("d08-info-running")

        let moved = waitForProgress(bar, beyond: start, timeout: 15)
        XCTAssertGreaterThan(moved, start,
                             "the progress bar never advanced while the original streamed: it read "
                               + "\(Int(start))%% and, 15 s later, \(Int(moved))%% — the queue is not being "
                               + "told about the bytes that arrive; \(screenDump())")
        shot("d09-info-advancing")

        // MARK: The transfer ENDS, and the row is COMPLETED — not failed
        //
        // `Cancel` disappears exactly when the row leaves `running`; from there
        // the row carries Share (its file is on disk) and neither Cancel nor
        // Retry (`DownloadInfoView` offers Cancel while running, Retry when
        // failed or cancelled). `finish()` is the only path to `.completed` and
        // it throws before that unless the streamed body was moved to
        // `Documents/Downloads/`, so a completed row IS a written file — which
        // is what makes the failure leg of this scenario (stub
        // `ORIGINAL_STATUS = 500`) discriminate.
        XCTAssertTrue(waitForDisappearance(cancel, timeout: 90),
                      "the transfer never left 'running' (still offered a Cancel after 90 s); \(screenDump())")
        XCTAssertTrue(row.exists, "the completed row vanished from the info screen; \(screenDump())")
        let shareButton = app.buttons.matching(identifier: "downloadInfoShare_\(target)").firstMatch
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10),
                      "the row does not offer Share: only a row that is not completed, or whose file is not "
                        + "on disk, lacks it; \(screenDump())")
        XCTAssertTrue(shareButton.isHittable,
                      "Share exists but cannot be touched (absorbed by the row's combined element?); \(screenDump())")
        // `DownloadInfoView` draws Retry for a row that FAILED or was CANCELLED,
        // and Share for a completed one. The message therefore states
        // the observation, not what the stub was told to answer: it has to read
        // correctly both on the green run and on the 500 negative control.
        XCTAssertFalse(retry.exists,
                       "the row is NOT completed: the info screen offers it a Retry, which only a failed "
                        + "or cancelled row gets — a 200 whose body reached Documents/Downloads/ can only "
                        + "finish as completed, so either the transfer failed after streaming or the body "
                        + "never arrived; \(screenDump())")
        XCTAssertEqual(settledSummary([1, 1]), [1, 1],
                       "the info screen does not read '1 of 1' after the transfer ended; \(screenDump())")
        // `Clear completed` is enabled for finished AND cancelled rows, never
        // for a failed one: it is the second, independent discriminator between
        // the two terminal states the panel must never confuse.
        let clearCompleted = app.buttons.matching(identifier: "downloadInfoClearCompleted").firstMatch
        XCTAssertTrue(clearCompleted.isEnabled,
                      "'Clear completed' is disabled after a completed download; \(screenDump())")
        shot("d10-info-completed")

        // MARK: On the wire — ONE original, and no batch announcement

        let requests = stubRequests()
        let originals = requests.filter { $0.method == "GET" && $0.path == "/api/assets/\(target)/original" }
        XCTAssertEqual(originals.count, 1,
                       "the original must be asked for exactly ONCE for one download — got \(originals.count); "
                        + "the whole log was:\n\(describe(requests))")
        let batches = requests.filter { $0.path.contains("/download/") }
        XCTAssertTrue(batches.isEmpty,
                      "a ONE-asset download must go straight to /original, never through the batch route "
                        + "(POST /download/info is only for a selection of two or more) — got:\n\(describe(batches))")
        XCTAssertTrue(requests.contains { $0.method == "GET" && $0.path == "/api/assets/\(target)" },
                      "the queue never asked the server for the asset itself, so the file name and its "
                        + "announced size could only be invented — got:\n\(describe(requests))")

        // MARK: Sharing the written file — a local operation
        //
        // The sheet opens on `destinationURL` (the written file, possibly
        // suffixed `-2` by an earlier run on this simulator — the file name is
        // never compared here). The wire must stay silent: no asset or batch
        // request between the tap and the sheet (decision #7: background traffic
        // of the app is not counted).
        let before = stubRequests().count
        shareButton.tap()
        // [INFERENCE] iOS 26 may expose the sheet under another identifier: the
        // first run on a macOS host replaces this set with the one `screenDump()`
        // shows. The criterion stays "an element owned by the system sheet appears".
        let sheet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["ActivityListView", "UIActivityContentView"]))
            .firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15),
                      "tapping Share did not open the system share sheet; \(screenDump())")
        shot("d10b-share-sheet")
        let afterTap = Array(stubRequests().dropFirst(before))
        XCTAssertTrue(afterTap.filter { $0.path.contains("/api/assets/") || $0.path.contains("/download/") }.isEmpty,
                      "sharing a finished file went back to the server — got:\n\(describe(afterTap))")
        let dismissSheet = app.buttons.matching(labelPredicate(["Close", "Fermer", "Schließen", "Cerrar", "Chiudi"])).firstMatch
        if dismissSheet.exists {
            dismissSheet.tap()
        } else {
            sheet.swipeDown()
        }
        XCTAssertTrue(waitForDisappearance(sheet, timeout: 15),
                      "the share sheet did not close; \(screenDump())")

        // MARK: Clearing the finished row, then leaving the screen

        clearCompleted.tap()
        XCTAssertTrue(waitForDisappearance(row, timeout: 15),
                      "'Clear completed' left the completed row on screen; \(screenDump())")
        shot("d11-info-cleared")

        let done = app.buttons.matching(identifier: "downloadInfoDone").firstMatch
        XCTAssertTrue(done.exists, "'Done' is missing from the info screen's bar; \(screenDump())")
        done.tap()

        // Nothing is in flight any more, so the panel is gone: it followed the
        // queue rather than staying on screen as decoration.
        XCTAssertTrue(waitForDisappearance(panel, timeout: 15),
                      "the panel outlives the queue (it is still on screen after the last row was cleared); "
                        + "\(screenDump())")
        shot("d12-after")
    }
}
