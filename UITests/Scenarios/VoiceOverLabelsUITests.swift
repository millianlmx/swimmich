import XCTest

/// End-to-end scenario for lot L-19 (B-23, AC-34): every button announces its
/// action. It reads, on the real screens and against
/// `immich_stub_voiceover.py`, what VoiceOver would say about a control: its
/// role (the element is looked up in `app.buttons`, so a control that lost its
/// button role is not found), its `label`, and, where the spec names it, its
/// `value` and its `isSelected` trait.
///
/// Rules of the scenario:
///
/// * An element is found by its `accessibilityIdentifier`, never by a localized
///   text. The only texts typed to navigate are the English item names of the
///   album menu ("Activity", "Road Trip"), which carry no identifier in the app
///   (and which are not asserted).
/// * The expected labels are written out below (`catalogue`), copied from
///   `Resources/Localizable.xcstrings`: a UI test target embeds no catalogue, so
///   it cannot read a translation. English is the catalogue key itself.
/// * The language is forced the way `PluralsUITests` does it:
///   `-AppleLanguages (xx) -AppleLocale xx_XX`; a relaunch keeps the session (no
///   `-authServerURL`).
/// * The slideshow hides its controls 3 s after the play start (without
///   VoiceOver, which the simulator behind XCUITest does not run; S-14 is proven
///   by `SlideshowChromeTests`). Before reading a slideshow control the scenario
///   waits 2 s for its identifier; absent, it touches the centre of the screen
///   once (`toggleControls`) and waits again. The play state is read on
///   `slideshowPlayPauseButton` right after the slideshow opens.
/// * A state the stub cannot provide in the forced language fails loudly: no
///   assertion is skipped or relaxed because an element is missing.
///
/// COMPILED, NOT RUN ON CI. `Scripts/ci.sh` builds this bundle
/// (`build-for-testing`) and runs only the unit bundle. All eleven tests are
/// compiled-but-not-run there; they are run by hand with the launcher, on an
/// erased device:
///
///     .omp/orchestration/uitest.sh <worktree> /tmp/voiceover.uitest.log \
///         UITests/stubs/immich_stub_voiceover.py VoiceOverLabelsUITests/<test> --erase
///
/// Two of them need more than the stub:
///
/// * `test_AC_34_7_widgetButtonsInFrench` drives SpringBoard (edit mode, widget
///   gallery) in FRENCH, as `ImmichWidgetHomeScreen` does, and reads the widget
///   buttons from `springboard.buttons`. SpringBoard follows the simulator's
///   language, not the app's: the test is skipped (`XCTSkip`) when the simulator
///   language is not French.
/// * `test_AC_34_7_shareExtensionButtons` drives Photos and the real share sheet
///   like `ShareExtensionUITests`: run it with `--media /tmp/media-share.png`
///   (the seeded file Photos shares).
///
/// A Menu is expected to be published as a button by XCUITest (as
/// `viewerOverflowMenu` is in the other scenarios); the map markers are
/// `MKAnnotationView`s whose accessibility depends on the photo sheet above the
/// map. Neither has been run: a failure there is a finding to look at, not a
/// reason to relax the assertion.
final class VoiceOverLabelsUITests: XCTestCase {

    private let stub = ProcessInfo.processInfo.environment["IMMICH_STUB_URL"] ?? "http://127.0.0.1:8421"
    private var app: XCUIApplication!

    // The stub's fixtures (recopied from immich_stub_voiceover.py).
    private let photoID = "aaaaaaaa-1111-4111-8111-000000000001"
    private let videoID = "aaaaaaaa-1111-4111-8111-000000000002"
    private let markerPlaceID = "dddddddd-2222-4222-8222-000000000001"
    private let markerBareID = "dddddddd-2222-4222-8222-000000000002"
    private let memoryID = "eeeeeeee-4444-4444-8444-000000000001"
    private let personID = "eeeeeeee-5555-4555-8555-000000000001"
    private let partnerID = "bbbbbbbb-2222-4222-8222-000000000002"
    private let linkID = "cccccccc-6666-4666-8666-000000000001"
    private let albumID = "22222222-2222-4222-8222-000000000019"
    private let albumPhotoID = "bbbbbbbb-4444-4444-8444-000000000001"
    private let partnerName = "Outgoing Olive"
    /// `MapPhoto.placeName`: city, state, country, joined by ", " (not localized).
    private let markerPlaceName = "Sydney, New South Wales, Australia"

    // MARK: - Languages

    private struct Lang {
        let code: String
        let locale: String
        /// `AppDateFormat` `.longDate` of 2024-07-29 (the photo and the video) and
        /// of 2024-08-02 (the album's photos), in that language.
        let photoDate: String
        let albumDate: String
    }

    private static let english = Lang(code: "en", locale: "en_US", photoDate: "July 29, 2024", albumDate: "August 2, 2024")
    private static let shipped = [
        Lang(code: "fr", locale: "fr_FR", photoDate: "29 juillet 2024", albumDate: "2 août 2024"),
        Lang(code: "de", locale: "de_DE", photoDate: "29. Juli 2024", albumDate: "2. August 2024"),
        Lang(code: "es", locale: "es_ES", photoDate: "29 de julio de 2024", albumDate: "2 de agosto de 2024"),
        Lang(code: "it", locale: "it_IT", photoDate: "29 luglio 2024", albumDate: "2 agosto 2024"),
    ]
    private static let everyLanguage = [english] + shipped

