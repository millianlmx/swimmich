import Foundation
import UIKit
import CoreImage
import Metal
import Observation
import Photos

/// Step shown while the edited photo is being saved (copy upload or Photos).
/// Extensible: only `PhotoEditorView` switches on it.
enum EditorSaveStep: Equatable {
    case rendering, uploading, savingToPhotos
}

enum EditorDismissReason: Equatable {
    case cancelled, savedCopy
}

/// Non-destructive photo editor ViewModel (cahier §5).
///
/// Holds the original `UIImage`, current `EditState`, and a Metal-backed `CIContext`.
/// On each mutation, `renderPreview()` re-applies the pipeline → publishes `previewImage`.
///
/// Testability: `urlSession` is injectable (mirrors `ImmichAPIClient(session:)` pattern) so
/// tests can mock HTTP via `CapturingURLProtocol` (AC-604, AC-617).
@Observable
@MainActor
final class PhotoEditorViewModel {

    // MARK: Identity / inputs

    let assetId: String
    private let store: EditStateStore
    private let client: any ImmichClient
    private let appLog: any AppLogSink
    private let photos: any PhotoLibraryService
    private let exportDirectory: URL

    /// Injectable for tests (CapturingURLProtocol pattern). AC-604 / AC-617.
    var urlSession: URLSession = .shared

    // MARK: Observable state

    var originalImage: UIImage?
    var previewImage: UIImage?
    var editState: EditState = .neutral {
        didSet {
            draftSettled = true
            savedToPhotos = false
            renderPreview()
        }
    }
    var isLoading: Bool = false
    var errorMessage: String?
    private(set) var saveStep: EditorSaveStep?
    private(set) var dismissReason: EditorDismissReason?
    /// True after a successful "Save to Photos" until the next edit, save, or editor close.
    private(set) var savedToPhotos = false

    /// True once the stored draft was read or `editState` was mutated; until then `saveState()`
    /// must not touch the store (a close during the original's download would delete the draft).
    @ObservationIgnored private var draftSettled = false
    /// True after a successful copy save: the draft is gone and must not be rewritten on close.
    @ObservationIgnored private var draftRetired = false

    /// Test-visible counter of render passes. AC-605 verifies mutation → render.
    @ObservationIgnored private(set) var renderCounter: Int = 0

    /// V1.5 polish: debounce interval (seconds) for render pipeline. Default 0 = synchronous
    /// (preserves AC-604/605 sync contract). DI wires 0.033 (≈30fps cap) for production so the
    /// Metal pipeline doesn't re-render per slider tick. AC-702 / AC-703.
    @ObservationIgnored var renderDebounceInterval: TimeInterval = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    // MARK: CIContext (lazy Metal-backed)

    @ObservationIgnored private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    // MARK: Derived UI helpers

    /// AC-608: rule-of-thirds overlay visible when crop is active.
    var isGridVisible: Bool {
        editState.aspectRatio != nil || editState.cropRect != nil
    }

    /// AC-612: revert button enabled only when state has any edit.
    var canRevert: Bool {
        editState.hasEdits
    }

    /// Gates both save actions (Save and Save to Photos): they share the same conditions.
    var isSaving: Bool { saveStep != nil }
    var canSave: Bool { originalImage != nil && editState.hasEdits && !isSaving }
    var canCancel: Bool { !isSaving }

    // MARK: Init

    init(assetId: String,
         client: any ImmichClient,
         appLog: any AppLogSink = NoopAppLogSink(),
         photos: any PhotoLibraryService = PhotoLibraryServiceImpl(),
         store: EditStateStore = EditStateStore(),
         urlSession: URLSession = .shared,
         exportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("immich-editor", isDirectory: true)) {
        self.assetId = assetId
        self.client = client
        self.appLog = appLog
        self.photos = photos
        self.store = store
        self.urlSession = urlSession
        self.exportDirectory = exportDirectory
    }

    // MARK: Loading (AC-604, AC-617)

