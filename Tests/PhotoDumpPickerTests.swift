import XCTest
@testable import ImmichSwiftUI

final class PhotoDumpPickerTests: XCTestCase {

    private func candidate(_ id: String, minute: Int, score: Double, focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> DumpCandidate {
        let time = String(format: "2024-07-01T%02d:%02d:00.000Z", minute / 60, minute % 60)
        let asset = AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: "x",
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
        return DumpCandidate(asset: asset, score: score, focus: focus, aspect: 1)
    }

    private let noDuplicates: (DumpCandidate, DumpCandidate) -> Bool = { $0.id == $1.id }

    // MARK: - Pick

    func test_pick_bestOfEachStretch_coverFirstThenChronological() {
        // Three stretches of two photos: the better of each pair is picked.
        let candidates = [
            candidate("a1", minute: 0, score: 0.2), candidate("a2", minute: 1, score: 0.6),
            candidate("b1", minute: 10, score: 0.9), candidate("b2", minute: 11, score: 0.3),
            candidate("c1", minute: 20, score: 0.4), candidate("c2", minute: 21, score: 0.5),
        ]
        let picks = PhotoDumpPicker.pick(candidates, count: 3, isDuplicate: noDuplicates)
        XCTAssertEqual(picks.map(\.id), ["b1", "a2", "c2"])
    }

    func test_pick_skipsDuplicatesOfAPickedPhoto() {
        // a1 and a2 are the same moment: the second stretch gives b instead.
        let candidates = [
            candidate("a1", minute: 0, score: 0.9), candidate("a2", minute: 1, score: 0.8),
            candidate("b", minute: 2, score: 0.1), candidate("c", minute: 3, score: 0.5),
        ]
        let sameMoment: (DumpCandidate, DumpCandidate) -> Bool = { a, b in
            a.id == b.id || (a.id.hasPrefix("a") && b.id.hasPrefix("a"))
        }
        let picks = PhotoDumpPicker.pick(candidates, count: 2, isDuplicate: sameMoment)
        XCTAssertEqual(Set(picks.map(\.id)), ["a1", "c"])
        XCTAssertEqual(picks.first?.id, "a1")
    }

    func test_pick_fewerCandidatesThanCount_returnsAll() {
        let candidates = (0..<3).map { candidate("p\($0)", minute: $0, score: Double($0)) }
        XCTAssertEqual(PhotoDumpPicker.pick(candidates, count: 10, isDuplicate: noDuplicates).count, 3)
    }

    func test_pick_onlyDuplicates_stillFillsTheCount() {
        let candidates = (0..<5).map { candidate("p\($0)", minute: $0, score: Double($0)) }
        let picks = PhotoDumpPicker.pick(candidates, count: 4, isDuplicate: { _, _ in true })
        XCTAssertEqual(picks.count, 4)
        XCTAssertEqual(Set(picks.map(\.id)).count, 4)
    }

    // MARK: - Swap

    func test_replacement_prefersTheSameStretchOfTime() {
        let candidates = [
            candidate("a", minute: 0, score: 0.5), candidate("a2", minute: 1, score: 0.3),
            candidate("b", minute: 10, score: 0.6), candidate("far", minute: 20, score: 0.99),
            candidate("c", minute: 30, score: 0.4),
        ]
        let picks = [candidates[2], candidates[0], candidates[4]]
        // a's neighbors in time: none before, b after → a2, not the better "far".
        let next = PhotoDumpPicker.replacement(
            for: "a", in: picks, candidates: candidates, excluded: [], isDuplicate: noDuplicates
        )
        XCTAssertEqual(next?.id, "a2")
    }

    func test_replacement_skipsExcludedAndFallsBackToBestOverall() {
        let candidates = [
            candidate("a", minute: 0, score: 0.5), candidate("a2", minute: 1, score: 0.3),
            candidate("b", minute: 10, score: 0.6), candidate("far", minute: 20, score: 0.9),
        ]
        let picks = [candidates[2], candidates[0]]
        let next = PhotoDumpPicker.replacement(
            for: "a", in: picks, candidates: candidates, excluded: ["a2"], isDuplicate: noDuplicates
        )
        XCTAssertEqual(next?.id, "far")
        XCTAssertNil(PhotoDumpPicker.replacement(
            for: "a", in: picks, candidates: candidates, excluded: ["a2", "far"], isDuplicate: noDuplicates
        ))
    }

    // MARK: - Resize

    func test_resized_growsInTimeOrder_shrinksWithoutTheCover() {
        let candidates = [
            candidate("a", minute: 0, score: 0.5), candidate("b", minute: 10, score: 0.9),
            candidate("c", minute: 20, score: 0.7), candidate("d", minute: 30, score: 0.2),
        ]
        let picks = [candidates[1], candidates[0]]
        let grown = PhotoDumpPicker.resized(picks, to: 3, candidates: candidates, excluded: [], isDuplicate: noDuplicates)
        XCTAssertEqual(grown.map(\.id), ["b", "a", "c"])
        let shrunk = PhotoDumpPicker.resized(grown, to: 2, candidates: candidates, excluded: [], isDuplicate: noDuplicates)
        XCTAssertEqual(shrunk.map(\.id), ["b", "c"])
    }

    // MARK: - Crop

    func test_cropRect_centersOnFocusWithinTheImage() {
        let size = CGSize(width: 1000, height: 500)
        // Square of a landscape: 500 × 500, centered on the focus.
        XCTAssertEqual(
            PhotoDumpPicker.cropRect(imageSize: size, ratio: 1, focus: CGPoint(x: 0.5, y: 0.5)),
            CGRect(x: 250, y: 0, width: 500, height: 500)
        )
        // A focus at the right edge stops at the edge.
        XCTAssertEqual(
            PhotoDumpPicker.cropRect(imageSize: size, ratio: 1, focus: CGPoint(x: 0.95, y: 0.5)),
            CGRect(x: 500, y: 0, width: 500, height: 500)
        )
        // 4:5 of a portrait 800 × 1200: full width, 1000 high, toward the top.
        XCTAssertEqual(
            PhotoDumpPicker.cropRect(imageSize: CGSize(width: 800, height: 1200), ratio: 0.8, focus: CGPoint(x: 0.5, y: 0.2)),
            CGRect(x: 0, y: 0, width: 800, height: 1000)
        )
    }

    func test_crop_drawsTheExportWidth() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let cropped = PhotoDumpViewModel.crop(image, ratio: 0.8, focus: CGPoint(x: 0.5, y: 0.5), width: 1080)
        XCTAssertEqual(cropped.size, CGSize(width: 1080, height: 1350))
    }

