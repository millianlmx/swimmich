import Foundation
import ImmichSharedKit

/// State and only state for the share sheet: it owns the items, the album
/// choice and the per-item status, and it is the *only* thing in the extension
/// that knows about `ShareUploading`. The view projects it and never talks to a
/// transport.
@Observable
@MainActor
final class ShareExtensionViewModel {
    private let uploader: any ShareUploading
    /// Directory the items were staged in; owned here because this is what
    /// knows when the share is over and the copies can go.
    private let stage: URL

    /// Rendered under the count: "Millian · photos.local".
    let serverLabel: String

    var items: [ShareItem] = []
    var albums: [ShareAlbum] = []
    var selectedAlbumId: String?
    var isUploading = false
    var errorMessage: String?

    init(uploader: any ShareUploading, stage: URL, serverLabel: String) {
        self.uploader = uploader
        self.stage = stage
        self.serverLabel = serverLabel
    }

    // MARK: - Derived state

    var selectedItems: [ShareItem] { items.filter(\.isSelected) }

    /// At least one selected item still needs sending, and nothing is in
    /// flight: the primary button sends.
    var canUpload: Bool { !isUploading && selectedItems.contains { $0.status.isPending } }

    /// Nothing left to send and nothing running: the primary button closes the
    /// sheet instead.
    var isFinished: Bool { !isUploading && !canUpload }

    /// "Upload 3 items" (a catalog plural: "Upload 1 item") — the count is the VM's job, the view only draws it.
    var headerTitle: String {
        String(localized: "Upload \(selectedItems.count) items")
    }

    var primaryActionTitle: String {
        if isUploading {
            return String(localized: "Uploading \(completedCount)/\(selectedItems.count)")
        }
        if canUpload {
            return String(localized: "Upload \(pendingCount) items")
        }
        return String(localized: "Done")
    }

    private var pendingCount: Int { selectedItems.filter { $0.status.isPending }.count }
    private var completedCount: Int { selectedItems.filter { $0.status.isTerminal }.count }

    // MARK: - Input

    func setItems(_ items: [ShareItem]) {
        self.items = items
    }

    /// Tap on a row. A deselected item is simply not sent and stays queued.
    func toggle(_ id: UUID) {
        guard !isUploading, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isSelected.toggle()
    }

    // MARK: - Work

    /// Best effort: a sheet with no album list still uploads, the user just
    /// cannot file the assets in one.
    func loadAlbums() async {
        do {
            albums = try await uploader.albums()
        } catch {
            albums = []
            errorMessage = Self.message(for: error)
        }
    }

    /// Sends every selected pending item in order, then attaches what it
    /// produced to the chosen album — and only then. A run that had failures
    /// leaves them selected, so the button offers to send exactly those again.
    func uploadAll() async {
        guard canUpload else { return }
        isUploading = true
        errorMessage = nil

        let pending = items.indices.filter { items[$0].isSelected && items[$0].status.isPending }
        let total = pending.count
        var uploadedIds: [String] = []
        var failures = 0

        for (position, index) in pending.enumerated() {
            // The shared session's delegate is the certificate-trust delegate,
            // not a task delegate, so byte-level progress is not available
            // inside an extension. The fraction is the batch position: a
            // determinate bar that advances with each finished item instead of
            // a spinner that says nothing.
            items[index].status = .running(total > 0 ? Double(position) / Double(total) : 0)
            let item = items[index]
            do {
                let result = try await uploader.upload(
                    fileURL: item.fileURL,
                    filename: item.filename,
                    createdAt: item.createdAt,
                    modifiedAt: item.createdAt,
                    duration: item.duration,
                    deviceAssetId: item.deviceAssetId
                )
                guard let current = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[current].status = .complete(assetId: result.id)
                uploadedIds.append(result.id)
            } catch {
                guard let current = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[current].status = .failed(Self.message(for: error))
                failures += 1
            }
        }

        isUploading = false

        guard let albumId = selectedAlbumId, !uploadedIds.isEmpty else {
            if failures > 0 && errorMessage == nil {
                errorMessage = String(localized: "\(failures) items could not be uploaded.")
            }
            return
        }
        do {
            try await uploader.addAssets(uploadedIds, toAlbum: albumId)
        } catch {
            // The assets are on the server; only the filing failed, and saying
            // so is better than a silent half-success.
            errorMessage = Self.message(for: error)
            return
        }
        if failures > 0 {
            errorMessage = String(localized: "\(failures) items could not be uploaded.")
        }
    }

    /// The staged copies exist only for this share: a shared gigabyte of video
    /// should not wait for the system to reap the container's temporary
    /// directory. Only files inside our own staging directory are touched.
    func discardStagedFiles() {
        for item in items where item.fileURL.path.hasPrefix(stage.path) {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
    }

    // MARK: - Messages

    /// Spoken form of a row's state. Composed here rather than in the view: the
    /// sheet draws strings the VM already built, and VoiceOver must not open
    /// three separate stops for one row.
    func statusText(for status: ShareItemStatus) -> String {
        switch status {
        case .enqueued:
            return String(localized: "Queued")
        case .running(let fraction):
            return String(localized: "Uploading \(Int((fraction * 100).rounded()))%")
        case .complete:
            return String(localized: "Uploaded")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ShareUploadError.server(_, let message):
            return message
        case ShareUploadError.transport:
            return String(localized: "Could not reach the server.")
        case ShareUploadError.invalidServerURL:
            return String(localized: "The saved server address is not valid.")
        case ShareUploadError.unreadableFile:
            return String(localized: "The shared file is no longer available.")
        default:
            return error.localizedDescription
        }
    }
}
