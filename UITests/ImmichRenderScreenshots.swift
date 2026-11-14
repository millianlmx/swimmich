import XCTest

/// End-to-end UI verification for the OAuth/SSO flow — drives the real app
/// through onboarding and `ASWebAuthenticationSession` against a local Immich
/// API stub and writes screenshots to `/tmp`.
///
/// This is the only test that exercises the real browser session: it is the
/// regression guard for the 404 the flow used to hit on `/api/auth/oauth/*`
/// (the app never reached the authenticated shell). It needs the stub running:
///
///     python3 /tmp/immich_stub_modes.py 8421
///
/// Without it the tests skip, so the default scheme stays green.
final class ImmichRenderScreenshots: XCTestCase {

    /// Overridable so a run can point the app at a NON-loopback address:
    /// App Transport Security exempts loopback, so only a real LAN/HTTP server
    /// exercises the policy the widget extension has to satisfy.
    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    /// Probe used only to decide skip-vs-run; the assertions below make their
    /// own requests.
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

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/shot-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SHOT /tmp/shot-\(name).png")
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

    /// Puts the stacks stub back to its initial state (one 3-photo stack).
    /// Best-effort: the plain OAuth stub has no such route, and those tests
    /// never look at stacks.
    private func resetStacks() {
        var request = URLRequest(url: URL(string: "\(stub)/__reset")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Same route, but states the intent for the partner stub: restore one
    /// incoming partner, one outgoing partner and no invitation.
    private func resetPartners() {
        resetStacks()
    }

    /// Selects the Albums tab and returns the Library tile `identifier`, scrolling
    /// the Albums ScrollView only when the tile is not hittable. Matched by
    /// identifier: the labels are translated.
    private func openAlbumsLibraryRow(_ identifier: String, missingShot: String) -> XCUIElement {
        let albums = app.tabBars.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 15), "Albums tab missing")
        albums.tap()
        sleep(3)
        let row = app.buttons.matching(identifier: identifier).firstMatch
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        if !row.waitForExistence(timeout: 10) {
            shot(missingShot)
            XCTFail("\(identifier) tile missing in the Albums library:\n\(app.debugDescription)")
        }
        return row
    }

    /// Waits for any button whose label contains `text` and taps it.
    ///
    /// Case-sensitive on purpose: the software keyboard's return key is
    /// labelled "continuer" (lowercase) and would otherwise shadow the
    /// "Continuer" CTA.
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

    /// The onboarding and empty-state copy is localized (issue #21): the app
    /// now ships English source strings plus a French translation, so a walk
    /// accepts either, whatever language the simulator runs in.
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
        // Some iOS builds surface the consent alert inside the app's own tree.
        for label in ["Continue", "Continuer"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    /// Taps the provider's "Authorize" link. The OAuth page is presented by
    /// `ASWebAuthenticationSession` in the system's `SafariViewService`
    /// process, so it is invisible to the app's own accessibility tree.
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

    /// The app persists the OAuth session (Keychain token), so only a
    /// simulator without it can present the onboarding flow. Re-runs on a warm
    /// simulator skip the full browser walk instead of failing.
    ///
    ///     xcrun simctl erase <device>   # to re-arm the full walk
    private func requireCleanSession() throws {
        try XCTSkipUnless(
            waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 25),
            "A persisted OAuth session skips onboarding — erase the simulator to re-run the full walk"
        )
    }

