import SwiftUI
import UIKit

/// In-memory cache of client-side-cropped face thumbnails (gap #5). Unassigned
/// faces have no server-side person thumbnail, so we crop the asset preview
/// locally; keyed by face id so a reassignment (which changes `person`) never
/// reuses a stale crop.
enum FaceCropCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func set(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Circular face thumbnail (gap #5). For a face assigned to a person it uses
/// the server-generated person thumbnail (`GET /api/people/{id}/thumbnail`);
/// for an unassigned face it downloads the asset preview and crops the
/// bounding box client-side (the server offers no per-face crop endpoint).
struct FaceThumbnailView: View {
    let asset: AssetReactItem
    let face: AssetFaceResponseDto
    let baseURL: URL
    let token: String?

    @State private var cropped: UIImage?

    var body: some View {
        ZStack {
            if let person = face.person {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.personThumbnail(personId: person.id, baseURL: baseURL),
                    token: token
                )
            } else if let cropped {
                Image(uiImage: cropped)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.bgTertiary.opacity(0.2))
                    .overlay(
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(Color.textSecondaryPV)
                    )
            }
        }
        .task(id: face.id) {
            if face.person == nil { await loadCrop() }
        }
    }

    private func loadCrop() async {
        if let cached = FaceCropCache.image(for: face.id) {
            cropped = cached
            return
        }
        let url = asset.thumbnailURL(base: baseURL, size: .preview)
        do {
            let image: UIImage
            if let cached = await ImageCache.shared.image(for: url) {
                image = cached
            } else {
                let epoch = await ImageCache.shared.epoch
                let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: token, session: .shared)
                guard let downloaded = UIImage(data: data) else { return }
                await ImageCache.shared.store(downloaded, for: url, epoch: epoch)
                image = downloaded
            }
            guard let cg = image.cgImage else { return }
            let crop = Self.cropRect(for: face, pixelSize: CGSize(width: cg.width, height: cg.height))
            guard let croppedCG = cg.cropping(to: crop) else { return }
            let result = UIImage(cgImage: croppedCG)
            FaceCropCache.set(result, for: face.id)
            cropped = result
        } catch {
            // Leave the placeholder on failure — non-fatal.
        }
    }

    /// Maps the face's normalized bounding box onto the preview's pixel space,
    /// adds ~25% padding, makes it square, and clamps to the image bounds.
    static func cropRect(for face: AssetFaceResponseDto, pixelSize: CGSize) -> CGRect {
        guard face.imageWidth > 0, face.imageHeight > 0, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGRect(origin: .zero, size: pixelSize)
        }
        let sx = pixelSize.width / CGFloat(face.imageWidth)
        let sy = pixelSize.height / CGFloat(face.imageHeight)
        let x1 = CGFloat(face.boundingBoxX1) * sx
        let x2 = CGFloat(face.boundingBoxX2) * sx
        let y1 = CGFloat(face.boundingBoxY1) * sy
        let y2 = CGFloat(face.boundingBoxY2) * sy

        let w = max(x2 - x1, 1)
        let h = max(y2 - y1, 1)
        let pad = max(w, h) * 0.25
        let cx = (x1 + x2) / 2
        let cy = (y1 + y2) / 2
        let side = max(w, h) + 2 * pad
        let half = side / 2

        let nx1 = max(0, cx - half)
        let ny1 = max(0, cy - half)
        let nx2 = min(pixelSize.width, nx1 + side)
        let ny2 = min(pixelSize.height, ny1 + side)
        return CGRect(x: nx1, y: ny1, width: max(0, nx2 - nx1), height: max(0, ny2 - ny1))
    }
}
