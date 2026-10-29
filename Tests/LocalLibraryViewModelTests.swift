import CryptoKit
import Photos
import XCTest
@testable import ImmichSwiftUI

/// "On this device" (P2 local-library, gap G3): the ViewModel *is* the screen —
/// what it reads from the device, what it asks the server, and what it sends.
///
/// `PHAsset` cannot be built with a real `localIdentifier` (a bare instance has
/// no library backing), so the fixtures are subclasses that override exactly the
/// properties the screen reads. That keeps the production code free of a test
/// seam: no closure or protocol exists only so this file can run.
@MainActor
final class LocalLibraryViewModelTests: XCTestCase {

    private var photos: LocalLibraryPhotoLibrary!
    private var source: MockBackupAssetSource!
    private var client: MockImmichClient!
    private var ledger: BackupLedger!
    private var environment: MockBackupEnvironment!
    private var settings: BackupSettingsStore!
    private var activity: MockBackupLiveActivityService!
    private var notifications: MockNotificationService!
    private var readOnly: ReadOnlyModeStore!
    private var upload: UploadViewModel!
    private var checkDirectory: URL!
    private var vm: LocalLibraryViewModel!

    override func setUp() {
        super.setUp()
        build()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: checkDirectory)
        photos = nil
        source = nil
        client = nil
        ledger = nil
        environment = nil
        settings = nil
        activity = nil
        notifications = nil
        readOnly = nil
        upload = nil
        checkDirectory = nil
        vm = nil
        super.tearDown()
    }

    /// The screen over the backup's own graph, as `DependencyContainer` wires it:
    /// one client, one source, one engine and ledger shared by the screen and the
    /// `UploadViewModel` it sends through. Callable again to start a test scene
    /// over (nothing leaks from the previous one).
    private func build(albumSync: (any AlbumSyncServicing)? = nil) {
        photos = LocalLibraryPhotoLibrary()
        source = MockBackupAssetSource()
        source.dataProvider = { Data("bytes-\($0)".utf8) }
        client = MockImmichClient()
        ledger = BackupLedger.inMemory()
        environment = MockBackupEnvironment()
        settings = BackupSettingsStore(suiteName: "local-library-\(UUID().uuidString)")
        activity = MockBackupLiveActivityService()
        notifications = MockNotificationService()
        readOnly = .ephemeral()
        checkDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-check-test-\(UUID().uuidString)", isDirectory: true)
        let userID: (@MainActor () -> String?)? = albumSync == nil ? nil : { "me" }
        let engine = BackupEngine(
            client: client, source: source, environment: environment,
            ledger: ledger, albumSync: albumSync, userID: userID
        )
        upload = UploadViewModel(
            client: client, photos: MockPhotoLibraryService(), engine: engine,
            settings: settings, scheduler: MockBackupScheduler(),
            activityService: activity, notifications: notifications,
            readOnly: readOnly
        )
        vm = LocalLibraryViewModel(
            photoLibrary: photos, albumSource: source, client: client,
            backup: upload, checkDirectory: checkDirectory
        )
    }

    // MARK: - Fixtures

    private func asset(_ id: String, video: Bool = false) -> PHAsset {
        LocalLibraryFakeAsset(id: id, mediaType: video ? .video : .image)
    }

    private func album(_ id: String, _ name: String, count: Int, smart: Bool = false) -> BackupAlbum {
        BackupAlbum(id: id, name: name, count: count, isSmart: smart)
    }

    private func candidate(_ id: String, video: Bool = false, live: Bool = false) -> BackupCandidate {
        BackupCandidate(
            id: id,
            kind: video ? .video : .image,
            fileName: video ? "\(id).mov" : "\(id).jpg",
            fileCreatedAt: "2024-01-01T00:00:00.000Z",
            fileModifiedAt: "2024-01-01T00:00:00.000Z",
            duration: video ? 12 : nil,
            isFavorite: false,
            isLivePhoto: live
        )
    }

    /// The device holds `items`, the grid shows them, and (by default) the user
    /// has selected them all.
    private func arrange(_ items: [BackupCandidate], selecting: Bool = true) async {
        source.candidates = items
        photos.library = items.map { asset($0.id, video: $0.kind == .video) }
        await vm.loadAssets(albumID: nil)
        if selecting { for item in items { vm.toggle(item.id) } }
    }

    /// What `bulk-upload-check` answers, for the Check and for the engine alike.
    private func answer(accept: [String] = [], reject: [String] = [], serverIDs: [String: String] = [:]) {
        let accepted = accept.map { AssetBulkUploadCheckResponse.Result(id: $0, action: "accept") }
        let rejected = reject.map {
            AssetBulkUploadCheckResponse.Result(id: $0, action: "reject", reason: "duplicate", assetId: serverIDs[$0])
        }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: accepted + rejected)
    }

    /// SHA1 of what `source.dataProvider` yields for `id`, base64 — the checksum
    /// the backup sends for the original.
    private func sha1(_ id: String) -> String { Self.sha1(Data("bytes-\(id)".utf8)) }

    private static func sha1(_ data: Data) -> String {
        Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
    }

    private func progress() -> [Int] { vm.uploadProgress.map { [$0.done, $0.total] } ?? [] }

    /// Parks until `condition` holds, or five seconds pass.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    private func ledgerState() -> [String] {
        ledger.entriesForReconciliation().map { "\($0.id):\($0.checksum)" }.sorted()
            + ["tracked=\(ledger.trackedCount())"]
    }

    /// Files the mock's engine directory still holds for assets whose id contains `marker`.
    private func exportsLeft(containing marker: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: MockBackupAssetSource.testBackupDirectory.path)) ?? []
        return names.filter { $0.contains(marker) }
    }

    private func assertStayedLocalOnly(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ledger.trackedCount(), 0, "no ledger entry for \(id)", file: file, line: line)
        XCTAssertEqual(vm.localOnlyIDs, [id], file: file, line: line)
        XCTAssertFalse(vm.savedIDs.contains(id), file: file, line: line)
        XCTAssertNotNil(vm.errorMessage, file: file, line: line)
        XCTAssertEqual(vm.errorMessage, upload.engine.failures.first { $0.assetID == id }?.reason, file: file, line: line)
    }

    // MARK: - Enumeration

    func test_loadAlbums_exposesUserAndSmartAlbums() async {
        source.albums = [
            album("album/trip", "Trip", count: 3),
            album(BackupAlbum.SmartID.screenshots, "Screenshots", count: 2, smart: true),
        ]

        vm.loadAlbums()

        XCTAssertEqual(vm.albums.map(\.id), ["album/trip", BackupAlbum.SmartID.screenshots])
        XCTAssertEqual(vm.albums.map(\.name), ["Trip", "Screenshots"])
        XCTAssertEqual(vm.albums.last?.isSmart, true)
    }

    func test_loadAssets_withoutAlbumID_returnsWholeLibrary() async {
        photos.library = [asset("L1"), asset("L2", video: true), asset("L3")]

        await vm.loadAssets(albumID: nil)

        XCTAssertEqual(vm.assets.map(\.localIdentifier), ["L1", "L2", "L3"])
        // Photos/videos/summary come from the media type alone; the device column
        // never carries bytes (counting them means reading every resource).
        XCTAssertEqual(vm.localSummary, LocalLibraryViewModel.MediaSummary(photos: 2, videos: 1, bytes: 0))
        XCTAssertEqual(vm.localSummary.total, 3)
        XCTAssertNil(vm.selectedAlbumID)
        XCTAssertNil(vm.selectedAlbumName)
        XCTAssertTrue(vm.didLoad)
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_loadAssets_withAlbumID_scopesToThatAlbum() async {
        photos.library = [asset("L1"), asset("L2"), asset("L3")]
        photos.scoped = ["album/trip": [asset("L3")]]
        source.albums = [album("album/trip", "Trip", count: 1)]
        vm.loadAlbums()

        await vm.loadAssets(albumID: "album/trip")

        XCTAssertEqual(vm.assets.map(\.localIdentifier), ["L3"])
        XCTAssertEqual(vm.selectedAlbumID, "album/trip")
        XCTAssertEqual(vm.selectedAlbumName, "Trip")
        XCTAssertEqual(vm.localSummary.photos, 1)
    }

    func test_switchingAlbum_dropsSelectionAndVerdict() async {
        photos.library = [asset("L1"), asset("L2")]
        photos.scoped = ["album/trip": [asset("L2")]]
        await vm.loadAssets(albumID: nil)
        vm.toggle("L1")
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "L1", action: "accept")])
        await vm.checkSelection()
        XCTAssertTrue(vm.hasVerdict)

        await vm.loadAssets(albumID: "album/trip")

        // A verdict describes the assets it was asked about: it does not follow
        // the user into another album.
        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertTrue(vm.savedIDs.isEmpty)
        XCTAssertFalse(vm.hasVerdict)
    }

    // MARK: - The server verdict

    func test_checkSelection_splitsAcceptedAndRejected() async {
        await arrange([candidate("A"), candidate("B")])
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "B", action: "reject"),
            .init(id: "A", action: "accept"),
        ])

        await vm.checkSelection()

        // `reject` = the server has it, `accept` = it does not.
        XCTAssertEqual(vm.savedIDs, ["B"])
        XCTAssertEqual(vm.localOnlyIDs, ["A"])
        XCTAssertEqual(vm.savedCount, 1)
        XCTAssertEqual(vm.localOnlyCount, 1)
        XCTAssertTrue(vm.hasVerdict)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.phase, .idle)
        // One request, carrying the checksums of the original bytes of exactly the selection.
        XCTAssertEqual(client.bulkUploadCheckChunks.count, 1)
        XCTAssertEqual(client.bulkUploadCheckChunks[0].map(\.id), ["A", "B"])
        XCTAssertEqual(client.bulkUploadCheckChunks[0].map(\.checksum), [sha1("A"), sha1("B")])
    }

    /// A photo edited in Photos and backed up earlier: the server holds the
    /// *original*, whose checksum is what the export yields. The old path hashed
    /// the edited rendering and called it "not on server".
    func test_AC1_check_classesRetouchedPhotoOnServerByOriginalChecksum() async {
        await arrange([candidate("A")])
        source.dataProvider = { _ in Data("original-bytes".utf8) }
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [.init(id: "A", action: "reject")])

        await vm.checkSelection()

        XCTAssertEqual(client.bulkUploadCheckChunks.first?.map(\.checksum), [Self.sha1(Data("original-bytes".utf8))])
        XCTAssertEqual(vm.savedIDs, ["A"])
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
    }

    func test_AC2_check_sendsStreamingSHA1OfExportedOriginal() async {
        await arrange([candidate("A"), candidate("B")])
        answer(accept: ["A", "B"])
        var hashedFromFile: [String] = []
        source.onExported = { url in
            hashedFromFile.append((try? BackupEngine.streamingSHA1Base64(url)) ?? "unreadable")
        }

        await vm.checkSelection()

        XCTAssertEqual(source.exportedIDs, ["A", "B"])
        XCTAssertEqual(hashedFromFile.count, 2)
        XCTAssertEqual(client.bulkUploadCheckChunks.first?.map(\.checksum), hashedFromFile)
    }

    func test_AC3_check_unreadableOriginal_hasNoVerdictAndShowsMessage() async {
        await arrange([candidate("A"), candidate("B"), candidate("C")])
        // "Z" is on the grid but Photos no longer holds it.
        photos.library.append(asset("Z"))
        await vm.loadAssets(albumID: nil)
        for id in ["A", "B", "C", "Z"] { vm.toggle(id) }
        source.deferIDs = ["B"]
        source.failIDs = ["C"]
        answer(accept: ["A"])

        await vm.checkSelection()

        XCTAssertEqual(vm.localOnlyIDs, ["A"])
        XCTAssertTrue(vm.savedIDs.isEmpty)
        XCTAssertEqual(client.bulkUploadCheckChunks.first?.map(\.id), ["A"], "only the readable asset is asked about")
        XCTAssertEqual(vm.errorMessage, String(localized: "Waiting for iCloud"), "B comes first on the grid")
        XCTAssertTrue(vm.hasVerdict)
        XCTAssertEqual(vm.phase, .idle)
    }

    /// A request that fails is not an unreadable asset: it ends the Check with
    /// its own message and no verdict.
    func test_check_bulkCheckError_endsWithoutVerdict() async {
        await arrange([candidate("A")])
        client.globalError = APIError.decoding("server down")

        await vm.checkSelection()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.hasVerdict)
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertTrue(vm.savedIDs.isEmpty)
        XCTAssertEqual(vm.phase, .idle)
    }

    /// B-2: a video gets a verdict and goes up as a video with its duration.
    func test_AC4_video_checkThenUpload_arrivesAsVideoWithDuration() async {
        await arrange([candidate("V", video: true)])
        answer(accept: ["V"])

        await vm.checkSelection()
        XCTAssertEqual(vm.localOnlyIDs, ["V"])
        await vm.uploadSelection()

        XCTAssertEqual(client.lastUploadFilename, "V.mov")
        XCTAssertEqual(client.lastUploadDuration, 12)
        XCTAssertTrue(vm.savedIDs.contains("V"))
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
    }

    /// 512 MiB original: a `Data(contentsOf:)` + `SHA1.hash(data:)` would climb by
    /// about that much during the hash. The sampler lives on its own thread, away
    /// from the cooperative pool the detached hash occupies.
    func test_AC5_check_largeVideo_keepsMemoryFootprintFlat() async {
        await arrange([candidate("V", video: true)])
        source.sizedIDs = ["V": 512 << 20]
        answer(accept: ["V"])
        var hasher = Insecure.SHA1()
        let zeros = Data(count: 1 << 20)
        for _ in 0..<512 { hasher.update(data: zeros) }
        let expected = Data(hasher.finalize()).base64EncodedString()

        let base = FootprintSampler.physFootprint()
        let sampler = FootprintSampler()
        var samplesAtExport = 0
        source.onExported = { _ in samplesAtExport = sampler.snapshot.count }
        sampler.start()
        await vm.checkSelection()
        sampler.stop()
        let observed = sampler.snapshot

        XCTAssertEqual(client.bulkUploadCheckChunks.first?.map(\.checksum), [expected])
        XCTAssertLessThan(observed.peak, base + (64 << 20), "the file must be read in blocks, not loaded")
        XCTAssertGreaterThanOrEqual(observed.count - samplesAtExport, 2, "the hash window was not observed")
    }

    // MARK: - Sending

    func test_uploadSelection_sendsOnlyAcceptedIDs() async {
        await arrange([candidate("A"), candidate("B")])
        client.bulkUploadCheckResponse = AssetBulkUploadCheckResponse(results: [
            .init(id: "A", action: "accept"),
            .init(id: "B", action: "reject"),
        ])
        await vm.checkSelection()

        await vm.uploadSelection()

        // The asset the server already had never leaves the device.
        XCTAssertEqual(client.uploads.map { $0.deviceAssetId }, ["A"])
        XCTAssertEqual(client.uploads.map { $0.visibility }, [.timeline])
        XCTAssertEqual(client.lastUploadData, Data("bytes-A".utf8))
        XCTAssertEqual(client.lastUploadFilename, "A.jpg")
        XCTAssertEqual(client.lastUploadChecksum, sha1("A"))
        // Sent assets swap columns; the progress bar goes away with the phase.
        XCTAssertEqual(vm.savedIDs, ["A", "B"])
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_AC6_upload_livePhoto_sendsLinkedPairedVideo() async {
        await arrange([candidate("LP", live: true)])
        source.livePhotoIDs = ["LP"]
        client.uploadResponsesByFilename = ["LP.MOV": AssetMediaResponseDto(id: "video-1", status: "created")]
        answer(accept: ["LP"])
        await vm.checkSelection()

        await vm.uploadSelection()

        XCTAssertEqual(client.uploads.map(\.filename), ["LP.MOV", "LP.jpg"])
        XCTAssertEqual(client.uploads.map(\.visibility), [.hidden, .timeline])
        XCTAssertEqual(client.uploads[1].livePhotoVideoId, "video-1")
        XCTAssertTrue(vm.savedIDs.contains("LP"))
    }

    /// The backup sent it between the Check and the Upload: the engine's own
    /// dedup answers `reject`, nothing is uploaded twice, and the asset is
    /// recorded.
    func test_AC7_upload_assetBackedUpMeanwhile_isRejectedNotDuplicated() async {
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        answer(reject: ["A"], serverIDs: ["A": "srv-A"])

        await vm.uploadSelection()

        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(vm.savedIDs, ["A"])
        XCTAssertTrue(vm.localOnlyIDs.isEmpty)
        XCTAssertTrue(ledger.isBackedUp(id: "A", signature: candidate("A").fileModifiedAt))
    }

    func test_AC8_upload_thenFullBackup_skipsTheAsset() async {
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        await vm.uploadSelection()
        let exportsBefore = source.exportedIDs.filter { $0 == "A" }.count
        // Keep the weekly reconciliation out of it: the mock answers `accept`
        // to everything, which would make it forget the entry.
        ledger.recordReconciliation(at: Date())

        await upload.engine.run(settings: settings.snapshot(), manual: true)

        XCTAssertEqual(exportsBefore, 2, "one export for the Check, one for the Upload")
        XCTAssertEqual(source.exportedIDs.filter { $0 == "A" }.count, exportsBefore)
        XCTAssertEqual(upload.engine.total, 0)
    }

    func test_AC9_upload_writesTheEngineLedgerAndNotifies() async {
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        var changes = 0
        upload.engine.onLedgerChange = { changes += 1 }

        await vm.uploadSelection()

        XCTAssertTrue(ledger.isBackedUp(id: "A", signature: candidate("A").fileModifiedAt))
        XCTAssertEqual(upload.engine.trackedAssetCount, 1)
        XCTAssertGreaterThanOrEqual(changes, 1)
    }

    func test_AC10_upload_failedOrUnlinked_leavesNoLedgerEntry() async {
        // 1. accepted, the still fails to upload
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        client.uploadErrorsByFilename = ["A.jpg": APIError.decoding("still down")]
        await vm.uploadSelection()
        assertStayedLocalOnly("A")

        // 2. accepted Live Photo, the paired video fails to upload
        build()
        await arrange([candidate("LP", live: true)])
        source.livePhotoIDs = ["LP"]
        answer(accept: ["LP"])
        await vm.checkSelection()
        client.uploadErrorsByFilename = ["LP.MOV": APIError.decoding("video down")]
        await vm.uploadSelection()
        assertStayedLocalOnly("LP")

        // 3. already on the server (the scenario of AC-7), the video fails to upload
        build()
        await arrange([candidate("LP", live: true)])
        source.livePhotoIDs = ["LP"]
        answer(accept: ["LP"])
        await vm.checkSelection()
        answer(reject: ["LP"], serverIDs: ["LP": "srv-LP"])
        client.uploadErrorsByFilename = ["LP.MOV": APIError.decoding("video down")]
        await vm.uploadSelection()
        assertStayedLocalOnly("LP")
    }

    func test_AC11_upload_reportsProgressThenFreesButton() async {
        await arrange([candidate("A"), candidate("B"), candidate("C")])
        answer(accept: ["A", "B", "C"])
        await vm.checkSelection()
        var atEachUpload: [[Int]] = []
        client.uploadGate = { atEachUpload.append(self.progress()) }
        var atLedgerWrite: [[Int]] = []
        upload.engine.onLedgerChange = { atLedgerWrite.append(self.progress()) }

        await vm.uploadSelection()

        XCTAssertEqual(atEachUpload, [[0, 3], [1, 3], [2, 3]])
        XCTAssertEqual(atLedgerWrite.last, [3, 3])
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_AC12_upload_oneOfThreeFails_movesOnlyTheTwoSent() async {
        await arrange([candidate("A"), candidate("B"), candidate("C")])
        answer(accept: ["A", "B", "C"])
        await vm.checkSelection()
        client.uploadErrorsByFilename = ["B.jpg": APIError.decoding("B refused")]

        await vm.uploadSelection()

        XCTAssertEqual(vm.savedIDs, ["A", "C"])
        XCTAssertEqual(vm.localOnlyIDs, ["B"])
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.errorMessage, upload.engine.failures.first { $0.assetID == "B" }?.reason)
    }

    func test_AC13_upload_readOnly_isRefusedWithMessage() async {
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        let exportsAfterCheck = source.exportedIDs
        readOnly.setEnabled(true)

        await vm.uploadSelection()

        XCTAssertEqual(vm.errorMessage, UserFacingError.readOnlyModeMessage)
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(source.exportedIDs, exportsAfterCheck)
        XCTAssertEqual(vm.localOnlyIDs, ["A"])
        XCTAssertEqual(vm.phase, .idle)
    }

    func test_AC14_upload_engineBusy_isRefusedWithoutTouchingTheActiveRun() async {
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        // The device holds another asset, sent by a run that is still in flight.
        source.candidates = [candidate("A"), candidate("X")]
        answer(accept: ["A", "X"])
        var holding = true
        var parked: CheckedContinuation<Void, Never>?
        client.uploadGate = {
            if holding { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in parked = c } }
        }
        let active = Task { await self.upload.runBackup(manual: true, only: ["X"]) }
        await waitUntil { parked != nil }
        XCTAssertNotNil(parked, "the first run never reached its upload")

        await vm.uploadSelection()

        XCTAssertEqual(vm.errorMessage, UploadViewModel.engineBusyMessage)
        XCTAssertFalse(client.uploads.contains { $0.deviceAssetId == "A" })
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.uploadProgress)
        XCTAssertNotNil(upload.engine.onProgressUpdate, "the running run keeps its progress callback")
        XCTAssertEqual(activity.startCalls.count, 1)
        XCTAssertEqual(vm.localOnlyIDs, ["A"])

        holding = false
        parked?.resume()
        _ = await active.value

        // A Stop that left the engine's flag up refuses the same way.
        build()
        await arrange([candidate("A")])
        answer(accept: ["A"])
        await vm.checkSelection()
        upload.engine.cancel()

        await vm.uploadSelection()

        XCTAssertEqual(vm.errorMessage, UploadViewModel.engineBusyMessage)
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(vm.localOnlyIDs, ["A"])
    }

    /// B-7: neither the excluded albums nor the Wi-Fi policy of the backup apply
    /// to an asset the user picked by hand.
    func test_AC15_upload_ignoresExcludedAlbumsAndWiFiPolicy() async {
        await arrange([candidate("V", video: true)])
        settings.excludedAlbumIDs = ["alb"]
        source.excludedAssetIDs = ["V"]
        settings.onlyOnWiFi = true
        settings.allowCellularForVideos = false
        environment.hasWiFiValue = false
        answer(accept: ["V"])
        await vm.checkSelection()

        await vm.uploadSelection()

        XCTAssertEqual(client.uploads.map(\.deviceAssetId), ["V"])
        XCTAssertTrue(vm.savedIDs.contains("V"))
    }

    func test_AC16_check_leavesLedgerUntouched() async {
        ledger.markBackedUp(id: "pre", signature: "sig", checksum: "sum", serverAssetId: nil)
        let before = ledgerState()
        await arrange([candidate("A"), candidate("B")])
        answer(accept: ["A"], reject: ["B"], serverIDs: ["B": "srv-B"])

        await vm.checkSelection()

        XCTAssertEqual(vm.localOnlyIDs, ["A"])
        XCTAssertEqual(vm.savedIDs, ["B"])
        XCTAssertEqual(ledgerState(), before)
        XCTAssertEqual(upload.engine.phase, .idle)
    }

    func test_AC17_checkAndUpload_leaveNoExportBehind() async {
        let fm = FileManager.default
        func entries(_ url: URL) -> [String] { (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] }
        func plantOrphan() throws {
            try fm.createDirectory(at: checkDirectory, withIntermediateDirectories: true)
            try Data("orphan".utf8).write(to: checkDirectory.appendingPathComponent("orphan.mov"))
        }
        await arrange([candidate("AC17-A"), candidate("AC17-C")])
        source.failIDs = ["AC17-C"]
        vm.toggle("AC17-C")  // selection: A alone

        answer(accept: ["AC17-A"])
        await vm.checkSelection()
        XCTAssertEqual(entries(checkDirectory), [], "after a successful Check")

        client.globalError = APIError.decoding("server down")
        await vm.checkSelection()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(entries(checkDirectory), [], "after a Check whose request failed")
        client.globalError = nil

        vm.toggle("AC17-C")  // A + C, whose export fails
        await vm.checkSelection()
        XCTAssertEqual(entries(checkDirectory), [], "after a Check with an unreadable asset")

        // A Check killed mid-export left a file behind: the next one reclaims it,
        // with or without an export of its own.
        try? plantOrphan()
        await vm.checkSelection()
        XCTAssertEqual(entries(checkDirectory), [], "orphan, A + C")
        vm.clearSelection()
        vm.toggle("AC17-C")
        try? plantOrphan()
        await vm.checkSelection()
        XCTAssertEqual(entries(checkDirectory), [], "orphan, C alone")

        // Upload: the engine owns its exports and removes them whatever the outcome.
        vm.clearSelection()
        vm.toggle("AC17-A")
        await vm.checkSelection()
        await vm.uploadSelection()
        XCTAssertEqual(vm.savedIDs, ["AC17-A"])
        XCTAssertEqual(exportsLeft(containing: "AC17"), [], "after a successful Upload")

        await vm.checkSelection()
        client.uploadErrorsByFilename = ["AC17-A.jpg": APIError.decoding("down")]
        await vm.uploadSelection()
        XCTAssertEqual(vm.localOnlyIDs, ["AC17-A"])
        XCTAssertEqual(exportsLeft(containing: "AC17"), [], "after an Upload whose request failed")
    }

    func test_AC19_upload_deferredAndCancelled_stayNotOnServer() async {
        await arrange([candidate("A"), candidate("B"), candidate("C")])
        answer(accept: ["A", "B", "C"])
        await vm.checkSelection()
        // B's original left the device since the Check; C's request is cancelled
        // in flight, as `stopAndWait()` does.
        source.deferIDs = ["B"]
        client.uploadErrorsByFilename = ["C.jpg": CancellationError()]

        await vm.uploadSelection()

        XCTAssertTrue(vm.savedIDs.contains("A"))
        XCTAssertEqual(vm.localOnlyIDs, ["B", "C"])
        XCTAssertEqual(ledger.trackedCount(), 1, "only A is recorded")
        XCTAssertEqual(vm.errorMessage, String(localized: "Waiting for iCloud"), "B comes before C")

        build()
        await arrange([candidate("C")])
        answer(accept: ["C"])
        await vm.checkSelection()
        client.uploadErrorsByFilename = ["C.jpg": CancellationError()]

        await vm.uploadSelection()

        XCTAssertEqual(vm.localOnlyIDs, ["C"])
        XCTAssertEqual(vm.errorMessage, String(localized: "Upload stopped before this item was sent."))
        XCTAssertEqual(ledger.trackedCount(), 0)
    }

    /// The real Stop of the Backup tab: `engine.cancel()` while the second
    /// upload is in flight. The request in flight completes (the flag is read at
    /// the next item), the third never starts.
    func test_AC19_upload_stoppedFromBackupTab_keepsUnsentNotOnServer() async {
        await arrange([candidate("AC19-P"), candidate("AC19-Q"), candidate("AC19-R")])
        answer(accept: ["AC19-P", "AC19-Q", "AC19-R"])
        await vm.checkSelection()
        var calls = 0
        var parked: CheckedContinuation<Void, Never>?
        client.uploadGate = {
            calls += 1
            if calls == 2 { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in parked = c } }
        }
        let sending = Task { await self.vm.uploadSelection() }
        await waitUntil { parked != nil }
        XCTAssertNotNil(parked, "the second upload never started")

        upload.cancelBackup()
        parked?.resume()
        await sending.value

        XCTAssertEqual(upload.engine.phase, .cancelled)
        XCTAssertEqual(vm.savedIDs, ["AC19-P", "AC19-Q"])
        XCTAssertEqual(vm.localOnlyIDs, ["AC19-R"])
        XCTAssertTrue(ledger.isBackedUp(id: "AC19-P", signature: candidate("AC19-P").fileModifiedAt))
        XCTAssertTrue(ledger.isBackedUp(id: "AC19-Q", signature: candidate("AC19-Q").fileModifiedAt))
        XCTAssertFalse(ledger.isBackedUp(id: "AC19-R", signature: candidate("AC19-R").fileModifiedAt))
        XCTAssertFalse(client.uploads.contains { $0.filename == "AC19-R.jpg" })
        XCTAssertEqual(vm.errorMessage, String(localized: "Upload stopped before this item was sent."))
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertEqual(exportsLeft(containing: "AC19"), [], "the stopped run removes what it staged")
    }

    /// An Upload is a backup run as the Backup tab sees it: history, notification,
    /// Live Activity, the failures of this run only, and the album mirror.
    func test_AC21_upload_isVisibleAsABackupRun() async {
        build(albumSync: AlbumSyncService(mapping: AlbumSyncStore(suiteName: "local-library-albums-\(UUID().uuidString)"), batchSize: 100))
        settings.syncedAlbumIDs = ["dev-vac"]
        source.albums = [BackupAlbum(id: "dev-vac", name: "Vacances", count: 2)]
        source.albumMembershipByDeviceAlbum = ["A": ["dev-vac"]]
        // An earlier backup left a failure behind.
        source.candidates = [candidate("old")]
        source.failIDs = ["old"]
        ledger.recordReconciliation(at: Date())
        await upload.runBackup(manual: true)
        XCTAssertEqual(upload.engine.failures.map(\.assetID), ["old"])

        await arrange([candidate("old"), candidate("A"), candidate("B")], selecting: false)
        vm.toggle("A")
        vm.toggle("B")
        answer(accept: ["A", "B"])
        await vm.checkSelection()
        client.uploadErrorsByFilename = ["B.jpg": APIError.decoding("B refused")]

        await vm.uploadSelection()

        XCTAssertEqual(upload.uploadHistory.count, 2)
        XCTAssertEqual(notifications.notifiedBackups.count, 2)
        XCTAssertEqual(activity.startCalls.count, 2)
        XCTAssertEqual(upload.engine.failures.map(\.assetID), ["B"])
        XCTAssertTrue(client.addAssetsToAlbumCalls.flatMap { $0.ids }.contains("new-asset"))
    }

    /// Nothing "not on server": no run — an empty `only` would back up the whole
    /// library.
    func test_AC22_upload_withNothingLocalOnly_startsNoRun() async {
        await arrange([candidate("A")])
        answer(reject: ["A"])
        await vm.checkSelection()
        let requested = source.requestedIDs
        let exported = source.exportedIDs

        await vm.uploadSelection()

        XCTAssertEqual(source.requestedIDs, requested)
        XCTAssertEqual(source.exportedIDs, exported)
        XCTAssertNil(source.lastAlbumIDs, "no library scan")
        XCTAssertTrue(upload.uploadHistory.isEmpty)
        XCTAssertTrue(activity.startCalls.isEmpty)
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(vm.savedIDs, ["A"])
        XCTAssertNil(vm.uploadProgress)
        XCTAssertEqual(vm.phase, .idle)
    }

    /// A backup starting during a Check wipes its own export directory; the
    /// Check's lives elsewhere, so its verdicts do not change.
    func test_AC23_check_survivesABackupPurgeMidway() async {
        await arrange([candidate("A"), candidate("B")])
        answer(accept: ["A", "B"])
        let engineSource = source!
        source.onExported = { _ in
            try? FileManager.default.removeItem(at: MockBackupAssetSource.testBackupDirectory)
            engineSource.purgeStaleExports()
        }

        await vm.checkSelection()

        XCTAssertEqual(engineSource.purgeCount, 2)
        XCTAssertEqual(client.bulkUploadCheckChunks.first?.map(\.checksum), [sha1("A"), sha1("B")])
        XCTAssertEqual(vm.localOnlyIDs, ["A", "B"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.hasVerdict)
    }

    // MARK: - Failure and selection state

    func test_loadRemoteSummary_failure_leavesRemoteNil() async {
        client.globalError = APIError.decoding("server unreachable")

        await vm.loadRemoteSummary()

        // An unreachable server is not an empty server: the column shows nothing
        // rather than a zero it cannot vouch for.
        XCTAssertNil(vm.remoteSummary)
        XCTAssertNotNil(vm.errorMessage)

        client.globalError = nil
        client.serverStatisticsResponse = ServerStatsResponseDto(
            photos: 12, videos: 3, usage: 2048, usagePhotos: 0, usageVideos: 0, usageByUser: []
        )

        await vm.loadRemoteSummary()

        XCTAssertEqual(vm.remoteSummary, LocalLibraryViewModel.MediaSummary(photos: 12, videos: 3, bytes: 2048))
        XCTAssertEqual(vm.remoteSummary?.total, 15)
        XCTAssertNil(vm.errorMessage)
    }

    func test_selectionState_togglesAndClears() async {
        photos.library = [asset("L1"), asset("L2")]
        await vm.loadAssets(albumID: nil)

        vm.toggle("L1")
        vm.toggle("L2")
        vm.toggle("L2")

        XCTAssertEqual(vm.selectedIDs, ["L1"])
        XCTAssertEqual(vm.selectionCount, 1)
        XCTAssertTrue(vm.hasSelection)

        vm.toggle("L1")
        XCTAssertFalse(vm.hasSelection)
        XCTAssertEqual(vm.selectionCount, 0)

        vm.toggle("L1")
        vm.clearSelection()
        XCTAssertTrue(vm.selectedIDs.isEmpty)
    }

    func test_requestAccess_denied_keepsLibraryUnreadable() async {
        photos.status = .denied

        await vm.requestAccess()

        XCTAssertEqual(vm.authorization, .denied)
        XCTAssertFalse(vm.canReadLibrary)
        // Nothing is enumerated for a library we are not allowed to read — an
        // empty grid here would read as "no photos".
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertFalse(vm.didLoad)
    }

    /// The thumbnail point this screen added must *terminate* for an asset that
    /// has no on-device image: `ContinuationGate` exists precisely because a
    /// dropped resume used to leave the caller parked forever, and a parked tile
    /// freezes the grid behind a skeleton. Run against the real
    /// `PhotoLibraryServiceImpl` — a mock would prove nothing about the gate.
    func test_loadThumbnail_withoutLocalImage_completesInsteadOfHanging() async {
        let service = PhotoLibraryServiceImpl()
        let orphan = asset("no-such-asset-in-any-library")

        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await service.loadThumbnail(for: orphan, targetSize: CGSize(width: 64, height: 64), scale: 2)
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(returned, "loadThumbnail never resumed — the tile would hang forever")
    }
}

