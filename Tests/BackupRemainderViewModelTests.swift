import Foundation
import Photos
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// "Remaining to back up": what a complete pass would still send, the entry's
/// count and the list's rows, and how both follow the run and the settings.
@MainActor
final class BackupRemainderViewModelTests: XCTestCase {

    // MARK: - Harness

    private final class RemainderPhotoLibrary: PhotoLibraryService, @unchecked Sendable {
        nonisolated(unsafe) var status: PHAuthorizationStatus = .authorized
        nonisolated(unsafe) var requestResult: PHAuthorizationStatus = .authorized
        nonisolated(unsafe) var requestCount = 0

        func authorizationStatus() -> PHAuthorizationStatus { status }

        func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) {
            requestCount += 1
            status = requestResult
            handler(requestResult)
        }

        func fetchAssets() -> [PHAsset] { [] }

        func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String) {
            ("2024-07-01T00:00:00.000Z", "2024-07-01T00:00:00.000Z")
        }

        func saveImage(data: Data) async throws -> String { "saved-image" }

        func saveVideo(at fileURL: URL) async throws -> String { "saved-video" }
    }

    /// Opened and closed from the test: holds a call of the fake client.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var calls = 0

        func open() { lock.lock(); isOpen = true; lock.unlock() }

        /// True for the first call only.
        private func isFirstCall() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls == 1
        }

        private var isOpenNow: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isOpen
        }

        /// The first call passes, the others wait for `open()`.
        func holdAfterFirst() async throws {
            if isFirstCall() { return }
            while !isOpenNow {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @MainActor
    private struct Rig {
        let client = MockImmichClient()
        let source = MockBackupAssetSource()
        let ledger = BackupLedger.inMemory()
        let editLedger = BackupEditLedger.inMemory()
        let photos = RemainderPhotoLibrary()
        let environment = MockBackupEnvironment()
        let engine: BackupEngine
        let settings: BackupSettingsStore
        let upload: UploadViewModel
        let vm: BackupRemainderViewModel

        init(
            candidates: [BackupCandidate] = [],
            albums: [BackupAlbum] = [],
            status: PHAuthorizationStatus = .authorized
        ) {
            // A full pass must not reconcile (the server answers accept to all).
            ledger.recordReconciliation(at: Date())
            source.candidates = candidates
            source.albums = albums
            source.dataProvider = { Data("orig-\($0)".utf8) }
            photos.status = status
            client.bulkUploadCheckResponder = { items in
                AssetBulkUploadCheckResponse(
                    results: items.map { AssetBulkUploadCheckResponse.Result(id: $0.id, action: "accept") }
                )
            }
            engine = BackupEngine(
                client: client, source: source, environment: environment,
                ledger: ledger, editLedger: editLedger
            )
            settings = BackupSettingsStore(suiteName: "remainder-\(UUID().uuidString)")
            upload = UploadViewModel(
                client: client, photos: photos, engine: engine,
                settings: settings, scheduler: MockBackupScheduler(),
                activityService: MockBackupLiveActivityService(),
                notifications: MockNotificationService(),
                readOnly: .ephemeral()
            )
            vm = BackupRemainderViewModel(upload: upload)
        }

        /// The ledger already knows `candidate` at its current signature.
        func record(_ candidate: BackupCandidate, serverID: String? = "srv") {
            ledger.markBackedUp(
                id: candidate.id, signature: candidate.fileModifiedAt,
                checksum: "chk-\(candidate.id)", serverAssetId: serverID
            )
        }

        /// A server that already holds every id.
        func serverHolds(_ ids: Set<String>) {
            client.bulkUploadCheckResponder = { items in
                AssetBulkUploadCheckResponse(results: items.map {
                    AssetBulkUploadCheckResponse.Result(
                        id: $0.id, action: ids.contains($0.id) ? "reject" : "accept"
                    )
                })
            }
        }
    }

    private func candidate(
        _ id: String,
        name: String? = nil,
        created: String = "2024-07-14T12:00:00.000Z",
        kind: BackupAssetKind = .image,
        adjusted: Bool = false
    ) -> BackupCandidate {
        BackupCandidate(
            id: id, kind: kind, fileName: name ?? "\(id).jpg",
            fileCreatedAt: created, fileModifiedAt: created,
            duration: kind == .video ? 5 : nil, isFavorite: false,
            hasAdjustments: adjusted
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func ids(_ vm: BackupRemainderViewModel) -> [String] { vm.items.map(\.id) }

    // MARK: - AC-65

    func test_AC_65_listsNeverSentHidesRecordedAndDropsSent() async throws {
        let a = candidate("a", name: "IMG_A.HEIC", created: "2024-07-14T12:00:00.000Z")
        let b = candidate("b", name: "IMG_B.HEIC", created: "2024-07-13T12:00:00.000Z")
        let c = candidate("c", name: "IMG_C.HEIC", created: "2024-07-12T12:00:00.000Z")
        let d = candidate("d", created: "2024-07-11T12:00:00.000Z")
        let e = candidate("e", created: "2024-07-10T12:00:00.000Z")
        let rig = Rig(candidates: [a, b, c, d, e])
        rig.record(d)
        rig.record(e)

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["a", "b", "c"], "the two recorded photos are not listed")
        XCTAssertEqual(rig.vm.items.map(\.fileName), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"])
        XCTAssertTrue(rig.vm.items.allSatisfy { $0.createdAt != nil })

        await rig.upload.runBackup(manual: true, only: ["b"])

        let gone = await waitUntil { !ids(rig.vm).contains("b") }
        XCTAssertTrue(gone, "the photo the pass sent leaves the list")
        XCTAssertEqual(ids(rig.vm), ["a", "c"])
        XCTAssertEqual(rig.client.uploads.count, 1)
    }

    // MARK: - AC-65.1

    func test_AC_65_1_entryCountFollowsTheRemainder() async {
        let photos = [candidate("p1"), candidate("p2"), candidate("p3")]
        let rig = Rig(candidates: photos)

        await rig.vm.load()
        XCTAssertEqual(rig.vm.count, 3)
        XCTAssertEqual(rig.vm.count, rig.vm.items.count)

        await rig.upload.runBackup(manual: true)

        let zero = await waitUntil { rig.vm.count == 0 }
        XCTAssertTrue(zero, "the entry follows the run without a reload")
        XCTAssertEqual(rig.client.uploads.count, 3)
    }

    // MARK: - AC-65.2

    func test_AC_65_2_followsTheBackupScope() async {
        let pa = candidate("pa", created: "2024-07-14T12:00:00.000Z")
        let pb = candidate("pb", created: "2024-07-13T12:00:00.000Z")
        let rig = Rig(candidates: [pa, pb])
        rig.source.candidatesByAlbum = ["A": [pa], "B": [pb]]
        rig.source.excludedAssetIDs = ["pa"]
        rig.settings.selectedAlbumIDs = ["A"]
        rig.settings.albumScope = .selected

        await rig.vm.load()
        XCTAssertEqual(ids(rig.vm), ["pa"], "only the photo of the chosen album")

        // Scope changed on the screen: no `load()` call, the vm recomputes.
        rig.settings.excludedAlbumIDs = ["A"]
        rig.settings.albumScope = .excluded
        let excluded = await waitUntil { ids(rig.vm) == ["pb"] && rig.vm.count == 1 }
        XCTAssertTrue(excluded, "with A excluded only the photo of B remains")

        // A scan held in flight: nothing of another scope is ever shown.
        let before = rig.source.fetchCandidatesCount
        let gate = DispatchSemaphore(value: 0)
        rig.source.fetchCandidatesGate = gate
        rig.settings.albumScope = .all
        let started = await waitUntil { rig.source.fetchCandidatesCount == before + 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(rig.vm.state, .loading)
        XCTAssertNil(rig.vm.count)
        XCTAssertFalse(rig.vm.showsReloadIndicator)

        // Two more changes while that scan is held: one more scan, no more.
        rig.settings.selectedAlbumIDs = ["A"]
        rig.settings.albumScope = .selected
        rig.source.fetchCandidatesGate = nil
        gate.signal()

        let settled = await waitUntil { ids(rig.vm) == ["pa"] && rig.vm.state == .list }
        XCTAssertTrue(settled, "the list matches the last setting")
        XCTAssertEqual(rig.source.fetchCandidatesCount, before + 2, "the held scan plus exactly one more")
    }

    // MARK: - AC-65.3

    func test_AC_65_3_failedAndDeferredStayListedWithoutExportOrRequest() async {
        let failing = candidate("fail", created: "2024-07-14T12:00:00.000Z")
        let deferred = candidate("defer", created: "2024-07-13T12:00:00.000Z")
        let fine = candidate("fine", created: "2024-07-12T12:00:00.000Z")
        let rig = Rig(candidates: [failing, deferred, fine])
        rig.source.failIDs = ["fail"]
        rig.source.deferIDs = ["defer"]

        await rig.upload.runBackup(manual: true)
        XCTAssertEqual(rig.engine.failedCount, 1)

        let exported = rig.source.exportedIDs.count
        let purged = rig.source.purgeCount
        let chunks = rig.client.bulkUploadCheckChunks.count
        let requests = rig.client.requestCount

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["fail", "defer"], "a failure and a deferral are still to back up")
        XCTAssertEqual(rig.source.exportedIDs.count, exported)
        XCTAssertEqual(rig.source.purgeCount, purged)
        XCTAssertEqual(rig.client.bulkUploadCheckChunks.count, chunks)
        XCTAssertEqual(rig.client.requestCount, requests)
    }

    // MARK: - AC-65.4

    func test_AC_65_4_rowShowsNameDateUserAlbumsVideoNewestFirst() async throws {
        let photo = candidate("p1", name: "IMG_0001.HEIC", created: "2024-07-14T12:00:00.000Z")
        let video = candidate("v1", name: "clip.MOV", created: "2024-07-13T12:00:00.000Z", kind: .video)
        // Listed oldest first on purpose: the list sorts.
        let rig = Rig(
            candidates: [video, photo],
            albums: [
                BackupAlbum(id: "a2", name: "Famille", count: 1),
                BackupAlbum(id: "a1", name: "Vacances", count: 1),
                BackupAlbum(id: BackupAlbum.SmartID.videos, name: "Videos", count: 1, isSmart: true),
            ]
        )
        rig.source.albumMembershipByDeviceAlbum = [
            "p1": ["a1", "a2"],
            "v1": [BackupAlbum.SmartID.videos],
        ]

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["p1", "v1"], "newest first")
        let first = try XCTUnwrap(rig.vm.items.first)
        let second = try XCTUnwrap(rig.vm.items.last)
        XCTAssertEqual(first.fileName, "IMG_0001.HEIC")
        XCTAssertEqual(first.albumNames, ["Famille", "Vacances"], "the order of the albums")
        XCTAssertEqual(first.kind, .image)
        XCTAssertEqual(second.kind, .video)
        XCTAssertEqual(second.albumNames, [], "smart albums are never named, \"Videos\" included")

        let fr = try language("fr")
        XCTAssertEqual(
            BackupRemainderViewModel.dateText(try XCTUnwrap(first.createdAt), locale: fr.locale),
            "14 juillet 2024"
        )
        XCTAssertEqual(
            BackupRemainderViewModel.accessibilityLabel(for: first, bundle: fr.bundle, locale: fr.locale),
            "IMG_0001.HEIC, 14 juillet 2024, Famille, Vacances"
        )
        XCTAssertEqual(
            BackupRemainderViewModel.accessibilityLabel(for: second, bundle: fr.bundle, locale: fr.locale),
            "clip.MOV, 13 juillet 2024, Vidéo"
        )
        XCTAssertNil(BackupRemainderViewModel.albumsText([]))
        XCTAssertEqual(BackupRemainderViewModel.albumsText(["x", "y"]), "x, y")
    }

    func test_AC_65_4_undatedRowsComeLastAndTiesBreakOnIdentifier() async {
        let rig = Rig(candidates: [
            candidate("z", created: "not a date"),
            candidate("b", created: "2024-07-14T12:00:00.000Z"),
            candidate("a", created: "2024-07-14T12:00:00.000Z"),
        ])

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["a", "b", "z"])
        XCTAssertNil(rig.vm.items.last?.createdAt)
    }

    // MARK: - AC-65.5

    func test_AC_65_5_editOfSavedPhotoListedOnlyWithSettingOn() async {
        let saved = candidate("saved", created: "2024-07-14T12:00:00.000Z", adjusted: true)
        let neverSent = candidate("never", created: "2024-07-13T12:00:00.000Z", adjusted: true)
        let rig = Rig(candidates: [saved, neverSent])
        rig.record(saved)
        rig.settings.backUpEdits = true

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["saved", "never"])
        XCTAssertEqual(rig.vm.items.first { $0.id == "saved" }?.isEditOnly, true)
        XCTAssertEqual(
            rig.vm.items.first { $0.id == "never" }?.isEditOnly, false,
            "an original never sent is a plain row, whatever its edit"
        )

        rig.settings.backUpEdits = false
        let off = await waitUntil { ids(rig.vm) == ["never"] }
        XCTAssertTrue(off, "setting off: the edit of a saved photo is not to back up")
    }

    // MARK: - AC-65.6

    func test_AC_65_6_sentAndRecognizedDisappearDuringTheRun() async {
        let rig = Rig(candidates: [
            candidate("c1", created: "2024-07-14T12:00:00.000Z"),
            candidate("c2", created: "2024-07-13T12:00:00.000Z"),
            candidate("c3", created: "2024-07-12T12:00:00.000Z"),
        ])
        rig.serverHolds(["c2"])
        let latch = Latch()
        rig.client.uploadGate = { try await latch.holdAfterFirst() }

        await rig.vm.load()
        XCTAssertEqual(rig.vm.count, 3)

        let run = Task { await rig.upload.runBackup(manual: true) }

        let two = await waitUntil { rig.vm.items.count == 1 }
        XCTAssertTrue(two, "one photo recognized as on the server, one sent")
        XCTAssertEqual(rig.vm.count, 1, "the entry drops with the list")
        XCTAssertNotEqual(ids(rig.vm), ["c2"])
        let held = ids(rig.vm)

        latch.open()
        _ = await run.value

        let empty = await waitUntil { rig.vm.items.isEmpty }
        XCTAssertTrue(empty)
        XCTAssertFalse(held.isEmpty)
    }

    // MARK: - AC-65.7

    func test_AC_65_7_emptyNoAccessAndLoadingStates() async {
        // Loading until a first result exists.
        let one = candidate("p1")
        let rig = Rig(candidates: [one])
        XCTAssertEqual(rig.vm.state, .loading)
        XCTAssertNil(rig.vm.count)

        // Everything on the server.
        rig.record(one)
        await rig.vm.load()
        XCTAssertEqual(rig.vm.state, .allBackedUp)
        XCTAssertEqual(rig.vm.count, 0)

        // A scope that holds nothing.
        let empty = Rig()
        await empty.vm.load()
        XCTAssertEqual(empty.vm.state, .emptyScope)

        // Access refused: no scan, no prompt.
        let denied = Rig(candidates: [candidate("d1")], status: .denied)
        await denied.vm.load()
        XCTAssertEqual(denied.vm.state, .noAccess(canAsk: false))
        XCTAssertNil(denied.vm.count)
        XCTAssertEqual(denied.source.fetchCandidatesCount, 0)
        XCTAssertEqual(denied.photos.requestCount, 0)

        // Not asked yet: the view offers the prompt, and an accepted prompt loads.
        let asking = Rig(candidates: [candidate("n1")], status: .notDetermined)
        await asking.vm.load()
        XCTAssertEqual(asking.vm.state, .noAccess(canAsk: true))
        XCTAssertEqual(asking.photos.requestCount, 0, "opening the list never prompts")
        await asking.vm.requestAccess()
        XCTAssertEqual(asking.vm.state, .list)
        XCTAssertEqual(asking.photos.requestCount, 1)

        // Same scope recalculated: the list stays, a discreet indicator shows.
        let gate = DispatchSemaphore(value: 0)
        let more = Rig(candidates: [candidate("m1"), candidate("m2")])
        await more.vm.load()
        more.source.fetchCandidatesGate = gate
        let reload = Task { await more.vm.load() }
        let running = await waitUntil { more.vm.isLoading }
        XCTAssertTrue(running)
        XCTAssertEqual(more.vm.state, .list)
        XCTAssertEqual(more.vm.count, 2)
        XCTAssertTrue(more.vm.showsReloadIndicator)
        more.source.fetchCandidatesGate = nil
        gate.signal()
        await reload.value
        XCTAssertFalse(more.vm.showsReloadIndicator)
        XCTAssertEqual(more.vm.count, 2)

        // Another scope recalculated: loading, no number.
        let held = DispatchSemaphore(value: 0)
        more.source.fetchCandidatesGate = held
        more.settings.backUpEdits = true
        XCTAssertEqual(more.vm.state, .loading)
        XCTAssertNil(more.vm.count)
        let started = await waitUntil { more.vm.isLoading }
        XCTAssertTrue(started)
        XCTAssertEqual(more.vm.state, .loading)
        XCTAssertNil(more.vm.count)
        XCTAssertFalse(more.vm.showsReloadIndicator)
        more.source.fetchCandidatesGate = nil
        held.signal()
        let back = await waitUntil { more.vm.state == .list }
        XCTAssertTrue(back)
    }

    // MARK: - AC-65.8

    func test_AC_65_8_largeLibraryScannedOffTheMainThread() async {
        let total = 20_000
        var all: [BackupCandidate] = []
        all.reserveCapacity(total)
        for index in 0..<total {
            let day = 1 + index / 1440
            let minute = index % 1440
            let created = String(format: "2024-01-%02dT%02d:%02d:00.000Z", day, minute / 60, minute % 60)
            all.append(candidate("p\(index)", created: created))
        }
        let albums = (0..<50).map { BackupAlbum(id: "a\($0)", name: "Album \($0)", count: 400) }
        let rig = Rig(candidates: all, albums: albums)
        for index in 0..<total { rig.source.albumMembershipByDeviceAlbum["p\(index)"] = ["a\(index % 50)"] }

        let watchdog = MainThreadWatchdog()
        watchdog.start()

        async let first: Void = rig.vm.load()
        async let second: Void = rig.vm.load()
        _ = await (first, second)

        XCTAssertEqual(rig.source.fetchCandidatesRanOnMainThread, false)
        XCTAssertEqual(rig.source.albumMembershipRanOnMainThread, false)
        XCTAssertEqual(rig.source.fetchCandidatesCount, 1, "two loads together: one scan")
        XCTAssertEqual(rig.vm.items.count, total)
        XCTAssertEqual(rig.vm.items.first?.id, "p\(total - 1)", "newest first")
        let dates = rig.vm.items.compactMap(\.createdAt)
        XCTAssertEqual(dates.count, total)
        XCTAssertTrue(zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }, "sorted by date, descending")

        // 200 batches of 100 retirements, as the run reports them.
        for batch in 0..<200 {
            let added = Set((0..<100).map { "p\(batch * 100 + $0)" })
            rig.vm.applyRecorded(added)
            await Task.yield()
        }
        let longest = watchdog.stop()

        XCTAssertTrue(rig.vm.items.isEmpty)
        XCTAssertLessThan(longest, .milliseconds(250), "the main thread is never blocked for long")
    }

    // MARK: - AC-65.9

    func test_AC_65_9_rowLabelInEveryShippedLanguage() throws {
        let date = try XCTUnwrap(LongDateFormatter.parse(isoTimestamp: "2024-07-13T12:00:00.000Z"))
        let item = BackupRemainderItem(
            id: "x", fileName: "clip.MOV", createdAt: date, kind: .video,
            albumNames: ["Zoo"], isEditOnly: true
        )
        let expected: [(code: String, video: String, edited: String)] = [
            ("fr", "Vidéo", "Version retouchée"),
            ("de", "Video", "Bearbeitete Version"),
            ("es", "Vídeo", "Versión editada"),
            ("it", "Video", "Versione modificata"),
        ]
        for entry in expected {
            let pinned = try language(entry.code)
            let day = BackupRemainderViewModel.dateText(date, locale: pinned.locale)
            XCTAssertEqual(
                BackupRemainderViewModel.accessibilityLabel(for: item, bundle: pinned.bundle, locale: pinned.locale),
                "clip.MOV, \(day), Zoo, \(entry.video), \(entry.edited)",
                entry.code
            )
        }
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(
            BackupRemainderViewModel.accessibilityLabel(for: item, bundle: .main, locale: english),
            "clip.MOV, \(BackupRemainderViewModel.dateText(date, locale: english)), Zoo, Video, Edited version"
        )
        let plain = BackupRemainderItem(
            id: "y", fileName: "a.jpg", createdAt: nil, kind: .image, albumNames: [], isEditOnly: false
        )
        XCTAssertEqual(
            BackupRemainderViewModel.accessibilityLabel(for: plain, bundle: .main, locale: english),
            "a.jpg"
        )
    }

    // MARK: - AC-65.10

    func test_AC_65_10_emptyLedgerListsServerCopiesUntilAPassRecognizesThem() async {
        let rig = Rig(candidates: [
            candidate("c1", created: "2024-07-14T12:00:00.000Z"),
            candidate("c2", created: "2024-07-13T12:00:00.000Z"),
        ])
        rig.serverHolds(["c1", "c2"])

        await rig.vm.load()
        XCTAssertEqual(ids(rig.vm), ["c1", "c2"], "an empty ledger knows nothing of the server")
        XCTAssertEqual(rig.vm.count, 2)

        await rig.upload.runBackup(manual: true)
        let recognized = await waitUntil { rig.vm.count == 0 }
        XCTAssertTrue(recognized)
        XCTAssertTrue(rig.client.uploads.isEmpty, "recognized, never sent")

        let revision = rig.upload.ledgerRevision
        rig.upload.resetBackupTracking()
        XCTAssertEqual(rig.upload.ledgerRevision, revision + 1)
        let back = await waitUntil { ids(rig.vm) == ["c1", "c2"] }
        XCTAssertTrue(back, "forgetting the ledger puts them back, without a manual reload")
    }

    // MARK: - AC-65.11

    func test_AC_65_11_listDependsOnTheLedgerOnlyAndNeverWritesIt() async {
        let rig = Rig(candidates: [candidate("c1")])
        rig.serverHolds(["c1"])
        let tracked = rig.engine.trackedAssetCount
        let requests = rig.client.requestCount

        await rig.vm.load()

        XCTAssertEqual(ids(rig.vm), ["c1"])
        XCTAssertEqual(rig.client.requestCount, requests)
        XCTAssertEqual(rig.engine.trackedAssetCount, tracked)

        await rig.upload.runBackup(manual: true)
        let gone = await waitUntil { rig.vm.items.isEmpty }
        XCTAssertTrue(gone)
    }

    // MARK: - AC-65.12

    func test_AC_65_12_serverDeletionListedOnlyAfterReconciliationForgetsIt() async {
        let saved = candidate("c1")
        let rig = Rig(candidates: [saved])
        rig.record(saved)
        rig.environment.isOnlineValue = false

        await rig.vm.load()
        XCTAssertTrue(rig.vm.items.isEmpty, "the ledger believes it is saved")
        XCTAssertEqual(rig.client.requestCount, 0, "offline: no request")

        rig.environment.isOnlineValue = true
        await rig.vm.load()
        XCTAssertTrue(rig.vm.items.isEmpty, "online: still no reconciliation on open")
        XCTAssertEqual(rig.client.requestCount, 0)

        // "Check server now": the server accepts = it no longer has the photo.
        await rig.upload.reconcileNow()

        let listed = await waitUntil { ids(rig.vm) == ["c1"] }
        XCTAssertTrue(listed, "forgotten by the reconciliation, listed without a manual load")
    }
}

/// Longest gap between two wake-ups of a 5 ms loop on the main actor: what a
/// blocked main thread looks like from the outside.
@MainActor
private final class MainThreadWatchdog {
    private var task: Task<Void, Never>?
    private(set) var longest: Duration = .zero

    func start() {
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = clock.now
                guard let self else { return }
                longest = max(longest, now - last)
                last = now
            }
        }
    }

    func stop() -> Duration {
        task?.cancel()
        return longest
    }
}
