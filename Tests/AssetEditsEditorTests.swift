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
    private func openEditor(_ client: MockImmichClient, store: EditStateStore? = nil) async -> PhotoEditorViewModel {
        let vm = PhotoEditorViewModel(assetId: assetId, client: client, store: store ?? makeStore(),
                                      urlSession: { .shared }, exportDirectory: exportDir())
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
                                      urlSession: { .shared }, exportDirectory: exportDir())
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

    /// AC-40 (second Given): on a server that does not serve `/edits`, saving a retouch creates a copy as
    /// before, without an error. A server that reports a recent version but answers 404 does the same.
    func test_AC_40_serverWithoutEditsSavesACopyWithoutError() async {
        let old = server(version: version(2, 0, 0))
        let missing = server()
        missing.getAssetEditsError = APIError.serverError(404, nil)
        for client in [old, missing] {
            let vm = await openEditor(client)
            vm.setCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
            await vm.save()?.value
            XCTAssertEqual(client.uploads.count, 1, "the copy is the fallback")
            XCTAssertEqual(client.lastUploadFilename, "IMG_0001_edited.jpg")
            XCTAssertTrue(client.putAssetEditsCalls.isEmpty)
            XCTAssertNil(vm.errorMessage)
            XCTAssertEqual(vm.dismissReason, .savedCopy)
        }
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

// MARK: - Display of the edited version (L-21: AC-39, AC-183, AC-186)

/// Every screen shows the version edited on the server: the URLs ask `edited=true`, the new thumbhash
/// reaches them once the server has regenerated the thumbnails, and offline copies follow.
@MainActor
final class AssetEditsDisplayTests: XCTestCase {

    private let base = URL(string: "https://immich.example")!

    override func setUp() {
        super.setUp()
        ThumbhashSuccession.shared.removeAll()
    }

    override func tearDown() {
        ThumbhashSuccession.shared.removeAll()
        super.tearDown()
    }

    private func item(id: String = "a1", thumbhash: String? = "h1") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 0.75, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: thumbhash,
            createdAt: "2024-07-01T10:00:00.000Z", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: [],
            pixelSize: PixelSize(width: 4000, height: 3000)
        )
    }

    private func record(id: String = "a1", thumbhash: String?) -> AssetResponseDto {
        var dto = EditorTestSupport.makeAssetDTO()
        dto = AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: thumbhash, localDateTime: dto.localDateTime,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: dto.createdAt,
            ownerId: "owner", originalPath: dto.originalPath, originalFileName: dto.originalFileName,
            fileCreatedAt: dto.fileCreatedAt, fileModifiedAt: dto.fileModifiedAt, updatedAt: dto.updatedAt,
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false, visibility: "timeline",
            checksum: "abc", isEdited: true)
        return dto
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// AC-183: every thumbnail and preview a screen builds asks `edited=true`, explicitly, whatever its
    /// size; the viewer's full-quality page asks the edited original and carries the thumbhash as cache key.
    func test_AC_183_everyDisplayURLAsksEditedTrue() {
        let photo = item()
        for size in [AssetMediaSize.thumbnail, .preview, .fullsize] {
            let url = photo.thumbnailURL(base: base, size: size)
            XCTAssertEqual(url.path, "/api/assets/a1/thumbnail")
            XCTAssertEqual(query(url, "size"), size.rawValue)
            XCTAssertEqual(query(url, "edited"), "true", "size \(size.rawValue) asks the edited rendering")
        }
        let direct = ImmichAssetURL.thumbnail(assetId: "a1", thumbhash: "", baseURL: base)
        XCTAssertEqual(query(direct, "edited"), "true", "an album cover or a memory builds it the same way")

        let page = ZoomableImageView.pageURL(asset: photo, baseURL: base, loadOriginal: true)
        XCTAssertEqual(page.path, "/api/assets/a1/original")
        XCTAssertEqual(query(page, "edited"), "true")
        XCTAssertEqual(query(page, "c"), "h1")
        let preview = ZoomableImageView.pageURL(asset: photo, baseURL: base, loadOriginal: false)
        XCTAssertEqual(query(preview, "edited"), "true")
    }

    /// Decision #4: the share sheet shares the photo as uploaded.
    func test_AC_183_shareAsksTheOriginalPreview() {
        let url = item().thumbnailURL(base: base, size: .preview, edited: false)
        XCTAssertEqual(query(url, "edited"), "false")
    }

    /// AC-183: once the server has regenerated the thumbnails, every URL built from the old thumbhash
    /// carries the new one, so no screen keeps the image it loaded before.
    func test_AC_183_newThumbhashReachesEveryURLBuiltFromTheOldOne() {
        let before = item().thumbnailURL(base: base, size: .preview)
        XCTAssertEqual(query(before, "c"), "h1")

        ThumbhashSuccession.shared.record(old: "h1", new: "h2")

        XCTAssertEqual(query(item().thumbnailURL(base: base, size: .preview), "c"), "h2")
        XCTAssertEqual(query(item().thumbnailURL(base: base), "c"), "h2")
        XCTAssertEqual(query(ImmichAssetURL.thumbnail(assetId: "a1", thumbhash: "h1", baseURL: base), "c"), "h2")
        XCTAssertEqual(query(ZoomableImageView.pageURL(asset: item(), baseURL: base, loadOriginal: true), "c"), "h2")
        XCTAssertNotEqual(item().thumbnailURL(base: base, size: .preview), before, "a different URL is a different cache entry")

        ThumbhashSuccession.shared.record(old: "h2", new: "h3")
        XCTAssertEqual(query(item().thumbnailURL(base: base), "c"), "h3", "a second edit follows the chain")
    }

    /// The map is keyed by the OLD value: a thumbhash that is nobody's predecessor is never rewritten,
    /// and an empty or unchanged value records nothing.
    func test_AC_183_aLaterThumbhashIsNeverShadowed() {
        ThumbhashSuccession.shared.record(old: "h1", new: "h2")
        ThumbhashSuccession.shared.record(old: nil, new: "x")
        ThumbhashSuccession.shared.record(old: "", new: "x")
        ThumbhashSuccession.shared.record(old: "h9", new: "h9")

        XCTAssertEqual(ThumbhashSuccession.shared.current(for: "h2"), "h2")
        XCTAssertEqual(ThumbhashSuccession.shared.current(for: "other"), "other")
        XCTAssertEqual(ThumbhashSuccession.shared.current(for: ""), "")
        XCTAssertEqual(ThumbhashSuccession.shared.current(for: "h9"), "h9")
    }

    /// AC-183: the regeneration is awaited: the record is read until its thumbhash changes.
    func test_AC_183_awaitRegenerationWaitsForTheNewThumbhash() async {
        let client = MockImmichClient()
        client.getAssetResponse["a1"] = record(thumbhash: "h1")
        let reads = TestBox(0)
        client.getAssetGate = { id in
            reads.value += 1
            if reads.value == 3 { client.getAssetResponse[id] = self.record(thumbhash: "h2") }
        }

        let fresh = await EditedAssetRefresh.awaitRegeneration(
            assetId: "a1", previousThumbhash: "h1", client: client, attempts: 10, interval: .milliseconds(1))

        XCTAssertEqual(fresh?.thumbhash, "h2")
        XCTAssertEqual(client.getAssetCalls, ["a1", "a1", "a1"], "it stops at the first record that changed")
    }

    func test_AC_183_awaitRegenerationGivesUpWhenNothingChanges() async {
        let client = MockImmichClient()
        client.getAssetResponse["a1"] = record(thumbhash: "h1")

        let fresh = await EditedAssetRefresh.awaitRegeneration(
            assetId: "a1", previousThumbhash: "h1", client: client, attempts: 3, interval: .milliseconds(1))

        XCTAssertNil(fresh)
        XCTAssertEqual(client.getAssetCalls.count, 3)
    }

    func test_AC_183_awaitRegenerationSurvivesAFailedRead() async {
        let client = MockImmichClient()
        client.getAssetResponse["a1"] = record(thumbhash: "h2")
        let reads = TestBox(0)
        client.getAssetGate = { _ in
            reads.value += 1
            if reads.value == 1 { throw URLError(.timedOut) }
        }

        let fresh = await EditedAssetRefresh.awaitRegeneration(
            assetId: "a1", previousThumbhash: "h1", client: client, attempts: 3, interval: .milliseconds(1))

        XCTAssertEqual(fresh?.thumbhash, "h2")
    }

    /// AC-183: a viewer item adopts the new thumbhash and forgets the pixel size of the original.
    func test_AC_183_refreshedItemCarriesTheNewThumbhash() {
        let refreshed = item().refreshed(from: record(thumbhash: "h2"))

        XCTAssertEqual(refreshed.thumbhash, "h2")
        XCTAssertNil(refreshed.pixelSize, "the EXIF no longer describes the displayed version")
        XCTAssertEqual(refreshed.id, "a1")
        XCTAssertEqual(refreshed.ratio, 0.75)
    }

    /// AC-183: the server's edit-ready events are listened to and counted as a change of the library, so
    /// the timeline, the albums, the memories and the viewer read their photos again without a gesture.
    func test_AC_183_editReadyEventsAreListenedAndRefreshTheScreens() {
        for event in ["AssetEditReadyV1", "AssetEditReadyV2"] {
            XCTAssertTrue(RealtimeBatch.listenedEvents.contains(event))
            let batch = RealtimeBatch(events: [event])
            XCTAssertTrue(batch.touchesAssets)
            XCTAssertTrue(batch.touchesEditedAssets)
        }
        XCTAssertFalse(RealtimeBatch(events: ["on_asset_update"]).touchesEditedAssets)
    }

    /// AC-39: the grid and the viewer show the edited version after the edits are saved, and the original
    /// again after they are removed — each time the thumbhash the server regenerated reaches the URLs.
    func test_AC_39_gridAndViewerFollowTheEditAndItsRemoval() async {
        let client = MockImmichClient()
        let photo = item()

        client.getAssetResponse["a1"] = record(thumbhash: "h2")
        let edited = await EditedAssetRefresh.awaitRegeneration(
            assetId: "a1", previousThumbhash: photo.thumbhash, client: client, attempts: 2, interval: .milliseconds(1))
        ThumbhashSuccession.shared.record(old: photo.thumbhash, new: edited?.thumbhash)
        XCTAssertEqual(query(photo.thumbnailURL(base: base), "c"), "h2", "the grid cell shows the edited image")
        XCTAssertEqual(query(photo.thumbnailURL(base: base, size: .preview), "c"), "h2", "so does the viewer")

        let shown = photo.refreshed(from: edited!)
        client.getAssetResponse["a1"] = record(thumbhash: "h3")
        let restored = await EditedAssetRefresh.awaitRegeneration(
            assetId: "a1", previousThumbhash: shown.thumbhash, client: client, attempts: 2, interval: .milliseconds(1))
        ThumbhashSuccession.shared.record(old: shown.thumbhash, new: restored?.thumbhash)
        XCTAssertEqual(query(photo.thumbnailURL(base: base), "c"), "h3", "the original comes back after the removal")
        XCTAssertEqual(query(photo.thumbnailURL(base: base), "edited"), "true")
    }

    /// AC-186: an offline copy is downloaded with `edited=true` when it is kept, and again with
    /// `edited=false` after the edits are removed. The store lands each download on the same path.
    func test_AC_186_offlineCopyFollowsTheDisplayedVersion() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetEditsOffline-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let transport = OfflineEditsTransport()
        let store = OfflineAssetStore(rootURL: folder, transport: transport,
                                      defaults: UserDefaults(suiteName: "assetEdits-offline-\(UUID().uuidString)")!)
        let index = OfflineAssetIndex()
        let client = MockImmichClient()
        client.getAssetResponse["a1"] = record(thumbhash: "h1")
        _ = store.setActiveAccount("acct", otherAccountsRegistered: false)
        let vm = OfflineDownloadViewModel(store: store, client: client, index: index, accountID: "acct")

        await vm.downloadAsset(item(), baseURL: base, token: "tok")
        await vm.downloadAsset(item(), baseURL: base, token: "tok", edited: false)

        let asked = transport.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "edited" }?.value }
        XCTAssertEqual(asked, ["true", "false"], "kept as the displayed version, then as the original after the removal")
        XCTAssertEqual(Set(transport.requests.map { $0.url?.path }), ["/api/assets/a1/original"])
        let local = try XCTUnwrap(index.localURL(for: "a1"))
        XCTAssertEqual(try Data(contentsOf: local), Data("edited=false".utf8), "the file at the same path is the new one")
    }
}

/// Answers each download with the value of its `edited` query item, so a test can tell which one it holds.
private final class OfflineEditsTransport: FileDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { seen } }

    func download(_ request: URLRequest, onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> DownloadedFile {
        lock.withLock { seen.append(request) }
        let edited = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "edited" }?.value ?? "nil"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("edits-\(UUID().uuidString)")
        try Data("edited=\(edited)".utf8).write(to: file)
        return DownloadedFile(url: file, statusCode: 200, contentType: "image/jpeg")
    }
}
