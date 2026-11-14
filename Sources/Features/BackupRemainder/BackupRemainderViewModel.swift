import Foundation
import Observation
import Photos
import UIKit

/// One row of "Remaining to back up": a photo or video a complete backup pass
/// would still send, with what the list shows of it.
struct BackupRemainderItem: Identifiable, Equatable, Sendable {
    /// Photos `localIdentifier`.
    let id: String
    let fileName: String
    /// Nil when the capture date cannot be read.
    let createdAt: Date?
    let kind: BackupAssetKind
    /// User albums only (smart albums are left out), in the order Photos lists
    /// the albums.
    let albumNames: [String]
    /// Only the edited version is still to send — the original is on the
    /// server already. An original never sent that also carries an edit is a
    /// plain row: the original is what the user will see go up first.
    let isEditOnly: Bool
}

/// What a complete backup pass would still send, for the "Remaining to back up"
/// entry and its list. Built by the dependency container, held by `RootView`,
/// and read by both the entry (a count) and the list (the rows), so they can
/// never disagree.
///
/// The calculation is the engine's own rule (`BackupEngine.remainder`) run off
/// the main actor. It never exports, hashes, writes a ledger or talks to the
/// server: "already backed up" is what the local ledger knows, written by a
/// pass of the engine.
@MainActor
@Observable
final class BackupRemainderViewModel {
    /// What a result was computed for. A result whose key differs from the
    /// current one belongs to another scope or another ledger state and is
    /// never shown.
    struct LoadKey: Equatable, Sendable {
        let selectedAlbumIDs: Set<String>
        let excludedAlbumIDs: Set<String>
        let backUpEdits: Bool
        let ledgerRevision: Int
    }

    enum State: Equatable {
        case noAccess(canAsk: Bool)
        case loading
        case emptyScope
        case allBackedUp
        case list
    }

    @ObservationIgnored private let upload: UploadViewModel
    nonisolated let photos: any PhotoLibraryService

    private(set) var items: [BackupRemainderItem] = []
    private(set) var scopeCount = 0
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadedKey: LoadKey?
    private(set) var authorization: PHAuthorizationStatus

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Ids the engine recorded while a scan was running: that scan may have
    /// listed them, and the publication drops them.
    @ObservationIgnored private var recordedDuringLoad: Set<String> = []
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(upload: UploadViewModel) {
        self.upload = upload
        self.photos = upload.photos
        self.authorization = upload.photos.authorizationStatus()
        observeRecordedIDs()
        observeKey()
    }

    deinit {
        for task in observationTasks { task.cancel() }
    }

    // MARK: - Derived state

    var currentKey: LoadKey {
        let snapshot = upload.settings.snapshot()
        return LoadKey(
            selectedAlbumIDs: snapshot.selectedAlbumIDs,
            excludedAlbumIDs: snapshot.excludedAlbumIDs,
            backUpEdits: snapshot.backUpEdits,
            ledgerRevision: upload.ledgerRevision
        )
    }

    /// The published result is the one of another scope or ledger state.
    var isStale: Bool { hasLoaded && loadedKey != currentKey }

    var canReadLibrary: Bool { authorization == .authorized || authorization == .limited }

    /// Nil whenever no trustworthy number exists: no Photos access, no result
    /// yet, or a result of another scope.
    var count: Int? { canReadLibrary && hasLoaded && !isStale ? items.count : nil }

    /// A recalculation of the same scope is running: the previous result stays
    /// on screen under a discreet indicator.
    var showsReloadIndicator: Bool { isLoading && hasLoaded && !isStale }

    var state: State {
        guard canReadLibrary else { return .noAccess(canAsk: authorization == .notDetermined) }
        guard hasLoaded, !isStale else { return .loading }
        if items.isEmpty { return scopeCount == 0 ? .emptyScope : .allBackedUp }
        return .list
    }

    // MARK: - Loading

    /// Recomputes the remainder off the main actor. Without Photos access it
    /// returns at once — no scan, no system prompt. A scan already running is
    /// joined, never doubled; a caller that goes away (a view that
    /// disappears) stops waiting without cancelling the scan.
    func load() async {
        authorization = photos.authorizationStatus()
        guard canReadLibrary else { return }
        if let running = loadTask {
            await running.value
            return
        }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        isLoading = true
        recordedDuringLoad = []
        let engine = upload.engine
        var published: (key: LoadKey, computed: Computed)?
        while published == nil {
            let key = currentKey
            let settings = upload.settings.snapshot()
            let computed = await Task.detached(priority: .userInitiated) {
                Self.compute(engine: engine, settings: settings)
            }.value
            // Settings changed during the scan: that result answers a question
            // nobody asks any more. One more scan, with the latest key.
            if key == currentKey { published = (key, computed) }
        }
        if let published {
            items = published.computed.items.filter { !recordedDuringLoad.contains($0.id) }
            scopeCount = published.computed.scopeCount
            loadedKey = published.key
            hasLoaded = true
        }
        isLoading = false
        loadTask = nil
    }

