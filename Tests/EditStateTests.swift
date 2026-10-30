import XCTest
import CoreImage
import CoreGraphics
@testable import ImmichSwiftUI

/// AC-600 (EditState Codable + neutral + totalRotationDeg),
/// AC-601 (CropAspectRatio enum values),
/// AC-602 (hasEdits),
/// AC-603 (EditStateStore save/load/delete),
/// AC-607 (pipeline order + neutral identity),
/// AC-618 (gestureRectToNormalized),
/// AC-619 (applyEditState crop+rotate extent).
@MainActor
final class EditStateTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: AC-600

    func test_AC_600_neutralState() {
        let s = EditState.neutral
        XCTAssertNil(s.cropRect)
        XCTAssertEqual(s.orientationSteps, 0)
        XCTAssertEqual(s.straightenDeg, 0)
        XCTAssertNil(s.aspectRatio)
        XCTAssertEqual(s.exposure, 0)
        XCTAssertEqual(s.contrast, 0)
        XCTAssertEqual(s.saturation, 0)
        XCTAssertEqual(s.warmth, 0)
    }

    func test_AC_600_hasEdits() {
        XCTAssertTrue(EditState.neutral.hasEdits == false)
        XCTAssertTrue(EditState(cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)).hasEdits)
        XCTAssertTrue(EditState(orientationSteps: 1).hasEdits)
        XCTAssertTrue(EditState(straightenDeg: 5).hasEdits)
    }

    func test_AC_600_roundtrip() throws {
        let original = EditState(
            cropRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6),
            orientationSteps: 2,
            straightenDeg: -12.5,
            aspectRatio: .fourByThree,
            exposure: 0.5,
            contrast: -0.3,
            saturation: 0.8,
            warmth: 0.1
        )
        let data = try JSONEncoder.immich.encode(original)
        let decoded = try JSONDecoder.immich.decode(EditState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_AC_600_totalRotationDeg() {
        XCTAssertEqual(EditState.neutral.totalRotationDeg, 0)
        XCTAssertEqual(EditState(orientationSteps: 1).totalRotationDeg, 90)
        XCTAssertEqual(EditState(orientationSteps: 2, straightenDeg: 10).totalRotationDeg, 190)
        XCTAssertEqual(EditState(straightenDeg: -45).totalRotationDeg, -45)
    }

    // MARK: AC-601

    func test_AC_601_cropRatioValues() {
        XCTAssertNil(CropAspectRatio.freeform.value)
        XCTAssertEqual(CropAspectRatio.square.value ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.fourByThree.value ?? 0, 4.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.threeByTwo.value ?? 0, 3.0 / 2.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.twoByThree.value ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.sixteenByNine.value ?? 0, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.nineBySixteen.value ?? 0, 9.0 / 16.0, accuracy: 0.0001)
        XCTAssertEqual(CropAspectRatio.allCases.count, 7)
    }

    // MARK: AC-602

    func test_AC_602_hasEdits_per_field() {
        XCTAssertFalse(EditState.neutral.hasEdits)
        XCTAssertTrue(EditState(exposure: 0.1).hasEdits)
        XCTAssertTrue(EditState(contrast: 0.1).hasEdits)
        XCTAssertTrue(EditState(saturation: 0.1).hasEdits)
        XCTAssertTrue(EditState(warmth: 0.1).hasEdits)
        XCTAssertTrue(EditState(aspectRatio: .square).hasEdits)
        XCTAssertTrue(EditState(cropRect: CGRect(x: 0, y: 0, width: 1, height: 1)).hasEdits)
        XCTAssertTrue(EditState(orientationSteps: 3).hasEdits)
        XCTAssertTrue(EditState(straightenDeg: 0.5).hasEdits)
    }

    // MARK: AC-603

    func test_AC_603_save_load_roundtrip() async throws {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)

        let state = EditState(cropRect: CGRect(x: 0, y: 0, width: 0.8, height: 0.8), exposure: 0.7, contrast: -0.2)
        try await store.save(state: state, forAssetId: "asset-1")

        let loaded = await store.load(assetId: "asset-1")
        XCTAssertEqual(loaded, state)
    }

    func test_AC_603_delete() async throws {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)

        try await store.save(state: EditState(exposure: 1.0), forAssetId: "asset-2")
        let beforeDelete = await store.load(assetId: "asset-2")
        XCTAssertNotNil(beforeDelete)

        try await store.delete(assetId: "asset-2")
        let afterDelete = await store.load(assetId: "asset-2")
        XCTAssertNil(afterDelete)
    }

    func test_AC_603_load_nonexistent_returns_nil() async {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)
        let loaded = await store.load(assetId: "never-saved")
        XCTAssertNil(loaded)
    }

    // MARK: AC-607 (pipeline)

    func test_AC_607_neutral_state_empty_filters() {
        let filters = EditPipeline.buildEditFilters(for: .neutral)
        XCTAssertTrue(filters.isEmpty, "neutral state should produce zero filters")
    }

    func test_AC_607_pipeline_filter_names_order() {
        let state = EditState(
            exposure: 0.5,
            contrast: 0.2,
            saturation: 0.3,
            warmth: 0.4
        )
        let filters = EditPipeline.buildEditFilters(for: state)
        XCTAssertEqual(filters.count, 3)
        XCTAssertEqual(filters[0].name, "CIExposureAdjust")
        XCTAssertEqual(filters[1].name, "CIColorControls")
        XCTAssertEqual(filters[2].name, "CITemperatureAndTint")
    }

    func test_AC_607_pipeline_partial_state() {
        // Only exposure non-neutral → single CIExposureAdjust filter.
        let state = EditState(exposure: 0.5)
        let filters = EditPipeline.buildEditFilters(for: state)
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters[0].name, "CIExposureAdjust")

        // Only contrast non-neutral → single CIColorControls.
        let state2 = EditState(contrast: 0.2)
        let filters2 = EditPipeline.buildEditFilters(for: state2)
        XCTAssertEqual(filters2.count, 1)
        XCTAssertEqual(filters2[0].name, "CIColorControls")
    }

    func test_AC_607_neutral_identity_extent() {
        let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let output = EditPipeline.applyEditState(to: input, state: .neutral)
        XCTAssertEqual(output.extent.width, 1000, accuracy: 1.0)
        XCTAssertEqual(output.extent.height, 1000, accuracy: 1.0)
    }

    // MARK: AC-618 (gestureRectToNormalized)

    func test_AC_618_gestureRectToNormalized() {
        let display = CGSize(width: 400, height: 300)
        // Full-size gesture rect → full normalized (0,0,1,1).
        let full = EditPipeline.gestureRectToNormalized(
            CGRect(x: 0, y: 0, width: 400, height: 300), in: display
        )
        XCTAssertEqual(full.origin.x, 0)
        XCTAssertEqual(full.origin.y, 0)
        XCTAssertEqual(full.width, 1, accuracy: 0.0001)
        XCTAssertEqual(full.height, 1, accuracy: 0.0001)

        // Half rect from origin.
        let half = EditPipeline.gestureRectToNormalized(
            CGRect(x: 0, y: 0, width: 200, height: 150), in: display
        )
        XCTAssertEqual(half.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.height, 0.5, accuracy: 0.0001)

        // Quarter rect offset.
        let quarter = EditPipeline.gestureRectToNormalized(
            CGRect(x: 100, y: 75, width: 200, height: 150), in: display
        )
        XCTAssertEqual(quarter.origin.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(quarter.origin.y, 0.25, accuracy: 0.0001)
        XCTAssertEqual(quarter.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(quarter.height, 0.5, accuracy: 0.0001)
    }

    // MARK: AC-619 (crop+rotate combined extent)

    private func solidImage(side: Int) -> CIImage {
        CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    func test_AC_619_crop_only_extent() {
        let input = solidImage(side: 1000)
        // Centered crop 0.6×0.6 of 1000×1000 → 600×600.
        let state = EditState(cropRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let output = EditPipeline.applyEditState(to: input, state: state)
        XCTAssertEqual(output.extent.width, 600, accuracy: 2.0)
        XCTAssertEqual(output.extent.height, 600, accuracy: 2.0)
    }

    func test_AC_619_crop_plus_90deg_extent() {
        let input = solidImage(side: 1000)
        let state = EditState(
            cropRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            orientationSteps: 1
        )
        let output = EditPipeline.applyEditState(to: input, state: state)
        // 600×600 square rotated 90° → 600×600.
        XCTAssertEqual(output.extent.width, 600, accuracy: 2.0)
        XCTAssertEqual(output.extent.height, 600, accuracy: 2.0)
    }

    func test_AC_619_crop_plus_45deg_extent() {
        let input = solidImage(side: 1000)
        let state = EditState(
            cropRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            straightenDeg: 45
        )
        let output = EditPipeline.applyEditState(to: input, state: state)
        // Square 600×600 rotated 45° → bounding box = 600 * sqrt(2) ≈ 848.5.
        let expected = 600.0 * sqrt(2.0)
        XCTAssertEqual(output.extent.width, expected, accuracy: 5.0)
        XCTAssertEqual(output.extent.height, expected, accuracy: 5.0)
    }
}