    /// Welcome → server URL → login. Leaves the app on the login screen.
    private func walkOnboardingToLogin() {
        XCTAssertTrue(tapAnyButton(["Get Started", "Commencer"], timeout: 30), "Welcome CTA missing")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        // The stub URL may already be seeded in the app's defaults; retyping
        // would append and produce an invalid URL.
        if (field.value as? String) != stub {
            field.tap()
            field.typeText(stub)
        }
        XCTAssertTrue(tapAnyButton(["Check connection", "Vérifier la connexion"]), "Check-connection CTA missing")
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Continue", "Continuer"]))
            .firstMatch.waitForExistence(timeout: 30), "Server never became reachable")
        shot("02-server-reachable")
        XCTAssertTrue(tapAnyButton(["Continue", "Continuer"]), "Continue CTA missing")
        XCTAssertTrue(waitForStaticText(["Sign in to Immich", "Connectez-vous à Immich"], timeout: 20),
                      "Login screen did not appear")
        app.swipeUp() // dismisses the keyboard (.scrollDismissesKeyboard)
    }

    // MARK: - Scenarios

    func test_01_onboardingAndOAuthSignIn() throws {
        setProvider("manual")
        app.launch()
        try requireCleanSession()
        shot("01-welcome")
        walkOnboardingToLogin()
        shot("03-login-sso-visible")

        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        // The provider page lives in the system auth sheet (a separate
        // process), so the "Authorize" link is queried there, not in `app`.
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")

        // Callback → POST /api/oauth/callback → session applied → main shell.
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        sleep(4) // let the timeline load its first buckets
        shot("06-timeline-after-oauth")

        // "Me" is a sheet raised from the avatar button in every tab's bar.
        let profile = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 15), "Profile avatar missing")
        profile.tap()
        sleep(3)
        shot("07-profile-me")
    }

    func test_02_renderAuthorizedShellAfterRelaunch() {
        setProvider("auto")
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)
        shot("08-timeline-relaunch")

        app.tabBars.buttons["Albums"].firstMatch.tap()
        sleep(3)
        shot("09-albums")
    }

    /// Stacks (gap #1) against a stub that returns one 3-photo stack: the
    /// timeline tile must show the stack badge, tapping it must open the stack
    /// detail (the bucket carries only the cover), and the Albums tab's Library
    /// section must open the same stack.
    ///
    /// Needs the stacks stub, which also serves the timeline bucket:
    ///
    ///     python3 /tmp/immich_stub_stacks.py 8421
    func test_03_stacksBadgeDetailAndHub() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(5)
        shot("10-timeline")

        // 3 members → the cover advertises the 2 photos behind it.
        let badge = app.descendants(matching: .any).matching(identifier: "stackBadge").firstMatch
        for _ in 0..<4 where !badge.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(badge.waitForExistence(timeout: 20),
                      "stack badge missing on the cover tile (withStacked column not rendered)")
        shot("11-timeline-stack-badge")

        badge.tap()
        XCTAssertTrue(app.staticTexts["Cover"].waitForExistence(timeout: 15),
                      "tapping a stacked tile did not open the stack detail")
        sleep(2)
        shot("12-stack-detail")

        // Back out of the pushed detail (the timeline hides its bar in browse
        // mode, so this also proves the destination puts a back affordance up).
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        if back.waitForExistence(timeout: 5) {
            shot("13-stack-detail-back-button")
            back.tap()
        } else {
            app.swipeRight()
        }
        sleep(2)

        let stacksRow = openAlbumsLibraryRow("stacksRow", missingShot: "14b-albums-no-stacks-row")
        shot("14-albums-library")
        stacksRow.tap()
        sleep(3)
        shot("15-stacks-hub")
        XCTAssertTrue(app.staticTexts["3 photos"].waitForExistence(timeout: 15),
                      "the hub did not list the stack")
    }

    /// Adding photos to an existing stack. There is no add-asset route on the
    /// server: the app re-posts `POST /api/stacks` with the stack's current
    /// cover first, which makes the server merge it — **and return a new stack
    /// id**. The stub models that faithfully (the old id 404s), so this test
    /// fails if the detail screen keeps holding the id it was pushed with.
    ///
    /// Needs the stacks stub: `python3 /tmp/immich_stub_stacks.py 8421`
    func test_04_addPhotosToExistingStack() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(5)

        let badge = app.descendants(matching: .any).matching(identifier: "stackBadge").firstMatch
        shot("16-timeline")
        for _ in 0..<4 where !badge.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "stack badge missing")
        badge.tap()

        // The stack the stub started with: aaaa-01.jpg on the cover.
        XCTAssertTrue(app.staticTexts["aaaa-01.jpg"].waitForExistence(timeout: 15),
                      "stack detail did not open")
        shot("17-stack-before-add")

        let addPhotos = app.buttons["addPhotosToStack"]
        XCTAssertTrue(addPhotos.waitForExistence(timeout: 10), "no 'Add photos' entry point")
        addPhotos.tap()

        // bbbb-09.jpg belongs to no stack, so it is the photo to add. It sits
        // behind the stack's own members, which the picker leaves out.
        let candidate = app.descendants(matching: .any)
            .matching(identifier: "pickerAsset_bbbbbbbb-2222-4222-8222-000000000009")
            .firstMatch
        for _ in 0..<5 where !candidate.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(candidate.waitForExistence(timeout: 15), "pickable photo missing from the grid")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "pickerAsset_aaaaaaaa-1111-4111-8111-000000000002")
            .firstMatch.exists,
            "a photo already in the stack must not be offered again")
        candidate.tap()
        shot("18-add-to-stack-picker")

        // Identifiers, not labels: the CTA's label is localized ("Créer"/"Add"
        // depending on the catalog), the identifier is not.
        let add = app.buttons["confirmAddToStack"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add CTA missing")
        XCTAssertTrue(add.isEnabled, "tapping a photo did not select it")
        add.tap()
        sleep(4)

        // The server re-created the stack under a new id: the screen must have
        // followed it, kept the cover, and gained the member.
        XCTAssertTrue(app.staticTexts["bbbb-09.jpg"].waitForExistence(timeout: 20),
                      "the added photo is not in the stack (detail screen stranded on the dead id?)")
        XCTAssertTrue(app.staticTexts["aaaa-01.jpg"].exists, "the cover changed")
        shot("19-stack-after-add")

        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button on the stack detail")
        back.tap()
        sleep(2)

        let stacksRow = openAlbumsLibraryRow("stacksRow", missingShot: "20b-albums-no-stacks-row")
        stacksRow.tap()
        sleep(3)
        shot("20-stacks-hub-after-add")

        XCTAssertTrue(app.staticTexts["4 photos"].waitForExistence(timeout: 15),
                      "the hub still shows the stack it had before the add")
    }

    /// Creating a stack from the Albums library. Kept as its own flow because the picker is
    /// where a silent regression hides: `AssetThumbnailCell` carries its own
    /// `onTapGesture`, so wrapping it in a `Button` swallows every tap — the
    /// grid then renders perfectly and selects nothing.
    ///
    /// Needs the stacks stub: `python3 /tmp/immich_stub_stacks.py 8421`
    func test_05_createStackFromHub() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        let stacksRow = openAlbumsLibraryRow("stacksRow", missingShot: "21b-albums-no-stacks-row")
        stacksRow.tap()
        sleep(3)

        let plus = app.buttons["newStackButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "no create button in the hub")
        plus.tap()
        sleep(3)

        let first = app.descendants(matching: .any)
            .matching(identifier: "pickerAsset_cccccccc-3333-4333-8333-000000000001").firstMatch
        let second = app.descendants(matching: .any)
            .matching(identifier: "pickerAsset_cccccccc-3333-4333-8333-000000000002").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "picker did not load")

        // The CTA stays disabled until 2 photos are picked (the server's
        // minimum), so a tap that fails to register shows up there — which is
        // exactly how the swallowed-tap defect surfaced.
        first.tap()
        second.tap()
        shot("21-create-stack-picker")

        let create = app.buttons["confirmCreateStack"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Create CTA missing")
        XCTAssertTrue(create.isEnabled, "tapping photos did not select them (2 needed)")
        create.tap()
        sleep(4)
        shot("22-stacks-hub-after-create")

        XCTAssertTrue(app.staticTexts["2 photos"].waitForExistence(timeout: 15),
                      "the new stack is not in the hub")
    }

    /// Partners (issue #14) against a committed stub. Two things can only be
    /// seen by running the app:
    ///
    /// 1. the **direction** query is really sent — the stub answers 400 for a
    ///    `/api/partners` without it, which is what the app used to do;
    /// 2. the **asymmetry** between the two lists is real on screen: an
    ///    incoming row carries the timeline switch and no remove button, an
    ///    outgoing row the opposite. `PUT` pairs `{sharedById: id, sharedWithId:
    ///    me}` and `DELETE` the reverse, so a row offering both would send a
    ///    request that matches nothing (or revokes the wrong access).
    ///
    /// Needs the partner stub (committed, unlike the stacks one):
    ///
    ///     python3 UITests/stubs/immich_stub_partners.py 8421
    func test_06_partners() throws {
        let incomingId = "aaaaaaaa-1111-4111-8111-111111111111"
        let outgoingId = "bbbbbbbb-2222-4222-8222-000000000002"
        let invitableId = "cccccccc-3333-4333-8333-000000000003"

        setProvider("auto")
        resetPartners()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        let partnersRow = openAlbumsLibraryRow("partnersRow", missingShot: "23b-albums-no-partners-row")
        partnersRow.tap()
        sleep(3)
        shot("23-partners")

        // The incoming partner (they share with me): switch, no remove button.
        let incomingToggle = app.descendants(matching: .any)
            .matching(identifier: "partnerTimelineToggle-\(incomingId)").firstMatch
        XCTAssertTrue(incomingToggle.waitForExistence(timeout: 15),
                      "no timeline switch on an incoming partner — is the list empty (direction rejected?)")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "partnerRemove-\(incomingId)").firstMatch.exists,
            "an incoming row must not offer remove: DELETE would pair {sharedById: me, sharedWithId: id} and revoke access I never granted")

        // The outgoing partner (I share with them): remove button, no switch.
        let outgoingRemove = app.descendants(matching: .any)
            .matching(identifier: "partnerRemove-\(outgoingId)").firstMatch
        XCTAssertTrue(outgoingRemove.waitForExistence(timeout: 10), "no remove button on my own partner")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "partnerTimelineToggle-\(outgoingId)").firstMatch.exists,
            "an outgoing row must not offer the timeline switch: PUT would pair {sharedById: id, sharedWithId: me} and match nothing")

        // Invite: the directory minus me minus everyone already in "Sharing".
        // Partner sharing is one-way, so the incoming partner is a legitimate
        // candidate (adding them back is how their library shows in my
        // timeline) — but the outgoing one is not.
        let invite = app.buttons["invitePartner"]
        XCTAssertTrue(invite.waitForExistence(timeout: 10), "no invite button in the toolbar")
        invite.tap()
        sleep(3)
        let candidate = app.buttons.matching(identifier: "inviteCandidate-\(invitableId)").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15), "invite sheet did not list the directory")
        XCTAssertFalse(app.buttons.matching(identifier: "inviteCandidate-\(outgoingId)").firstMatch.exists,
            "a user already in Sharing must not be offered again — POST /api/partners answers 400 'Partner already exists'")
        candidate.tap()
        shot("25-partners-invite")

        let confirmInvite = app.buttons["confirmInvitePartner"]
        XCTAssertTrue(confirmInvite.waitForExistence(timeout: 10), "Invite CTA missing")
        // The tap flips `selectedCandidateId`, which arms the CTA on the next
        // render — poll instead of reading a possibly stale enabled state.
        let armed = expectation(for: NSPredicate(format: "isEnabled == true"),
                                evaluatedWith: confirmInvite)
        let outcome = XCTWaiter().wait(for: [armed], timeout: 10)
        XCTAssertEqual(outcome, .completed, "picking a candidate did not arm the CTA")
        confirmInvite.tap()
        sleep(4)
        shot("26-partners-after-invite")

        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "partnerRemove-\(invitableId)").firstMatch.waitForExistence(timeout: 15),
            "the invited user did not appear under Sharing (POST /api/partners)")

        // Removing is the outgoing-only action.
        outgoingRemove.tap()
        sleep(2)
        // An alert: iOS 26 lists an identified alert button twice, so the
        // button is queried inside the alert and narrowed to its first match.
        let confirmAlert = app.alerts.firstMatch
        let confirm = confirmAlert.buttons.matching(identifier: "confirmStopSharing").firstMatch
        let confirmFallback = confirmAlert.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Stop sharing' OR label CONTAINS 'partage'")
        ).firstMatch
        let destructive = confirm.waitForExistence(timeout: 6) ? confirm : confirmFallback
        XCTAssertTrue(destructive.waitForExistence(timeout: 6), "no confirmation for the removal")
        shot("27-partners-remove-confirm")
        destructive.tap()
        sleep(4)

        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "partnerRemove-\(outgoingId)").firstMatch.exists,
            "the removed partner is still listed")
    }

    /// Shared links (issue #17) against a committed stub. What can only be seen
    /// by running the app:
    ///
    /// 1. the public URL really uses `externalDomain` and the link's **slug** —
    ///    the app used to hardcode `<serverURL>/share/<key>`, so the displayed
    ///    URL is the proof: the stub's config advertises
    ///    `https://photos.stub.test` while the app dials `127.0.0.1`;
    /// 2. the slug really goes out on the wire (`POST /api/shared-links` is
    ///    checked through the stub's own request log);
    /// 3. copying is reachable and acknowledged — XCTest cannot read the
    ///    pasteboard without the iOS consent prompt, so the in-app feedback is
    ///    the evidence that the tap landed (the `.buttonStyle(.plain)` defect
    ///    class shows a perfect screen and a dead button).
    ///
    /// Needs the committed stub:
    ///
    ///     python3 UITests/stubs/immich_stub_shared_links.py 8421
    func test_07_sharedLinks() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        openSharedTab()
        shot("28-shared-empty")

        let create = app.buttons["sharedLinksCreateButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "no create CTA on the empty state")
        create.tap()
        sleep(3)

        // The link is album-typed: pick the single album the stub serves.
        let picker = app.descendants(matching: .any)
            .matching(identifier: "sharedLinkAlbumPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "album picker missing in the create sheet")
        picker.tap()
        sleep(2)
        let album = app.buttons["Stub Album"]
        XCTAssertTrue(album.waitForExistence(timeout: 10), "album list did not open")
        album.tap()
        sleep(2)

        let slugField = app.textFields["sharedLinkSlugField"]
        XCTAssertTrue(slugField.waitForExistence(timeout: 10), "no custom-URL field")
        if !slugField.isHittable { app.swipeUp() }
        slugField.tap()
        slugField.typeText("trip-2026")

        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "sharedLinkExpiryPicker").firstMatch.exists,
            "no expiry preset picker in the create sheet")
        shot("29-create-shared-link")

        let confirm = app.buttons["confirmCreateSharedLink"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Create CTA missing")
        XCTAssertTrue(confirm.isEnabled, "picking the album did not arm the CTA")
        confirm.tap()
        sleep(4)

        // The "link ready" panel: the URL carries the stub's external domain and
        // the slug. Before the fix it read 127.0.0.1/…/share/<key>.
        let readyURL = app.staticTexts["sharedLinkReadyURL"]
        if !readyURL.waitForExistence(timeout: 8) {
            print("APP TREE AFTER CREATE:\n\(app.debugDescription)")
        }
        XCTAssertTrue(readyURL.waitForExistence(timeout: 7), "the ready panel did not appear")
        let shown = readyURL.label
        XCTAssertEqual(shown, "https://photos.stub.test/s/trip-2026",
                       "the public URL must use externalDomain + /s/<slug>, not the dialled server + /share/<key>")
        shot("30-shared-link-ready")

        // Copy is acknowledged in-app (the pasteboard itself needs a system
        // consent prompt).
        let copy = app.buttons["sharedLinkReadyCopy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), "no copy button on the ready panel")
        copy.tap()
        // The label flips to "Copied" — a predicate on "Copi" would already match
        // "Copy link" and prove nothing.
        let copied = NSPredicate(format: "label CONTAINS 'Copied' OR label CONTAINS 'Copié'")
        let acknowledged = expectation(for: copied, evaluatedWith: copy)
        XCTAssertEqual(XCTWaiter().wait(for: [acknowledged], timeout: 10), .completed,
                       "tapping copy produced no feedback")

        XCTAssertTrue(app.buttons["sharedLinkReadyShare"].exists, "no share button beside copy")
        let done = app.buttons["closeSharedLinkSheet"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "no Done button")
        done.tap()
        sleep(3)
        shot("31-shared-link-row")

        // The created link is listed, and its row copies the same URL.
        let rowCopy = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sharedLinkCopy-'")
        ).firstMatch
        XCTAssertTrue(rowCopy.waitForExistence(timeout: 15), "the created link is not in the list")
        rowCopy.tap()
        XCTAssertTrue(app.staticTexts["sharedLinkCopyFeedback"].waitForExistence(timeout: 10),
                      "the row's copy button produced no feedback")

        assertStubRecordedSlug("trip-2026")
    }

    /// Memories CRUD (issue #15) against a committed stub. Four things can only
    /// be seen by running the app:
    ///
    /// 1. `PUT /api/memories/{id}` really carries `isSaved` — the bookmark is
    ///    the only save entry point, and a view that flipped its icon locally
    ///    would pass a screenshot and fail this;
    /// 2. `POST /api/memories` carries the date **and** `isSaved: true` (the
    ///    server deletes unsaved memories after 30 days, so an unsaved create
    ///    would silently vanish);
    /// 3. `PUT`/`DELETE /api/memories/{id}/assets` — the routes are `put|delete`
    ///    on `{id}/assets`, and a `POST` (the shape the backlog card originally
    ///    specified) is a 404;
    /// 4. dropping the **last** photo moves the full-screen playback on to the
    ///    next memory (`GET /api/memories` filters empty memories out, so the
    ///    emptied one is gone from the list) — the card would otherwise stay on
    ///    screen for a memory the server no longer returns;
    ///
    /// Needs the memories stub (committed, unlike the stacks one):
    ///
    ///     python3 UITests/stubs/immich_stub_memories.py 8421
    func test_08_memories() throws {
        let initialMemory = "dddddddd-4444-4444-8444-000000000001"
        // The stub hands out ids in order from 2, so the created memory is
        // addressable without scraping the screen.
        let createdMemory = "dddddddd-4444-4444-8444-000000000002"
        let firstPhoto = "aaaaaaaa-1111-4111-8111-000000000001"
        let secondPhoto = "aaaaaaaa-1111-4111-8111-000000000002"
        let thirdPhoto = "aaaaaaaa-1111-4111-8111-000000000003"
        let fourthPhoto = "aaaaaaaa-1111-4111-8111-000000000004"

        setProvider("auto")
        resetStacks() // same `/__reset` route: restores the stub's initial state
        // Without the auto-play the playback only moves on this test's own
        // gestures: left running, it would leave the created memory (first in the
        // list, dated today) for the 2022 one during the `sleep`s below.
        app.launchArguments += ["-uiTestMemoryAutoplayOff", "YES"]
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        openMemoriesTab()
        shot("32-memories-list")

        // MARK: Save toggle

        let bookmark = app.buttons["memoryBookmark_\(initialMemory)"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 20), "the stub's memory is not in the list")
        XCTAssertEqual(bookmark.label, "Save memory", "an unsaved memory must offer to save")

        bookmark.tap()
        let saved = NSPredicate(format: "label == 'Unsave memory'")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: saved, evaluatedWith: bookmark)], timeout: 15),
                       .completed, "tapping the bookmark did not save the memory")
        shot("33-memory-saved")

        assertStubWrote(method: "PUT", path: "/api/memories/\(initialMemory)", isSaved: true)

        // MARK: Create from a selection

        let create = app.buttons["memoriesCreateButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "no create button in the Memories toolbar")
        create.tap()
        sleep(3)

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "memoryDatePicker")
            .firstMatch.waitForExistence(timeout: 15), "the create sheet has no date picker")

        let pickA = pickerAsset(firstPhoto)
        XCTAssertTrue(pickA.waitForExistence(timeout: 20), "the picker did not load the library")
        pickA.tap()
        pickerAsset(secondPhoto).tap()
        shot("34-create-memory-picker")

        let confirm = app.buttons["confirmCreateMemory"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Create CTA missing")
        XCTAssertTrue(confirm.isEnabled, "tapping photos did not select them")
        confirm.tap()
        sleep(4)

        let created = app.descendants(matching: .any).matching(identifier: "memoryCard_\(createdMemory)").firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 20), "the created memory is not in the list")
        shot("35-memory-created")

        assertStubCreatedMemory(assetIds: [firstPhoto, secondPhoto])

        // MARK: Add photos to the created memory

        created.tap()
        sleep(3)
        let addPhotos = app.buttons["memoryMomentAddPhotos"]
        XCTAssertTrue(addPhotos.waitForExistence(timeout: 15), "no add-photos action in the moment view")
        addPhotos.tap()
        sleep(3)

        let pickC = pickerAsset(thirdPhoto)
        XCTAssertTrue(pickC.waitForExistence(timeout: 20), "the add-photos picker did not load")
        pickC.tap()
        app.buttons["confirmAddPhotosToMemory"].tap()
        sleep(4)

        assertStubWrote(method: "PUT", path: "/api/memories/\(createdMemory)/assets", ids: [thirdPhoto])
        shot("36-memory-photo-added")

        // MARK: Drop every photo — the last one moves on to the next memory

        // The stub creation ran with 2 photos and one was just added, so three
        // removals empty it. The third shows the next memory of the list (the
        // initial one): the emptied memory no longer exists once
        // `GET /api/memories` filters it out.
        for index in 0..<3 {
            let remove = app.buttons["memoryMomentRemovePhoto"]
            XCTAssertTrue(remove.waitForExistence(timeout: 10), "remove action missing (pass \(index))")
            remove.tap()
            sleep(3)
        }

        let nextTitle = app.descendants(matching: .any)
            .matching(identifier: "memoryTitle_\(initialMemory)").firstMatch
        XCTAssertTrue(nextTitle.waitForExistence(timeout: 20) && nextTitle.isHittable,
                      "the playback did not move on to the next memory when this one lost its last photo")
        app.buttons["memoryMomentClose"].tap()
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 20),
                      "closing the playback did not come back to the list")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "memoryCard_\(createdMemory)")
            .firstMatch.waitForExistence(timeout: 5), "the emptied memory is still listed")
        shot("37-memory-emptied")

        // MARK: Delete the remaining memory

        let remaining = app.descendants(matching: .any)
            .matching(identifier: "memoryCard_\(initialMemory)").firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 15), "the initial memory vanished")
        remaining.tap()
        sleep(3)

        let delete = app.buttons["memoryMomentDelete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15), "no delete action in the moment view")
        delete.tap()
        sleep(2)
        let confirmDelete = app.alerts.firstMatch.buttons
            .matching(NSPredicate(format: "label == %@", "Delete Memory")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10), "no confirmation for the delete")
        confirmDelete.tap()
        sleep(4)

        assertStubWrote(method: "DELETE", path: "/api/memories/\(initialMemory)")
        XCTAssertTrue(app.staticTexts["No Memories Yet"].waitForExistence(timeout: 20),
                      "deleting the last memory must land on the empty state")
        shot("38-memories-empty")
    }

    /// Public shared-link viewer (issue #22) against a committed stub. Five
    /// things can only be seen by running the app:
    ///
    /// 1. a link received as a URL addresses the right credential — the `/s/<slug>`
    ///    path must go out as `slug=`, not as a guessed key;
    /// 2. no visitor request carries a bearer token, even though the app is
    ///    signed in — an accidental `Authorization` would read the link as its
    ///    owner (the stub logs the header);
    /// 3. a protected link refuses until the password is exchanged, and what
    ///    makes the next visit succeed is the **cookie** the login returned: the
    ///    stub gates `/shared-links/me` on it, exactly like
    ///    `SharedLinkService.getMine`, so a viewer that dropped the cookie would
    ///    stay stuck on the prompt;
    /// 4. an album link's photos come from `POST /search/metadata` with
    ///    `albumIds` — an unfiltered search is a 400 under shared-link auth;
    /// 5. `allowUpload: false` reads as read-only with no add-photos button, and
    ///    a revoked slug lands on the dead-link state instead of an error alert.
    ///
    /// Needs the viewer stub (committed):
    ///
    ///     python3 UITests/stubs/immich_stub_shared_link_viewer.py 8421
    func test_SLV_viewer() throws {
        let protectedLink = "\(stub)/s/trip-2026"
        let readOnlyLink = "\(stub)/s/open-link"
        let revokedLink = "\(stub)/s/gone-2026"
        let stubAlbum = "22222222-2222-4222-8222-000000000002"

        setProvider("auto")
        resetSharedLinkViewer()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        openSharedTab()
        openSharedLinkViewer()
        shot("69-shared-link-entry")
        pasteSharedLink(protectedLink)
        shot("70-shared-link-password")

        // MARK: A protected link asks for its password

        let passwordField = app.secureTextFields["sharedLinkViewerPassword"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 20),
                      "the password-protected link did not stop at the prompt")

        // Wrong password first: the refusal must stay on the prompt.
        passwordField.tap()
        passwordField.typeText("nope")
        app.buttons["submitSharedLinkPassword"].tap()
        sleep(3)
        XCTAssertTrue(app.staticTexts["That password is not right."].waitForExistence(timeout: 15),
                      "a wrong password must be reported inline")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "the prompt must stay put")

        // The real password — and the cookie it returns is what unlocks the visit.
        retype(passwordField, replacing: 4, with: "hunter2")
        app.buttons["submitSharedLinkPassword"].tap()
        sleep(4)

        let title = app.staticTexts["sharedLinkViewerTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the link did not open after the password")
        XCTAssertEqual(title.label, "Stub Album")

        let subtitle = app.staticTexts["sharedLinkViewerSubtitle"]
        XCTAssertTrue(subtitle.label.contains("3 photos"),
                      "the album link's count must come from the search — got \(subtitle.label)")
        XCTAssertTrue(subtitle.label.contains("You can add photos"),
                      "allowUpload true must be stated — got \(subtitle.label)")

        XCTAssertTrue(firstSharedLinkAsset().waitForExistence(timeout: 20),
                      "the album link's photos are not in the grid")
        shot("71-shared-link-opened")

        assertStubVisitedSharedLink(method: "POST", path: "/api/shared-links/login", password: "hunter2",
                                    slug: "trip-2026")
        assertStubVisitedSharedLink(method: "GET", path: "/api/shared-links/me", cookie: false,
                                    slug: "trip-2026")
        assertStubSearchedSharedAlbum(albumId: stubAlbum)
        assertStubLoadedSharedThumbnail(slug: "trip-2026")

        // MARK: Pull-to-refresh is the visit that needs the cookie

        // Opening the link a second time re-reads it, and *that* read only
        // passes because the client kept the cookie the login handed out — the
        // stub gates `/me` on it, like `SharedLinkService.getMine`. A dropped
        // cookie would bounce the viewer back to the password prompt.
        // A deliberate slow pull: `swipeDown()` is too fast to cross the
        // refresh threshold, and `.refreshable` is a drag, not a flick.
        let grid = app.scrollViews.firstMatch
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.3,
                   thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                   withVelocity: .slow,
                   thenHoldForDuration: 0.6)
        sleep(4)
        XCTAssertTrue(app.staticTexts["sharedLinkViewerTitle"].waitForExistence(timeout: 20),
                      "refreshing the link must not send the visitor back to the password prompt")
        XCTAssertFalse(app.secureTextFields["sharedLinkViewerPassword"].exists,
                       "the cookie is what keeps the visit unlocked")
        assertStubVisitedSharedLink(method: "GET", path: "/api/shared-links/me", cookie: true,
                                    slug: "trip-2026")

        // MARK: A photo opens full screen

        firstSharedLinkAsset().tap()
        let pagerClose = app.buttons["closeSharedLinkPager"]
        XCTAssertTrue(pagerClose.waitForExistence(timeout: 20), "tapping a photo must open it full screen")
        shot("72-shared-link-photo")
        pagerClose.tap()
        sleep(2)

        // MARK: A link that forbids uploads

        app.buttons["closeSharedLinkViewer"].tap()
        sleep(2)
        openSharedLinkViewer()
        pasteSharedLink(readOnlyLink)

        let readOnlySubtitle = app.staticTexts["sharedLinkViewerSubtitle"]
        XCTAssertTrue(readOnlySubtitle.waitForExistence(timeout: 20), "the open link did not load")
        XCTAssertTrue(readOnlySubtitle.label.contains("Read only"),
                      "allowUpload false must read as read-only — got \(readOnlySubtitle.label)")
        XCTAssertFalse(app.buttons["addPhotoToSharedLink"].exists,
                       "a link that forbids uploads must not offer one")
        XCTAssertTrue(firstSharedLinkAsset().waitForExistence(timeout: 20),
                      "an individual link's inline assets are not in the grid")
        assertStubLoadedSharedThumbnail(slug: "open-link")
        shot("73-shared-link-readonly")

        // MARK: A revoked link

        app.buttons["closeSharedLinkViewer"].tap()
        sleep(2)
        openSharedLinkViewer()
        pasteSharedLink(revokedLink)

        let deadLink = app.descendants(matching: .any)
            .matching(identifier: "sharedLinkViewerDeadLink").firstMatch
        XCTAssertTrue(deadLink.waitForExistence(timeout: 20),
                      "a revoked slug must land on the dead-link state")
        shot("74-shared-link-dead")
    }

    /// One picker cell, by the identity the grid gives it.
    private func pickerAsset(_ assetId: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pickerAsset_\(assetId)").firstMatch
    }

    /// The stub's request log, decoded with one shape for every method — the
    /// scenarios assert on the wire, not on a screenshot.
    private struct StubRequest: Decodable {
        let method: String
        let path: String
        let isSaved: Bool?
        let assetIds: [String]?
        let ids: [String]?
        let year: Int?

        enum CodingKeys: String, CodingKey {
            case method, path, isSaved, assetIds, ids, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            path = try container.decode(String.self, forKey: .path)
            isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved)
            assetIds = try container.decodeIfPresent([String].self, forKey: .assetIds)
            ids = try container.decodeIfPresent([String].self, forKey: .ids)
            year = try container.decodeIfPresent([String: Int].self, forKey: .data)?["year"]
        }
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
        requests.map { "\($0.method) \($0.path) isSaved=\($0.isSaved.map(String.init) ?? "-") " +
            "assetIds=\($0.assetIds ?? []) ids=\($0.ids ?? []) year=\($0.year.map(String.init) ?? "-")" }
            .joined(separator: "\n")
    }

    private func assertStubWrote(
        method: String,
        path: String,
        isSaved: Bool? = nil,
        ids: [String]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let requests = stubRequests()
        let match = requests.contains { entry in
            entry.method == method && entry.path == path
                && (isSaved == nil || entry.isSaved == isSaved)
                && (ids == nil || entry.ids == ids)
        }
        XCTAssertTrue(match, "no \(method) \(path) isSaved=\(isSaved.map(String.init) ?? "-") ids=\(ids ?? []) on the wire — got:\n\(describe(requests))",
                      file: file, line: line)
    }

    /// The create payload, all four fields at once: the picked photos in grid
    /// order, a `data.year` that matches `memoryAt`, the only type the server
    /// accepts, and `isSaved: true` so the 30-day cleanup cannot take it.
    private func assertStubCreatedMemory(assetIds: [String], file: StaticString = #filePath, line: UInt = #line) {
        let requests = stubRequests()
        guard let created = requests.first(where: { $0.method == "POST" && $0.path == "/api/memories" }) else {
            return XCTFail("no POST /api/memories on the wire — got:\n\(describe(requests))", file: file, line: line)
        }
        XCTAssertEqual(created.assetIds, assetIds, "the selection must be the payload", file: file, line: line)
        XCTAssertEqual(created.isSaved, true,
                       "an unsaved memory is deleted by the server after 30 days", file: file, line: line)
        XCTAssertNotNil(created.year, "data.year is required by MemoryCreateDto", file: file, line: line)
    }

    /// Offline download (issue #18), end to end against the committed stub.
    ///
    ///     python3 UITests/stubs/immich_stub_offline.py 8421
    ///
    /// Proves the whole promise in one run: the viewer downloads the original,
    /// the badge appears on the timeline tile, the storage screen lists it with
    /// a real usage figure, and removing it empties the cache again. The wire
    /// assertion is the load-bearing one — a badge that appeared without
    /// `/api/assets/{id}/original` ever being fetched would mean the app is
    /// claiming an offline copy it does not have.
    func test_09_offlineDownload() throws {
        // A SECOND-ROW photo: the timeline pins a floating date header over
        // its first row, and a badge underneath it is invisible in a capture.
        let target = "aaaaaaaa-1111-4111-8111-000000000004"

        setProvider("auto")
        resetStacks() // same `/__reset` route: restores the stub's initial state
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)
        shot("40-timeline-before-offline")

        // MARK: Download from the viewer

        let tile = app.descendants(matching: .any)
            .matching(identifier: "assetTile_\(target)").firstMatch
        if !tile.waitForExistence(timeout: 20) {
            // The grid only publishes rendered cells; the identifier may sit
            // below the fold on a small simulator.
            app.swipeUp()
            sleep(2)
        }
        tile.tap()
        sleep(3)
        shot("41-viewer")

        let share = app.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 15), "no share button in the viewer")
        share.tap()
        sleep(2)

        let download = app.buttons["downloadForOfflineButton"]
        XCTAssertTrue(download.waitForExistence(timeout: 15), "no 'Download for Offline' row in the share sheet")
        download.tap()

        // The row flips to "Available offline" only when the store reported the
        // asset cached — i.e. after the file was written and indexed.
        let available = app.descendants(matching: .any).matching(identifier: "offlineAvailableRow").firstMatch
        if !available.waitForExistence(timeout: 30) {
            // The section renders the failure inline; surfacing it here beats a
            // bare "never completed".
            let visible = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            XCTFail("the download never completed: the asset was not indexed as cached. On screen: \(visible)")
        }
        shot("42-viewer-available-offline")

        assertStubDownloadedOriginal(target)

        // Leave the sheet, then the viewer. Tapping alone proved unreliable
        // (a tap that misses leaves the viewer up, and every later assertion
        // then reads the covered timeline — which still exists in the
        // accessibility tree), so the dismissal is verified: `viewerBackButton`
        // is gone only once the cover really came down.
        app.buttons["closeShareSheet"].tap()
        sleep(2)
        for _ in 0..<4 where app.buttons["viewerBackButton"].exists {
            let back = app.buttons["viewerBackButton"]
            if back.isHittable { back.tap() } else { app.swipeDown() }
            sleep(2)
        }
        XCTAssertFalse(app.buttons["viewerBackButton"].exists,
                       "the photo viewer never dismissed — every later step would read the covered timeline")
        sleep(2)

        // MARK: The timeline tile is badged

        let badge = app.descendants(matching: .any).matching(identifier: "offlineBadge").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20),
                      "no offline badge on the cached tile — the environment index is not reaching the cells")
        // Scroll the tile clear of the floating date header before capturing:
        // the header covers the first row, so a badge inside it is asserted
        // (accessibility tree) but not visible in the screenshot.
        app.swipeUp()
        sleep(2)
        shot("43-timeline-offline-badge")

        // MARK: The storage screen — with the server refusing everything

        // From here the stub answers 503 to every asset and timeline route, so
        // anything still rendered comes from the downloaded file. This is what
        // turns "the cache holds a file" into "the app is usable offline".
        setStubNetwork(down: true)

        // The Library section of the Albums tab. Matched by identifier — the label
        // is translated ("Stockage hors ligne"), so a literal would depend on the
        // locale.
        let offlineRow = openAlbumsLibraryRow("offlineStorageRow", missingShot: "44-albums-no-offline-row")
        offlineRow.tap()
        sleep(4)
        shot("44-offline-storage")

        let usageText = app.staticTexts["offlineUsageText"]
        XCTAssertTrue(usageText.waitForExistence(timeout: 15), "no usage figure on the storage screen")

        let cachedBadge = app.descendants(matching: .any).matching(identifier: "offlineCachedBadge").firstMatch
        XCTAssertTrue(cachedBadge.waitForExistence(timeout: 15),
                      "the cached asset is not in the grid — the storage screen did not read the index")

        let cachedTile = app.descendants(matching: .any)
            .matching(identifier: "offlineAsset_\(target)").firstMatch
        XCTAssertTrue(cachedTile.waitForExistence(timeout: 15), "no addressable cached tile")

        // The grid rendered with the server down; nothing may have been fetched.
        assertStubServedNoAssetWhileDown()

        // MARK: Remove it

        cachedTile.press(forDuration: 1.5)
        let remove = firstButton(labels: ["Remove from Offline", "Retirer du hors ligne"])
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "no 'Remove from Offline' in the context menu")
        remove.tap()
        sleep(3)
        shot("45-offline-emptied")

        XCTAssertFalse(cachedTile.exists, "the removed asset is still in the offline grid")
        XCTAssertFalse(cachedBadge.exists, "the cache badge survived the removal")
        XCTAssertTrue(offlineEmptyStateShown(), "the storage screen did not fall back to its empty state")
    }

    /// The notification permission screen (issue #16) against the committed
    /// offline stub: the feature has **no** server contract of its own (the
    /// only notification the app posts is the local "backup complete" alert),
    /// so the stub is reused for what it does provide — onboarding, the OAuth
    /// handshake and the authenticated shell. The subject is the system
    /// permission: the screen must show the real status with exactly one action
    /// (ask, or go to Settings), and asking must really reach iOS.
    func test_10_notifications() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        let profile = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 15), "Profile avatar missing")
        profile.tap()
        sleep(3)

        // The Management section sits below the fold: a Form only publishes what
        // it has rendered. Matched by identifier — the label is translated.
        let row = app.buttons.matching(identifier: "notificationsRow").firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp()
            sleep(1)
        }
        if !row.waitForExistence(timeout: 10) {
            shot("45-notifications-hub-missing")
            XCTFail("Notifications row missing in the Me hub:\n\(app.debugDescription)")
        }
        shot("45-notifications-hub")
        row.tap()
        sleep(3)

        let status = app.descendants(matching: .any)
            .matching(identifier: "notificationsStatusRow").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "no status row on the notifications screen")
        shot("45-notifications-settings")

        let enable = app.buttons["notificationsEnableButton"]
        let openSettings = app.buttons["notificationsOpenSettingsButton"]

        if enable.waitForExistence(timeout: 5) {
            // Never asked on this simulator: ask, and let iOS deliver its answer.
            enable.tap()
            allowNotificationsAlertIfPresent()
            XCTAssertTrue(openSettings.waitForExistence(timeout: 15),
                          "after answering the prompt the screen must offer System Settings, not 'Enable' again")
            shot("45-notifications-allowed")
        } else {
            // Already answered on this simulator: a second ask would be ignored
            // by iOS, so the screen must not offer it.
            XCTAssertTrue(openSettings.exists,
                          "the screen shows neither 'Enable' nor 'Open System Settings'")
        }
    }

    /// The permission alert belongs to SpringBoard, not to the app (same shape
    /// as `dismissSystemSignInAlertIfPresent`, which also has to try both
    /// locales — this simulator runs in French).
    private func allowNotificationsAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Autoriser"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 10) {
                button.tap()
                return
            }
        }
        // Some iOS builds surface the permission alert inside the app's tree.
        for label in ["Allow", "Autoriser"] {
            let button = app.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    /// A button matched by either of two labels (the app runs in the
    /// simulator's locale, so a translated string must not decide a scenario).
    private func firstButton(labels: [String]) -> XCUIElement {
        let predicate = NSPredicate(format: "label IN %@", labels)
        return app.buttons.matching(predicate).firstMatch
    }

    /// Flips the stub between reachable and refusing-everything.
    private func setStubNetwork(down: Bool) {
        var request = URLRequest(url: URL(string: "\(stub)/__network?down=\(down ? 1 : 0)")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__network")
    }

    /// The offline screen must not have needed the server: with the stub down,
    /// every asset route it hit is recorded with `offline: true`.
    private func assertStubServedNoAssetWhileDown(file: StaticString = #filePath, line: UInt = #line) {
        struct Entry: Decodable { let path: String; let offline: Bool? }
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests", file: file, line: line)

        let entries = (try? JSONDecoder().decode([Entry].self, from: Data(body.utf8))) ?? []
        let refused = entries.filter { $0.offline == true }
        XCTAssertTrue(refused.isEmpty,
                      "the offline screen still asked the server for \(refused.map(\.path)) — it must read the downloaded file",
                      file: file, line: line)
    }

    /// The offline grid's empty state, matched by identifier or by its title:
    /// a `ContentUnavailableView` does not reliably keep an identifier placed on
    /// the container.
    private func offlineEmptyStateShown() -> Bool {
        if app.descendants(matching: .any).matching(identifier: "offlineEmptyState").firstMatch.exists {
            return true
        }
        return app.staticTexts["No offline photos"].exists
            || app.staticTexts.matching(labelPredicate(["No offline photos", "Aucune photo hors ligne"])).firstMatch.exists
    }

    /// The download really hit the wire, with the session's bearer token.
    private func assertStubDownloadedOriginal(_ assetId: String, file: StaticString = #filePath, line: UInt = #line) {
        struct Entry: Decodable { let method: String; let path: String; let assetId: String?; let authorization: String? }
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests", file: file, line: line)

        let entries = (try? JSONDecoder().decode([Entry].self, from: Data(body.utf8))) ?? []
        let download = entries.first {
            $0.method == "GET" && $0.path == "/api/assets/\(assetId)/original"
        }
        XCTAssertNotNil(download,
                        "no GET /api/assets/\(assetId)/original on the wire — got: \(entries.map { "\($0.method) \($0.path)" })",
                        file: file, line: line)
        XCTAssertEqual(download?.authorization, "Bearer stub-access-token",
                       "the original must be fetched with the session token", file: file, line: line)
    }

    /// The "Memories" tab, whichever language the catalog resolves it in.
    ///
    /// `firstMatch`: iOS 26 renders the tab bar's expanded and minimized forms
    /// at once while it is animating, so a bare `tabBars.buttons[label]` query
    /// intermittently matches two buttons and `.tap()` throws ("Find single
    /// matching element") — the same reason `tapButton` here already takes
    /// `firstMatch`.
    private func openMemoriesTab() {
        for label in ["Memories", "Souvenirs"] {
            let tab = app.tabBars.buttons[label].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.tap()
                return
            }
        }
        app.tabBars.buttons.element(boundBy: 1).tap()
    }

    /// Reads the stub's request log: the slug must have been on the wire —
    /// a form field that never reaches `POST /api/shared-links` would still
    /// produce a link, just one whose URL falls back to `/share/<key>`.
    private func assertStubRecordedSlug(_ slug: String) {
        struct Entry: Decodable { let method: String; let path: String; let slug: String? }
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")

        let entries = (try? JSONDecoder().decode([Entry].self, from: Data(body.utf8))) ?? []
        XCTAssertTrue(
            entries.contains { $0.method == "POST" && $0.path == "/api/shared-links" && $0.slug == slug },
            "no POST /api/shared-links carried slug=\(slug) — got \(entries.map { "\($0.method) \($0.path) slug=\($0.slug ?? "-")" })"
        )
        XCTAssertFalse(entries.contains { $0.method == "PUT" }, "the app sent a PUT the server does not expose")
    }

    /// The "Shared" tab, whichever language the catalog resolves it in
    /// ("Shared" → "Partagé" in `fr`). Falls back to tab position so the
    /// scenario never depends on the simulator's locale. `firstMatch` for the
    /// reason spelled out on `openMemoriesTab`.
    private func openSharedTab() {
        for label in ["Shared", "Partagé"] {
            let tab = app.tabBars.buttons[label].firstMatch
            if tab.waitForExistence(timeout: 5) {
                tab.tap()
                return
            }
        }
        app.tabBars.buttons.element(boundBy: 3).tap()
    }

    // MARK: - Shared-link viewer (issue #22)

    /// Same `/__reset` route, stated for the viewer stub: it restores the three
    /// links (protected, open, revoked) and empties the request log.
    private func resetSharedLinkViewer() {
        resetStacks()
    }

    private func openSharedLinkViewer() {
        let entry = app.buttons["openSharedLinkViewer"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no entry point in the Shared toolbar")
        entry.tap()
        XCTAssertTrue(app.textFields["sharedLinkViewerField"].waitForExistence(timeout: 15),
                      "the viewer did not present")
    }

    /// Types a received link into the viewer's field and opens it.
    private func pasteSharedLink(_ link: String) {
        let field = app.textFields["sharedLinkViewerField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no link field")
        field.tap()
        field.typeText(link)
        app.buttons["openSharedLink"].tap()
        sleep(3)
    }

    /// Replaces a field's content. Select-all + delete is flaky on a
    /// `SecureField`, so the existing characters are removed one by one.
    private func retype(_ element: XCUIElement, replacing count: Int, with text: String) {
        element.tap()
        if count > 0 {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
        element.typeText(text)
    }

    /// One grid cell of the viewer's asset grid. The stub hands out per-run asset
    /// ids (a disk-cached thumbnail would otherwise hide the image request), so
    /// cells are addressed by identifier prefix rather than by a fixed id.
    private func firstSharedLinkAsset() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sharedLinkAsset_"))
            .firstMatch
    }

    /// One entry of the viewer stub's visitor log — what the app actually sent,
    /// including whether it carried the login cookie or a bearer token.
    private struct VisitorRequest: Decodable {
        let method: String
        let path: String
        let credential: String?
        let slug: String?
        let key: String?
        let cookie: Bool?
        let authorization: Bool?
        let password: String?
        let albumIds: [String]?
    }

    private func visitorRequests() -> [VisitorRequest] {
        var request = URLRequest(url: URL(string: "\(stub)/__requests")!)
        request.timeoutInterval = 5
        let done = DispatchSemaphore(value: 0)
        var body = ""
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { body = String(decoding: data, as: UTF8.self) }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 6), .success, "stub did not answer /__requests")
        return (try? JSONDecoder().decode([VisitorRequest].self, from: Data(body.utf8))) ?? []
    }

    private func describeVisits(_ visits: [VisitorRequest]) -> String {
        visits.map { visit in
            "\(visit.method) \(visit.path) slug=\(visit.slug ?? "-") key=\(visit.key ?? "-") "
                + "cookie=\(visit.cookie.map(String.init) ?? "-") auth=\(visit.authorization.map(String.init) ?? "-") "
                + "password=\(visit.password ?? "-") albumIds=\(visit.albumIds ?? [])"
        }.joined(separator: "\n")
    }

    /// The stub's log grows as the app makes its requests, and an assertion that
    /// reads it the instant a cell appears can beat the image load — so wire
    /// assertions poll briefly instead of assuming the request already landed.
    private func pollVisits(
        until predicate: ([VisitorRequest]) -> Bool,
        timeout: TimeInterval = 15
    ) -> [VisitorRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var visits = visitorRequests()
        while !predicate(visits), Date() < deadline {
            sleep(1)
            visits = visitorRequests()
        }
        return visits
    }

    /// Proves a visit happened with the expected cookie state, and that no visit
    /// ever carried a bearer token: the app is signed in, so an accidental
    /// `Authorization` would silently read the link as its owner.
    private func assertStubVisitedSharedLink(
        method: String,
        path: String,
        cookie: Bool? = nil,
        password: String? = nil,
        slug: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func matches(_ visit: VisitorRequest) -> Bool {
            visit.method == method && visit.path == path
                && (cookie == nil || visit.cookie == cookie)
                && (password == nil || visit.password == password)
                && (slug == nil || visit.slug == slug)
        }
        let visits = pollVisits { $0.contains(where: matches) }
        XCTAssertTrue(visits.contains(where: matches),
                      "no \(method) \(path) cookie=\(cookie.map(String.init) ?? "-") "
                      + "password=\(password ?? "-") slug=\(slug ?? "-") on the wire — got:\n\(describeVisits(visits))",
                      file: file, line: line)
        XCTAssertFalse(visits.contains { $0.authorization == true },
                       "a shared link is read as a visitor — no visit may carry a bearer token",
                       file: file, line: line)
    }

    /// An album link's grid can only come from `POST /search/metadata` with an
    /// `albumIds` filter — the server 400s an unfiltered search under
    /// shared-link auth.
    private func assertStubSearchedSharedAlbum(albumId: String, file: StaticString = #filePath, line: UInt = #line) {
        func matches(_ visit: VisitorRequest) -> Bool {
            visit.method == "POST" && visit.path == "/api/search/metadata" && visit.albumIds == [albumId]
        }
        let visits = pollVisits { $0.contains(where: matches) }
        XCTAssertTrue(visits.contains(where: matches),
                      "the album link's photos did not come from an albumIds search — got:\n\(describeVisits(visits))",
                      file: file, line: line)
    }

    /// The photos themselves are public reads: each thumbnail must be requested
    /// with the link's credential in its URL, or a visitor gets empty tiles.
    private func assertStubLoadedSharedThumbnail(slug: String, file: StaticString = #filePath, line: UInt = #line) {
        func matches(_ visit: VisitorRequest) -> Bool {
            visit.path.hasSuffix("/thumbnail") && visit.slug == slug
        }
        let visits = pollVisits { $0.contains(where: matches) }
        XCTAssertTrue(visits.contains(where: matches),
                      "the grid never loaded a thumbnail with the link's credential — got:\n\(describeVisits(visits))",
                      file: file, line: line)
    }

    // MARK: - Language picker (issue #21)

    /// Me hub → Language: the list is reachable, a choice is persisted, the app
    /// retranslates itself at once, and the choice survives a relaunch because
    /// `AppLanguageStore` wrote `AppleLanguages`.
    ///
    /// Rows are matched by identifier, never by label: every label on this
    /// screen is translated by definition. The scenario ends by handing the
    /// choice back to the system, so it leaves the simulator the way it found it
    /// — the rest of the suite walks on localized copy.
    func test_11_languagePicker() throws {
        setProvider("auto")
        resetStacks()
        app.launch()
        if waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30) {
            walkOnboardingToLogin()
            XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
            dismissSystemSignInAlertIfPresent()
            _ = tapAuthorizeInProvider()
        }
        XCTAssertTrue(app.tabBars.buttons["Photos"].waitForExistence(timeout: 30),
                      "Authorized shell missing")
        sleep(4)

        let profile = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 15), "Profile avatar missing")
        profile.tap()
        sleep(3)

        let hubRow = app.buttons.matching(identifier: "languageRow").firstMatch
        for _ in 0..<6 where !hubRow.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(hubRow.waitForExistence(timeout: 10),
                      "Language row missing in the Me hub:\n\(app.debugDescription)")
        hubRow.tap()
        sleep(3)

        // Every language the catalog ships must be offered — a picker that
        // cannot offer French is the regression this card exists for.
        for code in ["en", "fr", "de", "es", "it"] {
            let row = app.buttons.matching(identifier: "languageRow.\(code)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "language row \(code) missing")
        }
        XCTAssertTrue(app.switches.matching(identifier: "useSystemLanguageToggle").firstMatch.exists,
                      "Use System Language toggle missing")
        shot("46-language-picker")

        // Pick the language the app is NOT rendering in: the title reads back
        // which one that is, so the scenario never assumes the simulator's
        // language. The view tree follows the injected locale immediately, and
        // the restart notice states what still waits for the next launch.
        let titles = ["Language": "en", "Langue": "fr", "Sprache": "de", "Idioma": "es", "Lingua": "it"]
        let current = titles.first { app.navigationBars[$0.key].exists }?.value ?? "en"
        let target = current == "de" ? "fr" : "de"
        app.buttons.matching(identifier: "languageRow.\(target)").firstMatch.tap()
        sleep(2)

        let dismiss = app.buttons.matching(identifier: "languageToastDismiss").firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10),
                      "no restart notice after changing language:\n\(app.debugDescription)")
        shot("46-language-changed")

        // The screen's own copy is already in the new language: the catalog is
        // being read through the injected locale, not the launch language. The
        // navigation bar's title is NOT part of this check — it is bridged to
        // UIKit and follows on the next push, like the rest of what the notice
        // promises.
        let sectionHeaders = ["en": "App Language", "fr": "Langue de l'app", "de": "App-Sprache", "es": "Idioma de la app", "it": "Lingua dell'app"]
        let expectedHeader = sectionHeaders[target]!
        XCTAssertTrue(app.staticTexts[expectedHeader].waitForExistence(timeout: 10),
                      "the picker did not retranslate in place (\(expectedHeader) missing):\n\(app.debugDescription)")

        // Relaunch: only `AppleLanguages` can make `Bundle` lookups follow, which
        // is exactly what the notice promised.
        dismiss.tap()
        sleep(1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 30),
                      "app did not come back after the language change")
        sleep(3)
        app.buttons.matching(identifier: "profileAvatar").firstMatch.tap()
        sleep(2)
        let pinnedRow = app.buttons.matching(identifier: "languageRow").firstMatch
        for _ in 0..<6 where !pinnedRow.exists {
            app.swipeUp()
            sleep(1)
        }
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 10), "Language row missing after relaunch")
        pinnedRow.tap()
        sleep(2)
        let targetRow = app.buttons.matching(identifier: "languageRow.\(target)").firstMatch
        XCTAssertTrue(targetRow.waitForExistence(timeout: 10), "language list missing after relaunch")
        XCTAssertTrue(targetRow.isSelected,
                      "the choice did not survive the relaunch: \(target) is not the selected row")
        shot("46-language-persisted")

        // Hand the language back to the system so the rest of the suite (and the
        // simulator) is left exactly as found.
        app.switches.matching(identifier: "useSystemLanguageToggle").firstMatch.tap()
        sleep(1)
        let notice = app.buttons.matching(identifier: "languageToastDismiss").firstMatch
        if notice.waitForExistence(timeout: 5) { notice.tap() }
        app.terminate()
    }
}