/// Minimal `PhotoLibraryService` for this screen: tables instead of Photos.
private final class LocalLibraryPhotoLibrary: PhotoLibraryService, @unchecked Sendable {
    var status: PHAuthorizationStatus = .authorized
    var library: [PHAsset] = []
    var scoped: [String: [PHAsset]] = [:]

    func authorizationStatus() -> PHAuthorizationStatus { status }

    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) { handler(status) }

    func fetchAssets() -> [PHAsset] { library }

    func fetchAssets(inAlbumID albumID: String) -> [PHAsset] { scoped[albumID] ?? [] }

    func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String) {
        ("2024-07-01T10:00:00.000Z", "2024-07-01T10:00:00.000Z")
    }

    func saveImage(data: Data) async throws -> String { "saved-image" }

    func saveVideo(at fileURL: URL) async throws -> String { "saved-video" }
}

/// A `PHAsset` that answers the four properties the screen reads. `PHAsset`
/// cannot be given a `localIdentifier` (KVC rejects it), so the only way to get
/// two distinguishable assets is to subclass it.
private final class LocalLibraryFakeAsset: PHAsset, @unchecked Sendable {
    private let identifier: String
    private let kind: PHAssetMediaType

    init(id: String, mediaType: PHAssetMediaType) {
        self.identifier = id
        self.kind = mediaType
        super.init()
    }

    override var localIdentifier: String { identifier }
    override var mediaType: PHAssetMediaType { kind }
    override var duration: TimeInterval { kind == .video ? 12 : 0 }
    override var isFavorite: Bool { false }
}

/// Reads the process's `phys_footprint` every 5 ms on a thread of its own and
/// keeps the peak. A thread, not a Task: the hash under test runs on the
/// cooperative pool, and a sampler queued behind it would never see it run.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var count = 0
    private var running = false

    var snapshot: (peak: UInt64, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (peak, count)
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let keepGoing = running
                lock.unlock()
                guard keepGoing else { return }
                let value = Self.physFootprint()
                lock.lock()
                peak = max(peak, value)
                count += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