    /// Fetches the original asset bytes via Bearer-authenticated `URLSession`.
    /// Sets `errorMessage` on 401, invalid image data, or transport errors.
    func loadOriginal(url: URL, token: String?) async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            errorMessage = error.userFacingMessage
            return
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let failure: APIError = http.statusCode == 401 ? .unauthorized : .http(http.statusCode)
            errorMessage = failure.userFacingMessage
            return
        }

        guard let image = UIImage(data: data) else {
            errorMessage = String(localized: "Invalid image data")
            return
        }

        originalImage = image
        renderImmediately()
    }

    // MARK: Render pipeline

    /// Debounced entry point. AC-703: with `renderDebounceInterval > 0`, cancels any pending
    /// render task and schedules a new one at `interval` — caps pipeline invocations during
    /// rapid slider drags. With interval = 0 (default), renders synchronously → preserves
    /// AC-604/605 sync test contract.
    func renderPreview() {
        guard renderDebounceInterval > 0 else {
            renderImmediately()
            return
        }
        renderTask?.cancel()
        let interval = renderDebounceInterval
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            // Cancellation: a newer mutation has rescheduled; skip this render.
            if Task.isCancelled { return }
            self?.renderImmediately()
        }
    }

    /// Synchronous Metal render. Re-applies the pipeline to `originalImage` → `previewImage`.
    /// AC-604 / AC-605. Called directly by `loadOriginal()` and (interval=0) by `renderPreview()`.
    func renderImmediately() {
        renderCounter += 1
        guard let original = originalImage,
              let cgImage = original.cgImage else {
            previewImage = originalImage
            return
        }
        let input = CIImage(cgImage: cgImage)
        let output = EditedImageRenderer.opaqueOutput(EditPipeline.applyEditState(to: input, state: editState))
        if let cgOut = ciContext.createCGImage(output, from: EditedImageRenderer.renderRect(output.extent)) {
            previewImage = UIImage(cgImage: cgOut, scale: original.scale, orientation: original.imageOrientation)
        } else {
            previewImage = original
        }
    }

    // MARK: Mutators (AC-605, AC-609, AC-610, AC-611)

    func setExposure(_ value: Double) {
        editState.exposure = clamp(value, -2.0, 2.0)
    }

    func setContrast(_ value: Double) {
        editState.contrast = clamp(value, -1.0, 1.0)
    }

    func setSaturation(_ value: Double) {
        editState.saturation = clamp(value, -1.0, 1.0)
    }

    func setWarmth(_ value: Double) {
        editState.warmth = clamp(value, -1.0, 1.0)
    }

    /// Fine-grained straightening slider, clamped to [-45, +45]. AC-609.
    func setStraighten(_ degrees: Double) {
        editState.straightenDeg = clamp(degrees, -45.0, 45.0)
    }

    func setCropRect(_ normalized: CGRect?) {
        editState.cropRect = normalized
    }

    /// Sets the aspect ratio AND adjusts `cropRect` to be centered with the requested ratio.
    /// AC-611.
    func setAspectRatio(_ ratio: CropAspectRatio?) {
        editState.aspectRatio = ratio
        guard let target = ratio?.value else {
            // Freeform: drop cropRect to let user freely drag, or leave existing.
            return
        }
        // Center a crop rect of the requested ratio within normalized 0..1 space.
        // Image normalized square: width=height=1. Fit a centered rect with the target W/H ratio.
        let h: CGFloat
        let w: CGFloat
        if target >= 1 {
            w = 1.0
            h = 1.0 / target
        } else {
            h = 1.0
            w = target
        }
        editState.cropRect = CGRect(
            x: (1.0 - w) / 2.0,
            y: (1.0 - h) / 2.0,
            width: w,
            height: h
        )
    }

    /// 90° clockwise rotation. orientationSteps increments mod 4. AC-609.
    func rotate90CW() {
        editState.orientationSteps = (editState.orientationSteps + 1) % 4
    }

    /// 90° counter-clockwise rotation. AC-609.
    func rotate90CCW() {
        editState.orientationSteps = (editState.orientationSteps + 3) % 4
    }

    /// Resets all edits to neutral. AC-606.
    func resetToOriginal() {
        editState = .neutral
    }

    // MARK: Cancel / Save (copy to server)

    /// Closes the editor without sending anything. The draft is left to `saveState()` (#1).
    func cancel() {
        guard !isSaving else { return }
        dismissReason = .cancelled
    }

    /// Renders the original at full resolution, writes a temp JPEG and uploads it as a NEW asset.
    /// Returns nil (and changes nothing) when `!canSave`, so a second call never double-uploads.
    @discardableResult
    func saveCopyToServer() -> Task<Void, Never>? {
        guard canSave else { return nil }
        errorMessage = nil
        savedToPhotos = false
        saveStep = .rendering
        return Task { await performSave() }
    }

    /// Renders the edited original at full resolution to a temp JPEG and writes it to the
    /// device photo library — the same file Save would upload, nothing is uploaded.
    /// Returns nil (and changes nothing) when `!canSave`.
    @discardableResult
    func saveToPhotos() -> Task<Void, Never>? {
        guard canSave else { return nil }
        errorMessage = nil
        savedToPhotos = false
        saveStep = .savingToPhotos
        return Task { await performSaveToPhotos() }
    }

    private func performSaveToPhotos() async {
        do {
            try await withRenderedCopy { fileURL, _, _ in
                let data: Data
                do { data = try await Task.detached { try Data(contentsOf: fileURL) }.value }
                catch { throw EditorSaveError.fileWriteFailed }
                do { _ = try await photos.saveImage(data: data) }
                catch { throw Self.classifyPhotosError(error) }
            }
        } catch {
            errorMessage = message(for: error)
            saveStep = nil
            return
        }
        savedToPhotos = true
        saveStep = nil
    }

    /// Renders the edited original to a temp JPEG in `exportDirectory`, runs `body` with it,
    /// and always removes the file.
    private func withRenderedCopy<T>(_ body: (_ fileURL: URL, _ asset: AssetResponseDto,
                                              _ metadata: EditedCopyMetadata) async throws -> T) async throws -> T {
        guard let original = originalImage, let cgImage = original.cgImage else {
            throw EditorSaveError.renderFailed
        }
        let orientation = original.imageOrientation
        let state = editState

        let asset = try await fetchOriginalAsset()
        let metadata = try EditedCopyMetadata(asset: asset)

        let directory = exportDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EditorSaveError.fileWriteFailed
        }
        let fileURL = directory.appendingPathComponent("edit-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await Task.detached(priority: .userInitiated) {
            try EditedImageRenderer.writeJPEG(cgImage: cgImage, orientation: orientation,
                                              state: state, metadata: metadata, to: fileURL)
        }.value

        return try await body(fileURL, asset, metadata)
    }

    private func performSave() async {
        do {
            try await withRenderedCopy { fileURL, asset, metadata in
                let checksum: String
                do {
                    checksum = try await Task.detached { try BackupEngine.streamingSHA1Base64(fileURL) }.value
                } catch {
                    throw EditorSaveError.fileWriteFailed
                }

                saveStep = .uploading
                do {
                    _ = try await client.uploadAsset(
                        fileURL: fileURL,
                        fileCreatedAt: asset.fileCreatedAt,
                        fileModifiedAt: asset.fileModifiedAt,
                        filename: metadata.fileName,
                        duration: nil,
                        isFavorite: false,
                        visibility: .timeline,
                        livePhotoVideoId: nil,
                        checksum: checksum,
                        deviceAssetId: "edited-\(assetId)-\(UUID().uuidString)",
                        deviceId: DeviceIdentity.current
                    )
                } catch {
                    throw Self.classifyUploadError(error)
                }
            }
        } catch {
            errorMessage = message(for: error)
            saveStep = nil
            return
        }

        // Success: the draft is retired and `saveState()` (onDisappear) must not recreate it.
        draftRetired = true
        do {
            try await store.delete(assetId: assetId)
        } catch {
            logDraftFailure("Edit draft delete failed", error)
        }
        dismissReason = .savedCopy
        saveStep = nil
    }

    /// Original's server metadata. Only transport-level failures keep their own message;
    /// everything else (404, decoding…) means the original's details are unavailable.
    private func fetchOriginalAsset() async throws -> AssetResponseDto {
        do {
            return try await client.getAsset(id: assetId)
        } catch {
            guard let family = UserFacingError.from(error)?.family else { throw error }
            if family == .other { throw EditorSaveError.metadataUnavailable }
            throw error
        }
    }

    private static func classifyUploadError(_ error: Error) -> Error {
        switch error as? APIError {
        case .serverError(let code, _) where (400..<500).contains(code),
             .http(let code) where (400..<500).contains(code):
            return EditorSaveError.uploadRejected
        default:
            return error
        }
    }

    /// Only the user's exact refusal is singled out; any other PhotoKit error keeps the generic message.
    private static func classifyPhotosError(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.accessUserDenied.rawValue {
            return EditorSaveError.photosAccessDenied
        }
        return error
    }

    /// `nil` for a cancellation (no message).
    private func message(for error: Error) -> String? {
        switch error as? EditorSaveError {
        case .metadataUnavailable: return String(localized: "Couldn't read the original photo's details.")
        case .renderFailed: return String(localized: "Couldn't render the edited photo.")
        case .fileWriteFailed: return String(localized: "Couldn't write the edited photo to storage.")
        case .uploadRejected: return String(localized: "The server refused the edited photo.")
        case .photosAccessDenied:
            return String(localized: "Access to Photos is denied. Allow it in Settings to save the edited photo.")
        case nil: return error.userFacingMessage
        }
    }

    // MARK: Persistence (AC-616)

    /// Persists state to disk. If `!hasEdits`, deletes the stored file instead of writing
    /// an orphan — preserves "Revenir à l'original" guarantee across app kills (loop 3 challenger
    /// SIGNIFICANT resolution). No-op until the stored draft has been read (or the state mutated)
    /// and after a successful copy save; failures go to the app log.
    @discardableResult
    func saveState() -> Task<Void, Never> {
        guard draftSettled, !draftRetired else { return Task {} }
        return Task { [store, assetId, editState, weak self] in
            do {
                if editState.hasEdits {
                    try await store.save(state: editState, forAssetId: assetId)
                } else {
                    try await store.delete(assetId: assetId)
                }
            } catch {
                let what = editState.hasEdits ? "Edit draft save failed" : "Edit draft delete failed"
                self?.logDraftFailure(what, error)
            }
        }
    }

    /// Restores previously saved state on entry. AC-616.
    func loadState() async {
        if let restored = await store.load(assetId: assetId) {
            editState = restored
        }
        draftSettled = true
    }

    private func logDraftFailure(_ message: String, _ error: Error) {
        appLog.record(AppLogEntry(level: .warning, method: "FILE", path: "EditStates",
                                  category: "Editor", message: message,
                                  details: String(describing: error)))
    }

    // MARK: Private

    private func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(value, lo), hi)
    }
}
