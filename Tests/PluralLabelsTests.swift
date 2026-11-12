import XCTest
@testable import ImmichSwiftUI

/// B-21: the counted labels that are built in code (not read straight by a
/// `Text` from the catalog) agree with their number in every shipped language.
/// Each label function takes the language's bundle and locale: the test pins the
/// language instead of following the host's.
@MainActor
final class PluralLabelsTests: XCTestCase {

    private func french() throws -> (bundle: Bundle, locale: Locale) { try language("fr") }

    // MARK: - Fixtures

    private func asset(_ id: String, type: String = "IMAGE", people: [PersonResponseDto]? = nil) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: type, thumbhash: nil, localDateTime: "2023-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2023-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/x.jpg", originalFileName: "x.jpg",
            fileCreatedAt: "2023-07-01T00:00:00.000Z", fileModifiedAt: "2023-07-01T00:00:00.000Z",
            updatedAt: "2023-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            people: people
        )
    }

    private func memory(assets: [AssetResponseDto]) -> MemoryResponseDto {
        MemoryResponseDto(
            id: "m1", createdAt: "2023-07-01T00:00:00.000Z", updatedAt: "2023-07-01T00:00:00.000Z",
            memoryAt: "2023-07-01T00:00:00.000Z", ownerId: "owner", type: .on_this_day,
            data: MemoryDataDto(year: 2023), assets: assets, isSaved: false,
            showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
    }

    private func unnamed(_ id: String) -> PersonResponseDto {
        PersonResponseDto(
            id: id, name: "", birthDate: nil, thumbnailPath: nil, isHidden: false,
            color: nil, isFavorite: nil, updatedAt: nil
        )
    }

    // MARK: - Memories

    func test_AC_32_2_memoryLabels() throws {
        let (bundle, locale) = try french()
        XCTAssertEqual(
            MemoryCardPresentation.mediaCountLabel(for: memory(assets: [asset("a")]), bundle: bundle, locale: locale),
            "1 photo"
        )
        let mixed = memory(assets: [asset("a"), asset("b"), asset("c", type: "VIDEO")])
        XCTAssertEqual(
            MemoryCardPresentation.mediaCountLabel(for: mixed, bundle: bundle, locale: locale),
            "2 photos · 1 vidéo"
        )
        let oneVideo = memory(assets: [asset("a", type: "VIDEO")])
        XCTAssertEqual(
            MemoryCardPresentation.mediaCountLabel(for: oneVideo, bundle: bundle, locale: locale), "1 vidéo"
        )

        let onePerson = memory(assets: [asset("a", people: [unnamed("p1")])])
        let twoPeople = memory(assets: [asset("a", people: [unnamed("p1"), unnamed("p2")])])
        XCTAssertEqual(MemoryMomentPresentation.peopleLabel(for: onePerson, bundle: bundle, locale: locale), "1 personne")
        XCTAssertEqual(MemoryMomentPresentation.peopleLabel(for: twoPeople, bundle: bundle, locale: locale), "2 personnes")

        XCTAssertEqual(MemoryCardPresentation.yearsAgoText(count: 2, bundle: bundle, locale: locale), "il y a 2 ans")
        XCTAssertEqual(MemoryCardPresentation.yearsAgoText(count: 1, bundle: bundle, locale: locale), "L'année dernière")
    }

    // MARK: - Shared link viewer

    private func sharedLink(assets: Int, allowUpload: Bool, allowDownload: Bool) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: "link-1", description: nil, password: nil, userId: "owner", key: "k", type: .individual,
            createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: (0..<assets).map {
                SharedLinkAssetDto(
                    id: "a\($0)", type: "IMAGE", hasMetadata: true, ownerId: "owner",
                    createdAt: "2024-01-01T00:00:00.000Z", fileCreatedAt: "2024-01-01T00:00:00.000Z",
                    isFavorite: false, isTrashed: false, visibility: "timeline"
                )
            },
            album: nil, allowUpload: allowUpload, allowDownload: allowDownload, showMetadata: true, slug: nil
        )
    }

    func test_AC_32_2_sharedLinkViewerTitleAndSubtitle() async {
        for (count, upload, download) in [(1, true, true), (2, false, false)] {
            let client = MockImmichClient()
            client.sharedLinkMineResponse = sharedLink(assets: count, allowUpload: upload, allowDownload: download)
            let vm = SharedLinkViewerViewModel(
                client: client, baseURL: URL(string: "https://photos.example.com")!, externalDomain: ""
            )
            vm.linkText = "https://photos.example.com/s/holidays"
            await vm.openLink()

            XCTAssertEqual(vm.title, localizedString("%lld photos", count))
            var parts = [
                localizedString("%lld photos", count),
                localizedString(upload ? "You can add photos" : "Read only"),
            ]
            if !download { parts.append(localizedString("Downloads off")) }
            XCTAssertEqual(vm.subtitle, parts.joined(separator: " • "))
        }
    }

    // MARK: - Duplicates

    func test_AC_32_3_duplicatesDeletePrompt() throws {
        let (bundle, locale) = try french()
        XCTAssertEqual(DuplicatesView.deletePrompt(count: 1, bundle: bundle, locale: locale), "Supprimer 1 doublon ?")
        XCTAssertEqual(DuplicatesView.deletePrompt(count: 2, bundle: bundle, locale: locale), "Supprimer 2 doublons ?")
    }

    // MARK: - Widgets

    func test_AC_32_4_widgetCounters() throws {
        let (bundle, locale) = try french()
        XCTAssertEqual(WidgetCopy.photosText(0, bundle: bundle, locale: locale), "0 photo")
        XCTAssertEqual(WidgetCopy.photosText(1, bundle: bundle, locale: locale), "1 photo")
        XCTAssertEqual(WidgetCopy.photosText(2, bundle: bundle, locale: locale), "2 photos")
        // A six-figure library keeps its grouped digits (decision #6).
        XCTAssertEqual(
            WidgetCopy.photosText(12483, bundle: bundle, locale: locale),
            12483.formatted(.number.locale(locale)) + " photos"
        )
        XCTAssertEqual(WidgetCopy.favoritesText(1, bundle: bundle, locale: locale), "1 favori")
        XCTAssertEqual(WidgetCopy.favoritesText(2, bundle: bundle, locale: locale), "2 favoris")
        XCTAssertEqual(WidgetCopy.yearsAgoText(0, bundle: bundle, locale: locale), "Cette année")
        XCTAssertEqual(WidgetCopy.yearsAgoText(1, bundle: bundle, locale: locale), "il y a 1 an")
        XCTAssertEqual(WidgetCopy.yearsAgoText(2, bundle: bundle, locale: locale), "il y a 2 ans")
    }

    // MARK: - Stack badge (VoiceOver)

    func test_AC_32_5_stackAccessibilityLabel() throws {
        let expected: [String: (String, String)] = [
            "fr": ("1 photo dans une pile", "2 photos dans une pile"),
            "de": ("1 Foto in einem Stapel", "2 Fotos in einem Stapel"),
            "es": ("1 foto en una pila", "2 fotos en una pila"),
            "it": ("1 foto in un gruppo", "2 foto in un gruppo"),
        ]
        for (code, forms) in expected {
            let (bundle, locale) = try language(code)
            XCTAssertEqual(AssetThumbnailCell.stackAccessibilityLabel(count: 1, bundle: bundle, locale: locale), forms.0, code)
            XCTAssertEqual(AssetThumbnailCell.stackAccessibilityLabel(count: 2, bundle: bundle, locale: locale), forms.1, code)
        }
        let (bundle, locale) = try french()
        XCTAssertEqual(
            AssetThumbnailCell.stackAccessibilityLabel(count: nil, bundle: bundle, locale: locale), "Dans une pile"
        )
    }

    // MARK: - Explore, backup, admin, notification, Live Activity (decision #5)

    func test_AC_32_9_exploreFooter() throws {
        let (bundle, locale) = try french()
        XCTAssertEqual(ExplorePlaceCard.footerText(photoCount: 1, date: nil, bundle: bundle, locale: locale), "1 photo")
        XCTAssertEqual(ExplorePlaceCard.footerText(photoCount: 2, date: nil, bundle: bundle, locale: locale), "2 photos")
        XCTAssertEqual(ExplorePlaceCard.footerText(photoCount: nil, date: nil, bundle: bundle, locale: locale), "·")
    }

    func test_AC_32_9_backupAlbumCounts() throws {
        let (bundle, locale) = try french()
        let expected: [(BackupAlbumCountKind, String, String)] = [
            (.selected, "1 album sélectionné", "2 albums sélectionnés"),
            (.excluded, "1 album exclu", "2 albums exclus"),
            (.mirrored, "1 album reflété", "2 albums reflétés"),
        ]
        for (kind, one, other) in expected {
            XCTAssertEqual(BackupSettingsView.albumCountText(0, kind: kind, bundle: bundle, locale: locale), "Aucun album")
            XCTAssertEqual(BackupSettingsView.albumCountText(1, kind: kind, bundle: bundle, locale: locale), one)
            XCTAssertEqual(BackupSettingsView.albumCountText(2, kind: kind, bundle: bundle, locale: locale), other)
        }
    }

    func test_AC_32_9_backupLegendAndVoiceOver() throws {
        let (bundle, locale) = try french()
        func legend(_ kind: BackupLegendKind, _ count: Int) -> String {
            BackupSettingsView.legendText(kind, count: count, bundle: bundle, locale: locale)
        }
        XCTAssertEqual(legend(.uploaded, 1), "1 envoyée")
        XCTAssertEqual(legend(.uploaded, 2), "2 envoyées")
        XCTAssertEqual(legend(.onServer, 1), "1 sur le serveur")
        XCTAssertEqual(legend(.onServer, 2), "2 sur le serveur")
        XCTAssertEqual(legend(.failed, 1), "1 en échec")
        XCTAssertEqual(legend(.failed, 2), "2 en échec")
        XCTAssertEqual(legend(.waiting(wifi: true, icloud: true), 2), "2 en attente")
        XCTAssertEqual(legend(.waiting(wifi: true, icloud: false), 1), "1 en attente du Wi-Fi")
        XCTAssertEqual(legend(.waiting(wifi: false, icloud: true), 2), "2 en attente d'iCloud")

        XCTAssertEqual(
            BackupSettingsView.activeAccessibilityLabel(
                phase: .uploading, total: 10, examined: 3, percent: 30, status: nil, bundle: bundle, locale: locale
            ),
            "Sauvegarde en cours, 3 sur 10, 30 pour cent"
        )
        XCTAssertEqual(
            BackupSettingsView.activeAccessibilityLabel(
                phase: .checking, total: 0, examined: 0, percent: 0, status: nil, bundle: bundle, locale: locale
            ),
            "Analyse de votre photothèque"
        )
        // The engine's own status line is already localized: it is appended as is.
        XCTAssertEqual(
            BackupSettingsView.activeAccessibilityLabel(
                phase: .uploading, total: 10, examined: 3, percent: 30, status: "En pause",
                bundle: bundle, locale: locale
            ),
            "Sauvegarde en cours, 3 sur 10, 30 pour cent, En pause"
        )
    }

    func test_AC_32_9_jobSummaryAndBackupNotification() throws {
        let (bundle, locale) = try french()
        func counts(_ n: Int) -> QueueStatisticsDto {
            QueueStatisticsDto(active: n, completed: n, failed: n, delayed: 0, waiting: n, paused: 0)
        }
        XCTAssertEqual(
            AdminView.jobSummary(counts(1), bundle: bundle, locale: locale),
            "1 active · 1 en attente · 1 terminée · 1 en échec"
        )
        XCTAssertEqual(
            AdminView.jobSummary(counts(2), bundle: bundle, locale: locale),
            "2 actives · 2 en attente · 2 terminées · 2 en échec"
        )

        XCTAssertEqual(
            NotificationService.backupCompleteBody(uploaded: 1, failed: 1, success: true, bundle: bundle, locale: locale),
            "1 photo envoyée, 1 en échec."
        )
        XCTAssertEqual(
            NotificationService.backupCompleteBody(uploaded: 2, failed: 2, success: true, bundle: bundle, locale: locale),
            "2 photos envoyées, 2 en échec."
        )
        XCTAssertEqual(
            NotificationService.backupCompleteBody(uploaded: 1, failed: 2, success: false, bundle: bundle, locale: locale),
            "1 envoyée, 2 en échec."
        )
        XCTAssertEqual(
            NotificationService.backupCompleteBody(uploaded: 2, failed: 1, success: false, bundle: bundle, locale: locale),
            "2 envoyées, 1 en échec."
        )
    }

    func test_AC_32_9_liveActivityCounters() throws {
        let (bundle, locale) = try french()
        func done(uploaded: Int, failed: Int) -> BackupActivityAttributes.ContentState {
            BackupActivityAttributes.ContentState(
                progress: 1, processed: uploaded + failed, total: uploaded + failed, uploaded: uploaded,
                onServer: 0, waiting: 0, failed: failed, phase: .done, fileName: nil, estimatedDone: nil
            )
        }
        XCTAssertEqual(backupIslandSubtitle(done(uploaded: 3, failed: 1), bundle: bundle, locale: locale), "1 en échec")
        XCTAssertEqual(backupIslandSubtitle(done(uploaded: 3, failed: 2), bundle: bundle, locale: locale), "2 en échec")
        XCTAssertEqual(backupIslandSubtitle(done(uploaded: 3, failed: 0), bundle: bundle, locale: locale), "All done")

        XCTAssertEqual(
            BackupLockScreenView.subtitle(for: done(uploaded: 3, failed: 1), bundle: bundle, locale: locale),
            "Terminé avec 1 échec"
        )
        XCTAssertEqual(
            BackupLockScreenView.subtitle(for: done(uploaded: 3, failed: 2), bundle: bundle, locale: locale),
            "Terminé avec 2 échecs"
        )

        XCTAssertEqual(
            BackupLockScreenView.footerText(for: done(uploaded: 1, failed: 0), bundle: bundle, locale: locale),
            "1 photo en sécurité sur Immich"
        )
        XCTAssertEqual(
            BackupLockScreenView.footerText(for: done(uploaded: 2, failed: 0), bundle: bundle, locale: locale),
            "2 photos en sécurité sur Immich"
        )
        XCTAssertEqual(
            BackupLockScreenView.footerText(for: done(uploaded: 1, failed: 2), bundle: bundle, locale: locale),
            "1 envoyée · 2 en échec"
        )
        XCTAssertEqual(
            BackupLockScreenView.footerText(for: done(uploaded: 2, failed: 1), bundle: bundle, locale: locale),
            "2 envoyées · 1 en échec"
        )
    }
}
