import XCTest
import UIKit
import CryptoKit
import ImageIO
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

        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient(), urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNotNil(vm.originalImage)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func test_AC_604_renderPreview_triggers_on_mutation() async {
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
        XCTAssertEqual(vm.editState.orientationSteps, 0)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 1)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 2)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 3)
        vm.rotate90CW(); XCTAssertEqual(vm.editState.orientationSteps, 0)
    }

    func test_AC_609_rotate90_ccw_cycles() {
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
        XCTAssertEqual(vm.editState.orientationSteps, 0)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 3)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 2)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 1)
        vm.rotate90CCW(); XCTAssertEqual(vm.editState.orientationSteps, 0)
    }

    func test_AC_609_straighten_clamped() {
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
        vm.setStraighten(100); XCTAssertEqual(vm.editState.straightenDeg, 45, accuracy: 0.001)
        vm.setStraighten(-100); XCTAssertEqual(vm.editState.straightenDeg, -45, accuracy: 0.001)
        vm.setStraighten(0); XCTAssertEqual(vm.editState.straightenDeg, 0, accuracy: 0.001)
    }

    func test_AC_609_independent_orientation_straighten() {
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient())
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

        let vm1 = PhotoEditorViewModel(assetId: "asset-persist", client: MockImmichClient(), store: store)
        vm1.setExposure(0.5)
        vm1.setContrast(0.3)
        vm1.saveState()

        // Spin runloop briefly so the Task inside saveState() runs.
        try await Task.sleep(nanoseconds: 100_000_000)

        let vm2 = PhotoEditorViewModel(assetId: "asset-persist", client: MockImmichClient(), store: store)
        await vm2.loadState()
        XCTAssertEqual(vm2.editState.exposure, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vm2.editState.contrast, 0.3, accuracy: 0.0001)
    }

    func test_AC_616_saveState_neutral_deletes_persisted() async throws {
        let url = tempStoreURL()
        defer { cleanup(url) }
        let store = EditStateStore(folderURL: url)

        // Step 1: save edits.
        let vm1 = PhotoEditorViewModel(assetId: "asset-delete", client: MockImmichClient(), store: store)
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
        let vm = PhotoEditorViewModel(assetId: "never-persisted", client: MockImmichClient(), store: store)
        await vm.loadState()
        XCTAssertEqual(vm.editState, .neutral)
    }

    // MARK: AC-617 (loadOriginal errors)

    func test_AC_617_loadOriginal_401() async {
        let session = makeMockedSession()
        CapturingURLProtocol.nextData = Data("unauthorized".utf8)
        CapturingURLProtocol.nextStatus = 401

        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient(), urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.errorMessage, UserFacingError.sessionExpiredMessage)
    }

    func test_AC_617_loadOriginal_invalid_data() async {
        let session = makeMockedSession()
        CapturingURLProtocol.nextData = Data("not-an-image".utf8)
        CapturingURLProtocol.nextStatus = 200

        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient(), urlSession: session)
        await vm.loadOriginal(url: URL(string: "https://example.com/img")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.errorMessage, localizedString("Invalid image data"))
    }

    func test_AC_617_loadOriginal_transport_error() async {
        // No URLProtocol installed on .shared → real network → fails immediately for localhost:1.
        let vm = PhotoEditorViewModel(assetId: "abc", client: MockImmichClient(), urlSession: .shared)
        await vm.loadOriginal(url: URL(string: "http://127.0.0.1:1/nope")!, token: "tok")

        XCTAssertNil(vm.originalImage)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Save copy / Cancel (S-1…S-19)

    private typealias Support = EditorTestSupport

    private func exportDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorExport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeStore() -> EditStateStore {
        let url = tempStoreURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return EditStateStore(folderURL: url)
    }

    /// A file where a directory is expected: any write below it fails.
    private func blockedURL() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.appendingPathComponent("sub", isDirectory: true)
    }

    private func makeVM(client: any ImmichClient = MockImmichClient(),
                        store: EditStateStore? = nil,
                        appLog: any AppLogSink = NoopAppLogSink(),
                        exportDirectory: URL) -> PhotoEditorViewModel {
        PhotoEditorViewModel(assetId: "asset-1", client: client, appLog: appLog,
                             store: store ?? makeStore(), exportDirectory: exportDirectory)
    }

    /// VM with a small loaded original and one exposure edit: `canSave` is true.
    private func editedVM(client: any ImmichClient = MockImmichClient(),
                          store: EditStateStore? = nil,
                          appLog: any AppLogSink = NoopAppLogSink(),
                          exportDirectory: URL,
                          width: Int = 64, height: Int = 48,
                          orientation: UIImage.Orientation = .up) -> PhotoEditorViewModel {
        let vm = makeVM(client: client, store: store, appLog: appLog, exportDirectory: exportDirectory)
        vm.originalImage = Support.rawImage(width: width, height: height, orientation: orientation)
        vm.setExposure(0.2)
        return vm
    }

    private func filesIn(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Releases an upload held by `MockImmichClient.uploadGate`.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation { c in
                lock.lock()
                if opened { lock.unlock(); c.resume() } else { continuation = c; lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true
            let c = continuation; continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// Saves and returns the uploaded JPEG plus the preview it must match.
    private func saveAndDecode(_ vm: PhotoEditorViewModel, client: MockImmichClient,
                               file: StaticString = #filePath, line: UInt = #line)
        async throws -> (data: Data, decoded: EditorTestSupport.DecodedJPEG, preview: UIImage) {
        await vm.saveCopyToServer()?.value
        XCTAssertEqual(vm.dismissReason, .savedCopy, "save should succeed", file: file, line: line)
        let data = try XCTUnwrap(client.lastUploadData, file: file, line: line)
        let decoded = try XCTUnwrap(Support.decodeJPEG(data), file: file, line: line)
        return (data, decoded, try XCTUnwrap(vm.previewImage, file: file, line: line))
    }

    // MARK: AC-1 / AC-2

    func test_AC1_cancel_sendsNothing_andCreatesNoFile() async {
        let client = MockImmichClient()
        let dir = exportDir()
        let vm = editedVM(client: client, exportDirectory: dir)

        vm.cancel()
        await vm.saveState().value

        XCTAssertEqual(vm.dismissReason, .cancelled)
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertTrue(filesIn(dir).isEmpty)
    }

    func test_AC2_cancel_keepsDraft_restoredOnReopen() async {
        let store = makeStore()
        let vm1 = editedVM(store: store, exportDirectory: exportDir())
        vm1.setContrast(0.3)
        vm1.cancel()
        await vm1.saveState().value

        let vm2 = makeVM(store: store, exportDirectory: exportDir())
        await vm2.loadState()
        XCTAssertEqual(vm2.editState.exposure, 0.2, accuracy: 0.0001)
        XCTAssertEqual(vm2.editState.contrast, 0.3, accuracy: 0.0001)
    }

    func test_AC2_cancelBeforeDraftLoaded_keepsDraft() async throws {
        let store = makeStore()
        try await store.save(state: EditState(exposure: 0.9), forAssetId: "asset-1")
        let vm = makeVM(store: store, exportDirectory: exportDir())

        vm.cancel()
        await vm.saveState().value

        let kept = await store.load(assetId: "asset-1")
        XCTAssertEqual(kept?.exposure, 0.9)
    }

    // MARK: AC-3 / AC-6

    func test_AC3_save_uploadsNonEmptyFile_withOriginalDates() async throws {
        let client = MockImmichClient()
        client.getAssetResponse["asset-1"] = Support.makeAssetDTO()
        let vm = editedVM(client: client, exportDirectory: exportDir())

        await vm.saveCopyToServer()?.value

        XCTAssertEqual(client.uploads.count, 1)
        let data = try XCTUnwrap(client.lastUploadData)
        XCTAssertFalse(data.isEmpty)
        XCTAssertNotNil(Support.decodeJPEG(data))
        XCTAssertEqual(client.lastUploadFilename, "IMG_0001_edited.jpg")
        XCTAssertEqual(client.lastUploadFileCreatedAt, "2024-06-30T23:30:00.000Z")
        XCTAssertEqual(client.lastUploadFileModifiedAt, "2024-07-02T10:00:00.000Z")
        XCTAssertEqual(client.lastUploadIsFavorite, false)
        XCTAssertNil(client.lastUploadLivePhotoVideoId)
        XCTAssertEqual(client.lastUploadVisibility, .timeline)
        XCTAssertEqual(client.lastUploadDeviceId, DeviceIdentity.current)
        XCTAssertTrue(client.lastUploadDeviceAssetId?.hasPrefix("edited-asset-1-") == true)
        XCTAssertEqual(client.lastUploadChecksum, Data(Insecure.SHA1.hash(data: data)).base64EncodedString())
    }

    func test_AC6_save_callsOnlyGetAssetAndUpload() async {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir())

        await vm.saveCopyToServer()?.value

        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertNil(client.lastUpdateAssetId)
        XCTAssertNil(client.lastDeleteBody)
    }

    // MARK: AC-4 (full resolution, orientation)

    func test_AC4_rotation90_fullResolution() async throws {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir(), width: 4000, height: 3000)
        vm.resetToOriginal()
        vm.rotate90CW()
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.decoded.width, 3000)
        XCTAssertEqual(result.decoded.height, 4000)
    }

    func test_AC4_cropLeftHalf_fullResolution() async throws {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir(), width: 4000, height: 3000)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.decoded.width, 2000)
        XCTAssertEqual(result.decoded.height, 3000)
    }

    func test_AC4_exifRight_matchesPreview() async throws {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir(),
                          width: 4000, height: 3000, orientation: .right)
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.preview.size.width * result.preview.scale, 3000)
        XCTAssertEqual(result.decoded.width, 3000)
        XCTAssertEqual(result.decoded.height, 4000)
        let expected = Support.markerCorners(of: result.preview)
        XCTAssertNotNil(expected.red)
        XCTAssertEqual(Support.markerCorners(of: try XCTUnwrap(UIImage(data: result.data))).red, expected.red)
        XCTAssertEqual(Support.markerCorners(of: try XCTUnwrap(UIImage(data: result.data))).green, expected.green)
    }

    func test_AC4_exifRight_crop_matchesPreview() async throws {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir(),
                          width: 4000, height: 3000, orientation: .right)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.decoded.width, Int(result.preview.size.width * result.preview.scale))
        XCTAssertEqual(result.decoded.height, Int(result.preview.size.height * result.preview.scale))
        let expected = Support.markerCorners(of: result.preview)
        XCTAssertNotNil(expected.red)
        XCTAssertEqual(Support.markerCorners(of: try XCTUnwrap(UIImage(data: result.data))).red, expected.red)
    }

    // MARK: AC-5

    func test_AC5_tempFileRemoved_afterSuccessAndFailure() async {
        let client = MockImmichClient()
        let dir = exportDir()
        let vm = editedVM(client: client, exportDirectory: dir)

        client.uploadError = URLError(.notConnectedToInternet)
        await vm.saveCopyToServer()?.value
        XCTAssertEqual(client.uploads.count, 1, "the upload was attempted")
        XCTAssertTrue(filesIn(dir).isEmpty, "temp file kept after a failed upload")

        client.uploadError = nil
        await vm.saveCopyToServer()?.value
        XCTAssertEqual(vm.dismissReason, .savedCopy)
        XCTAssertTrue(filesIn(dir).isEmpty, "temp file kept after a successful upload")
    }

    // MARK: AC-7

    func test_AC7_saving_exposesSteps_blocksActions() async {
        let client = MockImmichClient()
        let gate = Gate()
        client.uploadGate = { await gate.wait() }
        let vm = editedVM(client: client, exportDirectory: exportDir())
        XCTAssertTrue(vm.canSave)
        XCTAssertTrue(vm.canCancel)

        let task = vm.saveCopyToServer()
        XCTAssertEqual(vm.saveStep, .rendering)

        await waitUntil { vm.saveStep == .uploading && client.uploads.count == 1 }
        XCTAssertEqual(vm.saveStep, .uploading)
        XCTAssertTrue(vm.isSaving)
        XCTAssertFalse(vm.canSave)
        XCTAssertFalse(vm.canCancel)
        XCTAssertNil(vm.saveCopyToServer(), "a second save must be ignored")
        vm.cancel()
        XCTAssertNil(vm.dismissReason, "cancel is blocked while saving")

        gate.open()
        await task?.value
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertNil(vm.saveStep)
        XCTAssertEqual(vm.dismissReason, .savedCopy)
    }

    // MARK: AC-8

    func test_AC8_uploadFailure_isShown_andRetryable() async {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: exportDir())
        let stateBefore = vm.editState
        let cases: [(Error, String)] = [
            (URLError(.notConnectedToInternet), UserFacingError.offlineMessage),
            (APIError.serverError(500, nil), UserFacingError.serverErrorMessage),
            (APIError.serverError(400, nil), localizedString("The server refused the edited photo.")),
            (APIError.serverError(413, nil), localizedString("The server refused the edited photo."))
        ]
        for (error, message) in cases {
            client.uploadError = error
            await vm.saveCopyToServer()?.value
            XCTAssertEqual(vm.errorMessage, message)
            XCTAssertNotEqual(vm.errorMessage, UserFacingError.genericMessage)
            XCTAssertNil(vm.saveStep)
            XCTAssertNil(vm.dismissReason)
            XCTAssertEqual(vm.editState, stateBefore)
            XCTAssertTrue(vm.canSave, "Save must be available again to retry")
        }
        client.uploadError = nil
        await vm.saveCopyToServer()?.value
        XCTAssertNil(vm.errorMessage, "a new attempt clears the previous error")
        XCTAssertEqual(vm.dismissReason, .savedCopy)
    }

    // MARK: AC-9

    func test_AC9_renderFailure_noUpload() async {
        let client = MockImmichClient()
        let vm = makeVM(client: client, exportDirectory: exportDir())
        vm.originalImage = UIImage(ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10)))
        vm.setExposure(0.2)
        XCTAssertTrue(vm.canSave)

        await vm.saveCopyToServer()?.value

        XCTAssertEqual(vm.errorMessage, localizedString("Couldn't render the edited photo."))
        XCTAssertEqual(client.requestCount, 0)
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertNil(vm.saveStep)
    }

    func test_AC9_fileWriteFailure_noUpload() async throws {
        let client = MockImmichClient()
        let vm = editedVM(client: client, exportDirectory: try blockedURL())

        await vm.saveCopyToServer()?.value

        XCTAssertEqual(vm.errorMessage, localizedString("Couldn't write the edited photo to storage."))
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertNil(vm.dismissReason)
    }

    // MARK: AC-12

    func test_AC12_readOnly_refusesSave_noUploadReachesInner() async {
        let inner = MockImmichClient()
        let dir = exportDir()
        let guarded = ReadOnlyGuardClient(inner: inner, isEnabled: { true })
        let vm = editedVM(client: guarded, exportDirectory: dir)

        await vm.saveCopyToServer()?.value

        XCTAssertEqual(vm.errorMessage, UserFacingError.readOnlyModeMessage)
        XCTAssertTrue(inner.uploads.isEmpty)
        XCTAssertNil(vm.dismissReason)
        XCTAssertTrue(filesIn(dir).isEmpty)
    }

    // MARK: AC-13

    func test_AC13_canSave_requiresLoadedOriginalAndEdits() {
        let client = MockImmichClient()
        let vm = makeVM(client: client, exportDirectory: exportDir())

        vm.setExposure(0.2)
        XCTAssertFalse(vm.canSave, "no original loaded")
        XCTAssertNil(vm.saveCopyToServer())

        vm.originalImage = Support.rawImage(width: 32, height: 32)
        XCTAssertTrue(vm.canSave)

        vm.resetToOriginal()
        XCTAssertFalse(vm.canSave, "no edit applied")
        XCTAssertNil(vm.saveCopyToServer())
        XCTAssertEqual(client.requestCount, 0)

        vm.setWarmth(0.2)
        XCTAssertTrue(vm.canSave)
    }

    // MARK: AC-14 / AC-15

    func test_AC14_success_dismisses_andDraftStaysDeleted() async throws {
        let store = makeStore()
        try await store.save(state: EditState(exposure: 0.2), forAssetId: "asset-1")
        let client = MockImmichClient()
        let vm = makeVM(client: client, store: store, exportDirectory: exportDir())
        await vm.loadState()
        vm.originalImage = Support.rawImage(width: 64, height: 48)
        XCTAssertTrue(vm.canSave)

        await vm.saveCopyToServer()?.value
        XCTAssertEqual(vm.dismissReason, .savedCopy)

        await vm.saveState().value // what `onDisappear` runs
        let leftover = await store.load(assetId: "asset-1")
        XCTAssertNil(leftover)
        let reopened = makeVM(store: store, exportDirectory: exportDir())
        await reopened.loadState()
        XCTAssertEqual(reopened.editState, .neutral)
    }

    func test_AC15_duplicate_isSuccess() async {
        let client = MockImmichClient()
        client.uploadResponse = AssetMediaResponseDto(id: "existing", status: "duplicate")
        let vm = editedVM(client: client, exportDirectory: exportDir())

        await vm.saveCopyToServer()?.value

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.dismissReason, .savedCopy)
    }

    // MARK: AC-16

    func test_AC16_draftWriteFailure_isLogged() async throws {
        let appLog = AppLogStore()
        let store = EditStateStore(folderURL: try blockedURL())
        let vm = makeVM(store: store, appLog: appLog, exportDirectory: exportDir())
        vm.setExposure(0.5)

        await vm.saveState().value

        let entry = try XCTUnwrap(appLog.snapshot().first)
        XCTAssertEqual(entry.level, .warning)
        XCTAssertEqual(entry.category, "Editor")
        XCTAssertNotNil(entry.details)
    }

    // MARK: AC-17

    func test_AC17_getAssetFailure_noUpload_noTempFile() async {
        let client = MockImmichClient()
        let dir = exportDir()
        let vm = editedVM(client: client, exportDirectory: dir)
        let stateBefore = vm.editState
        let cases: [(Error, String)] = [
            (APIError.network(URLError(.notConnectedToInternet)), UserFacingError.offlineMessage),
            (APIError.serverError(404, nil), localizedString("Couldn't read the original photo's details."))
        ]
        for (error, message) in cases {
            client.globalError = error
            await vm.saveCopyToServer()?.value
            XCTAssertEqual(vm.errorMessage, message)
            XCTAssertTrue(client.uploads.isEmpty)
            XCTAssertTrue(filesIn(dir).isEmpty)
            XCTAssertEqual(vm.editState, stateBefore)
            XCTAssertNil(vm.dismissReason)
        }
    }

    // MARK: AC-18

    func test_AC18_jpegCarriesOriginalDateAndOffset() async throws {
        let client = MockImmichClient()
        client.getAssetResponse["asset-1"] = Support.makeAssetDTO(
            localDateTime: "2024-07-01T01:30:00.000Z", fileCreatedAt: "2024-06-30T23:30:00.000Z")
        let vm = editedVM(client: client, exportDirectory: exportDir())
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.decoded.exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2024:07:01 01:30:00")
        XCTAssertEqual(result.decoded.exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, "+02:00")
        XCTAssertFalse(result.decoded.hasGPS)
    }

    func test_AC18_noExifOriginal_offsetZero() async throws {
        let client = MockImmichClient()
        client.getAssetResponse["asset-1"] = Support.makeAssetDTO(
            localDateTime: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z")
        let vm = editedVM(client: client, exportDirectory: exportDir())
        let result = try await saveAndDecode(vm, client: client)
        XCTAssertEqual(result.decoded.exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String, "+00:00")
    }
}
