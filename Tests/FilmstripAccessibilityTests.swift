import XCTest
@testable import ImmichSwiftUI

/// AC-34.12 / AC-34.2 (L-19): a filmstrip cell is announced by its position and
/// its media type — "Photo 1 of 2", "Video 2 of 2" — in every shipped language.
@MainActor
final class FilmstripAccessibilityTests: XCTestCase {

    func test_AC_34_12_labelNamesType() throws {
        let (bundle, locale) = try language("fr")

        XCTAssertEqual(
            PhotoViewer.filmstripAccessibilityLabel(isVideo: false, position: 1, count: 2, bundle: bundle, locale: locale),
            "Photo 1 sur 2"
        )
        XCTAssertEqual(
            PhotoViewer.filmstripAccessibilityLabel(isVideo: true, position: 2, count: 2, bundle: bundle, locale: locale),
            "Vidéo 2 sur 2"
        )

        let expected: [String: (photo: String, video: String)] = [
            "de": ("Foto 1 von 2", "Video 2 von 2"),
            "es": ("Foto 1 de 2", "Vídeo 2 de 2"),
            "it": ("Foto 1 di 2", "Video 2 di 2"),
        ]
        for (code, forms) in expected {
            let (bundle, locale) = try language(code)
            XCTAssertEqual(
                PhotoViewer.filmstripAccessibilityLabel(isVideo: false, position: 1, count: 2, bundle: bundle, locale: locale),
                forms.photo, code
            )
            XCTAssertEqual(
                PhotoViewer.filmstripAccessibilityLabel(isVideo: true, position: 2, count: 2, bundle: bundle, locale: locale),
                forms.video, code
            )
        }
    }
}
