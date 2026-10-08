import Foundation
import Observation

/// The download queue (gap G10): one row per file, followed from anywhere in
/// the app.
///
/// Built once by `DependencyContainer` and shared, like `UploadViewModel`
/// ("One VM, one run, one island"): the floating panel, the viewer's
/// "Download to Files" and the timeline's mass action must all drive ONE
/// queue, and a queue built per presentation would die with the sheet that
/// started it — the very defect this feature exists to fix
/// (`SaveToLibraryViewModel` is created and destroyed with the viewer).
///
/// It owns the rows but no transport: the request comes from `ImmichClient`,
/// the bytes are streamed to disk by `FileDownloadTransport` (the same seam
/// the offline cache uses), and the file name comes from `AssetFileTransfer`.
@MainActor
@Observable
final class DownloadQueueViewModel {
    private let client: any ImmichClient
    private let transport: any FileDownloadTransport
    private let fileManager: FileManager

    /// Every row asked for in this process, oldest first.
    private(set) var items: [DownloadItem] = []
    /// Failure to *queue* something (the batch could not be announced, the
    /// asset could not be read). A row's own failure lives on the row so it
    /// never reads as a failure of the queue.
    private(set) var errorMessage: String?

    /// In-flight runs, so a row can be cancelled.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// What each row needs to rebuild its request — kept so `retry(assetId:)`
    /// re-runs a row without asking the server for its shape again.
    private var plans: [String: DownloadPlan] = [:]
    /// Bumped on every launch: a cancelled run must not clear the handle of
    /// the run that replaced it (cancel → retry is one tap apart).
    private var generations: [String: Int] = [:]

    init(
        client: any ImmichClient,
        transport: any FileDownloadTransport,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.transport = transport
        self.fileManager = fileManager
    }

    // MARK: - Derived state

    /// True while something is queued or in flight.
    var isActive: Bool {
        items.contains { $0.status == .queued || $0.status == .running }
    }

    /// What the floating panel is keyed on: the panel exists only while there
    /// is something to follow, and it stays up when the screen that started
    /// the download is long gone.
    var isPanelVisible: Bool { isActive }

    var activeCount: Int {
        items.filter { $0.status == .queued || $0.status == .running }.count
    }

    var totalCount: Int { items.count }
    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var cancelledCount: Int { items.filter { $0.status == .cancelled }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }

