import XCTest
import UIKit
import ImageIO
@testable import ImmichSwiftUI

/// The editor's server-side edits path: context loading, save mode, PUT/DELETE, drafts, and the copy fallback.
@MainActor
final class AssetEditsEditorTests: XCTestCase {

    private typealias Support = EditorTestSupport

    private let assetId = "asset-1"

    // MARK: Fixtures

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> ServerVersionResponseDto {
        ServerVersionResponseDto(major: major, minor: minor, patch: patch, prerelease: nil)
    }

    private func record(orientation: String? = "6", fileName: String = "IMG_0001.HEIC",
                        livePhotoVideoId: String? = nil, type: String = "IMAGE") -> AssetResponseDto {
        var asset = Support.makeAssetDTO(fileName: fileName)
        asset.exifInfo = ExifResponseDto(exifImageWidth: 4000, exifImageHeight: 3000, orientation: orientation)
        asset.livePhotoVideoId = livePhotoVideoId
        asset = AssetResponseDto(
            id: asset.id, type: type, thumbhash: asset.thumbhash, localDateTime: asset.localDateTime,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: asset.createdAt,
            ownerId: asset.ownerId, originalPath: asset.originalPath, originalFileName: asset.originalFileName,
            fileCreatedAt: asset.fileCreatedAt, fileModifiedAt: asset.fileModifiedAt, updatedAt: asset.updatedAt,
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false, visibility: "timeline",
            checksum: "abc", isEdited: false, livePhotoVideoId: livePhotoVideoId, exifInfo: asset.exifInfo)
        return asset
    }

    private func server(version v: ServerVersionResponseDto? = nil, asset: AssetResponseDto? = nil) -> MockImmichClient {
        let client = MockImmichClient()
        client.serverVersionResponse = v ?? version(3, 4, 0)
        client.getAssetResponse = [assetId: asset ?? record()]
        return client
    }

