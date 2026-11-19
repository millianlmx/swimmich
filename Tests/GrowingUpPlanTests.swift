import XCTest
@testable import ImmichSwiftUI

final class GrowingUpPlanTests: XCTestCase {

    private func asset(_ id: String, offset: Double = 0) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: "x",
            createdAt: "", fileCreatedAt: "",
            localOffsetHours: offset, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private let day: TimeInterval = 86_400

    // MARK: - Alignment

    func test_alignment_putsBothEyesOnTheEyeLine() {
        let canvas = CGSize(width: 1080, height: 1920)
        // A tilted face: the right eye lower than the left one.
        let eyes = GrowingUpEyes(CGPoint(x: 300, y: 400), CGPoint(x: 200, y: 380))
        XCTAssertEqual(eyes.left, CGPoint(x: 200, y: 380), "sorted by x")
        let transform = GrowingUpPlan.alignment(eyes: eyes, canvas: canvas)
        let left = eyes.left.applying(transform)
        let right = eyes.right.applying(transform)
        XCTAssertEqual(left.x, 1080 * (0.5 - GrowingUpPlan.eyeSpan / 2), accuracy: 0.01)
        XCTAssertEqual(left.y, 1920 * GrowingUpPlan.eyeLineY, accuracy: 0.01)
        XCTAssertEqual(right.x, 1080 * (0.5 + GrowingUpPlan.eyeSpan / 2), accuracy: 0.01)
        XCTAssertEqual(right.y, left.y, accuracy: 0.01, "level")
    }

    func test_preferredFace_firstLevelElseLeastLeaning() {
        let level = GrowingUpEyes(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 10))    // ~6°
        let leaning = GrowingUpEyes(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40))  // ~22°
        let steep = GrowingUpEyes(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100))   // 45°
        XCTAssertEqual(GrowingUpPlan.preferredFace([("lean", leaning), ("level", level)]), "level")
        XCTAssertEqual(GrowingUpPlan.preferredFace([("steep", steep), ("lean", leaning)]), "lean")
        XCTAssertNil(GrowingUpPlan.preferredFace([("steep", steep)]), "past maxTilt")
    }

    func test_aligned_turnedPhotoLeavesNoBlackCorner() throws {
        // A red photo whose eyes lean 30°: turned level, its corners would be black.
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let eyes = GrowingUpEyes(CGPoint(x: 150, y: 120), CGPoint(x: 236, y: 170))
        let canvas = CGSize(width: 108, height: 192)
        let aligned = try XCTUnwrap(GrowingUpRenderer.aligned(try XCTUnwrap(photo.cgImage), eyes: eyes, canvas: canvas))
        let width = Int(canvas.width), height = Int(canvas.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(aligned, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row 2, column 2 from the top-left (the bitmap's first row is the top).
        let pixel = Array(pixels[(2 * width + 2) * 4..<(2 * width + 2) * 4 + 4])
        XCTAssertGreaterThan(pixel[0], 60, "the backdrop fills the corner")
    }

    func test_looksLikeDocument_manyLinesOrLargeText() {
        let line = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.02)
        XCTAssertFalse(GrowingUpPlan.looksLikeDocument(textBoxes: []))
        XCTAssertFalse(GrowingUpPlan.looksLikeDocument(textBoxes: [line, line]), "a sign behind someone")
        XCTAssertTrue(GrowingUpPlan.looksLikeDocument(textBoxes: Array(repeating: line, count: 5)), "an ID card")
        XCTAssertTrue(GrowingUpPlan.looksLikeDocument(textBoxes: [CGRect(x: 0, y: 0.8, width: 0.9, height: 0.1)]), "a screen's large text")
    }

    // MARK: - Timing

    func test_frame_holdsThenEasesIntoTheNext_lastStays() {
        let speed = GrowingUpSpeed.normal // 0.4 s a face
        XCTAssertEqual(GrowingUpPlan.frame(at: 0.1, frameCount: 5, speed: speed).index, 0)
        XCTAssertEqual(GrowingUpPlan.frame(at: 0.1, frameCount: 5, speed: speed).blend, 0)
        let fading = GrowingUpPlan.frame(at: 0.4 * (GrowingUpPlan.holdShare + 1) / 2, frameCount: 5, speed: speed)
        XCTAssertEqual(fading.index, 0)
        XCTAssertEqual(fading.blend, 0.5, accuracy: 0.001, "half way through the fade")
        XCTAssertEqual(GrowingUpPlan.frame(at: 0.45, frameCount: 5, speed: speed).index, 1)
        let end = GrowingUpPlan.frame(at: 100, frameCount: 5, speed: speed)
        XCTAssertEqual(end.index, 4)
        XCTAssertEqual(end.blend, 0)
        XCTAssertEqual(GrowingUpPlan.duration(frameCount: 5, speed: speed), 4 * 0.4 + GrowingUpPlan.endHold, accuracy: 0.0001)
    }

    func test_caption_switchesHalfWayThroughTheFade() {
        let eyes = GrowingUpEyes(.zero, CGPoint(x: 10, y: 0))
        let frames = ["a", "b"].map { GrowingUpFrame(asset: asset($0), imageData: Data(), eyes: eyes, age: $0, year: "2020") }
        XCTAssertEqual(GrowingUpRenderer.caption(frames, index: 0, blend: 0.4)?.id, "a")
        XCTAssertEqual(GrowingUpRenderer.caption(frames, index: 0, blend: 0.6)?.id, "b")
    }

    // MARK: - Stretches

    func test_stretches_cutTimeNotCount() {
        // Fifty photos on one day, then one a year later: two stretches of
        // four (a birthday does not take the whole film).
        let start = Date(timeIntervalSince1970: 0)
        var assets: [AssetReactItem] = []
        var dates: [String: Date] = [:]
        for i in 0..<50 {
            let a = asset("party\(i)")
            assets.append(a)
            dates[a.id] = start.addingTimeInterval(Double(i))
        }
        let later = asset("later")
        assets.append(later)
        dates[later.id] = start.addingTimeInterval(365 * day)
        let groups = GrowingUpPlan.stretches(assets, dates: dates, stretchCount: 4, perStretch: 3)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertEqual(groups[1].map(\.id), ["later"])
    }

    // MARK: - Age

    func test_ageLabel_fromTheBirthdayAndTheLocalDay() {
        // 23:30 UTC on 1 March, taken at UTC+2: already the 2nd where it was taken.
        let date = ISO8601DateFormatter().date(from: "2022-03-01T23:30:00Z")!
        let day = GrowingUpPlan.localDay(of: asset("a", offset: 2), date: date)
        XCTAssertEqual(day, CalendarDay(year: 2022, month: 3, day: 2))
        XCTAssertNotNil(GrowingUpPlan.ageLabel(birthDate: "2020-03-02", takenOn: day))
        XCTAssertEqual(
            GrowingUpPlan.ageLabel(birthDate: "2020-03-02", takenOn: day),
            PersonAge.years(2).label()
        )
        XCTAssertNil(GrowingUpPlan.ageLabel(birthDate: nil, takenOn: day))
        XCTAssertNil(GrowingUpPlan.ageLabel(birthDate: "2023-01-01", takenOn: day), "before the birth")
    }
}