    /// Asks for Photos access when the system has not asked yet, then loads.
    /// A refusal is handled by the view (Settings is the only way forward).
    func requestAccess() async {
        guard authorization == .notDetermined else { return }
        let photos = self.photos
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            photos.requestAuthorization { continuation.resume(returning: $0) }
        }
        authorization = status
        if canReadLibrary { await load() }
    }

    // MARK: - Live removal

    /// Drops the photos a pass just recorded as backed up. Never adds one.
    func applyRecorded(_ added: Set<String>) {
        guard !added.isEmpty else { return }
        if isLoading { recordedDuringLoad.formUnion(added) }
        guard items.contains(where: { added.contains($0.id) }) else { return }
        items.removeAll { added.contains($0.id) }
    }

    private func observeRecordedIDs() {
        let engine = upload.engine
        observationTasks.append(Task { [weak self] in
            var previous: Set<String>?
            for await ids in Observations({ engine.backedUpIDs }) {
                guard let self else { return }
                if let previous {
                    let added = ids.subtracting(previous)
                    if !added.isEmpty { self.applyRecorded(added) }
                }
                previous = ids
            }
        })
    }

    /// A scope, edit-setting or ledger change made on the backup screen
    /// recomputes the remainder without leaving it. Nothing starts before a
    /// first load: the screen's own `.task` does that.
    private func observeKey() {
        observationTasks.append(Task { [weak self] in
            for await key in Observations({ [weak self] in self?.currentKey }) {
                guard let self, key != nil else { return }
                Task { await self.reloadIfStale() }
            }
        })
    }

    /// Reloads when the published result is not the one of the current key.
    /// Checked when the task runs, not when it was queued: a scan that has
    /// published in between makes it a no-op instead of a second scan.
    private func reloadIfStale() async {
        guard canReadLibrary, hasLoaded || loadTask != nil, loadedKey != currentKey else { return }
        await load()
    }

    // MARK: - Off-main work

    private struct Computed: Sendable {
        let scopeCount: Int
        let items: [BackupRemainderItem]
    }

    /// Scan, album names, dates and ordering — all of it on a background
    /// thread; the main actor only publishes the result.
    private nonisolated static func compute(engine: BackupEngine, settings: BackupSettings) -> Computed {
        let scan = engine.remainder(settings: settings)
        let source = engine.source
        let userAlbums = source.fetchAlbums().filter { !$0.isSmart }
        let membership = userAlbums.isEmpty
            ? [:]
            : source.albumMembership(deviceAlbumIDs: Set(userAlbums.map(\.id)))
        let items = scan.pending.map { pending -> BackupRemainderItem in
            let candidate = pending.candidate
            let memberOf = Set(membership[candidate.id] ?? [])
            return BackupRemainderItem(
                id: candidate.id,
                fileName: candidate.fileName,
                createdAt: LongDateFormatter.parse(isoTimestamp: candidate.fileCreatedAt),
                kind: candidate.kind,
                albumNames: userAlbums.filter { memberOf.contains($0.id) }.map(\.name),
                isEditOnly: pending.plan.needsEdit && !pending.plan.needsOriginal
            )
        }
        return Computed(scopeCount: scan.scopeCount, items: items.sorted(by: Self.isOrderedBefore))
    }

    /// Newest first; same date → identifier; undated last.
    private nonisolated static func isOrderedBefore(_ lhs: BackupRemainderItem, _ rhs: BackupRemainderItem) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
            return left != right ? left > right : lhs.id < rhs.id
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.id < rhs.id
        }
    }

    /// A tile-sized thumbnail from Photos, never from the network. Not
    /// isolated on purpose: the PHAsset lookup stays off the main actor.
    nonisolated func thumbnail(for id: String, side: CGFloat, scale: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return nil
        }
        return await photos.loadThumbnail(
            for: asset, targetSize: CGSize(width: side, height: side), scale: scale
        )
    }

    // MARK: - Row texts

    static func dateText(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        AppDateFormat.string(from: date, style: .longDate, locale: locale)
    }

    static func albumsText(_ names: [String]) -> String? {
        names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// What VoiceOver reads for a whole row: name, date, albums, then "Video"
    /// and "Edited version" when they apply.
    static func accessibilityLabel(
        for item: BackupRemainderItem,
        bundle: Bundle = .main,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var parts = [item.fileName]
        if let date = item.createdAt { parts.append(dateText(date, locale: locale)) }
        if let albums = albumsText(item.albumNames) { parts.append(albums) }
        if item.kind == .video { parts.append(String(localized: "Video", bundle: bundle, locale: locale)) }
        if item.isEditOnly { parts.append(String(localized: "Edited version", bundle: bundle, locale: locale)) }
        return parts.joined(separator: ", ")
    }
}
