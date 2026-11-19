import XCTest
@testable import ImmichSwiftUI

final class ThenAndNowPlanTests: XCTestCase {

    private func marker(_ id: String, _ lat: Double, _ lon: Double, year: Int, city: String? = "Paris") -> DatedMarker {
        DatedMarker(id: id, latitude: lat, longitude: lon, year: year, city: city, country: "France")
    }

    // MARK: - Spots

    func test_spots_samePlaceYearsApart_widestGapFirst() {
        let markers = [
            // The Eiffel Tower: 2014 and 2024 (10 years).
            marker("e1", 48.85840, 2.29450, year: 2014), marker("e2", 48.85842, 2.29452, year: 2024),
            marker("e3", 48.85841, 2.29449, year: 2024),
            // A café in Lyon: 2020 and 2023 (3 years).
            marker("c1", 45.76400, 4.83560, year: 2020, city: "Lyon"), marker("c2", 45.76401, 4.83561, year: 2023, city: "Lyon"),
            // A one-year gap: not a then & now.
            marker("b1", 43.29650, 5.36980, year: 2022, city: "Marseille"), marker("b2", 43.29651, 5.36981, year: 2023, city: "Marseille"),
            // Far apart in space: two different places.
            marker("f1", 48.86000, 2.33000, year: 2010), marker("f2", 48.87000, 2.35000, year: 2025),
        ]
        let spots = ThenAndNowPlan.spots(markers)
        XCTAssertEqual(spots.map(\.thenYear), [2014, 2020])
        XCTAssertEqual(spots.first?.nowIDs, ["e2", "e3"])
        XCTAssertEqual(spots.first?.thenIDs, ["e1"])
        XCTAssertEqual(spots.first?.place, "Paris, France")
        XCTAssertEqual(spots.last?.yearGap, 3)
    }

    func test_spots_oneStreetIsOneSpot() {
        // Two spots 100 m apart along one street: the better one only.
        let markers = [
            marker("a1", 48.85000, 2.35000, year: 2012), marker("a2", 48.85001, 2.35001, year: 2024),
            marker("b1", 48.85090, 2.35000, year: 2015), marker("b2", 48.85091, 2.35001, year: 2024),
        ]
        let spots = ThenAndNowPlan.spots(markers)
        XCTAssertEqual(spots.count, 1)
        XCTAssertEqual(spots.first?.thenYear, 2012)
    }

    // MARK: - Pairs

    func test_rankedPairs_mostAlikeFirst_unknownLast() {
        let distances: [String: Double] = ["a|x": 0.9, "a|y": 0.2, "b|x": 0.5]
        let pairs = ThenAndNowPlan.rankedPairs(then: ["a", "b"], now: ["x", "y"]) { distances["\($0)|\($1)"] }
        XCTAssertEqual(pairs.map { "\($0.then)|\($0.now)" }, ["a|y", "b|x", "a|x", "b|y"])
    }

    // MARK: - Video

    func test_wipe_holdsSweepsAndStays() {
        XCTAssertEqual(ThenAndNowPlan.wipe(at: 0.5), 0)
        XCTAssertEqual(ThenAndNowPlan.wipe(at: ThenAndNowPlan.videoHold + ThenAndNowPlan.videoWipe / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ThenAndNowPlan.wipe(at: ThenAndNowPlan.videoDuration), 1)
    }

    func test_filter_coversTheYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let filter = ThenAndNowPlan.filter(year: 2019, calendar: calendar)
        XCTAssertEqual(filter.from.map { calendar.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2019, month: 1, day: 1))
        XCTAssertEqual(filter.to.map { calendar.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2019, month: 12, day: 31))
    }

    // MARK: - Drawing

    func test_wipeImage_drawsBothPhotos() throws {
        // Decoded for display, like the previews: in a SwiftUI Canvas such
        // photos did not draw and the picture stayed blank.
        func photo(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }.preparingForDisplay()!
        }
        let then = ThenNowPhoto(id: "a", image: photo(.red), focus: CGPoint(x: 0.5, y: 0.5), year: 2014)
        let now = ThenNowPhoto(id: "b", image: photo(.blue), focus: CGPoint(x: 0.5, y: 0.5), year: 2024)
        let image = ThenAndNowRenderer.wipeImage(then: then, now: now, wipe: 0.5, size: CGSize(width: 90, height: 160))
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 90 * 160 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: 90, height: 160, bitsPerComponent: 8, bytesPerRow: 90 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 90, height: 160))
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 90 + x) * 4..<(y * 90 + x) * 4 + 3]) }
        XCTAssertGreaterThan(pixel(20, 60)[2], 200, "the now photo, on the left")
        XCTAssertGreaterThan(pixel(70, 60)[0], 200, "the then photo, on the right")
    }

    func test_stacked_isAStoryImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let then = ThenNowPhoto(id: "a", image: image, focus: CGPoint(x: 0.5, y: 0.5), year: 2014)
        let now = ThenNowPhoto(id: "b", image: image, focus: CGPoint(x: 0.5, y: 0.5), year: 2024)
        let stacked = ThenAndNowRenderer.stacked(then: then, now: now, place: "Paris, France", credit: true)
        XCTAssertEqual(stacked.size, CGSize(width: 1080, height: 1920))
    }
}
