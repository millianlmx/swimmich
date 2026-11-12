import XCTest
@testable import ImmichSwiftUI

/// AC-34.9 / AC-34.2 (L-19): what VoiceOver says on a grid thumbnail — the media
/// type, then the capture date when it is known. Languages are pinned through
/// the `<language>.lproj` bundles, so the assertions do not follow the language
/// of the test host.
@MainActor
final class AssetThumbnailAccessibilityTests: XCTestCase {

    private func item(isImage: Bool, fileCreatedAt: String, livePhotoVideoId: String? = nil) -> AssetReactItem {
        AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1, isFavorite: false,
            visibility: "timeline", isTrashed: false, isImage: isImage, thumbhash: nil,
            createdAt: fileCreatedAt, fileCreatedAt: fileCreatedAt,
            localOffsetHours: 0, duration: isImage ? nil : 12, livePhotoVideoId: livePhotoVideoId,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private let taken = "2024-07-29T14:30:00.000Z"

    func test_AC_34_9_labelNamesTypeAndDate() throws {
        let (bundle, locale) = try language("fr")

        XCTAssertEqual(
            AssetThumbnailCell.accessibilityLabel(for: item(isImage: true, fileCreatedAt: taken), bundle: bundle, locale: locale),
            "Photo, 29 juillet 2024"
        )
        XCTAssertEqual(
            AssetThumbnailCell.accessibilityLabel(for: item(isImage: false, fileCreatedAt: taken), bundle: bundle, locale: locale),
            "Vidéo, 29 juillet 2024"
        )
        // A Live Photo is a photo.
        XCTAssertEqual(
            AssetThumbnailCell.accessibilityLabel(
                for: item(isImage: true, fileCreatedAt: taken, livePhotoVideoId: "pair"), bundle: bundle, locale: locale
            ),
            "Photo, 29 juillet 2024"
        )
    }

    func test_AC_34_9_unknownDateNamesTypeOnly() throws {
        let (bundle, locale) = try language("fr")

        for unknown in ["", "garbage"] {
            XCTAssertEqual(
                AssetThumbnailCell.accessibilityLabel(for: item(isImage: true, fileCreatedAt: unknown), bundle: bundle, locale: locale),
                "Photo", unknown
            )
            XCTAssertEqual(
                AssetThumbnailCell.accessibilityLabel(for: item(isImage: false, fileCreatedAt: unknown), bundle: bundle, locale: locale),
                "Vidéo", unknown
            )
        }
    }

    func test_AC_34_2_labelsInEveryShippedLanguage() throws {
        let expected: [String: (photo: String, video: String)] = [
            "fr": ("Photo, 29 juillet 2024", "Vidéo, 29 juillet 2024"),
            "de": ("Foto, 29. Juli 2024", "Video, 29. Juli 2024"),
            "es": ("Foto, 29 de julio de 2024", "Vídeo, 29 de julio de 2024"),
            "it": ("Foto, 29 luglio 2024", "Video, 29 luglio 2024"),
        ]
        for (code, forms) in expected {
            let (bundle, locale) = try language(code)
            XCTAssertEqual(
                AssetThumbnailCell.accessibilityLabel(for: item(isImage: true, fileCreatedAt: taken), bundle: bundle, locale: locale),
                forms.photo, code
            )
            XCTAssertEqual(
                AssetThumbnailCell.accessibilityLabel(for: item(isImage: false, fileCreatedAt: taken), bundle: bundle, locale: locale),
                forms.video, code
            )
        }
    }
}
