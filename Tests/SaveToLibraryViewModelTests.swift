import XCTest
@testable import ImmichSwiftUI

@MainActor
final class SaveToLibraryViewModelTests: XCTestCase {

    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    private func makeAsset(id: String = "p1", isImage: Bool = true, fileName: String = "2024-07-01T10:00:00.000Z") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 0.75, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: isImage, thumbhash: nil,
            createdAt: fileName, fileCreatedAt: fileName, localOffsetHours: 0,
            duration: isImage ? nil : 12, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeVM(
        asset: AssetReactItem,
        client: MockImmichClient = MockImmichClient(),
        photoLibrary: MockPhotoLibraryService = MockPhotoLibraryService(),
        token: String? = "tok",
        nextData: Data = Data("payload".utf8),
        nextHeaders: [String: String] = ["Content-Type": "image/jpeg"],
        nextStatus: Int = 200,
        onPresent: @escaping ([Any], (() -> Void)?) -> Void = { _, _ in }
    ) -> (vm: SaveToLibraryViewModel, client: MockImmichClient, photoLibrary: MockPhotoLibraryService, session: URLSession) {
        CapturingURLProtocol.nextData = nextData
        CapturingURLProtocol.nextHeaders = nextHeaders
        CapturingURLProtocol.nextStatus = nextStatus
        let session = makeMockedSession()
        let vm = SaveToLibraryViewModel(
            asset: asset, client: client, baseURL: URL(string: "https://example.com")!,
            token: token, photoLibrary: photoLibrary, session: { session }, presentShare: onPresent
        )
        return (vm, client, photoLibrary, session)
    }

    // MARK: - Save to Photos

    func test_saveImage_downloadsOriginalWithAuthAndSavesBytes() async {
        let payload = Data("payload-bytes".utf8)
        let photoLibrary = MockPhotoLibraryService()
        let (vm, _, _, _) = makeVM(
            asset: makeAsset(),
            photoLibrary: photoLibrary,
            nextData: payload,
            nextHeaders: ["Content-Type": "image/jpeg"]
        )

        await vm.saveToPhotos()

        XCTAssertEqual(vm.lastSavedIdentifier, "local://mock")
        XCTAssertEqual(vm.savedKind, "image")
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(photoLibrary.savedImageData, payload)

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.url?.path, "/api/assets/p1/original")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // MARK: - Edited version or original (L-21, AC-40, AC-187)