    /// Bytes on disk so far, across every row.
    var aggregateReceivedBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.receivedBytes }
    }

    /// Fraction of the announced total that has arrived; `nil` while no row
    /// knows its length (the bar is then removed rather than frozen at 0 %).
    /// Computed from the rows — never a counter to keep in step.
    var aggregateProgress: Double? {
        let known = items.filter { $0.expectedBytes > 0 }
        guard !known.isEmpty else { return nil }
        let expected = known.reduce(Int64(0)) { $0 + $1.expectedBytes }
        guard expected > 0 else { return nil }
        let received = known.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.expectedBytes) }
        return min(1, Double(received) / Double(expected))
    }

    /// The total the user asked for, formatted by the VM: a view never
    /// formats a number (`OfflineDownloadViewModel.formattedUsage(_:)` is the
    /// precedent).
    var formattedAggregateSize: String {
        let announced = items.reduce(Int64(0)) { $0 + $1.expectedBytes }
        return ByteCountFormatter.string(
            fromByteCount: announced > 0 ? announced : aggregateReceivedBytes,
            countStyle: .file
        )
    }

    /// VoiceOver reads the capsule as ONE element, so its label is this
    /// sentence — not the concatenation of the `Text`s inside it.
    var panelAccessibilityLabel: String {
        String(localized: "\(completedCount) of \(totalCount) downloads in progress")
    }

    // MARK: - Per-asset access

    /// 0...1 while that asset is downloading, `nil` when idle or when the
    /// server announced no length — the same convention as
    /// `OfflineDownloadViewModel.progress(for:)`.
    func progress(for assetId: String) -> Double? {
        items.first { $0.id == assetId }?.progress
    }

    func status(for assetId: String) -> DownloadStatus? {
        items.first { $0.id == assetId }?.status
    }

    func isDownloading(_ assetId: String) -> Bool {
        let status = status(for: assetId)
        return status == .queued || status == .running
    }

    // MARK: - Enqueueing

    /// Queues the server's original for a single asset — the viewer's
    /// "Download to Files".
    func enqueue(asset: AssetReactItem) async {
        await enqueue(assets: [asset])
    }

    /// Queues a whole selection.
    ///
    /// More than one asset goes through the server's batch route, which is a
    /// **two-step** call: `POST /download/info` is what splits the request
    /// into archives and announces their sizes, and `POST /download/archive`
    /// refuses a batch it was never told about ("assets must have been
    /// previously requested via the getDownloadInfo endpoint"). A single
    /// asset has no batch to announce and goes straight to `/original`.
    func enqueue(assets: [AssetReactItem]) async {
        guard !assets.isEmpty else { return }
        errorMessage = nil

        guard assets.count > 1 else {
            await enqueueOriginal(assets[0])
            return
        }

        do {
            let info = try await client.downloadInfo(assetIds: assets.map(\.id), albumId: nil)
            let stamp = Self.todayStamp()
            for (offset, archive) in info.archives.enumerated() {
                let name = Self.archiveFileName(stamp: stamp, index: offset)
                upsert(
                    DownloadItem(
                        id: name,
                        assetId: name,
                        fileName: name,
                        isArchive: true,
                        expectedBytes: archive.size
                    ),
                    plan: .archive(name: name, assetIds: archive.assetIds)
                )
            }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// The one-asset path: the name comes from the server (a timeline cell
    /// carries none), the length from its EXIF block so the row is determinate
    /// before the first byte.
    private func enqueueOriginal(_ asset: AssetReactItem) async {
        do {
            let dto = try await client.getAsset(id: asset.id)
            let ext = (dto.originalFileName as NSString).pathExtension
            let base = AssetFileTransfer.baseName(
                originalName: dto.originalFileName,
                datePrefix: String(asset.fileCreatedAt.prefix(10))
            )
            let name = ext.isEmpty
                ? "\(base).\(AssetFileTransfer.fileExtension(forMime: dto.originalMimeType))"
                : "\(base).\(ext)"
            upsert(
                DownloadItem(
                    id: asset.id,
                    assetId: asset.id,
                    fileName: name,
                    expectedBytes: dto.exifInfo?.fileSizeInByte.map(Int64.init) ?? 0
                ),
                plan: .asset(id: asset.id)
            )
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Adds the row — or raises the one already there: a row's key IS the
    /// asset id, so asking twice never queues a second copy of the same file.
    private func upsert(_ item: DownloadItem, plan: DownloadPlan) {
        plans[item.id] = plan
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            guard items[index].status != .queued, items[index].status != .running else { return }
            items[index] = item
        } else {
            items.append(item)
        }
        start(item.id)
    }

    // MARK: - Row actions

    /// Stops a row. Cancelling is not failing: the row is parked at
    /// `.cancelled` with no error, and a queued row is simply never launched.
    func cancel(assetId: String) {
        tasks[assetId]?.cancel()
        tasks[assetId] = nil
        guard let index = items.firstIndex(where: { $0.id == assetId }) else { return }
        guard items[index].status == .queued || items[index].status == .running else { return }
        items[index].status = .cancelled
        items[index].errorMessage = nil
    }

    /// Runs a failed (or cancelled) row again, from the top.
    func retry(assetId: String) {
        guard let index = items.firstIndex(where: { $0.id == assetId }) else { return }
        guard !isDownloading(assetId) else { return }
        items[index].status = .queued
        items[index].receivedBytes = 0
        items[index].errorMessage = nil
        start(assetId)
    }

    /// Drops the rows that are over: the ones that finished, and the ones the
    /// user stopped.
    ///
    /// A cancelled row is cleared here too — it has no action of its own, and
    /// upstream drops a cancelled task from its map outright
    /// (`download.provider.dart` → `remove(id)`); leaving it behind would
    /// strand a row that nothing can ever remove.
    func clearCompleted() {
        let finished = items
            .filter { $0.status == .completed || $0.status == .cancelled }
            .map(\.id)
        guard !finished.isEmpty else { return }
        items.removeAll { finished.contains($0.id) }
        for id in finished {
            tasks[id]?.cancel()
            tasks[id] = nil
            plans[id] = nil
            generations[id] = nil
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Running one row

    private func start(_ id: String) {
        guard tasks[id] == nil, let plan = plans[id] else { return }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, plan: plan)
            // Only clear our own registration: a cancel-then-retry replaces
            // the handle while the cancelled run is still unwinding.
            if self.generations[id] == generation {
                self.tasks[id] = nil
            }
        }
    }

    private func run(id: String, plan: DownloadPlan) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .running
        items[index].receivedBytes = 0
        items[index].errorMessage = nil

        do {
            let request = try request(for: plan)
            let file = try await transport.download(request) { [weak self] received, expected in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply(received: received, expected: expected, to: id)
                }
            }
            try finish(id: id, file: file)
        } catch {
            // A cancel is not a failure: the row was already parked at
            // `.cancelled`, and this path must not turn it into an error.
            if UserFacingError.isCancellation(error) {
                if let index = items.firstIndex(where: { $0.id == id }),
                   items[index].status == .running {
                    items[index].status = .cancelled
                }
                return
            }
            markFailed(id: id, error: error)
        }
    }

    /// Builds the request for a row. The client owns URL construction and the
    /// bearer token — the queue never assembles a URL itself.
    private func request(for plan: DownloadPlan) throws -> URLRequest {
        switch plan {
        case let .asset(id):
            return try client.originalRequest(assetId: id)
        case let .archive(name, assetIds):
            // `edited: false` — the originals as stored, the same bytes the
            // offline cache and the viewer's share sheet fetch.
            return try client.downloadArchiveRequest(archiveName: name, assetIds: assetIds, edited: false)
        }
    }

    /// Progress arrives on URLSession's own queue through the transport's
    /// `@Sendable` callback, so the hop to the main actor happens here (the
    /// same seam as `OfflineDownloadViewModel.downloadAsset`).
    private func apply(received: Int64, expected: Int64, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .running else { return }
        if expected > 0 { items[index].expectedBytes = expected }
        items[index].receivedBytes = received
    }

    /// Parks ONE row at `.failed` — a row that failed must not stop the queue.
    private func markFailed(id: String, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status != .cancelled else { return }
        items[index].status = .failed
        items[index].errorMessage = error.userFacingMessage
    }

    /// Moves the streamed temp file to its final home and closes the row.
    ///
    /// The transport hands back the HTTP status instead of judging it, so the
    /// status is checked here: a 404 writes its error body to disk like any
    /// other response, and a row reporting "completed" over an error page is
    /// the one outcome this feature must never produce.
    private func finish(id: String, file: DownloadedFile) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let statusCode = file.statusCode, !(200..<300).contains(statusCode) {
            try? fileManager.removeItem(at: file.url)
            throw APIError.serverError(statusCode, nil)
        }

        let destination = try destinationURL(for: items[index].fileName)
        try fileManager.moveItem(at: file.url, to: destination)

        let written = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        items[index].receivedBytes = items[index].expectedBytes > 0
            ? items[index].expectedBytes
            : Int64(written)
        items[index].destinationURL = destination
        items[index].status = .completed
        items[index].errorMessage = nil
    }

    /// Where a finished file lands: `Documents/Downloads/`.
    ///
    /// Deliberately neither the offline cache's folder (`Application
    /// Support/OfflineAssets/<assetId>.<ext>`, trimmed by `setMaxCacheSize` and
    /// wiped by `clearAll`) nor `NSTemporaryDirectory()`, which the OS evicts:
    /// a file the user asked for has to survive and be findable. A name
    /// already taken gets a `-2`, `-3` suffix instead of being overwritten —
    /// two assets may share a server file name.
    private func destinationURL(for fileName: String) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = documents.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
            candidate = folder.appendingPathComponent(next)
            attempt += 1
        }
        return candidate
    }

    // MARK: - Helpers

    /// What a row needs to build its request, kept so a retry repeats the same
    /// call instead of re-announcing the batch.
    private enum DownloadPlan: Sendable {
        case asset(id: String)
        case archive(name: String, assetIds: [String])
    }

    /// The ZIP the server is about to build. An archive has no name of its
    /// own server-side, so it falls back to the repo's single naming authority
    /// (`AssetFileTransfer.baseName(originalName:datePrefix:)`) plus one
    /// suffix per chunk when the server split the batch.
    private static func archiveFileName(stamp: String, index: Int) -> String {
        let base = AssetFileTransfer.baseName(originalName: nil, datePrefix: stamp)
        return index == 0 ? "\(base).zip" : "\(base)-\(index + 1).zip"
    }

    /// `yyyy-MM-dd` — the shape `AssetFileTransfer.baseName(originalName:datePrefix:)`
    /// expects from an asset's `fileCreatedAt`; a batch has no single asset
    /// date, so it gets today's.
    private static func todayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
