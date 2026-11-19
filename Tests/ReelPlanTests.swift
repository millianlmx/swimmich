import XCTest
@testable import ImmichSwiftUI

final class ReelPlanTests: XCTestCase {

    private func candidate(_ id: String, minute: Int, score: Double) -> DumpCandidate {
        let time = String(format: "2024-07-01T%02d:%02d:00.000Z", minute / 60, minute % 60)
        let asset = AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: "x",
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
        return DumpCandidate(asset: asset, score: score, focus: CGPoint(x: 0.5, y: 0.5), aspect: 1)
    }

    // MARK: - Timeline

    func test_segment_titleThenOneBeatAPhoto_lastHeld() {
        XCTAssertEqual(ReelPlan.segment(at: 0.5, photoCount: 4).segment, .title)
        XCTAssertEqual(ReelPlan.segment(at: ReelPlan.titleDuration, photoCount: 4).segment, .photo(0))
        let second = ReelPlan.segment(at: ReelPlan.titleDuration + ReelPlan.beat * 1.5, photoCount: 4)
        XCTAssertEqual(second.segment, .photo(1))
        XCTAssertEqual(second.progress, 0.5, accuracy: 0.0001)
        // The last photo runs its beat and the end hold.
        let end = ReelPlan.segment(at: ReelPlan.duration(photoCount: 4) - 0.01, photoCount: 4)
        XCTAssertEqual(end.segment, .photo(3))
        XCTAssertGreaterThan(end.progress, 0.99)
        XCTAssertEqual(ReelPlan.duration(photoCount: 4), ReelPlan.titleDuration + 4 * ReelPlan.beat + ReelPlan.endHold, accuracy: 0.0001)
    }

    // MARK: - Pick

    func test_pick_weighsMatchAndQuality_skipsDuplicates_chronological() {
        // Best match first. b is the best photo but the worst match; c is a duplicate of a.
        let candidates = [
            candidate("a", minute: 30, score: 0.5),
            candidate("c", minute: 31, score: 0.9),
            candidate("d", minute: 10, score: 0.4),
            candidate("b", minute: 0, score: 1.0),
        ]
        let sameMoment: (DumpCandidate, DumpCandidate) -> Bool = { x, y in
            x.id == y.id || Set([x.id, y.id]) == ["a", "c"]
        }
        let picks = ReelPlan.pick(candidates, count: 3, isDuplicate: sameMoment)
        XCTAssertEqual(picks.map(\.id), ["b", "d", "c"], "c outweighs a; in the order taken")
    }

    func test_pick_keepsAddedPhotos_neverRemovedOnes() {
        let candidates = (0..<6).map { candidate("p\($0)", minute: $0, score: Double(6 - $0) / 6) }
        let picks = ReelPlan.pick(
            candidates, count: 3, required: ["p5"], excluded: ["p0"], isDuplicate: { $0.id == $1.id }
        )
        // p5 (the worst) stays because it was added; p0 (the best) is gone because it was removed.
        XCTAssertEqual(picks.map(\.id), ["p1", "p2", "p5"])
    }

    func test_placeLabel() {
        XCTAssertEqual(ReelPlan.placeLabel(city: "Lisbon", country: "Portugal"), "Lisbon, Portugal")
        XCTAssertEqual(ReelPlan.placeLabel(city: "Singapore", country: "Singapore"), "Singapore")
        XCTAssertEqual(ReelPlan.placeLabel(city: " ", country: "France"), "France")
        XCTAssertNil(ReelPlan.placeLabel(city: nil, country: ""))
    }

    func test_yearRange() {
        XCTAssertEqual(ReelPlan.yearRange([2021, 2019, 2025]), "2019 – 2025")
        XCTAssertEqual(ReelPlan.yearRange([2024, 2024]), "2024")
        XCTAssertNil(ReelPlan.yearRange([]))
    }

    // MARK: - Push-in

    func test_visibleRect_narrowsTowardTheSubjectInsideTheCrop() {
        let image = CGSize(width: 1600, height: 1200)
        let canvas = CGSize(width: 1080, height: 1920)
        let start = ReelPlan.visibleRect(imageSize: image, canvas: canvas, focus: CGPoint(x: 0.5, y: 0.5), progress: 0)
        let end = ReelPlan.visibleRect(imageSize: image, canvas: canvas, focus: CGPoint(x: 0.5, y: 0.5), progress: 1)
        XCTAssertEqual(start.height, 1200, accuracy: 0.5, "a 9:16 crop of a landscape: full height")
        XCTAssertEqual(end.width, start.width * (1 - ReelPlan.zoom), accuracy: 0.5)
        XCTAssertTrue(start.insetBy(dx: -0.5, dy: -0.5).contains(end))
        // The drawn image puts the visible part exactly on the canvas.
        let rect = ReelPlan.drawRect(imageSize: image, visible: end, canvas: canvas)
        XCTAssertEqual(rect.minX + end.minX * rect.width / image.width, 0, accuracy: 0.5)
        XCTAssertEqual(end.width * rect.width / image.width, canvas.width, accuracy: 0.5)
    }
}