    /// Key → language → value, copied from `Resources/Localizable.xcstrings`.
    /// `%@` and `%lld` are the catalogue's own placeholders; a plural key is
    /// written once per category (`#one`, `#other`).
    private static let catalogue: [String: [String: String]] = [
        "Back": ["en": "Back", "fr": "Retour", "de": "Zurück", "es": "Atrás", "it": "Indietro"],
        "Close Slideshow": ["en": "Close Slideshow", "fr": "Fermer le diaporama", "de": "Diashow schließen", "es": "Cerrar presentación", "it": "Chiudi presentazione"],
        "Play": ["en": "Play", "fr": "Lire", "de": "Abspielen", "es": "Reproducir", "it": "Riproduci"],
        "Pause": ["en": "Pause", "fr": "Pause", "de": "Pause", "es": "Pausar", "it": "Pausa"],
        "Shuffle": ["en": "Shuffle", "fr": "Mélanger", "de": "Mischen", "es": "Mezclar", "it": "Mescola"],
        "Previous": ["en": "Previous", "fr": "Précédent", "de": "Zurück", "es": "Anterior", "it": "Precedente"],
        "Next": ["en": "Next", "fr": "Suivant", "de": "Weiter", "es": "Siguiente", "it": "Successivo"],
        "Slideshow Speed": ["en": "Slideshow Speed", "fr": "Vitesse du diaporama", "de": "Diashow-Geschwindigkeit", "es": "Velocidad de la presentación", "it": "Velocità presentazione"],
        "Transition": ["en": "Transition", "fr": "Transition", "de": "Übergang", "es": "Transición", "it": "Transizione"],
        "Favorite": ["en": "Favorite", "fr": "Favori", "de": "Favorit", "es": "Favorito", "it": "Preferito"],
        "Unfavorite": ["en": "Unfavorite", "fr": "Retirer des favoris", "de": "Favorit entfernen", "es": "Quitar de favoritos", "it": "Rimuovi dai preferiti"],
        "Rename": ["en": "Rename", "fr": "Renommer", "de": "Umbenennen", "es": "Cambiar nombre", "it": "Rinomina"],
        "Hide": ["en": "Hide", "fr": "Masquer", "de": "Ausblenden", "es": "Ocultar", "it": "Nascondi"],
        "Birthday": ["en": "Birthday", "fr": "Anniversaire", "de": "Geburtstag", "es": "Cumpleaños", "it": "Compleanno"],
        "Refresh people": ["en": "Refresh people", "fr": "Actualiser les personnes", "de": "Personen aktualisieren", "es": "Actualizar personas", "it": "Aggiorna persone"],
        "Merge person": ["en": "Merge person", "fr": "Fusionner la personne", "de": "Person zusammenführen", "es": "Combinar personas", "it": "Unisci persona"],
        "Detected text": ["en": "Detected text", "fr": "Texte détecté", "de": "Erkannter Text", "es": "Texto detectado", "it": "Testo rilevato"],
        "Slideshow": ["en": "Slideshow", "fr": "Diaporama", "de": "Diashow", "es": "Presentación", "it": "Presentazione"],
        "on": ["en": "on", "fr": "Activé", "de": "Ein", "es": "Activado", "it": "Attivato"],
        "off": ["en": "off", "fr": "Désactivé", "de": "Aus", "es": "Desactivado", "it": "Disattivato"],
        "Item": ["en": "Item", "fr": "Élément", "de": "Objekt", "es": "Elemento", "it": "Elemento"],
        "Item, %@": ["en": "Item, %@", "fr": "Élément, %@", "de": "Objekt, %@", "es": "Elemento, %@", "it": "Elemento, %@"],
        "Video %lld of %lld": ["en": "Video %lld of %lld", "fr": "Vidéo %lld sur %lld", "de": "Video %lld von %lld", "es": "Vídeo %lld de %lld", "it": "Video %lld di %lld"],
        "Photo %lld of %lld": ["en": "Photo %lld of %lld", "fr": "Photo %lld sur %lld", "de": "Foto %lld von %lld", "es": "Foto %lld de %lld", "it": "Foto %lld di %lld"],
        "Photo, %@": ["en": "Photo, %@", "fr": "Photo, %@", "de": "Foto, %@", "es": "Foto, %@", "it": "Foto, %@"],
        "Video, %@": ["en": "Video, %@", "fr": "Vidéo, %@", "de": "Video, %@", "es": "Vídeo, %@", "it": "Video, %@"],
        "Remove rating": ["en": "Remove rating", "fr": "Retirer la note", "de": "Bewertung entfernen", "es": "Quitar la valoración", "it": "Rimuovi la valutazione"],
        "Search mode: %@": ["en": "Search mode: %@", "fr": "Mode de recherche : %@", "de": "Suchmodus: %@", "es": "Modo de búsqueda: %@", "it": "Modalità di ricerca: %@"],
        "Smart": ["en": "Smart", "fr": "Intelligent", "de": "Intelligent", "es": "Inteligente", "it": "Intelligente"],
        "Metadata": ["en": "Metadata", "fr": "Métadonnées", "de": "Metadaten", "es": "Metadatos", "it": "Metadati"],
        "Save search": ["en": "Save search", "fr": "Enregistrer la recherche", "de": "Suche speichern", "es": "Guardar búsqueda", "it": "Salva ricerca"],
        "Search by detected text": ["en": "Search by detected text", "fr": "Rechercher par texte détecté", "de": "Nach erkanntem Text suchen", "es": "Buscar por texto detectado", "it": "Cerca per testo rilevato"],
        "Invite a partner": ["en": "Invite a partner", "fr": "Inviter un partenaire", "de": "Partner einladen", "es": "Invitar a un socio", "it": "Invita un partner"],
        "Stop sharing with %@": ["en": "Stop sharing with %@", "fr": "Ne plus partager avec %@", "de": "Teilen mit %@ beenden", "es": "Dejar de compartir con %@", "it": "Interrompi condivisione con %@"],
        "Copy link": ["en": "Copy link", "fr": "Copier le lien", "de": "Link kopieren", "es": "Copiar enlace", "it": "Copia link"],
        "Share link": ["en": "Share link", "fr": "Partager le lien", "de": "Link teilen", "es": "Compartir enlace", "it": "Condividi link"],
        "Send comment": ["en": "Send comment", "fr": "Envoyer le commentaire", "de": "Kommentar senden", "es": "Enviar comentario", "it": "Invia commento"],
        "Show password": ["en": "Show password", "fr": "Afficher le mot de passe", "de": "Passwort anzeigen", "es": "Mostrar la contraseña", "it": "Mostra la password"],
        "Hide password": ["en": "Hide password", "fr": "Masquer le mot de passe", "de": "Passwort verbergen", "es": "Ocultar la contraseña", "it": "Nascondi la password"],
        "Scan server QR code": ["en": "Scan server QR code", "fr": "Scanner le code QR du serveur", "de": "Server-QR-Code scannen", "es": "Escanear el código QR del servidor", "it": "Scansiona il codice QR del server"],
        "Close": ["en": "Close", "fr": "Fermer", "de": "Schließen", "es": "Cerrar", "it": "Chiudi"],
        "Export video": ["en": "Export video", "fr": "Exporter la vidéo", "de": "Video exportieren", "es": "Exportar vídeo", "it": "Esporta video"],
        "Back 15 seconds": ["en": "Back 15 seconds", "fr": "Reculer de 15 secondes", "de": "15 Sekunden zurück", "es": "Retroceder 15 segundos", "it": "Indietro di 15 secondi"],
        "Forward 15 seconds": ["en": "Forward 15 seconds", "fr": "Avancer de 15 secondes", "de": "15 Sekunden vor", "es": "Avanzar 15 segundos", "it": "Avanti di 15 secondi"],
        "Add to favorites": ["en": "Add to favorites", "fr": "Ajouter aux favoris", "de": "Zu Favoriten hinzufügen", "es": "Añadir a favoritos", "it": "Aggiungi ai preferiti"],
        "Remove from favorites": ["en": "Remove from favorites", "fr": "Retirer des favoris", "de": "Aus Favoriten entfernen", "es": "Quitar de favoritos", "it": "Rimuovi dai preferiti"],
        "Shuffle memories": ["en": "Shuffle memories", "fr": "Mélanger les souvenirs", "de": "Erinnerungen mischen", "es": "Mezclar recuerdos", "it": "Mescola ricordi"],
        "Open this memory's photos": ["en": "Open this memory's photos", "fr": "Ouvrir les photos de ce souvenir", "de": "Fotos dieser Erinnerung öffnen", "es": "Abrir las fotos de este recuerdo", "it": "Apri le foto di questo ricordo"],
        "Close memory": ["en": "Close memory", "fr": "Fermer le souvenir", "de": "Erinnerung schließen", "es": "Cerrar recuerdo", "it": "Chiudi ricordo"],
        "View in timeline": ["en": "View in timeline", "fr": "Afficher dans la timeline", "de": "In der Zeitleiste ansehen", "es": "Ver en la cronología", "it": "Visualizza nella cronologia"],
        "Clear marker filter": ["en": "Clear marker filter", "fr": "Effacer le filtre des marqueurs", "de": "Markierungsfilter löschen", "es": "Borrar filtro de marcadores", "it": "Rimuovi filtro indicatori"],
        "Rate %lld stars#one": ["en": "Rate %lld star", "fr": "Noter %lld étoile", "de": "%lld Stern vergeben", "es": "Valorar con %lld estrella", "it": "Valuta %lld stella"],
        "Rate %lld stars#other": ["en": "Rate %lld stars", "fr": "Noter %lld étoiles", "de": "%lld Sterne vergeben", "es": "Valorar con %lld estrellas", "it": "Valuta %lld stelle"],
    ]