    // MARK: - Grid

    func test_gridMetrics_centersAndSlotUnderTheFinger() {
        // 3 columns of 100 × 125 (4:5), 6 apart.
        let metrics = DumpGridMetrics(width: 312, columns: 3, ratio: 0.8, spacing: 6)
        XCTAssertEqual(metrics.cellWidth, 100)
        XCTAssertEqual(metrics.cellHeight, 125)
        XCTAssertEqual(metrics.center(of: 4), CGPoint(x: 156, y: 193.5))
        XCTAssertEqual(metrics.height(count: 7), 3 * 125 + 2 * 6)
        XCTAssertEqual(metrics.index(at: metrics.center(of: 4), count: 7), 4)
        // Past the edges: clamped to the grid, and to the last photo.
        XCTAssertEqual(metrics.index(at: CGPoint(x: -40, y: -40), count: 7), 0)
        XCTAssertEqual(metrics.index(at: CGPoint(x: 500, y: 2000), count: 7), 6)
    }

    func test_gridMetrics_fourColumnsPastNinePhotos() {
        XCTAssertEqual(DumpGridMetrics.columns(forCount: 9), 3)
        XCTAssertEqual(DumpGridMetrics.columns(forCount: 10), 4)
    }

    func test_stretches_coverEveryIndexOnce() {
        let stretches = PhotoDumpPicker.stretches(10, into: 3)
        XCTAssertEqual(stretches.flatMap { Array($0) }, Array(0..<10))
        XCTAssertEqual(stretches.count, 3)
    }
}