    private func editedFlag(_ request: URLRequest?) -> String? {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "edited" }?.value
    }

    /// AC-40: "Save to Photos" asks `edited=true` for the edited version and `edited=false` for the original.
    func test_AC_40_saveToPhotosAsksTheChosenVersionExplicitly() async {
        let (vm, _, _, _) = makeVM(asset: makeAsset())

        await vm.saveToPhotos(edited: true)
        XCTAssertEqual(editedFlag(CapturingURLProtocol.lastRequest), "true")

        await vm.saveToPhotos(edited: false)
        XCTAssertEqual(editedFlag(CapturingURLProtocol.lastRequest), "false")

        await vm.saveToPhotos()
        XCTAssertEqual(editedFlag(CapturingURLProtocol.lastRequest), "false", "without a choice: the original")
    }

    /// AC-187: "Download original" never takes the edited version.
    func test_AC_187_downloadOriginalAlwaysAsksTheOriginal() async {
        let (vm, _, _, _) = makeVM(asset: makeAsset())

        await vm.downloadOriginal()

        XCTAssertEqual(editedFlag(CapturingURLProtocol.lastRequest), "false")
    }

    /// AC-187: the question is asked only for a photo whose record says it is edited.
    func test_AC_187_choiceIsOfferedOnlyForAnEditedRecord() async throws {
        let client = MockImmichClient()
        var dto = try await client.getAsset(id: "p1")
        dto.isEdited = false
        client.getAssetResponse["p1"] = dto
        let (vm, _, _, _) = makeVM(asset: makeAsset(), client: client)
        let notEdited = await vm.offersEditedChoice()
        XCTAssertFalse(notEdited, "isEdited false: the original goes without a question")

        dto.isEdited = true
        client.getAssetResponse["p1"] = dto
        let edited = await vm.offersEditedChoice()
        XCTAssertTrue(edited)
    }

    func test_saveVideo_stagesTempFileWithRealExtensionAndCleansUp() async {
        let photoLibrary = MockPhotoLibraryService()
        let (vm, _, _, _) = makeVM(
            asset: makeAsset(isImage: false),
            photoLibrary: photoLibrary,
            nextData: Data("video-bytes".utf8),
            nextHeaders: ["Content-Type": "video/mp4"]
        )

        await vm.saveToPhotos()

        XCTAssertEqual(vm.savedKind, "video")
        guard let savedURL = photoLibrary.savedVideoURL else {
            return XCTFail("saveVideo not called")
        }
        XCTAssertEqual(savedURL.pathExtension, "mp4")
        XCTAssertEqual(savedURL.lastPathComponent, "x.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.deletingLastPathComponent().path), "temp dir removed after save")
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path), "temp file removed after save")
    }

    func test_saveUsesServerOriginalNameForFilename() async throws {
        let client = MockImmichClient()
        var dto = try await client.getAsset(id: "p1")
        dto.originalFileName = "vacation.heic"
        client.getAssetResponse["p1"] = dto
        let (vm, _, _, _) = makeVM(asset: makeAsset(), client: client)

        await vm.downloadOriginal()

        XCTAssertEqual(vm.lastDownloadFileName, "vacation.jpg")
    }

    func test_AC_102_downloadOriginalOfJpegXLIsNamedJxl() async throws {
        let client = MockImmichClient()
        var dto = try await client.getAsset(id: "p1")
        dto.originalFileName = "vacation"
        client.getAssetResponse["p1"] = dto
        let (vm, _, _, _) = makeVM(
            asset: makeAsset(),
            client: client,
            nextHeaders: ["Content-Type": "image/jxl"]
        )

        await vm.downloadOriginal()

        XCTAssertEqual(vm.lastDownloadFileName, "vacation.jxl")
    }

    func test_saveError_surfacesMessage() async {
        let photoLibrary = MockPhotoLibraryService()
        photoLibrary.saveError = APIError.serverError(500, "boom")
        let (vm, _, _, _) = makeVM(asset: makeAsset(), photoLibrary: photoLibrary)

        await vm.saveToPhotos()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.lastSavedIdentifier)
    }

    // MARK: - Download original

    func test_downloadOriginal_presentsFileURLAndCleansUpAfterCompletion() async {
        var presented: [Any] = []
        var completion: (() -> Void)?
        let (vm, _, _, _) = makeVM(
            asset: makeAsset(),
            onPresent: { items, done in presented = items; completion = done }
        )

        await vm.downloadOriginal()

        XCTAssertTrue(vm.didPresentDownload)
        XCTAssertEqual(presented.count, 1)
        guard let fileURL = presented.first as? URL else {
            return XCTFail("expected file URL")
        }
        XCTAssertEqual(fileURL.lastPathComponent, "x.jpg")
        XCTAssertEqual(vm.lastDownloadFileName, fileURL.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        completion?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func test_downloadFails_500_noPresentation() async {
        var presentedCount = 0
        let (vm, _, _, _) = makeVM(asset: makeAsset(), nextStatus: 500, onPresent: { _, _ in presentedCount += 1 })

        await vm.downloadOriginal()

        XCTAssertFalse(vm.didPresentDownload)
        XCTAssertEqual(presentedCount, 0)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - AssetFileTransfer

    func test_assetFileTransfer_mimeMapping() {
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/png"), "png")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/webp"), "webp")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/heic"), "heic")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/gif"), "gif")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "image/avif"), "avif")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "video/mp4"), "mp4")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "video/quicktime"), "mov")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: nil), "jpg")
        XCTAssertEqual(AssetFileTransfer.fileExtension(forMime: "application/octet-stream"), "jpg")
    }

    func test_assetFileTransfer_baseName() {
        XCTAssertEqual(AssetFileTransfer.baseName(originalName: "IMG_1234.JPG", datePrefix: "2024-07-01"), "IMG_1234")
        XCTAssertEqual(AssetFileTransfer.baseName(originalName: "noext", datePrefix: "2024-07-01"), "noext")
        XCTAssertEqual(AssetFileTransfer.baseName(originalName: nil, datePrefix: "2024-07-01"), "Photo-2024-07-01")
        XCTAssertEqual(AssetFileTransfer.baseName(originalName: "", datePrefix: "2024-07-01"), "Photo-2024-07-01")
    }

    func test_assetFileTransfer_fetchData_rejectsNon2xx() async {
        CapturingURLProtocol.nextStatus = 401
        let session = makeMockedSession()
        do {
            _ = try await AssetFileTransfer.fetchData(
                from: URL(string: "https://example.com/x")!,
                token: "tok",
                session: session
            )
            XCTFail("expected error")
        } catch let e {
            guard case APIError.serverError = e else {
                return XCTFail("expected serverError, got \(e)")
            }
        }
    }

    func test_assetFileTransfer_fetchData_emptyPayloadFails() async {
        CapturingURLProtocol.nextData = Data()
        let session = makeMockedSession()
        do {
            _ = try await AssetFileTransfer.fetchData(
                from: URL(string: "https://example.com/x")!,
                token: nil,
                session: session
            )
            XCTFail("expected error")
        } catch let e {
            guard case APIError.decoding = e else {
                return XCTFail("expected decoding, got \(e)")
            }
        }
    }

    // MARK: - Custom HTTP headers (L-09)
    //
    // The view model downloads through `AssetFileTransfer.fetchData`; these call
    // it with a fixed provider so the shared keychain-backed registry is never read.

    func test_AC_118_fetchCarriesHeaders() async throws {
        CapturingURLProtocol.nextData = Data("payload".utf8)
        CapturingURLProtocol.nextHeaders = ["Content-Type": "image/jpeg"]
        let url = URL(string: "https://example.com/api/assets/p1/original")!

        _ = try await AssetFileTransfer.fetchData(
            from: url, token: "tok", session: makeMockedSession(),
            customHeaders: StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://example.com")
        )
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Access"), "secret")
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        _ = try await AssetFileTransfer.fetchData(
            from: url, token: "tok", session: makeMockedSession(),
            customHeaders: StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://elsewhere.example.org")
        )
        XCTAssertNil(CapturingURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Access"))
    }

    func test_AC_120_fetchDropsHeadersOnCrossHostRedirect() async throws {
        RedirectingURLProtocol.reset()
        let headers = StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://a.proxy.test")
        let session = RedirectingURLProtocol.makeSession()

        _ = try await AssetFileTransfer.fetchData(
            from: URL(string: "https://a.proxy.test/api/assets/p1/original")!,
            token: "tok", session: session, customHeaders: headers
        )
        let crossed = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "b.other.test").first)
        crossed.assertNoSecrets()

        RedirectingURLProtocol.reset()
        _ = try await AssetFileTransfer.fetchData(
            from: URL(string: "https://a.proxy.test/same/original")!,
            token: "tok", session: session, customHeaders: headers
        )
        let same = try XCTUnwrap(RedirectingURLProtocol.requests(toHost: "a.proxy.test").first)
        same.assertSecretsKept()
    }
}
