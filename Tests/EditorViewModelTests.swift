import XCTest
import UIKit
import CoreImage
@testable import ImmichSwiftUI

/// AC-604, 605, 606, 608, 609, 610, 611, 612, 616, 617.
@MainActor
final class EditorViewModelTests: XCTestCase {

    private func tempStoreURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorVMTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// 1×1 PNG for the mock payload.
    private func onePixelPNG() -> Data {
        let context = CIContext()
        let img = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let cg = context.createCGImage(img, from: img.extent)!
        let ui = UIImage(cgImage: cg)
        return ui.pngData()!
    }

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    // MARK: AC-604

    func test_AC_604_loadOriginal_success() async {
        let session = makeMockedSession()
        CapturingURLProtocol.nextData = onePixelPNG()
        CapturingURLProtocol.nextStatus = 200

        let vm = PhotoEditorViewModel(assetId: "abc", urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNotNil(vm.originalImage)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_604_renderPreview_triggers_on_mutation() async {
        let vm = PhotoEditorViewModel(assetId: "abc")
        // Pre-seed original image directly (no network) to isolate render logic.
        vm.originalImage = UIImage(cgImage: CIContext().createCGImage(
            CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)),
            from: CGRect(x: 0, y: 0, width: 100, height: 100)
        )!)
        let beforeCount = vm.renderCounter
        vm.setExposure(0.5)
        let afterCount = vm.renderCounter
        XCTAssertGreaterThan(afterCount, beforeCount, "mutation must trigger render")
    }

    // MARK: AC-605 (single test exercising all mutators)