    /// The catalogue's value for `key` in `lang`, its placeholders filled in order.
    private func text(_ key: String, _ lang: Lang, _ args: String...) -> String {
        guard var result = Self.catalogue[key]?[lang.code] else {
            XCTFail("the scenario's catalogue has no \(key) in \(lang.code)")
            return "<missing \(key)>"
        }
        for arg in args {
            guard let range = result.range(of: "%@") ?? result.range(of: "%lld") else { break }
            result.replaceSubrange(range, with: arg)
        }
        return result
    }

    private func rateLabel(_ value: Int, _ lang: Lang) -> String {
        text(value == 1 ? "Rate %lld stars#one" : "Rate %lld stars#other", lang, "\(value)")
    }

    private func filmstripLabel(isVideo: Bool, position: Int, count: Int, _ lang: Lang) -> String {
        text(isVideo ? "Video %lld of %lld" : "Photo %lld of %lld", lang, "\(position)", "\(count)")
    }

    // MARK: - Set-up

    private let englishArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    private let autoplayOff = ["-uiTestMemoryAutoplayOff", "YES"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        try XCTSkipUnless(stubIsReachable(), "Local Immich stub not running on \(stub)")
    }

    /// One last launch in the clean-session shape, so no session survives the test.
    override func tearDownWithError() throws {
        guard stubIsReachable() else { return }
        app.terminate()
        app.launchArguments = englishArguments + ["-authServerURL", "()"]
        app.launch()
        XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                      "the cleanup launch did not reach the onboarding: the session may have survived")
        app.terminate()
    }

    // MARK: - AC-34

    /// The six surfaces of AC-34 (timeline, viewer, info panel, slideshow, map,
    /// memories), the filmstrip and the map markers included, in English.
    func test_AC_34_sixSurfacesAnnounceTheirActions() throws {
        try start()
        assertSixSurfaces(Self.english)
    }

    // MARK: - AC-34.2

    /// The same six surfaces in French, German, Spanish and Italian: every label is
    /// the catalogue's translation in that language (the expected values are
    /// written out, so an English residue fails the equality).
    func test_AC_34_2_labelsInFourLanguages() throws {
        try start()
        for lang in Self.shipped {
            assertSixSurfaces(lang)
        }
    }

    // MARK: - AC-34.3

    /// The map's photo sheet: a thumbnail is a button, its label is neutral about
    /// the media type and names the place when it has one; touching it opens the
    /// viewer on that item.
    func test_AC_34_3_mapThumbnailIsAButton() throws {
        try start()
        let lang = Self.english
        relaunch(lang)
        openMapTab()
        assertMapThumbnails(lang)

        let thumb = button("mapPhotoThumb_\(markerPlaceID)")
        thumb.tap()
        XCTAssertTrue(button("viewerBackButton").waitForExistence(timeout: 25),
                      "touching the thumbnail of \(markerPlaceID) did not open the viewer — \(screenReads())")
    }

    // MARK: - AC-34.4

    /// Buttons with two states: the label (or the announced state) follows the new
    /// state, and none describes the opposite of what is shown.
    func test_AC_34_4_twoStateButtonsFollowState() throws {
        try start()
        let lang = Self.english

        // The viewer's heart: a photo that is not a favorite offers "Favorite", then
        // "Unfavorite", then "Favorite" again.
        relaunch(lang)
        openViewer(on: photoID)
        let heart = assertButton("viewerFavoriteButton", label: text("Favorite", lang), "viewer, photo not a favorite")
        heart.tap()
        XCTAssertTrue(waitForLabel(heart, text("Unfavorite", lang)),
                      "the heart did not turn into \"Unfavorite\" after the tap — it reads \"\(heart.label)\"")
        heart.tap()
        XCTAssertTrue(waitForLabel(heart, text("Favorite", lang)),
                      "the heart did not turn back into \"Favorite\" — it reads \"\(heart.label)\"")

        // The viewer's detected-text toggle announces its state as a value.
        let ocr = assertButton("viewerOcrToggle", label: text("Detected text", lang), "viewer, detected text off")
        XCTAssertEqual(ocr.value as? String, text("off", lang), "the detected-text toggle starts off")
        ocr.tap()
        XCTAssertTrue(waitForValue(ocr, text("on", lang)),
                      "the detected-text toggle did not announce \"on\" — it reads \(String(describing: ocr.value))")
        XCTAssertEqual(ocr.label, text("Detected text", lang), "its label stays the action, only its value changes")

        // The slideshow's Play/Pause: playing right after the start, then paused, then playing.
        relaunch(lang)
        openViewer(on: photoID)
        tapViewerSlideshow()
        let playPause = slideshowControl("slideshowPlayPauseButton")
        XCTAssertEqual(playPause.label, text("Pause", lang), "a slideshow that plays offers Pause")
        playPause.tap()
        XCTAssertTrue(waitForLabel(playPause, text("Play", lang)),
                      "the paused slideshow did not offer Play — it reads \"\(playPause.label)\"")
        playPause.tap()
        XCTAssertTrue(waitForLabel(playPause, text("Pause", lang)),
                      "the resumed slideshow did not offer Pause — it reads \"\(playPause.label)\"")

        // The video player's Play/Pause: the label is one of the two, and the tap flips it.
        relaunch(lang)
        let videoTile = element("assetTile_\(videoID)")
        XCTAssertTrue(videoTile.waitForExistence(timeout: 40), "no tile for the video — \(screenReads())")
        videoTile.tap()
        XCTAssertTrue(element("videoPlayerScrubber").waitForExistence(timeout: 40),
                      "the video page never showed its transport — \(screenReads())")
        let videoPlayPause = button("videoPlayerPlayPause")
        XCTAssertTrue(videoPlayPause.waitForExistence(timeout: 15), "no videoPlayerPlayPause button")
        let pause = text("Pause", lang)
        let play = text("Play", lang)
        let before = videoPlayPause.label
        XCTAssertTrue([pause, play].contains(before), "the video's Play/Pause reads \"\(before)\"")
        assertButton("videoPlayerBack15", label: text("Back 15 seconds", lang), "video player")
        assertButton("videoPlayerForward15", label: text("Forward 15 seconds", lang), "video player")
        videoPlayPause.tap()
        XCTAssertTrue(waitForLabel(videoPlayPause, before == pause ? play : pause),
                      "the video's Play/Pause did not flip from \"\(before)\" — it reads \"\(videoPlayPause.label)\"")

        // The search's detected-text filter is inactive (the stub's server predates the
        // structured filter): it announces its action and "off".
        relaunch(lang)
        openTab(4)
        let filter = assertButton("searchOcrFilterToggle", label: text("Search by detected text", lang),
                                  "search, detected-text filter inactive")
        XCTAssertEqual(filter.value as? String, text("off", lang), "the search's detected-text filter reads off")

        // The change-password screen's reveal: masked offers "Show password", revealed
        // offers "Hide password".
        relaunch(lang)
        openChangePassword()
        let reveal = assertButton("currentPasswordReveal", label: text("Show password", lang),
                                  "change password, masked")
        reveal.tap()
        XCTAssertTrue(waitForLabel(reveal, text("Hide password", lang)),
                      "the revealed field did not offer \"Hide password\" — it reads \"\(reveal.label)\"")
        reveal.tap()
        XCTAssertTrue(waitForLabel(reveal, text("Show password", lang)),
                      "the masked field did not offer \"Show password\" — it reads \"\(reveal.label)\"")
    }

    // MARK: - AC-34.5

    /// Rating stars (info panel, with a note of 3; search filter, none then 3): each
    /// star is a button whose label is the plural-correct action, the star of the
    /// current note offers to remove it, stars 1…note carry the selected trait.
    func test_AC_34_5_ratingStars() throws {
        try start()
        for lang in Self.everyLanguage {
            // The info panel: the stub rates the photo 3.
            relaunch(lang)
            openViewer(on: photoID)
            tapViewerAction(id: "viewerDetailsButton", menu: "viewerMenuDetails")
            XCTAssertTrue(button("assetRatingStar_3").waitForExistence(timeout: 25),
                          "\(lang.code): the info panel never showed its rating bar — \(screenReads())")
            assertStarBar(lang, rating: 3, identifier: { "assetRatingStar_\($0)" }, context: "info panel")

            // The search filter: no note, then the tap on star 3 sets it.
            relaunch(lang)
            openTab(4)
            let filters = button("searchFilterButton")
            XCTAssertTrue(filters.waitForExistence(timeout: 25), "\(lang.code): no Filters button — \(screenReads())")
            filters.tap()
            XCTAssertTrue(button("searchFilterStar1").waitForExistence(timeout: 20),
                          "\(lang.code): the filter sheet never showed its stars — \(screenReads())")
            assertStarBar(lang, rating: nil, identifier: { "searchFilterStar\($0)" }, context: "search filter, no note")
            button("searchFilterStar3").tap()
            XCTAssertTrue(waitForLabel(button("searchFilterStar3"), text("Remove rating", lang)),
                          "\(lang.code): star 3 did not offer to remove the note after the tap")
            assertStarBar(lang, rating: 3, identifier: { "searchFilterStar\($0)" }, context: "search filter, note 3")
        }
    }

    // MARK: - AC-34.6

    /// The screens outside AC-34 that carry icon-only buttons, in English: the server
    /// address screen, a person's card (and the people list), the partners, the
    /// change-password screen, the search (mode menu, save) and its filters, the
    /// shared links, an album's activity feed and the Road Trip.
    func test_AC_34_6_otherScreens() throws {
        let lang = Self.english

        // The server address screen: before any session exists.
        try start(onServerScreen: {
            self.assertButton("serverQRScanButton", label: self.text("Scan server QR code", lang), "server address screen")
        })

        // The people list and a person's card.
        relaunch(lang)
        openPeopleList()
        assertButton("peopleRefreshButton", label: text("Refresh people", lang), "people list")
        openPersonCard()
        assertButton("personFavoriteAction", label: text("Favorite", lang), "person card, not a favorite")
        assertButton("personRenameAction", label: text("Rename", lang), "person card")
        assertButton("personHideAction", label: text("Hide", lang), "person card, not hidden")
        assertButton("personBirthdayAction", label: text("Birthday", lang), "person card")
        assertButton("personMergeMenu", label: text("Merge person", lang), "person card")

        // The partners.
        relaunch(lang)
        openTab(2)
        libraryRow("partnersRow").tap()
        XCTAssertTrue(button("invitePartner").waitForExistence(timeout: 20), "the Partners screen never opened — \(screenReads())")
        assertButton("invitePartner", label: text("Invite a partner", lang), "partners")
        assertButton("partnerRemove-\(partnerID)", label: text("Stop sharing with %@", lang, partnerName), "partners, outgoing row")

        // The change-password screen.
        relaunch(lang)
        openChangePassword()
        for id in ["currentPasswordReveal", "newPasswordReveal", "confirmPasswordReveal"] {
            assertButton(id, label: text("Show password", lang), "change password")
        }

        // The search: mode menu, save, then the filters' stars (AC-34.5 reads their
        // labels in every language).
        relaunch(lang)
        openTab(4)
        let smart = text("Search mode: %@", lang, text("Smart", lang))
        let metadata = text("Search mode: %@", lang, text("Metadata", lang))
        let modeMenu = button("searchModeMenu")
        XCTAssertTrue(modeMenu.waitForExistence(timeout: 25), "search: no searchModeMenu button — \(screenReads())")
        XCTAssertTrue([smart, metadata].contains(modeMenu.label),
                      "search: the mode menu reads \"\(modeMenu.label)\", expected \"\(smart)\" or \"\(metadata)\"")
        assertButton("searchSaveButton", label: text("Save search", lang), "search")

        // The shared links.
        relaunch(lang)
        openTab(3)
        assertButton("sharedLinkCopy-\(linkID)", label: text("Copy link", lang), "shared links")
        assertButton("sharedLinkShare-\(linkID)", label: text("Share link", lang), "shared links")

        // An album's activity feed, then its Road Trip.
        relaunch(lang)
        openAlbum()
        openAlbumAction("Activity")
        assertButton("activityFeedSendButton", label: text("Send comment", lang), "activity feed")

        relaunch(lang)
        openAlbum()
        openAlbumAction("Road Trip")
        assertButton("roadTripCloseButton", label: text("Close", lang), "road trip")
        assertButton("roadTripExportButton", label: text("Export video", lang), "road trip")
    }

    // MARK: - AC-34.7

    /// The widgets' heart and shuffle buttons on the Home Screen, with the device in
    /// French. Skipped when the simulator is not in French (SpringBoard follows it).
    func test_AC_34_7_widgetButtonsInFrench() throws {
        try XCTSkipUnless(Locale.preferredLanguages.first?.hasPrefix("fr") == true,
                          "the simulator language is not French (\(Locale.preferredLanguages)): SpringBoard and the widgets are not in French")
        try start()
        sleep(3) // the widgets read the session the app publishes on launch

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        addHomeScreenWidget(springboard, title: "Photos Swimmich")
        addHomeScreenWidget(springboard, title: "Souvenirs Swimmich")
        XCUIDevice.shared.press(.home)
        sleep(25) // WidgetKit asks for a timeline a few seconds after the placement

        let heart = springboard.buttons.matching(identifier: "widgetFavoriteButton").firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 30),
                      "the Photos widget shows no widgetFavoriteButton in springboard.buttons")
        let french = Self.shipped[0]
        XCTAssertTrue([text("Add to favorites", french), text("Remove from favorites", french)].contains(heart.label),
                      "the widget's heart reads \"\(heart.label)\", not a French favorite action")
        let shuffle = springboard.buttons.matching(identifier: "widgetShuffleButton").firstMatch
        XCTAssertTrue(shuffle.waitForExistence(timeout: 30),
                      "the Memories widget shows no widgetShuffleButton in springboard.buttons")
        XCTAssertEqual(shuffle.label, text("Shuffle memories", french), "the Memories widget's shuffle button")
    }

    /// The share extension's own buttons: each is announced by a real label, never by
    /// a symbol name. Needs `--media /tmp/media-share.png` (the file Photos shares).
    func test_AC_34_7_shareExtensionButtons() throws {
        try start()
        sleep(3) // the keychain write of the sign-in
        app.terminate()
        sleep(3)

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        photos.launch()
        XCTAssertEqual(photos.state, .runningForeground, "Photos did not come to the foreground")
        sleep(5)
        for label in ["Continuer", "Continue", "Done", "Terminé", "Get Started", "OK"] {
            let next = photos.buttons[label]
            if next.exists && next.isHittable {
                next.tap()
                sleep(2)
            }
        }
        let tiles = photos.descendants(matching: .any).matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20), "the Photos library never published a tile")
        tiles.element(boundBy: tiles.count - 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let share = photos.buttons.matching(identifier: "PUOneUpBarButtonItemIdentifierShare").firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 25), "the photo viewer of Photos never offered its share button")
        share.tap()

        let activity = shareActivity(photos, springboard)
        XCTAssertNotNil(activity, "the share sheet has no Swimmich activity — the extension is not registered or is out of reach")
        activity?.tap()

        XCTAssertTrue(photos.staticTexts.matching(identifier: "shareExtensionServerLabel").firstMatch.waitForExistence(timeout: 40),
                      "the Swimmich share sheet never presented itself")
        let row = photos.buttons.matching(identifier: "shareExtensionItemRow_0").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "shareExtensionItemRow_0 is not in the extension's buttons")
        XCTAssertTrue(row.label.contains("media-share"), "the row reads \"\(row.label)\", not the shared file's name")
        for id in ["shareExtensionCancelButton", "shareExtensionAlbumPicker", "shareExtensionUploadButton"] {
            let control = photos.buttons.matching(identifier: id).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 15), "\(id) is not in the extension's buttons")
        }
        let announced = photos.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shareExtension'"))
        XCTAssertGreaterThanOrEqual(announced.count, 4, "the extension publishes fewer than four buttons")
        let symbolName = NSPredicate(format: "SELF MATCHES %@", "^[a-z0-9]+(\\.[a-z0-9]+)+$")
        for control in announced.allElementsBoundByIndex {
            XCTAssertFalse(control.label.isEmpty, "\(control.identifier) is announced without a label")
            XCTAssertNotEqual(control.label, control.identifier, "\(control.identifier) is announced by its identifier")
            XCTAssertFalse(symbolName.evaluate(with: control.label),
                           "\(control.identifier) is announced by a symbol name: \"\(control.label)\"")
        }
    }

    // MARK: - AC-34.9

    /// Grid thumbnails (timeline, album): a button, named by type and date; touching
    /// it opens the viewer, and in selection mode it toggles and carries the
    /// selected trait.
    func test_AC_34_9_gridThumbnails() throws {
        try start()
        let lang = Self.english
        relaunch(lang)
        assertTimelineTiles(lang)

        // A touch opens the viewer.
        button("assetTile_\(photoID)").tap()
        XCTAssertTrue(button("viewerBackButton").waitForExistence(timeout: 25),
                      "touching the tile did not open the viewer — \(screenReads())")
        button("viewerBackButton").tap()

        // In selection mode the same touch toggles the tile and selects it.
        let select = button("selectButton")
        XCTAssertTrue(select.waitForExistence(timeout: 20), "no Select button — \(screenReads())")
        select.tap()
        let tile = button("assetTile_\(photoID)")
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the tile left the timeline in selection mode")
        XCTAssertFalse(tile.isSelected, "a tile starts unselected")
        tile.tap()
        XCTAssertTrue(waitForSelected(tile), "the tile did not carry the selected trait after the touch")
        XCTAssertEqual(tile.label, text("Photo, %@", lang, lang.photoDate), "a selected tile keeps naming its content")

        // The album's grid is built on the same cell.
        relaunch(lang)
        openAlbum()
        let albumTile = button("assetTile_\(albumPhotoID)")
        XCTAssertTrue(albumTile.waitForExistence(timeout: 30), "the album grid shows no tile — \(screenReads())")
        XCTAssertEqual(albumTile.label, text("Photo, %@", lang, lang.albumDate), "the album's tile")
        albumTile.tap()
        XCTAssertTrue(button("viewerBackButton").waitForExistence(timeout: 25),
                      "touching the album's tile did not open the viewer — \(screenReads())")

        // And in French, the date and the type are French.
        let french = Self.shipped[0]
        relaunch(french)
        assertTimelineTiles(french)
    }

    // MARK: - AC-34.11

    /// The map's markers are buttons with a neutral label (the place when known),
    /// in every language; touching one filters the sheet, which then offers to
    /// clear that filter.
    func test_AC_34_11_mapMarkersAreButtons() throws {
        try start()
        for lang in Self.everyLanguage {
            relaunch(lang)
            openMapTab()
            assertMapMarkers(lang)
        }

        let lang = Self.english
        relaunch(lang)
        openMapTab()
        let marker = button("mapMarker_\(markerPlaceID)")
        XCTAssertTrue(marker.waitForExistence(timeout: 40), "no marker for \(markerPlaceID) — \(screenReads())")
        marker.tap()
        assertButton("mapClearMarkerButton", label: text("Clear marker filter", lang), "map sheet filtered by a marker")
    }

    // MARK: - AC-34.12

    /// The viewer's filmstrip names the type and the position of each cell.
    func test_AC_34_12_filmstripNamesType() throws {
        try start()
        for lang in Self.everyLanguage {
            relaunch(lang)
            openViewer(on: photoID)
            assertFilmstrip(lang)
        }
    }

    // MARK: - Surfaces

    private func assertSixSurfaces(_ lang: Lang) {
        relaunch(lang)
        assertTimelineTiles(lang)

        relaunch(lang)
        assertViewer(lang)

        relaunch(lang)
        assertSlideshow(lang)

        relaunch(lang)
        assertMemory(lang)

        relaunch(lang)
        openMapTab()
        assertMapMarkers(lang)
        assertMapThumbnails(lang)
    }

    /// Timeline: the photo and the video tile are buttons named by type and date.
    private func assertTimelineTiles(_ lang: Lang) {
        let context = "\(lang.code), timeline"
        assertButton("assetTile_\(photoID)", label: text("Photo, %@", lang, lang.photoDate), context)
        assertButton("assetTile_\(videoID)", label: text("Video, %@", lang, lang.photoDate), context)
    }

    /// Viewer (top bar, heart, filmstrip) and info panel (rating bar).
    private func assertViewer(_ lang: Lang) {
        let context = "\(lang.code), viewer"
        openViewer(on: photoID)
        assertButton("viewerBackButton", label: text("Back", lang), context)
        assertButton("viewerFavoriteButton", label: text("Favorite", lang), context)
        assertButton("viewerSlideshowButton", label: text("Slideshow", lang), context)
        let ocr = assertButton("viewerOcrToggle", label: text("Detected text", lang), context)
        XCTAssertEqual(ocr.value as? String, text("off", lang), "\(context): the detected-text toggle starts off")
        assertFilmstrip(lang)

        tapViewerAction(id: "viewerDetailsButton", menu: "viewerMenuDetails")
        XCTAssertTrue(button("assetRatingStar_3").waitForExistence(timeout: 25),
                      "\(lang.code), info panel: no rating bar — \(screenReads())")
        assertStarBar(lang, rating: 3, identifier: { "assetRatingStar_\($0)" }, context: "\(lang.code), info panel")
    }

    private func assertFilmstrip(_ lang: Lang) {
        let context = "\(lang.code), filmstrip"
        // Filmstrip cells keep main's index identifier (L-18): the photo is 1st, the video 2nd.
        assertButton("viewerFilmstripCell_0", label: filmstripLabel(isVideo: false, position: 1, count: 2, lang), context)
        assertButton("viewerFilmstripCell_1", label: filmstripLabel(isVideo: true, position: 2, count: 2, lang), context)
    }

    private func assertStarBar(_ lang: Lang, rating: Int?, identifier: (Int) -> String, context: String) {
        for value in 1...5 {
            let expected = value == rating ? text("Remove rating", lang) : rateLabel(value, lang)
            let star = assertButton(identifier(value), label: expected, "\(lang.code), \(context), star \(value)")
            XCTAssertEqual(star.isSelected, value <= (rating ?? 0),
                           "\(lang.code), \(context): star \(value) selected trait, note \(String(describing: rating))")
        }
    }

    /// Slideshow: every control is present and named. Close, Shuffle, Previous, Next,
    /// the speed menu (its value is the current speed) and the transition menu.
    private func assertSlideshow(_ lang: Lang) {
        let context = "\(lang.code), slideshow"
        openViewer(on: photoID)
        tapViewerSlideshow()
        // The play state first, right after the start: a slideshow that plays offers Pause.
        let playPause = slideshowControl("slideshowPlayPauseButton")
        XCTAssertEqual(playPause.label, text("Pause", lang), "\(context): Play/Pause while playing")
        let expected: [(String, String)] = [
            ("slideshowCloseButton", text("Close Slideshow", lang)),
            ("slideshowShuffleButton", text("Shuffle", lang)),
            ("slideshowPreviousButton", text("Previous", lang)),
            ("slideshowNextButton", text("Next", lang)),
            ("slideshowTransitionMenu", text("Transition", lang)),
        ]
        for (id, label) in expected {
            let control = slideshowControl(id)
            XCTAssertEqual(control.label, label, "\(context): \(id)")
        }
        let speed = slideshowControl("slideshowSpeedMenu")
        XCTAssertEqual(speed.label, text("Slideshow Speed", lang), "\(context): slideshowSpeedMenu")
        let speedValue = (speed.value as? String) ?? ""
        XCTAssertFalse(speedValue.isEmpty, "\(context): the speed menu announces no value")
        XCTAssertNotEqual(speedValue, speed.label, "\(context): the speed menu's value is its label")
    }

    /// Memories: the hero page, close and "view in timeline" are buttons.
    private func assertMemory(_ lang: Lang) {
        let context = "\(lang.code), memories"
        openTab(1)
        let card = element("memoryCard_\(memoryID)")
        XCTAssertTrue(card.waitForExistence(timeout: 40), "\(context): no memory card — \(screenReads())")
        for _ in 0..<6 where !card.isHittable {
            app.swipeUp()
            sleep(1)
        }
        card.tap()
        XCTAssertTrue(button("memoryMomentHero").waitForExistence(timeout: 30),
                      "\(context): the memory's hero page is not a button (or never opened) — \(screenReads())")
        assertButton("memoryMomentHero", label: text("Open this memory's photos", lang), context)
        assertButton("memoryMomentClose", label: text("Close memory", lang), context)
        assertButton("memoryMomentViewInTimeline", label: text("View in timeline", lang), context)
    }

    /// Map markers: buttons named by place (or "Item" without one).
    private func assertMapMarkers(_ lang: Lang) {
        let context = "\(lang.code), map markers"
        let withPlace = assertButton("mapMarker_\(markerPlaceID)",
                                     label: text("Item, %@", lang, markerPlaceName), context, timeout: 40)
        XCTAssertNotEqual(withPlace.label, text("Item", lang), "\(context): the marker with a place names it")
        assertButton("mapMarker_\(markerBareID)", label: text("Item", lang), context)
    }

    /// The map's photo sheet: thumbnails are buttons named like the markers, never
    /// by media type.
    private func assertMapThumbnails(_ lang: Lang) {
        let context = "\(lang.code), map sheet"
        let withPlace = assertButton("mapPhotoThumb_\(markerPlaceID)",
                                     label: text("Item, %@", lang, markerPlaceName), context, timeout: 40)
        let bare = assertButton("mapPhotoThumb_\(markerBareID)", label: text("Item", lang), context)
        for label in [withPlace.label, bare.label] {
            for word in ["photo", "video", "vidéo", "foto", "vídeo"] {
                XCTAssertFalse(label.lowercased().contains(word), "\(context): \"\(label)\" names the media type")
            }
        }
    }

    // MARK: - Reading controls

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The element of this identifier among the BUTTONS only: a control that lost its
    /// button role is not found.
    private func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    @discardableResult
    private func assertButton(_ identifier: String, label expected: String, _ context: String,
                              timeout: TimeInterval = 20) -> XCUIElement {
        let control = button(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: timeout),
                      "\(context): no \(identifier) among the app's buttons (missing, or not a button) — \(screenReads())")
        XCTAssertEqual(control.label, expected, "\(context): \(identifier)")
        return control
    }

    private func waitForLabel(_ control: XCUIElement, _ expected: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)],
                                timeout: timeout) == .completed
    }

    private func waitForValue(_ control: XCUIElement, _ expected: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)],
                                timeout: timeout) == .completed
    }

    private func waitForSelected(_ control: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "selected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)],
                                timeout: timeout) == .completed
    }

    private func screenReads() -> String {
        app.staticTexts.allElementsBoundByIndex.prefix(25).map(\.label).joined(separator: " | ")
    }

    /// A slideshow control: waits 2 s for its identifier; absent (the controls hide 3 s
    /// after the play start), touches the centre of the screen once (`toggleControls`)
    /// and waits again. Fails when it is still absent.
    private func slideshowControl(_ identifier: String) -> XCUIElement {
        let control = button(identifier)
        if !control.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(control.waitForExistence(timeout: 2),
                          "slideshow: \(identifier) is not among the buttons, even after a touch on the slide — \(screenReads())")
        }
        return control
    }

    // MARK: - Navigation

    private func openTab(_ index: Int) {
        let tab = app.tabBars.buttons.element(boundBy: index)
        XCTAssertTrue(tab.waitForExistence(timeout: 40), "no tab \(index) — \(screenReads())")
        tab.tap()
    }

    private func openViewer(on id: String) {
        let tile = element("assetTile_\(id)")
        XCTAssertTrue(tile.waitForExistence(timeout: 40), "no tile for \(id) — \(screenReads())")
        tile.tap()
        XCTAssertTrue(button("viewerBackButton").waitForExistence(timeout: 25),
                      "the viewer never showed its top bar — \(screenReads())")
    }

    private func tapViewerSlideshow() {
        let slideshow = button("viewerSlideshowButton")
        XCTAssertTrue(slideshow.waitForExistence(timeout: 15), "the viewer's row has no slideshow pill")
        slideshow.tap()
    }

    /// A viewer top-bar action: its pill when the row carries it, else its item in
    /// the "⋯" menu (by identifier). Taps it.
    private func tapViewerAction(id: String, menu: String) {
        let pill = button(id)
        if pill.waitForExistence(timeout: 5) {
            pill.tap()
            return
        }
        let overflow = button("viewerOverflowMenu")
        XCTAssertTrue(overflow.waitForExistence(timeout: 15), "\(id) is neither on the viewer's row nor behind ⋯")
        overflow.tap()
        let item = element(menu)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "⋯ holds no \(menu) — \(screenReads())")
        item.tap()
    }

    private func openMapTab() {
        openTab(4)
        let segment = element("searchModeSegment_map")
        XCTAssertTrue(segment.waitForExistence(timeout: 25), "the Map segment is missing — \(screenReads())")
        segment.tap()
    }

    /// A row of the Albums library, scrolled into reach.
    private func libraryRow(_ identifier: String) -> XCUIElement {
        let row = button(identifier)
        _ = row.waitForExistence(timeout: 15)
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        return row
    }

    private func openPeopleList() {
        openTab(2)
        libraryRow("peopleRow").tap()
        XCTAssertTrue(element("personRow_\(personID)").waitForExistence(timeout: 30),
                      "the people list never rendered personRow_\(personID) — \(screenReads())")
    }

    /// Opens the person's card. A row of this list is a `NavigationLink` that combines
    /// its children: the first gestures touch the app at a point (see
    /// `PersonBirthdayUITests.tapRowOnce`, where this was measured), the later ones
    /// the element.
    private func openPersonCard() {
        let row = element("personRow_\(personID)")
        for attempt in 1...4 {
            guard row.exists else { break }
            let frame = row.frame
            let bounds = app.frame
            switch attempt {
            case 1, 2:
                let x = attempt == 1 ? frame.midX : frame.minX + frame.width * 0.25
                app.coordinate(withNormalizedOffset: CGVector(
                    dx: (x - bounds.minX) / bounds.width,
                    dy: (frame.midY - bounds.minY) / bounds.height)).tap()
            case 3:
                row.tap()
            default:
                row.press(forDuration: 0.4)
            }
            if button("personBirthdayAction").waitForExistence(timeout: 25) { return }
        }
        XCTFail("tapping the person row never opened the card (no personBirthdayAction) — \(screenReads())")
    }

    private func openChangePassword() {
        let avatar = button("profileAvatar")
        XCTAssertTrue(avatar.waitForExistence(timeout: 30), "no profile avatar — \(screenReads())")
        avatar.tap()
        sleep(4) // the sheet animates in; the Form is not hittable before it does
        let row = button("changePasswordRow")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no Change Password row in the Me hub — \(screenReads())")
        for _ in 0..<5 where !row.isHittable {
            app.swipeUp()
            sleep(1)
        }
        row.tap()
        XCTAssertTrue(button("changePasswordSubmit").waitForExistence(timeout: 20),
                      "the change-password screen did not present — \(screenReads())")
    }

    /// Albums tab → the stub's album → its grid.
    private func openAlbum() {
        openTab(2)
        let card = element("albumCard_\(albumID)")
        var attempts = 0
        while !card.waitForExistence(timeout: 3) && attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(card.exists, "no album card — \(screenReads())")
        card.tap()
        XCTAssertTrue(element("assetTile_\(albumPhotoID)").waitForExistence(timeout: 30),
                      "the album grid shows no tile — \(screenReads())")
    }

    /// An item of the album's actions menu. The items carry no identifier in the app, so
    /// they are reached by their ENGLISH name, which this scenario never asserts.
    private func openAlbumAction(_ name: String) {
        let menu = button("albumActionsMenu")
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "no album actions menu — \(screenReads())")
        menu.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the album menu has no \"\(name)\" item — \(screenReads())")
        item.tap()
    }

    // MARK: - Home Screen widgets (French SpringBoard)

    private func hittableButton(_ springboard: XCUIApplication, containing text: String,
                                timeout: TimeInterval = 15) -> XCUIElement? {
        let query = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", text))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0..<query.count where query.element(boundBy: index).isHittable {
                return query.element(boundBy: index)
            }
            usleep(400_000)
        }
        return nil
    }

    /// Home Screen → edit mode → widget gallery → the widget whose sheet title contains
    /// `title` → "Ajouter le widget" (the flow of `ImmichWidgetHomeScreen`).
    private func addHomeScreenWidget(_ springboard: XCUIApplication, title: String) {
        XCUIDevice.shared.press(.home)
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 2.0)
        sleep(3)
        if let edit = hittableButton(springboard, containing: "Modifier", timeout: 6) {
            edit.tap()
            sleep(2)
        }
        guard let addWidget = hittableButton(springboard, containing: "Ajouter un widget", timeout: 8) else {
            return XCTFail("the edit menu has no widget entry — SpringBoard flow changed")
        }
        addWidget.tap()
        sleep(4)

        let gallerySearch = springboard.searchFields["Rechercher des widgets"].firstMatch
        guard gallerySearch.waitForExistence(timeout: 15) else {
            return XCTFail("the widget gallery never appeared")
        }
        gallerySearch.tap()
        gallerySearch.typeText("Swimmich")
        sleep(3)
        let result = springboard.cells.containing(NSPredicate(format: "label CONTAINS 'Swimmich'")).firstMatch
        guard result.waitForExistence(timeout: 10) else {
            return XCTFail("the gallery lists no Swimmich widget")
        }
        result.tap()
        sleep(3)

        let preview = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Widget'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), "the sheet shows no widget preview")
        let page = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        for _ in 0..<8 where !page.exists {
            preview.swipeLeft()
            sleep(2)
        }
        XCTAssertTrue(page.waitForExistence(timeout: 5), "never reached the \(title) widget page")
        guard let place = hittableButton(springboard, containing: "Ajouter le widget", timeout: 10) else {
            return XCTFail("the widget sheet has no add button")
        }
        place.tap()
        sleep(2)
    }

    // MARK: - Share extension (Photos)

    /// Photos' activity for this extension, by label (its `CFBundleDisplayName`), scrolled
    /// into reach if the app row is full.
    private func shareActivity(_ photos: XCUIApplication, _ springboard: XCUIApplication) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == 'Swimmich'")
        for attempt in 0..<3 {
            for root in [photos as XCUIElement, springboard as XCUIElement] {
                let match = root.descendants(matching: .any).matching(predicate).firstMatch
                if match.exists { return match }
            }
            if attempt < 2 {
                let row = photos.collectionViews.firstMatch
                if row.exists { row.swipeLeft() } else { photos.swipeLeft() }
                sleep(2)
            }
        }
        return nil
    }

    // MARK: - Sign-in (the same OAuth walk as the other scenarios)

    /// A clean launch in English, then onboarding → OAuth → the timeline. `onServerScreen`
    /// runs on the server address screen, once its field is up.
    private func start(onServerScreen: (() -> Void)? = nil) throws {
        if app.state != .notRunning { app.terminate() }
        stubGet("/__reset")
        stubGet("/__provider?mode=manual")
        app.launchArguments = englishArguments + ["-authServerURL", "()"] + autoplayOff
        app.launch()
        XCTAssertTrue(waitForStaticText(["Your photo library", "Votre photothèque"], timeout: 30),
                      "the onboarding did not appear — the scenario would start from a stale session")
        walkOnboardingToLogin(onServerScreen: onServerScreen)
        XCTAssertTrue(tapButton(containing: "Immich SSO"), "SSO button missing on login screen")
        dismissSystemSignInAlertIfPresent()
        XCTAssertTrue(tapAuthorizeInProvider(), "Authorize link not reachable in the auth sheet")
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 30),
                      "OAuth did not reach the authenticated shell")
        XCTAssertTrue(element("assetTile_\(photoID)").waitForExistence(timeout: 40),
                      "the timeline never rendered against \(stub) — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    /// A relaunch in another language; the session is kept (no `-authServerURL`).
    private func relaunch(_ lang: Lang) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(\(lang.code))", "-AppleLocale", lang.locale] + autoplayOff
        app.launch()
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 40),
                      "\(lang.code): the relaunch did not reach the authenticated shell — \(screenReads())")
        dismissWhatsNewIfPresent()
    }

    private func dismissWhatsNewIfPresent() {
        let done = button("whatsNewDoneButton")
        guard done.waitForExistence(timeout: 5) else { return }
        done.tap()
    }

    private func walkOnboardingToLogin(onServerScreen: (() -> Void)?) {
        _ = tapAnyButton(["Get Started", "Commencer"], timeout: 15)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Server URL field missing")
        onServerScreen?()
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
