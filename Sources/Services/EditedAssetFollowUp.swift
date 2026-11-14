import Foundation

/// Follows the photos saved or reset in Swimmich until the server has regenerated their thumbnails (L-21).
///
/// After a `PUT`/`DELETE /edits` the server serves the old image under the old thumbhash until its job
/// ends. A photo enters the table at the save and leaves it the first time the app sees a different
/// thumbhash: from the wait that follows the save, from the `AssetEditReadyV1`/`V2` event (`RootView`),
/// from the record the viewer reads when it shows the photo, or when the app returns to the foreground.
/// Seeing it means, in this order: recording the new thumbhash (every screen builds its URLs from it),
/// reloading the widgets, then fetching the offline copy again if the photo is kept. The table is in
/// memory only: a relaunch forgets it, and the next list read brings the new thumbhash anyway.
@MainActor
final class EditedAssetFollowUp {
    struct Pending: Equatable {
        let item: AssetReactItem
        let previousThumbhash: String?
        let removed: Bool
    }

    private let client: any ImmichClient
    private let reloadWidgets: @Sendable () -> Void
    private let attempts: Int
    private let interval: Duration
    private var pendingByAsset: [String: Pending] = [:]

    init(
        client: any ImmichClient,
        reloadWidgets: @escaping @Sendable () -> Void,
        attempts: Int = EditedAssetRefresh.defaultAttempts,
        interval: Duration = EditedAssetRefresh.defaultInterval
    ) {
        self.client = client
        self.reloadWidgets = reloadWidgets
        self.attempts = attempts
        self.interval = interval
    }

    /// The save of `id` whose regeneration has not been seen yet.
    func pending(for id: String) -> Pending? { pendingByAsset[id] }

    /// Registers the save, then waits for the regeneration. The record with the new thumbhash, or nil when
    /// it did not change in time (the photo stays pending and a later sighting resumes it).
    func afterSave(
        of item: AssetReactItem,
        removed: Bool,
        offline: OfflineDownloadViewModel?,
        baseURL: URL,
        token: String?,
        onRegenerated: (AssetResponseDto) -> Void = { _ in }
    ) async -> AssetResponseDto? {
        pendingByAsset[item.id] = Pending(item: item, previousThumbhash: item.thumbhash, removed: removed)
        guard let fresh = await EditedAssetRefresh.awaitRegeneration(
            assetId: item.id, previousThumbhash: item.thumbhash, client: client, attempts: attempts, interval: interval
        ) else { return nil }
        // Succession, widgets and the viewer are up to date before the first byte of the copy arrives.
        let adopted = adopt(fresh)
        onRegenerated(fresh)
        if let adopted {
            await offline?.followEdits(
                of: adopted.item.refreshed(from: fresh), edited: !adopted.removed, baseURL: baseURL, token: token
            )
        }
        return fresh
    }

    /// Reads the record of each photo still pending and adopts those whose thumbhash changed.
    func resumePending(offline: OfflineDownloadViewModel?, baseURL: URL, token: String?) async {
        for id in Array(pendingByAsset.keys) {
            guard let record = try? await client.getAsset(id: id) else { continue }
            await resume(with: record, offline: offline, baseURL: baseURL, token: token)
        }
    }

    /// The same rule for a record that was read elsewhere.
    func resume(with record: AssetResponseDto, offline: OfflineDownloadViewModel?, baseURL: URL, token: String?) async {
        guard let adopted = adopt(record) else { return }
        await offline?.followEdits(
            of: adopted.item.refreshed(from: record), edited: !adopted.removed, baseURL: baseURL, token: token
        )
    }

    /// Synchronous on purpose: the entry leaves the table before any suspension, so a regeneration seen by
    /// the event, the viewer and the foreground at once is adopted a single time.
    private func adopt(_ record: AssetResponseDto) -> Pending? {
        guard let pending = pendingByAsset[record.id],
              let thumbhash = record.thumbhash, !thumbhash.isEmpty,
              thumbhash != pending.previousThumbhash else { return nil }
        pendingByAsset[record.id] = nil
        ThumbhashSuccession.shared.record(old: pending.previousThumbhash, new: thumbhash, assetId: record.id)
        reloadWidgets()
        return pending
    }
}
