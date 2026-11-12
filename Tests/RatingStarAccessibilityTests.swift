import XCTest
@testable import ImmichSwiftUI

/// AC-34.5 (L-19): each star of a rating bar says the action its touch performs
/// (the catalog agrees the plural), the current rank says it takes the rating
/// back, and the stars up to the rating carry the selected trait.
final class RatingStarAccessibilityTests: XCTestCase {

    func test_AC_34_5_starLabelsAndSelection() throws {
        let (bundle, locale) = try language("fr")
        let rating = 3

        XCTAssertEqual(PVRatingBar.starLabel(value: 1, rating: rating, bundle: bundle, locale: locale), "Noter 1 étoile")
        XCTAssertEqual(PVRatingBar.starLabel(value: 2, rating: rating, bundle: bundle, locale: locale), "Noter 2 étoiles")
        XCTAssertEqual(PVRatingBar.starLabel(value: 3, rating: rating, bundle: bundle, locale: locale), "Retirer la note")
        XCTAssertEqual(PVRatingBar.starLabel(value: 4, rating: rating, bundle: bundle, locale: locale), "Noter 4 étoiles")
        XCTAssertEqual(PVRatingBar.starLabel(value: 5, rating: rating, bundle: bundle, locale: locale), "Noter 5 étoiles")

        XCTAssertEqual((1...5).map { PVRatingBar.isStarSelected(value: $0, rating: rating) }, [true, true, true, false, false])
    }

    func test_AC_34_5_noRatingSelectsNoStar() throws {
        let (bundle, locale) = try language("fr")

        XCTAssertEqual((1...5).map { PVRatingBar.isStarSelected(value: $0, rating: nil) }, [false, false, false, false, false])
        XCTAssertEqual(PVRatingBar.starLabel(value: 1, rating: nil, bundle: bundle, locale: locale), "Noter 1 étoile")
        XCTAssertEqual(PVRatingBar.starLabel(value: 5, rating: nil, bundle: bundle, locale: locale), "Noter 5 étoiles")
    }
}