    func test_AC_605_all_mutators_trigger_render() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        vm.originalImage = UIImage(cgImage: CIContext().createCGImage(
            CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)),
            from: CGRect(x: 0, y: 0, width: 100, height: 100)
        )!)

        var prev = vm.renderCounter
        vm.setExposure(0.5);     XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setContrast(0.2);     XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setSaturation(0.3);   XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setWarmth(0.4);       XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setStraighten(10);    XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setCropRect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.setAspectRatio(.square)
        XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.rotate90CW()
        XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.rotate90CCW()
        XCTAssertGreaterThan(vm.renderCounter, prev); prev = vm.renderCounter
        vm.resetToOriginal()
        XCTAssertGreaterThan(vm.renderCounter, prev)
    }

    // MARK: AC-606

    func test_AC_606_resetToOriginal() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        vm.setExposure(0.5)
        vm.setContrast(0.3)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(vm.editState.hasEdits)

        vm.resetToOriginal()

        XCTAssertEqual(vm.editState, .neutral)
        XCTAssertFalse(vm.editState.hasEdits)
        XCTAssertFalse(vm.canRevert)
    }

    // MARK: AC-608 (isGridVisible)

    func test_AC_608_grid_visible_when_cropping() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        XCTAssertFalse(vm.isGridVisible)
        vm.setAspectRatio(.square)
        XCTAssertTrue(vm.isGridVisible)
        vm.setAspectRatio(nil)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertTrue(vm.isGridVisible)
        vm.setCropRect(nil)
        XCTAssertFalse(vm.isGridVisible)
    }

    // MARK: AC-609 (rotate90 + straighten clamp + independence)

    func test_AC_609_rotate90_cw_cycles() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        XCTAssertEqual(vm.editState.orientationSteps, 0)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 1)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 2)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 3)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 0)
    }

    func test_AC_609_rotate90_ccw_cycles() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        XCTAssertEqual(vm.editState.orientationSteps, 0)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 3)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 2)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 1)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 0)
    }

    func test_AC_609_straighten_clamped() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        vm.setStraighten(100); XCTAssertEqual(vm.editState.straightenDeg, 45, accuracy: 0.001)
        vm.setStraighten(-100); XCTAssertEqual(vm.editState.straightenDeg, -45, accuracy: 0.001)
        vm.setStraighten(0); XCTAssertEqual(vm.editState.straightenDeg, 0, accuracy: 0.001)
    }

    func test_AC_609_independent_orientation_straighten() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        vm.rotate90CW()             // orientationSteps=1
        vm.setStraighten(10)        // straightenDeg=10
        XCTAssertEqual(vm.editState.orientationSteps, 1)
        XCTAssertEqual(vm.editState.straightenDeg, 10, accuracy: 0.001)
        // Rotating again must not clobber straighten.
        vm.rotate90CW()
        XCTAssertEqual(vm.editState.orientationSteps, 2)
        XCTAssertEqual(vm.editState.straightenDeg, 10, accuracy: 0.001)
        // Straightening again must not clobber orientation.
        vm.setStraighten(-5)
        XCTAssertEqual(vm.editState.orientationSteps, 2)
        XCTAssertEqual(vm.editState.straightenDeg, -5, accuracy: 0.001)
    }

    // MARK: AC-610 (adjustment ranges clamp)

    func test_AC_610_adjustment_ranges() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        // Exposure ±2.
        vm.setExposure(10);  XCTAssertEqual(vm.editState.exposure, 2.0, accuracy: 0.0001)
        vm.setExposure(-10); XCTAssertEqual(vm.editState.exposure, -2.0, accuracy: 0.0001)
        // Contrast ±1.
        vm.setContrast(5);   XCTAssertEqual(vm.editState.contrast, 1.0, accuracy: 0.0001)
        vm.setContrast(-5);  XCTAssertEqual(vm.editState.contrast, -1.0, accuracy: 0.0001)
        // Saturation ±1.
        vm.setSaturation(5); XCTAssertEqual(vm.editState.saturation, 1.0, accuracy: 0.0001)
        vm.setSaturation(-5); XCTAssertEqual(vm.editState.saturation, -1.0, accuracy: 0.0001)
        // Warmth ±1.
        vm.setWarmth(5);     XCTAssertEqual(vm.editState.warmth, 1.0, accuracy: 0.0001)
        vm.setWarmth(-5);    XCTAssertEqual(vm.editState.warmth, -1.0, accuracy: 0.0001)
    }

    // MARK: AC-611 (aspect ratio adjusts centered cropRect)

    func test_AC_611_setAspectRatio_adjusts_crop_center() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        vm.setAspectRatio(.square)
        // Square 1:1 → full 1×1 cropRect centered.
        XCTAssertEqual(vm.editState.cropRect?.origin.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.origin.y ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.width ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.height ?? -1, 1, accuracy: 0.0001)

        // 16:9 (target >= 1) → width=1, height=1/16*9.
        vm.setAspectRatio(.sixteenByNine)
        let expectedH = 9.0 / 16.0
        XCTAssertEqual(vm.editState.cropRect?.width ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.height ?? -1, expectedH, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.origin.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(vm.editState.cropRect?.origin.y ?? -1, (1 - expectedH) / 2, accuracy: 0.0001)
    }

    // MARK: AC-612 (canRevert)

    func test_AC_612_canRevert_enabled_only_when_hasEdits() {
        let vm = PhotoEditorViewModel(assetId: "abc")
        XCTAssertFalse(vm.canRevert)
        vm.setExposure(0.1)
        XCTAssertTrue(vm.canRevert)
        vm.resetToOriginal()
        XCTAssertFalse(vm.canRevert)
    }

    // MARK: AC-616 (persistence lifecycle)

    func test_AC_616_saveState_persists_across_new_vm() async throws {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)

        let vm1 = PhotoEditorViewModel(assetId: "asset-persist", store: store)
        vm1.setExposure(0.5)
        vm1.setContrast(0.3)
        vm1.saveState()

        // Spin runloop briefly so the Task inside saveState() runs.
        try await Task.sleep(nanoseconds: 100_000_000)

        let vm2 = PhotoEditorViewModel(assetId: "asset-persist", store: store)
        await vm2.loadState()
        XCTAssertEqual(vm2.editState.exposure, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vm2.editState.contrast, 0.3, accuracy: 0.0001)
    }

    func test_AC_616_saveState_neutral_deletes_persisted() async throws {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)

        // Step 1: save edits.
        let vm1 = PhotoEditorViewModel(assetId: "asset-delete", store: store)
        vm1.setExposure(0.5)
        vm1.saveState()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Confirm persisted.
        let saved = await store.load(assetId: "asset-delete")
        XCTAssertNotNil(saved)

        // Step 2: reset to neutral, save → must delete the file (loop 3 challenger SIGNIFICANT).
        vm1.resetToOriginal()
        vm1.saveState()
        try await Task.sleep(nanoseconds: 100_000_000)

        let afterReset = await store.load(assetId: "asset-delete")
        XCTAssertNil(afterReset, "neutral saveState must delete persisted file, not orphan it")
    }

    func test_AC_616_loadState_noop_when_absent() async {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)
        let vm = PhotoEditorViewModel(assetId: "never-persisted", store: store)
        await vm.loadState()
        XCTAssertEqual(vm.editState, .neutral)
    }

    // MARK: AC-617 (loadOriginal errors)

    func test_AC_617_loadOriginal_401() async {
        let session = makeMockedSession()
        CapturingURLProtocol.nextData = Data("unauthorized".utf8)
        CapturingURLProtocol.nextStatus = 401

        let vm = PhotoEditorViewModel(assetId: "abc", urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.errorMessage, UserFacingError.sessionExpiredMessage)
    }

    func test_AC_617_loadOriginal_invalid_data() async {
        let session = makeMockedSession()
        CapturingURLProtocol.nextData = Data("not-an-image".utf8)
        CapturingURLProtocol.nextStatus = 200

        let vm = PhotoEditorViewModel(assetId: "abc", urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.errorMessage, localizedString("Invalid image data"))
    }

    func test_AC_617_loadOriginal_transport_error() async {
        // No URLProtocol installed on .shared → real network → fails immediately for localhost:1.
        let vm = PhotoEditorViewModel(assetId: "abc", urlSession: .shared)
        await vm.loadOriginal(url: URL(string: "http://127.0.0.1:1/nope")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
    }
}