    private func makeStore() -> EditStateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetEditsEditor-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return EditStateStore(folderURL: url)
    }

    private func exportDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetEditsExport-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A VM whose context is loaded and whose (small) original is in place.
    private func openEditor(_ client: MockImmichClient, store: EditStateStore? = nil,
                            serverEditsEnabled: Bool = true) async -> PhotoEditorViewModel {
        let vm = PhotoEditorViewModel(assetId: assetId, client: client, store: store ?? makeStore(),
                                      urlSession: { .shared }, exportDirectory: exportDir(),
                                      serverEditsEnabled: serverEditsEnabled)
        await vm.loadState()
        vm.originalImage = Support.rawImage(width: 64, height: 48)
        return vm
    }

    private func puts(_ client: MockImmichClient) -> [[AssetEditItem]] {
        client.putAssetEditsCalls.map { $0.edits }
    }

    // MARK: AC-181

    func test_AC_181_oracleBodyForExifSix() async {
        let client = server()
        let vm = await openEditor(client)
        vm.setCropRect(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        vm.rotate90CW()
        vm.mirrorHorizontally()
        XCTAssertEqual(vm.saveMode, .server)
        XCTAssertTrue(vm.canSave)

        await vm.save()?.value

        XCTAssertEqual(puts(client), [[.crop(x: 750, y: 1000, width: 1500, height: 2000),
                                       .mirror(.vertical), .rotate(angle: 90)]])
        XCTAssertEqual(client.putAssetEditsCalls.first?.id, assetId)
        XCTAssertTrue(client.uploads.isEmpty, "no file is sent")
        XCTAssertTrue(client.deleteAssetEditsCalls.isEmpty)
        XCTAssertEqual(vm.dismissReason, .savedEdits)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.saveStep)
    }

    // MARK: AC-182

    func test_AC_182_opensOnServerEditsThenReplacesThenDeletes() async {
        let client = server()
        let list: [AssetEditItem] = [.crop(x: 750, y: 1000, width: 1500, height: 2000),
                                     .mirror(.horizontal), .rotate(angle: 90)]
        client.assetEditsResponse[assetId] = AssetEditsResponseDto(assetId: assetId, edits: list)
        let store = makeStore()

        let vm = await openEditor(client, store: store)
        let exif = record().exifInfo!
        XCTAssertEqual(vm.editState, AssetEditsMapping.state(from: list, exif: exif))
        XCTAssertEqual(vm.saveMode, .server)
        XCTAssertFalse(vm.canSave, "nothing changed since the server's state")

        vm.rotate90CW()
        XCTAssertTrue(vm.canSave)
        await vm.save()?.value
        XCTAssertEqual(puts(client), [[.crop(x: 750, y: 1000, width: 1500, height: 2000),
                                       .mirror(.horizontal), .rotate(angle: 180)]])

        let again = await openEditor(client, store: store)
        again.resetToOriginal()
        XCTAssertTrue(again.canSave)
        let putsBefore = client.putAssetEditsCalls.count
        await again.save()?.value
        XCTAssertEqual(client.deleteAssetEditsCalls, [assetId])
        XCTAssertEqual(client.putAssetEditsCalls.count, putsBefore, "no PUT for a removal")
        XCTAssertTrue(client.uploads.isEmpty)
        XCTAssertEqual(again.dismissReason, .removedEdits)
    }

    func test_AC_182_workingImageAsksEditedFalse() throws {
        let base = try XCTUnwrap(URL(string: "https://immich.example"))
        let edited = ImmichAssetURL.original(assetId: "a1", baseURL: base, edited: false)
        let items = URLComponents(url: edited, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "edited" })?.value, "false")
        XCTAssertEqual(edited.path, "/api/assets/a1/original")

        let shared = ImmichAssetURL.original(assetId: "a1", baseURL: base,
                                             sharedLink: .key("k"), edited: true)
        let names = URLComponents(url: shared, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        XCTAssertEqual(names, ["key", "edited"])

        XCTAssertEqual(ImmichAssetURL.original(assetId: "a1", baseURL: base).absoluteString,
                       "https://immich.example/api/assets/a1/original")
    }

    func test_AC_182_controlsWaitForTheContext() async {
        let client = server()
        let vm = PhotoEditorViewModel(assetId: assetId, client: client, store: makeStore(),
                                      urlSession: { .shared }, exportDirectory: exportDir(),
                                      serverEditsEnabled: true)
        XCTAssertFalse(vm.isContextLoaded)
        vm.originalImage = Support.rawImage(width: 64, height: 48)
        vm.setExposure(0.2)
        XCTAssertFalse(vm.canSave, "Save waits for the server's state")
        await vm.loadState()
        XCTAssertTrue(vm.isContextLoaded)
    }

    // MARK: AC-184

    func test_AC_184_screenMirrorAfterQuarterTurn() async {
        let lists: [(horizontal: Bool, expected: [AssetEditItem])] = [
            (true, [.mirror(.vertical), .rotate(angle: 90)]),
            (false, [.mirror(.horizontal), .rotate(angle: 90)])
        ]
        for row in lists {
            let client = server(asset: record(orientation: nil))
            let vm = await openEditor(client)
            vm.rotate90CW()
            if row.horizontal { vm.mirrorHorizontally() } else { vm.mirrorVertically() }
            await vm.save()?.value
            XCTAssertEqual(puts(client), [row.expected], "horizontal: \(row.horizontal)")
        }

        let client = server(asset: record(orientation: nil))
        let vm = await openEditor(client)
        vm.mirrorHorizontally()
        await vm.save()?.value
        XCTAssertEqual(puts(client), [[.mirror(.horizontal)]])
    }

    func test_AC_184_previewAndCopyMarkers() async throws {
        // Old server: copy path. Raw image `.up` 400×300: red top left, green top right.
        let client = MockImmichClient()
        client.serverVersionResponse = version(2, 0, 0)
        let vm = PhotoEditorViewModel(assetId: assetId, client: client, store: makeStore(),
                                      urlSession: { .shared }, exportDirectory: exportDir())
        await vm.loadState()
        vm.originalImage = Support.rawImage(width: 400, height: 300)
        vm.rotate90CW()
        vm.mirrorHorizontally()

        let preview = try XCTUnwrap(vm.previewImage)
        let previewCorners = Support.markerCorners(of: preview)
        XCTAssertEqual(previewCorners.red, .topLeft)
        XCTAssertEqual(previewCorners.green, .bottomLeft)

        await vm.saveCopyToServer()?.value
        XCTAssertEqual(vm.dismissReason, .savedCopy)
        let data = try XCTUnwrap(client.lastUploadData)
        let copyCorners = Support.markerCorners(of: try XCTUnwrap(UIImage(data: data)))
        XCTAssertEqual(copyCorners.red, .topLeft)
        XCTAssertEqual(copyCorners.green, .bottomLeft)
    }

    func test_AC_184_resetClearsTheMirror() async {
        let vm = await openEditor(server())
        vm.mirrorHorizontally()
        vm.mirrorVertically()
        XCTAssertTrue(vm.editState.mirrorHorizontal && vm.editState.mirrorVertical)
        vm.resetToOriginal()
        XCTAssertEqual(vm.editState, .neutral)
    }

    // MARK: AC-185

    func test_AC_185_draftWinsThenRetiredAfterPut() async throws {
        let client = server()
        client.assetEditsResponse[assetId] = AssetEditsResponseDto(assetId: assetId, edits: [.rotate(angle: 90)])
        let store = makeStore()
        let draft = EditState(cropRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        try await store.save(state: draft, forAssetId: assetId)

        let vm = await openEditor(client, store: store)
        XCTAssertEqual(vm.editState, draft, "the draft is shown, not the server's rotation")
        await vm.save()?.value
        XCTAssertEqual(client.putAssetEditsCalls.count, 1)
        vm.saveState()
        let stored = await store.load(assetId: assetId)
        XCTAssertNil(stored, "the draft is gone after the PUT")

        let reopened = await openEditor(client, store: store)
        XCTAssertEqual(reopened.editState.orientationSteps, 0, "reopening shows what the server holds")
    }

    func test_AC_185_draftRetiredAfterDelete() async throws {
        let client = server()
        client.assetEditsResponse[assetId] = AssetEditsResponseDto(assetId: assetId, edits: [.rotate(angle: 90)])
        let store = makeStore()
        try await store.save(state: .neutral, forAssetId: assetId)

        let vm = await openEditor(client, store: store)
        XCTAssertEqual(vm.editState, .neutral)
        await vm.save()?.value
        XCTAssertEqual(client.deleteAssetEditsCalls, [assetId])
        await vm.saveState().value
        let stored = await store.load(assetId: assetId)
        XCTAssertNil(stored)

        let reopened = await openEditor(client, store: store)
        XCTAssertEqual(reopened.editState, .neutral, "the DELETE emptied the server's list")
    }

    func test_AC_185_unchangedServerStateWritesNoDraft() async {
        let client = server()
        client.assetEditsResponse[assetId] = AssetEditsResponseDto(assetId: assetId, edits: [.rotate(angle: 90)])
        let store = makeStore()
        let vm = await openEditor(client, store: store)
        XCTAssertEqual(vm.editState.orientationSteps, 1)
        await vm.saveState().value
        let stored = await store.load(assetId: assetId)
        XCTAssertNil(stored)
    }

    func test_AC_185_unknownServerStateLeavesDraftUntouched() async throws {
        for failure in ["edits", "version"] {
            let client = server()
            if failure == "edits" {
                client.getAssetEditsError = APIError.serverError(500, nil)
            } else {
                client.serverVersionError = URLError(.notConnectedToInternet)
            }
            let store = makeStore()
            let vm = await openEditor(client, store: store)
            vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            await vm.saveState().value
            let none = await store.load(assetId: assetId)
            XCTAssertNil(none, "no draft is written blind (\(failure))")
            if failure == "version" { XCTAssertTrue(client.getAssetEditsCalls.isEmpty) }

            let draft = EditState(exposure: 0.4)
            try await store.save(state: draft, forAssetId: assetId)
            let second = await openEditor(client, store: store)
            second.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            await second.saveState().value
            let kept = await store.load(assetId: assetId)
            XCTAssertEqual(kept, draft, "the existing draft is untouched (\(failure))")
        }
    }

    // MARK: AC-188

    func test_AC_188_oldServerCopiesWithoutEditsCalls() async {
        let client = server(version: version(2, 0, 0))
        let vm = await openEditor(client)
        XCTAssertEqual(vm.saveMode, .copy)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        await vm.save()?.value
        XCTAssertTrue(client.getAssetEditsCalls.isEmpty)
        XCTAssertTrue(client.putAssetEditsCalls.isEmpty)
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertEqual(client.lastUploadFilename, "IMG_0001_edited.jpg")
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.dismissReason, .savedCopy)
    }

    func test_AC_188_serverWithoutTheRouteCopies() async {
        // A server that reports a recent version but answers 404 on /edits: known, copy.
        let client = server()
        client.getAssetEditsError = APIError.serverError(404, nil)
        let vm = await openEditor(client)
        XCTAssertEqual(vm.saveMode, .copy)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        await vm.save()?.value
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertTrue(client.putAssetEditsCalls.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func test_AC_188_modeFollowsAdjustmentsAndLivePhoto() async {
        let client = server()
        let vm = await openEditor(client)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(vm.saveMode, .server)
        vm.setExposure(0.2)
        XCTAssertEqual(vm.saveMode, .copy)
        vm.setExposure(0)
        XCTAssertEqual(vm.saveMode, .server)
        vm.setStraighten(5)
        XCTAssertEqual(vm.saveMode, .copy)
        vm.setStraighten(0)
        XCTAssertEqual(vm.saveMode, .server)

        vm.setExposure(0.2)
        await vm.save()?.value
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertTrue(client.putAssetEditsCalls.isEmpty)

        let live = server(asset: record(livePhotoVideoId: "video-1"))
        let liveVM = await openEditor(live)
        liveVM.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(liveVM.saveMode, .copy)
        XCTAssertTrue(live.getAssetEditsCalls.isEmpty)
        await liveVM.save()?.value
        XCTAssertEqual(live.uploads.count, 1)
        XCTAssertTrue(live.putAssetEditsCalls.isEmpty)
    }

    func test_AC_188_ineligiblePhotosCopy() async {
        let cases: [AssetResponseDto] = [
            record(fileName: "anim.gif"), record(fileName: "logo.SVG"),
            record(type: "VIDEO"), record(orientation: nil, fileName: "x.jpg").withoutExifSize()
        ]
        for asset in cases {
            let client = server(asset: asset)
            let vm = await openEditor(client)
            vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            XCTAssertEqual(vm.saveMode, .copy, asset.originalFileName)
            XCTAssertTrue(client.getAssetEditsCalls.isEmpty, asset.originalFileName)
        }
    }

    func test_AC_188_unreadableEditsStillCopiesNonServerEdits() async {
        let client = server()
        client.getAssetEditsError = APIError.serverError(500, nil)
        let vm = await openEditor(client)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(vm.saveMode, .unavailable)
        XCTAssertFalse(vm.canSave)
        XCTAssertNil(vm.save())

        vm.setExposure(0.2)
        XCTAssertEqual(vm.saveMode, .copy)
        await vm.save()?.value
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertTrue(client.putAssetEditsCalls.isEmpty)
        XCTAssertTrue(client.deleteAssetEditsCalls.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func test_AC_188_unreadableVersionIsAnUnknownState() async {
        let client = server()
        client.serverVersionError = URLError(.notConnectedToInternet)
        let vm = await openEditor(client)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(vm.saveMode, .unavailable)
        XCTAssertTrue(client.getAssetEditsCalls.isEmpty)
    }

    func test_AC_188_serverSaveSwitchOffCopies() async {
        let client = server()
        let vm = await openEditor(client, serverEditsEnabled: false)
        XCTAssertTrue(client.getAssetEditsCalls.isEmpty)
        XCTAssertEqual(client.requestCount, 0, "no request at all while the switch is off")
        XCTAssertEqual(vm.saveMode, .copy)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        await vm.save()?.value
        XCTAssertEqual(client.uploads.count, 1)
        XCTAssertEqual(client.lastUploadFilename, "IMG_0001_edited.jpg")
        XCTAssertTrue(client.putAssetEditsCalls.isEmpty)
    }

    // MARK: AC-189

    func test_AC_189_putFailureKeepsEditorAndNeverCopies() async {
        let client = server()
        client.putAssetEditsError = APIError.serverError(500, nil)
        let vm = await openEditor(client)
        vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        vm.rotate90CW()
        let before = vm.editState

        await vm.save()?.value
        XCTAssertFalse((vm.errorMessage ?? "").isEmpty)
        XCTAssertNil(vm.dismissReason)
        XCTAssertEqual(vm.editState, before)
        XCTAssertTrue(client.uploads.isEmpty, "never a silent copy")
        XCTAssertNil(vm.saveStep)
        XCTAssertTrue(vm.canSave, "the user can retry")

        client.putAssetEditsError = APIError.serverError(400, "bad edit")
        await vm.save()?.value
        XCTAssertEqual(vm.errorMessage, localizedString("The server refused the edits."))
        XCTAssertNil(vm.dismissReason)
        XCTAssertTrue(client.uploads.isEmpty)

        client.putAssetEditsError = nil
        await vm.save()?.value
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.dismissReason, .savedEdits)
    }

    func test_AC_189_readOnlyModeRefusesWithoutARequest() async {
        let inner = server()
        let guarded = ReadOnlyGuardClient(inner: inner, isEnabled: { true })
        do {
            _ = try await guarded.putAssetEdits(id: assetId, edits: [.mirror(.horizontal)])
            XCTFail("expected readOnlyMode")
        } catch {
            XCTAssertEqual(error as? APIError, .readOnlyMode)
        }
        do {
            try await guarded.deleteAssetEdits(id: assetId)
            XCTFail("expected readOnlyMode")
        } catch {
            XCTAssertEqual(error as? APIError, .readOnlyMode)
        }
        XCTAssertTrue(inner.putAssetEditsCalls.isEmpty)
        XCTAssertTrue(inner.deleteAssetEditsCalls.isEmpty)
        _ = try? await guarded.getAssetEdits(id: assetId)
        XCTAssertEqual(inner.getAssetEditsCalls, [assetId])
    }
}

private extension AssetResponseDto {
    func withoutExifSize() -> AssetResponseDto {
        var copy = self
        copy.exifInfo = ExifResponseDto(orientation: "1")
        return copy
    }
}
