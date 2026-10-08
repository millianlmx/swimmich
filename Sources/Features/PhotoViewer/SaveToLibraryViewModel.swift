import Foundation
import Observation
import UIKit

/// Backs the viewer's "save" actions inside the share sheet:
/// 1. **Save to Photos** — downloads the original bytes (or video file) and
///    adds them to the user's photo library via `PhotoLibraryService`.
/// 2. **Download original** — downloads the original into a uniquely-named
///    temp file and hands it to the system share sheet ("Save to Files",
///    AirDrop, …).
///
/// All infrastructure is injectable so unit tests never touch
/// `PHPhotoLibrary`, `URLSession` or the system presenter:
/// - `photoLibrary` — `PhotoLibraryService` (default `PhotoLibraryServiceImpl`)
/// - `session` — `URLSession` (default `.shared`, tests use `CapturingURLProtocol`)
/// - `presentShare` — presenter closure (default `ActivityPresenter.present`)
@MainActor
@Observable
final class SaveToLibraryViewModel {
    let asset: AssetReactItem
    let client: any ImmichClient
    let baseURL: URL
    let token: String?
    let photoLibrary: any PhotoLibraryService
    let session: URLSession
    var presentShare: ([Any], (() -> Void)?) -> Void

    var isSaving = false
    var isDownloading = false
    var errorMessage: String?
    var lastSavedIdentifier: String?
    var savedKind: String?
    var didPresentDownload = false
    var lastDownloadFileName: String?

    private var originalName: String?

    init(
        asset: AssetReactItem,
        client: any ImmichClient,
        baseURL: URL,
        token: String?,
        photoLibrary: any PhotoLibraryService = PhotoLibraryServiceImpl(),
        session: URLSession = .shared,
        presentShare: @escaping ([Any], (() -> Void)?) -> Void = { items, completion in
            MainActor.assumeIsolated {
                ActivityPresenter.present(items: items, completion: completion)
            }
        }
    ) {
        self.asset = asset
        self.client = client
        self.baseURL = baseURL
        self.token = token
        self.photoLibrary = photoLibrary
        self.session = session
        self.presentShare = presentShare
    }

    /// Saves the asset into the user's Photos library. Images go through
    /// `saveImage(data:)`; videos are staged to a temp file (real extension
    /// from the Content-Type) then `saveVideo(at:)`, with the temp dir removed
    /// afterwards.
    func saveToPhotos() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let (data, contentType) = try await transferOriginal()
            if asset.isVideo {
                let ext = AssetFileTransfer.fileExtension(forMime: contentType)
                let name = "\(AssetFileTransfer.baseName(originalName: originalName, datePrefix: datePrefix)).\(ext)"
                let fileURL = try AssetFileTransfer.writeTempFile(data: data, name: name)
                do {
                    lastSavedIdentifier = try await photoLibrary.saveVideo(at: fileURL)
                    savedKind = "video"
                } catch {
                    throw error
                }
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            } else {
                lastSavedIdentifier = try await photoLibrary.saveImage(data: data)
                savedKind = "image"
            }
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }

    /// Downloads the original into a unique temp file and presents it through
    /// the injected share presenter ("Save to Files" etc.). The temp dir is
    /// removed once the presentation completes.
    func downloadOriginal() async {
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }
        do {
            let (data, contentType) = try await transferOriginal()
            let ext = AssetFileTransfer.fileExtension(forMime: contentType)
            let base = AssetFileTransfer.baseName(originalName: originalName, datePrefix: datePrefix)
            let fileURL = try AssetFileTransfer.writeTempFile(data: data, name: "\(base).\(ext)")
            lastDownloadFileName = fileURL.lastPathComponent
            presentShare([fileURL]) {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
            didPresentDownload = true
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }

    /// Downloads the ORIGINAL file (`/api/assets/{id}/original`) with the
    /// Bearer token. Also resolves the server-side original base name once for
    /// file naming (silently falls back to a date-based name).
    private func transferOriginal() async throws -> (Data, String?) {
        if originalName == nil {
            originalName = (try? await client.getAsset(id: asset.id))?.originalFileName
        }
        let url = ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL)
        return try await AssetFileTransfer.fetchData(from: url, token: token, session: session)
    }

    private var datePrefix: String {
        String(asset.fileCreatedAt.prefix(10))
    }
}