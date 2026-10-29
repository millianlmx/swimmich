import Foundation
import Photos
import UIKit

/// Abstraction over PHPhotoLibrary for backup / upload workflows.
protocol PhotoLibraryService: AnyObject, Sendable {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void)

    /// Enumerates assets in the user's library (ordered by creation date desc).
    func fetchAssets() -> [PHAsset]

    /// Enumerates one album's assets, ordered like `fetchAssets()`. `albumID` is
    /// the `localIdentifier` a `BackupAlbum` carries, or one of its `SmartID`s.
    func fetchAssets(inAlbumID albumID: String) -> [PHAsset]

    /// Tile-sized thumbnail of a local asset — what a grid enumerating the
    /// *device* needs (the backup path only ever wants full-resolution data).
    ///
    /// `targetSize` is in points; `scale` turns it into the pixel size the
    /// request needs. Returns nil — never throws — when the asset has no local
    /// image or the call is cancelled: a tile that cannot be drawn degrades one
    /// cell, it must not tear the grid down.
    func loadThumbnail(for asset: PHAsset, targetSize: CGSize, scale: CGFloat) async -> UIImage?

    /// Creation + modification timestamps formatted as ISO8601 `yyyy-MM-dd'T'HH:mm:ss.SSSZ`.
    func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String)

    /// Saves image bytes into the user's photo library. Returns the new asset's
    /// `localIdentifier`.
    func saveImage(data: Data) async throws -> String

    /// Saves a video (local file) into the user's photo library. Returns the new
    /// asset's `localIdentifier`.
    func saveVideo(at fileURL: URL) async throws -> String
}

extension PhotoLibraryService {
    /// Defaults for the two inventory-only points above: a conformer that only
    /// reads/writes originals (the upload path, the test doubles) answers "no
    /// album scoping, no thumbnail" instead of having to write a body it has no
    /// use for. The device screen gets the real ones from
    /// `PhotoLibraryServiceImpl`.
    func fetchAssets(inAlbumID albumID: String) -> [PHAsset] { [] }

    func loadThumbnail(for asset: PHAsset, targetSize: CGSize, scale: CGFloat) async -> UIImage? { nil }
}
