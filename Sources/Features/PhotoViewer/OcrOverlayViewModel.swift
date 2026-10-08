import Foundation

/// Detected-text overlay state for ONE asset (gap #8, ocr-text).
///
/// One instance per asset — the viewer rebuilds it on page change, exactly like
/// `AssetDetailViewModel`. The cache is therefore the instance itself, not a
/// global dictionary, which is what makes `load()` idempotent.
@Observable
@MainActor
final class OcrOverlayViewModel {
    let assetId: String
    private let client: any ImmichClient

    /// Boxes in reading order (`textScore` descending, then top-left `y`).
    private(set) var boxes: [AssetOcrResponseDto] = []
    private(set) var isLoading = false
    /// True once a fetch has succeeded — the boxes are then cached for the
    /// lifetime of this instance.
    private(set) var didLoad = false
    /// Set when a fetch failed for a reason other than cancellation. The viewer
    /// renders it in a chrome capsule, never as a blocking alert.
    var errorMessage: String?

    init(assetId: String, client: any ImmichClient) {
        self.assetId = assetId
        self.client = client
    }

    /// Fetches the detected text once per asset; further calls are no-ops while
    /// a fetch is in flight or after a completed one. A failed fetch leaves
    /// `didLoad` false so re-enabling the toggle retries it.
    func load() async {
        guard !(didLoad || isLoading) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            boxes = try await client.getAssetOcr(id: assetId).sorted(by: Self.readingOrder)
            errorMessage = nil
            didLoad = true
        } catch {
            guard !UserFacingError.isCancellation(error) else { return }
            errorMessage = String(localized: "Detected text unavailable")
        }
    }

    /// Stable reading order: most confident first, then top-to-bottom on the
    /// image (the server's array order is not specified).
    private static func readingOrder(_ a: AssetOcrResponseDto, _ b: AssetOcrResponseDto) -> Bool {
        if a.textScore != b.textScore { return a.textScore > b.textScore }
        return a.quad.topLeft.y < b.quad.topLeft.y
    }
}
