import Foundation
import Observation

/// Reads the pixel size of one viewer page's photo (L-06). One per page, never
/// shared. A grid item carries no dimensions; the full record does, so a page
/// without them reads its asset once. The image never waits for this: the zoom
/// ceiling stays at the 4x default until the size arrives.
@Observable @MainActor
final class AssetPixelSizeViewModel {
    private let asset: AssetReactItem
    private let client: (any ImmichClient)?
    private var hasRead = false

    private(set) var pixelSize: PixelSize?

    init(asset: AssetReactItem, client: (any ImmichClient)?) {
        self.asset = asset
        self.client = client
        self.pixelSize = asset.pixelSize
    }

    /// No-op when the size is known, without a client, or after a read finished
    /// (success or failure). A cancelled read counts as not done.
    func load() async {
        guard pixelSize == nil, !hasRead, let client else { return }
        do {
            let dto = try await client.getAsset(id: asset.id)
            hasRead = true
            // Deliberately without the `isEdited` rule of `AssetReactItem(from:)`:
            // the viewer and the slideshow, the only surfaces that pass a client,
            // display the original, which is what the EXIF describes. When L-21
            // makes them show the edited version, apply that rule here too.
            pixelSize = PixelSize(exif: dto.exifInfo)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            hasRead = true
        }
    }
}
