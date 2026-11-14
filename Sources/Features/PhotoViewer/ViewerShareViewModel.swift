import Foundation
import Observation

/// Shares the viewer's current photo through the iOS share sheet, in the
/// quality the user chose (B-31).
///
/// The body is streamed to a file by a `FileDownloadTransport` and moved — never
/// held in memory — so an original of hundreds of megabytes costs no RAM. The
/// download reports its progress, can be cancelled (cancelling shares nothing
/// and leaves no temporary file) and, when it fails, says so instead of opening
/// an empty sheet.
///
/// A video is always shared in its original quality (upstream's behavior): the
/// "preview" of a video is a still frame.
@MainActor
@Observable
final class ViewerShareViewModel {
    enum Phase: Equatable {
        case idle
        /// `fraction` is `nil` until the server tells the size of the body.
        case downloading(fraction: Double?)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    /// Set while a failed share's message waits for the user's OK.
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private let client: any ImmichClient
    private let baseURL: URL
    private let token: String?
    private let transport: any FileDownloadTransport
    private let customHeaders: any CustomHeadersProviding
    private let fileManager: FileManager
    private let presentShare: ([Any], (() -> Void)?) -> Void
    private var task: Task<Void, Never>?

    init(
        client: any ImmichClient,
        baseURL: URL,
        token: String?,
        transport: any FileDownloadTransport,
        customHeaders: any CustomHeadersProviding = CustomHeadersRegistry.shared,
        fileManager: FileManager = .default,
        presentShare: @escaping ([Any], (() -> Void)?) -> Void = { items, done in
            MainActor.assumeIsolated {
                ActivityPresenter.present(items: items, completion: done)
            }
        }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.customHeaders = customHeaders
        self.fileManager = fileManager
        self.presentShare = presentShare
    }

    /// The qualities the long-press menu offers: a video has only its original.
    static func choices(for asset: AssetReactItem) -> [ShareQuality] {
        asset.isVideo ? [.original] : ShareQuality.allCases
    }

    static func effectiveQuality(_ requested: ShareQuality, for asset: AssetReactItem) -> ShareQuality {
        asset.isVideo ? .original : requested
    }

    /// Starts a share. Ignored while another one is downloading.
    func share(_ asset: AssetReactItem, quality: ShareQuality) {
        if case .downloading = phase { return }
        phase = .downloading(fraction: nil)
        task = Task { [weak self] in
            await self?.run(asset, quality: quality)
        }
    }

    /// Stops the download in flight. Without effect when none is, so it is safe
    /// to call whenever the viewer goes away.
    func cancel() {
        guard case .downloading = phase else { return }
        task?.cancel()
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    /// Returns once the transfer in flight (if any) has ended, whatever its end.
    func waitForCompletion() async {
        await task?.value
    }

    private func updateProgress(_ fraction: Double?) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction: fraction)
    }

    private func run(_ asset: AssetReactItem, quality: ShareQuality) async {
        var received: URL?
        var shareDirectory: URL?
        do {
            let resolved = Self.effectiveQuality(quality, for: asset)
            // The original's name and type only name the file: a failure here
            // is tolerated, the date-based name takes over.
            let info = try? await client.getAsset(id: asset.id)
            try Task.checkCancellation()

            // The photo as uploaded, never its edited rendering (L-21 #4: sharing keeps the original),
            // sent explicitly in both qualities since the server's default differs between versions.
            let url = resolved == .original
                ? ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL, edited: false)
                : asset.thumbnailURL(base: baseURL, size: .preview, edited: false)
            var request = URLRequest(url: url)
            ServerRequestAuthorization.apply(token: token, custom: customHeaders.headers(for: url), to: &request)

            let file = try await transport.download(request) { [weak self] done, expected in
                let fraction: Double? = expected > 0 ? Double(done) / Double(expected) : nil
                Task { @MainActor in self?.updateProgress(fraction) }
            }
            received = file.url

            if let status = file.statusCode, !(200..<300).contains(status) {
                throw APIError.serverError(status, nil)
            }
            let size = (try? fileManager.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw APIError.decoding("Downloaded payload is empty") }

            let originalName = info?.originalFileName
            let base = AssetFileTransfer.baseName(
                originalName: originalName, datePrefix: String(asset.fileCreatedAt.prefix(10))
            )
            let ext: String
            switch resolved {
            case .original:
                let named = originalName.map { ($0 as NSString).pathExtension } ?? ""
                ext = named.isEmpty
                    ? AssetFileTransfer.fileExtension(forMime: file.contentType ?? info?.originalMimeType)
                    : named
            case .preview:
                ext = AssetFileTransfer.sharedFileExtension(
                    sharedContentType: file.contentType, originalMime: info?.originalMimeType
                )
            }

            let fileURL = try AssetFileTransfer.moveToShareFile(file.url, name: "\(base).\(ext)", fileManager: fileManager)
            received = nil
            let directory = fileURL.deletingLastPathComponent()
            shareDirectory = directory

            // A cancel that arrived while the transport was finishing still
            // wins: nothing is presented and the file is removed below.
            try Task.checkCancellation()
            phase = .idle
            shareDirectory = nil
            presentShare([fileURL]) { [fileManager] in
                try? fileManager.removeItem(at: directory)
            }
        } catch {
            if let received { try? fileManager.removeItem(at: received) }
            if let shareDirectory { try? fileManager.removeItem(at: shareDirectory) }
            if UserFacingError.isCancellation(error) {
                phase = .idle
            } else {
                phase = .failed(message: error.userFacingMessage ?? String(localized: "Couldn't Share"))
            }
        }
    }
}
