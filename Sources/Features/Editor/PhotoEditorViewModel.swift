import Foundation
import UIKit
import CoreImage
import Metal
import Observation

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

    /// Injectable for tests (CapturingURLProtocol pattern). AC-604 / AC-617.
    var urlSession: URLSession = .shared

    // MARK: Observable state

    var originalImage: UIImage?
    var previewImage: UIImage?
    var editState: EditState = .neutral {
        didSet { renderPreview() }
    }
    var isLoading: Bool = false
    var errorMessage: String?

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

    // MARK: Init

    init(assetId: String,
         store: EditStateStore = EditStateStore(),
         urlSession: URLSession = .shared) {
        self.assetId = assetId
        self.store = store
        self.urlSession = urlSession
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
        let output = EditPipeline.applyEditState(to: input, state: editState)
        if let cgOut = ciContext.createCGImage(output, from: output.extent) {
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

    // MARK: Persistence (AC-616)

    /// Persists state to disk. If `!hasEdits`, deletes the stored file instead of writing
    /// an orphan — preserves "Revenir à l'original" guarantee across app kills (loop 3 challenger
    /// SIGNIFICANT resolution).
    func saveState() {
        Task { [store, assetId, editState] in
            if editState.hasEdits {
                try? await store.save(state: editState, forAssetId: assetId)
            } else {
                await store.delete(assetId: assetId)
            }
        }
    }

    /// Restores previously saved state on entry. AC-616.
    func loadState() async {
        if let restored = await store.load(assetId: assetId) {
            editState = restored
        }
    }

    // MARK: Private

    private func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(value, lo), hi)
    }
}
