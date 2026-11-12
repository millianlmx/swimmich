import XCTest

/// Content collections outside the "Me" sheet (L-12, B-16): the 15 collections
/// open in at most two touches from a content tab, and the Me sheet keeps only
/// the account, the settings and the tools.
///
/// Against `immich_stub_collections.py`, which gives every collection one
/// element of its own (see the stub's header). Everything is read by
/// `accessibilityIdentifier`; localized text appears only in `test_AC_139`, whose
/// whole point is the translation (the catalog is not embedded in the UI target,
/// so the expected strings are written out here).
///
/// TOUCH COUNT (decision #1). It starts from the host tab shown at its root: the
/// touch that SELECTS the tab, the scrolling, and the PIN of the locked folder
/// do not count. Every other touch goes through `tapCounted`, which is also
/// where a touch on the Me avatar would be noticed.
///
/// SESSION. Every launch of `start()` passes `-authServerURL ()`: the restore
/// finds no server and wipes the token, so the onboarding and the OAuth sign-in
/// run each time, and `tearDown` relaunches once the same way to erase the
/// session whatever state a method died in.
///
/// Run it with the launcher, never by hand:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/collections.uitest.log \
///         UITests/stubs/immich_stub_collections.py ContentCollectionsUITests --erase
final class ContentCollectionsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    private var touches = 0
    private var avatarTouched = false

    // MARK: - The stub's fixtures (recopied from immich_stub_collections.py)

    private let ordinary = ["aaaaaaaa-1111-4111-8111-000000000001", "aaaaaaaa-1111-4111-8111-000000000002"]
    private let favorites = ["fafafafa-1111-4111-8111-000000000001", "fafafafa-1111-4111-8111-000000000002"]
    private let archived = ["acacacac-1111-4111-8111-000000000001", "acacacac-1111-4111-8111-000000000002"]
    private let trashed = "dddddddd-1111-4111-8111-000000000001"
    private let locked = "1c1c1c1c-1111-4111-8111-000000000001"
    private let taken = "bbbbbbbb-1111-4111-8111-000000000001"
    private let added = "cccccccc-1111-4111-8111-000000000001"
    private let partner = "aaaaaaaa-5555-4555-8555-000000000001"
    private let partnerPhoto = "a5a5a5a5-1111-4111-8111-000000000001"
    private let ada = "eeeeeeee-3333-4333-8333-000000000001"
    private let adaPhoto = "e1e1e1e1-1111-4111-8111-000000000001"
    private let tag = "7a000000-0000-4000-8000-000000000001"
    private let stack = "57ac0000-1111-4111-8111-000000000001"
    private let stackMember = "57ac0001-1111-4111-8111-000000000001"
    private let folderPhoto = "dd000001-1111-4111-8111-000000000001"
    private let duplicate = "d9d9d9d9-1111-4111-8111-000000000000"
    private let album = "a1b2c3d4-1111-4111-8111-000000000001"
    private let pin = "123456"

    private static let libraryRows = [
        "recentTakenRow", "recentAddedRow", "peopleRow", "tagsRow", "foldersRow", "stacksRow",
        "partnersRow", "localLibraryRow", "offlineStorageRow", "duplicatesRow", "trashRow", "lockedFolderRow",
    ]
    private static let screenIDs = [
        "recentTakenScreen", "recentAddedScreen", "trashScreen", "peopleScreen", "tagsScreen", "stacksScreen",
        "partnersScreen", "foldersScreen", "localLibraryScreen", "duplicatesScreen", "offlineStorageScreen",
    ]

    private static let welcome = ["Your photo library", "Votre photothèque"]
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
        app.terminate()
        app.launchArguments = launchArguments
        app.launch()
        XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                      "the cleanup launch did not reach the onboarding: the session may have survived")
        app.terminate()
    }

    // MARK: - The 15 collections

    private enum Collection: CaseIterable, CustomStringConvertible {
        case recentTaken, recentAdded, favorites, archive, trash, people, places, tags, stacks
        case partners, folders, lockedFolder, localLibrary, duplicates, offlineStorage

        /// The Albums tab's Library tile (nil: Favorites and Archive are the
        /// Photos filter, Places is Search's Explore).
        var tile: String? {
            switch self {
            case .recentTaken: "recentTakenRow"
            case .recentAdded: "recentAddedRow"
            case .trash: "trashRow"
            case .people: "peopleRow"
            case .tags: "tagsRow"
            case .stacks: "stacksRow"
            case .partners: "partnersRow"
            case .folders: "foldersRow"
            case .lockedFolder: "lockedFolderRow"
            case .localLibrary: "localLibraryRow"
            case .duplicates: "duplicatesRow"
            case .offlineStorage: "offlineStorageRow"
            case .favorites, .archive, .places: nil
            }
        }

        var screenID: String? {
            switch self {
            case .recentTaken: "recentTakenScreen"
            case .recentAdded: "recentAddedScreen"
            case .trash: "trashScreen"
            case .people: "peopleScreen"
            case .tags: "tagsScreen"
            case .stacks: "stacksScreen"
            case .partners: "partnersScreen"
            case .folders: "foldersScreen"
            case .localLibrary: "localLibraryScreen"
            case .duplicates: "duplicatesScreen"
            case .offlineStorage: "offlineStorageScreen"
            case .favorites, .archive, .places, .lockedFolder: nil
            }
        }

        var description: String { String(describing: self) }
    }

    // MARK: - The scenarios

    /// AC-24: each of the 15 collections is reached in at most two touches from
    /// its host tab, without the Me avatar.
    func test_AC_24() throws {
        try start()
        for collection in Collection.allCases {
            visit(collection)
            assertReached(collection)
            leave(collection)
        }
    }

    /// AC-133: the proof of opening of every collection, within two touches.
    func test_AC_133() throws {
        try start()
        var screens = Set<String>()
        for collection in Collection.allCases {
            visit(collection)
            assertReached(collection)
            assertProof(collection)
            if let screen = collection.screenID { screens.insert(screen) }
            leave(collection)
        }
        XCTAssertEqual(screens.count, 11, "the screen identifiers of the Library collections are not pairwise distinct")
    }

    /// AC-134: Favorites then Archive show exactly their photos, and the journal
    /// shows the filter on both timeline routes.
    func test_AC_134() throws {
        try start()
        selectTab("Photos")
        XCTAssertTrue(element("filterMenu").waitForExistence(timeout: 15), "no filter menu on the Photos tab")
        for (raw, label, expected) in [("favorites", "Favorites", favorites), ("archived", "Archived", archived)] {
            chooseFilter(raw, label: label)
            XCTAssertTrue(waitUntil(timeout: 20) { !self.element("assetTile_\(self.ordinary[0])").exists },
                          "the ordinary photo is still on screen under \(label)")
            XCTAssertTrue(waitUntil(timeout: 20) { self.assetTiles(in: nil) == Set(expected) },
                          "\(label) shows \(assetTiles(in: nil).sorted()) instead of \(expected)")
            let (param, value) = raw == "favorites" ? ("isFavorite", "true") : ("visibility", "archive")
            for path in ["/api/timeline/buckets", "/api/timeline/bucket"] {
                XCTAssertTrue(stubRequests().contains { $0.path == path && $0.params[param] == value },
                              "no \(path) with \(param)=\(value) in the journal:\n\(describe(stubRequests()))")
            }
        }
    }

    /// AC-135: the locked folder shows its door before any photo, and the grid
    /// appears only after the right PIN.
    func test_AC_135() throws {
        try start()
        goToAlbumsRoot()
        openTile("lockedFolderRow")
        XCTAssertTrue(element("lockedFolderPINField").waitForExistence(timeout: 15), "no PIN door")
        XCTAssertTrue(element("lockedFolderUnlockButton").exists, "no unlock button on the door")
        XCTAssertTrue(assetTiles(in: nil).isEmpty, "a photo is visible before the PIN")
        submitPIN("000000")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(element("lockedFolderPINField").exists, "a wrong PIN opened the folder")
        XCTAssertTrue(assetTiles(in: nil).isEmpty, "a photo is visible after a wrong PIN")
        submitPIN(pin)
        XCTAssertTrue(element("assetTile_\(locked)").waitForExistence(timeout: 20),
                      "the folder did not open after the right PIN — \(screenReads())")
    }

    /// AC-136: sub-screen, photo, two ways back, one navigation bar at each step.
    func test_AC_136() throws {
        try start()
        // (collection tile, row to open, sub-screen, photo in the sub-screen, parent screen)
        let flows: [(tile: String, parent: String, row: String, sub: String, photo: String)] = [
            ("peopleRow", "peopleScreen", "personRow_\(ada)", "personScreen_\(ada)", "assetTile_\(adaPhoto)"),
            ("foldersRow", "foldersScreen", "folderRow_/Photos", "folderScreen_/Photos", "assetTile_\(folderPhoto)"),
            ("partnersRow", "partnersScreen", "partnerLibraryLink-\(partner)", "partnerLibraryGrid", "assetTile_\(partnerPhoto)"),
            // A stack member is a row, not a grid tile: it has its own identifier.
            ("stacksRow", "stacksScreen", "stackRow_\(stack)", "stackDetailScreen", "stackMember_\(stackMember)"),
        ]
        for flow in flows {
            goToAlbumsRoot()
            openTile(flow.tile)                                                       // 1
            XCTAssertTrue(element(flow.parent).waitForExistence(timeout: 20), "\(flow.parent) never appeared")
            assertSingleNavigationBar("\(flow.tile): collection")
            let row = element(flow.row)
            XCTAssertTrue(row.waitForExistence(timeout: 20), "no \(flow.row) — \(screenReads())")
            row.tap()                                                                 // 2
            XCTAssertTrue(element(flow.sub).waitForExistence(timeout: 20), "\(flow.sub) never appeared")
            assertSingleNavigationBar("\(flow.tile): sub-screen")
            let photo = element(flow.photo)
            XCTAssertTrue(photo.waitForExistence(timeout: 20), "no \(flow.photo) in \(flow.sub)")
            photo.tap()                                                               // 3
            let viewerBack = element("viewerBackButton")
            XCTAssertTrue(viewerBack.waitForExistence(timeout: 20), "the viewer did not open from \(flow.sub)")
            viewerBack.tap()                                                          // 4
            XCTAssertTrue(element(flow.sub).waitForExistence(timeout: 15), "\(flow.sub) is gone after the viewer")
            assertSingleNavigationBar("\(flow.tile): after the viewer")
            tapBack()                                                                 // 5
            XCTAssertTrue(element(flow.parent).waitForExistence(timeout: 15), "the first back did not reach \(flow.parent)")
            assertSingleNavigationBar("\(flow.tile): first back")
            tapBack()                                                                 // 6
            XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 15),
                          "the second back did not reach the Albums tab root")
            assertSingleNavigationBar("\(flow.tile): second back")
        }
    }

    /// AC-137: an open locked folder closes when the app goes to the background,
    /// from its own tab or from another one.
    func test_AC_137() throws {
        try start()
        goToAlbumsRoot()
        openTile("lockedFolderRow")
        unlockLockedFolder()
        let locksBefore = lockRequests()
        backgroundAndReturn()
        assertDoorBack(locksBefore: locksBefore, "after the background, on the folder's own tab")

        // Second pass: unlocked, then the Photos tab, then the background.
        unlockLockedFolder()
        let locksMid = lockRequests()
        selectTab("Photos")
        XCTAssertTrue(element("filterMenu").waitForExistence(timeout: 15))
        backgroundAndReturn()
        selectTab("Albums")
        assertDoorBack(locksBefore: locksMid, "after the background, from another tab")
    }

    /// AC-138: with the read-only mode on, emptying the Trash opened from the
    /// Albums tab is refused and nothing is written.
    func test_AC_138() throws {
        try start()
        openMeSheet(from: "Photos")
        let toggle = reveal(app.switches.matching(identifier: "readOnlyModeToggle").firstMatch)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", "the read-only switch did not turn on")
        dismissMeSheet()
        let journalMark = stubRequests().count

        goToAlbumsRoot()
        openTile("trashRow")
        XCTAssertTrue(element("assetTile_\(trashed)").waitForExistence(timeout: 25), "the trash is empty — \(screenReads())")
        let empty = element("trashEmptyButton")
        XCTAssertTrue(waitUntil(timeout: 15) { empty.isEnabled }, "Empty Trash stays disabled")
        empty.tap()
        let confirm = element("trashEmptyConfirmButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no confirmation for Empty Trash")
        confirm.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15), "the refusal showed no alert")
        app.alerts.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(element("assetTile_\(trashed)").exists, "the trashed photo left the screen")
        let reads: Set<String> = ["POST /api/search/metadata", "POST /api/search/statistics"]
        let writes = stubRequests().dropFirst(journalMark).filter {
            $0.method != "GET" && !reads.contains("\($0.method) \($0.path)")
        }
        XCTAssertTrue(writes.isEmpty, "a write reached the stub in read-only mode:\n\(describe(Array(writes)))")
        XCTAssertFalse(stubRequests().contains { $0.method == "POST" && $0.path == "/api/trash/empty" })
    }

    /// AC-139: in French, German, Spanish and Italian, the Library title, every
    /// tile and the filter button read in the language of the app.
    func test_AC_139() throws {
        try start()
        let expected: [(code: String, locale: String, albums: String, library: String, filter: String, tiles: [String])] = [
            ("fr", "fr_FR", "Albums", "Bibliothèque", "Filtrer",
             ["Prises récemment", "Ajoutées récemment", "Personnes", "Étiquettes", "Dossiers", "Piles", "Partenaires",
              "Sur cet appareil", "Stockage hors ligne", "Doublons", "Corbeille", "Dossier verrouillé"]),
            ("de", "de_DE", "Alben", "Mediathek", "Filter",
             ["Kürzlich aufgenommen", "Kürzlich hinzugefügt", "Personen", "Tags", "Ordner", "Stapel", "Partner",
              "Auf diesem Gerät", "Offline-Speicher", "Duplikate", "Papierkorb", "Gesperrter Ordner"]),
            ("es", "es_ES", "Álbumes", "Biblioteca", "Filtrar",
             ["Tomadas recientemente", "Añadidas recientemente", "Personas", "Etiquetas", "Carpetas", "Pilas", "Socios",
              "En este dispositivo", "Almacenamiento sin conexión", "Duplicados", "Papelera", "Carpeta bloqueada"]),
            ("it", "it_IT", "Album", "Libreria", "Filtro",
             ["Scattate di recente", "Aggiunte di recente", "Persone", "Etichette", "Cartelle", "Gruppi", "Partner",
              "Su questo dispositivo", "Archiviazione offline", "Duplicati", "Cestino", "Cartella bloccata"]),
        ]
        for language in expected {
            // The session is kept (no `-authServerURL`): only the language changes.
            app.terminate()
            app.launchArguments = ["-AppleLanguages", "(\(language.code))", "-AppleLocale", language.locale]
            app.launch()
            dismissWhatsNewIfPresent()
            XCTAssertTrue(app.tabBars.buttons[language.albums].waitForExistence(timeout: 40),
                          "\(language.code): no Albums tab — \(screenReads())")
            app.tabBars.buttons[language.albums].tap()
            let section = element("albumsLibrarySection")
            XCTAssertTrue(section.waitForExistence(timeout: 20), "\(language.code): no Library section")
            XCTAssertTrue(section.descendants(matching: .staticText)[language.library].exists
                          || app.staticTexts[language.library].exists,
                          "\(language.code): the Library title is not \(language.library) — \(screenReads())")
            for (row, title) in zip(Self.libraryRows, language.tiles) {
                let tile = scrolledButton(row)
                XCTAssertTrue(tile.exists, "\(language.code): no \(row)")
                XCTAssertEqual(tile.label, title, "\(language.code): \(row) reads \(tile.label)")
            }
            app.tabBars.buttons.element(boundBy: 0).tap()
            let filter = element("filterMenu")
            XCTAssertTrue(filter.waitForExistence(timeout: 20), "\(language.code): no filter button")
            XCTAssertEqual(filter.label, language.filter, "\(language.code): the filter button reads \(filter.label)")
        }
    }

    /// AC-25: no entry of the Me sheet leads to a collection, and the tab bar
    /// still has five items.
    func test_AC_25() throws {
        try start()
        selectTab("Memories")
        XCTAssertEqual(app.tabBars.buttons.count, 5, "the tab bar does not have five items")
        openMeSheet(from: "Memories")
        XCTAssertEqual(app.tabBars.buttons.count, 5, "the tab bar changed under the sheet")
        var seen = Set<String>()
        for _ in 0..<16 {
            for id in Self.libraryRows where element(id).exists { seen.insert(id) }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(seen.isEmpty, "the Me sheet still offers \(seen.sorted())")
        XCTAssertTrue(element("logoutButton").exists, "the Me sheet was not scrolled to its end")
    }

    /// AC-140: the Me sheet's entries are EXACTLY the allowed list (administrator
    /// with two saved accounts), and nothing it pushes leads to a collection.
    func test_AC_140() throws {
        try start()
        // A second account, signed in through the same OAuth stub.
        stubControl("user?id=22222222-2222-4222-8222-222222222222&email=second@example.com&name=Second%20User")
        openMeSheet(from: "Photos")
        let add = reveal(element("addAccountButton"))
        add.tap()
        signInAfterAddAccount()
        selectTab("Memories")
        openMeSheet(from: "Memories")

        let allowed: Set<String> = [
            "profilePictureRow", "addAccountButton", "openInBrowserButton", "preferencesRow", "languageRow",
            "backupRow", "notificationsRow", "freeUpSpaceRow", "apiKeysRow", "adminRow", "aboutRow",
            "customHeadersRow", "appLogsRow", "mediaStatsRow", "downloadInfoRow", "clientCertificateRow",
            "changePasswordRow", "appLockToggle", "deviceSessionsRow", "readOnlyModeToggle", "logoutButton",
        ]
        var found = Set<String>()
        let list = element("profileList")
        XCTAssertTrue(list.waitForExistence(timeout: 20), "no profileList")
        for _ in 0..<20 {
            for kind in [XCUIElement.ElementType.button, .switch] {
                for control in list.descendants(matching: kind).allElementsBoundByIndex where control.exists {
                    let id = control.identifier
                    found.insert(id.isEmpty || id == "profileList" ? "<no identifier: \(control.label)>" : id)
                }
            }
            if element("logoutButton").exists && element("logoutButton").isHittable { break }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
        }
        let accounts = found.filter { $0.hasPrefix("savedAccountRow_") }
        XCTAssertEqual(accounts.count, 2, "one row per saved account expected: \(found.sorted())")
        XCTAssertEqual(found.subtracting(accounts), allowed, "the Me sheet's entries differ from the list: \(found.sorted())")

        let pushed = ["profilePictureRow", "preferencesRow", "languageRow", "backupRow", "notificationsRow",
                      "freeUpSpaceRow", "apiKeysRow", "adminRow", "aboutRow", "customHeadersRow", "appLogsRow",
                      "mediaStatsRow", "downloadInfoRow", "clientCertificateRow", "changePasswordRow",
                      "deviceSessionsRow"]
        for row in pushed {
            let link = reveal(app.buttons.matching(identifier: row).firstMatch)
            XCTAssertTrue(link.waitForExistence(timeout: 10), "no \(row) in the Me sheet")
            link.tap()
            Thread.sleep(forTimeInterval: 1.5)
            assertNoCollectionVisible(on: row)
            tapBack()
        }
    }

    /// AC-141: five tabs, each root one touch away, and the list of albums in
    /// each of its states under the Library section.
    func test_AC_141() throws {
        try start()
        XCTAssertEqual(app.tabBars.buttons.count, 5, "the tab bar does not have five items")
        selectTab("Photos")
        XCTAssertTrue(element("filterMenu").waitForExistence(timeout: 15), "Photos has no filter button")
        selectTab("Memories")
        XCTAssertTrue(element("memoriesCreateButton").waitForExistence(timeout: 15), "Memories root missing")
        selectTab("Shared")
        XCTAssertTrue(element("newSharedLinkButton").waitForExistence(timeout: 15), "Shared root missing")
        selectTab("Photos")
        selectTab("Search")
        XCTAssertTrue(element("searchModeSegment_results").waitForExistence(timeout: 15), "Search root missing")

        // The album grid.
        goToAlbumsRoot()
        let card = scrolledButton("albumCard_\(album)")
        XCTAssertTrue(card.exists, "no album card — \(screenReads())")
        XCTAssertTrue(element("albumsLibrarySection").exists)
        card.tap()
        let title = element("albumHeroTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the album did not open")
        XCTAssertEqual(title.label, "Stub Album")
        assertSingleNavigationBar("album detail")
        tapBack()
        XCTAssertTrue(element("albumsLibrarySection").waitForExistence(timeout: 15))
        XCTAssertTrue(scrolledButton("albumCard_\(album)").exists, "the card is gone after the back")

        // Error, set BEFORE the launch: a refresh after a success keeps the albums.
        relaunch(albums: "error")
        goToAlbumsRoot()
        XCTAssertTrue(scrolledButton("albumsRetryButton").exists, "no retry button in the error state")
        XCTAssertFalse(element("albumCard_\(album)").exists, "an album card in the error state")
        XCTAssertTrue(element("albumsLibrarySection").exists, "the Library vanished with the error")
        XCTAssertEqual(visibleLibraryTiles(), Set(Self.libraryRows), "the Library lost tiles in the error state")
        stubControl("albums?mode=normal")
        scrolledButton("albumsRetryButton").tap()
        XCTAssertTrue(scrolledButton("albumCard_\(album)").waitForExistence(timeout: 20), "the retry did not bring the album back")
        XCTAssertTrue(element("albumsLibrarySection").exists)

        // Empty.
        relaunch(albums: "empty")
        goToAlbumsRoot()
        XCTAssertTrue(scrolledButton("albumsCreateButton").exists, "no Create Album in the empty state")
        XCTAssertFalse(element("albumCard_\(album)").exists)
        XCTAssertTrue(element("albumsLibrarySection").exists)
    }

    // MARK: - Walking to a collection

    /// Starts from the host tab's root, follows the path of the collection, and
    /// leaves `touches`/`avatarTouched` for the assertions.
    private func visit(_ collection: Collection) {
        touches = 0
        avatarTouched = false
        switch collection {
        case .favorites:
            goToPhotosRoot()
            chooseFilter("favorites", label: "Favorites")
        case .archive:
            goToPhotosRoot()
            chooseFilter("archived", label: "Archived")
        case .places:
            goToSearchRoot()
            tapCounted(element("searchModeSegment_explore"))
        default:
            goToAlbumsRoot()
            tapCounted(scrolledButton(collection.tile!))
            if collection == .localLibrary { allowPhotosIfAsked() }
        }
    }

    private func assertReached(_ collection: Collection) {
        XCTAssertLessThanOrEqual(touches, 2, "\(collection) took \(touches) touches")
        XCTAssertFalse(avatarTouched, "\(collection) went through the Me avatar")
        switch collection {
        case .favorites, .archive:
            XCTAssertTrue(element("filterMenu").exists)
            let value = (element("filterMenu").value as? String) ?? ""
            XCTAssertEqual(value, collection == .favorites ? "Favorites" : "Archived", "\(collection): filter value")
        case .places:
            XCTAssertTrue(element("explorePlaceCard_Lisbon").waitForExistence(timeout: 30), "\(collection) shows no place — \(screenReads())")
        case .lockedFolder:
            XCTAssertTrue(element("lockedFolderPINField").waitForExistence(timeout: 20), "\(collection) shows no door — \(screenReads())")
        default:
            XCTAssertTrue(element(collection.screenID!).waitForExistence(timeout: 25),
                          "\(collection) never showed \(collection.screenID!) — \(screenReads())")
        }
    }

    /// The proof of opening of req.md for each collection.
    private func assertProof(_ collection: Collection) {
        func tile(_ id: String, in screen: String) {
            XCTAssertTrue(element("assetTile_\(id)").waitForExistence(timeout: 30), "\(collection): no tile \(id) in \(screen)")
        }
        func present(_ id: String) {
            XCTAssertTrue(element(id).waitForExistence(timeout: 30), "\(collection): no \(id) — \(screenReads())")
        }
        if collection != .favorites && collection != .archive && collection != .places && collection != .lockedFolder {
            assertSingleNavigationBar("\(collection)")
        }
        switch collection {
        case .recentTaken:
            tile(taken, in: "recentTakenScreen")
            XCTAssertFalse(element("recentAddedScreen").exists)
        case .recentAdded:
            tile(added, in: "recentAddedScreen")
            XCTAssertFalse(element("recentTakenScreen").exists)
        case .favorites:
            XCTAssertTrue(waitUntil(timeout: 25) { !self.element("assetTile_\(self.ordinary[0])").exists })
            XCTAssertTrue(waitUntil(timeout: 25) { self.assetTiles(in: nil) == Set(self.favorites) },
                          "Favorites shows \(assetTiles(in: nil).sorted())")
        case .archive:
            XCTAssertTrue(waitUntil(timeout: 25) { !self.element("assetTile_\(self.ordinary[0])").exists })
            XCTAssertTrue(waitUntil(timeout: 25) { self.assetTiles(in: nil) == Set(self.archived) },
                          "Archive shows \(assetTiles(in: nil).sorted())")
        case .trash:
            tile(trashed, in: "trashScreen")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(assetTiles(in: "trashScreen"), [trashed],
                           "the Trash shows \(assetTiles(in: "trashScreen").sorted()) instead of the one trashed photo")
        case .people: present("personRow_\(ada)")
        case .places:
            present("explorePlaceCard_Porto")
            XCTAssertTrue(stubRequests().contains { $0.path == "/api/search/cities" }, "GET /api/search/cities is not in the journal")
        case .tags: present("tagRow_root_\(tag)")
        case .stacks: present("stackRow_\(stack)")
        case .partners: present("partnerLibraryLink-\(partner)")
        case .folders: present("folderRow_/Photos")
        case .lockedFolder:
            present("lockedFolderUnlockButton")
            XCTAssertTrue(assetTiles(in: nil).isEmpty, "a photo of the locked folder is visible before the PIN")
        case .localLibrary: present("localLibrarySummary")
        case .duplicates: present("duplicateGroup_\(duplicate)")
        case .offlineStorage: present("offlineUsageRing")
        }
    }

    /// Back to the root of the host tab, not counted.
    private func leave(_ collection: Collection) {
        switch collection {
        case .favorites, .archive:
            if element("filterMenu").exists { chooseFilter("all", label: "All", counted: false) }
        case .places:
            element("searchModeSegment_results").tap()
        default:
            popToAlbumsRoot()
        }
    }

    private func goToAlbumsRoot() {
        selectTab("Albums")
        popToAlbumsRoot()
        let section = element("albumsLibrarySection")
        XCTAssertTrue(section.waitForExistence(timeout: 20), "the Albums tab shows no Library section — \(screenReads())")
    }

    private func popToAlbumsRoot() {
        for _ in 0..<6 {
            let section = element("albumsLibrarySection")
            if section.exists && section.isHittable { return }
            let viewerBack = element("viewerBackButton")
            if viewerBack.exists && viewerBack.isHittable { viewerBack.tap(); Thread.sleep(forTimeInterval: 0.8); continue }
            tapBack()
        }
    }

    private func goToPhotosRoot() {
        selectTab("Photos")
        XCTAssertTrue(element("filterMenu").waitForExistence(timeout: 20), "the Photos tab shows no filter button")
        if (element("filterMenu").value as? String) != "All" { chooseFilter("all", label: "All", counted: false) }
    }

    /// Search is only reachable from Photos or Memories (the bubble keeps its
    /// action on Albums and Shared).
    private func goToSearchRoot() {
        selectTab("Photos")
        selectTab("Search")
        XCTAssertTrue(element("searchModeSegment_results").waitForExistence(timeout: 20), "no Search root")
        element("searchModeSegment_results").tap()
    }

    private func chooseFilter(_ raw: String, label: String, counted: Bool = true) {
        let menu = element("filterMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "no filter menu")
        if counted { tapCounted(menu) } else { menu.tap() }
        let candidates = [element("timelineFilter_\(raw)"), app.buttons[label], app.menuItems[label]]
        var item: XCUIElement?
        for candidate in candidates where candidate.waitForExistence(timeout: 4) {
            item = candidate
            break
        }
        guard let item else { return XCTFail("no filter item \(raw) — \(screenReads())") }
        if counted { tapCounted(item) } else { item.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    private func openTile(_ identifier: String) {
        tapCounted(scrolledButton(identifier))
    }

    private func tapCounted(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 20), "nothing to touch — \(screenReads())")
        if element.identifier == "profileAvatar" { avatarTouched = true }
        touches += 1
        element.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// The button with this identifier, scrolled into view when it is not (a
    /// `LazyVGrid` and a `Form` only publish what they rendered).
    private func scrolledButton(_ identifier: String) -> XCUIElement {
        reveal(app.buttons.matching(identifier: identifier).firstMatch)
    }

    private func reveal(_ target: XCUIElement) -> XCUIElement {
        for direction in [true, false] {
            for _ in 0..<12 where !(target.exists && target.isHittable) {
                if direction { app.swipeUp() } else { app.swipeDown() }
                Thread.sleep(forTimeInterval: 0.5)
            }
            if target.exists && target.isHittable { break }
        }
        return target
    }

    private func selectTab(_ label: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no \(label) tab — \(screenReads())")
        tab.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func tapBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no way back — \(screenReads())")
        back.tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func assertSingleNavigationBar(_ step: String) {
        XCTAssertEqual(app.navigationBars.count, 1, "\(step): \(app.navigationBars.count) navigation bars")
    }

    // MARK: - Reading the screen

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The `assetTile_` ids under a screen container (or the whole app).
    private func assetTiles(in screen: String?) -> Set<String> {
        let root = screen.map { element($0) } ?? app.windows.firstMatch
        let tiles = root.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "assetTile_"))
        return Set(tiles.allElementsBoundByIndex.map { String($0.identifier.dropFirst("assetTile_".count)) })
    }

    /// The Library tiles that exist while scrolling from the top to the bottom.
    private func visibleLibraryTiles() -> Set<String> {
        var seen = Set<String>()
        for _ in 0..<2 {
            for _ in 0..<8 {
                for id in Self.libraryRows where element(id).exists { seen.insert(id) }
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.4)
            }
            for _ in 0..<8 { app.swipeDown() }
        }
        return seen
    }

    private func assertNoCollectionVisible(on row: String) {
        for id in Self.libraryRows + Self.screenIDs + ["filterMenu", "searchModeSegment_explore",
                                                      "albumsLibrarySection", "lockedFolderPINField"] {
            XCTAssertFalse(element(id).exists, "\(row) exposes \(id)")
        }
        let places = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "explorePlaceCard_"))
        XCTAssertEqual(places.count, 0, "\(row) exposes a place card")
    }

    private func screenReads() -> String {
        "screen reads: \(app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label))"
    }

    // MARK: - The locked folder

    private func submitPIN(_ digits: String) {
        let field = element("lockedFolderPINField")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no PIN field")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText(digits)
        let unlock = element("lockedFolderUnlockButton")
        XCTAssertTrue(unlock.waitForExistence(timeout: 10), "no unlock button")
        if !unlock.isHittable { app.swipeDown() }
        unlock.tap()
    }

    private func unlockLockedFolder() {
        submitPIN(pin)
        XCTAssertTrue(element("assetTile_\(locked)").waitForExistence(timeout: 25),
                      "the locked folder did not open — \(screenReads())")
    }

    private func lockRequests() -> Int {
        stubRequests().filter { $0.method == "POST" && $0.path == "/api/auth/session/lock" }.count
    }

    private func backgroundAndReturn() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        Thread.sleep(forTimeInterval: 2)
    }

    private func assertDoorBack(locksBefore: Int, _ context: String) {
        XCTAssertTrue(element("lockedFolderPINField").waitForExistence(timeout: 20), "the door did not come back \(context)")
        XCTAssertTrue(assetTiles(in: nil).isEmpty, "a locked photo is still visible \(context)")
        XCTAssertGreaterThan(lockRequests(), locksBefore, "no POST /api/auth/session/lock \(context)")
    }

    // MARK: - The Me sheet

    private func openMeSheet(from tab: String) {
        selectTab(tab)
        dismissWhatsNewIfPresent()
        let avatar = app.buttons.matching(identifier: "profileAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "no Me avatar on \(tab)")
        avatar.tap()
        XCTAssertTrue(element("profileList").waitForExistence(timeout: 20), "the Me sheet did not open")
        Thread.sleep(forTimeInterval: 2)
    }

    private func dismissMeSheet() {
        for _ in 0..<4 {
            if app.buttons.matching(identifier: "profileAvatar").firstMatch.isHittable { return }
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            top.press(forDuration: 0.1, thenDragTo: bottom)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - Launch and sign-in

    private func start() throws {
        if app.state != .notRunning { app.terminate() }
        stubGet("/__reset")
        stubGet("/__provider?mode=manual")
        installPhotoPromptHandler()
        app.launchArguments = launchArguments
        app.launch()
        signIn()
        settleOnShell()
    }

    /// The same session, the albums in another state (set before the launch).
    private func relaunch(albums mode: String) {
        app.terminate()
        stubControl("albums?mode=\(mode)")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        settleOnShell()
    }

    private func signIn() {
        XCTAssertTrue(waitForStaticText(Self.welcome, timeout: 30),
                      "the onboarding did not appear — the scenario would start from a stale session")
        walkOnboardingToLogin()
        finishOAuth()
    }

    /// "Add Account" returns to the onboarding; the stub then signs in as the
    /// user `/control/user` chose.
    private func signInAfterAddAccount() {
        XCTAssertTrue(app.buttons.matching(labelPredicate(["Get Started", "Commencer", "Check connection", "Vérifier la connexion"]))
            .firstMatch.waitForExistence(timeout: 30) || app.textFields.firstMatch.waitForExistence(timeout: 5),
                      "Add Account did not lead back to the onboarding")
        walkOnboardingToLogin()
        finishOAuth()
        settleOnShell()
    }

    private func finishOAuth() {
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.matching(labelPredicate(["Photos", "Fotos"]))
            .firstMatch.waitForExistence(timeout: 30), "OAuth did not reach the authenticated shell")
    }

    private func settleOnShell() {
        XCTAssertTrue(element("assetTile_\(ordinary[0])").waitForExistence(timeout: 40),
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
        // Typed on purpose: `app` is an IUO, so `[springboard, app]` would infer
        // `[XCUIApplication?]` and `host.alerts` would not compile.
        let hosts: [XCUIApplication] = [springboard, app]
        for host in hosts {
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

    private func stubControl(_ path: String) {
        let body = stubGet("/control/\(path)")
        XCTAssertFalse(body.isEmpty, "the stub rejected the control /control/\(path)")
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
