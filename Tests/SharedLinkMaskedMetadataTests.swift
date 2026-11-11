import XCTest
@testable import ImmichSwiftUI

/// Shared links that hide the photos' metadata ("Show metadata" off): the server
/// hands out the reduced form, and the link must still open — on every server
/// version from v2.x to v3.4.0 — without showing or making up what is hidden.
///
/// Tests that open a link go through the real `ImmichAPIClient` decoding and the
/// real `SharedLinkViewerViewModel`, with canned bodies behind `CapturingURLProtocol`.
@MainActor
final class SharedLinkMaskedMetadataTests: XCTestCase {

    private let base = URL(string: "https://photos.example.com")!
    private let albumId = "33333333-3333-4333-8333-000000000003"

    override func tearDown() {
        CapturingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures (server shapes, as JSON objects)

    private func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func orNull<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    /// v3.4.0 `SanitizedAssetResponseDto`: exactly these ten keys.
    private func reducedV3(
        _ id: String, _ type: String = "IMAGE", duration: Int? = nil, live: String? = nil,
        width: Int? = nil, height: Int? = nil
    ) -> [String: Any] {
        [
            "id": id, "type": type, "originalMimeType": "image/jpeg", "thumbhash": "3OcRJYB4d3h/iIeHeEh3eIhw+j3A",
            "localDateTime": "2024-05-01T10:00:00.000Z",
            "duration": orNull(duration), "livePhotoVideoId": orNull(live),
            "hasMetadata": false, "width": orNull(width), "height": orNull(height),
        ]
    }

    /// v2.0.0 reduced form: duration is a string, never null; no width/height.
    private func reducedV200(_ id: String, _ type: String = "IMAGE", duration: String) -> [String: Any] {
        [
            "id": id, "type": type, "thumbhash": "3OcRJYB4d3h/iIeHeEh3eIhw+j3A", "originalMimeType": "image/jpeg",
            "localDateTime": "2024-05-01T10:00:00.000Z", "duration": duration, "livePhotoVideoId": NSNull(),
            "hasMetadata": false,
        ]
    }

    /// v2.7.5 reduced form: the same with nullable width/height.
    private func reducedV275(_ id: String, _ type: String = "IMAGE", duration: String) -> [String: Any] {
        var json = reducedV200(id, type, duration: duration)
        json["width"] = NSNull()
        json["height"] = NSNull()
        return json
    }

    /// A v2.x full record that leaks everything a masking link must hide.
    private func fullV2(_ id: String, _ n: Int, duration: String) -> [String: Any] {
        [
            "id": id, "type": "IMAGE", "thumbhash": "3OcRJYB4d3h/iIeHeEh3eIhw+j3A",
            "localDateTime": "2019-03-14T10:00:00.000Z", "duration": duration, "hasMetadata": true,
            "width": 8000, "height": 6000, "createdAt": "2019-03-15T08:00:00.000Z",
            "ownerId": "owner-secret", "originalPath": "/upload/SECRET-\(n).jpg",
            "originalFileName": "SECRET-\(n).jpg", "fileCreatedAt": "2019-03-14T10:00:00.000Z",
            "fileModifiedAt": "2019-03-14T10:00:00.000Z", "updatedAt": "2019-03-15T08:00:00.000Z",
            "isFavorite": true, "isArchived": false, "isTrashed": false, "isOffline": false,
            "visibility": "timeline", "checksum": "abc=",
            "exifInfo": [
                "exifImageWidth": 8000, "exifImageHeight": 6000, "orientation": "1",
                "projectionType": "equirectangular", "city": "Lisbon", "country": "Portugal",
                "latitude": 38.7223, "longitude": -9.1393, "dateTimeOriginal": "2019-03-14T10:00:00.000Z",
            ] as [String: Any],
        ]
    }

    /// v3 full record (`duration` is null for a still).
    private func fullV3(_ id: String, isEdited: Bool?) -> [String: Any] {
        var json = fullV2(id, 1, duration: "unused")
        json["duration"] = NSNull()
        json["city"] = nil
        json["exifInfo"] = [
            "exifImageWidth": 8000, "exifImageHeight": 6000, "orientation": "1", "city": "Paris",
        ] as [String: Any]
        if let isEdited { json["isEdited"] = isEdited }
        return json
    }

    private func linkJSON(
        type: String, showMetadata: Bool, assets: [[String: Any]] = [], albumId: String? = nil,
        allowUpload: Bool = false
    ) -> [String: Any] {
        let album: Any = albumId.map { id in
            [
                "id": id, "albumName": "Holidays", "description": "", "createdAt": "2024-01-01T00:00:00.000Z",
                "updatedAt": "2024-01-01T00:00:00.000Z", "albumThumbnailAssetId": NSNull(), "shared": true,
                "hasSharedLink": true, "assetCount": 2, "isActivityEnabled": false, "order": NSNull(),
                "albumUsers": [],
            ] as [String: Any]
        } ?? NSNull()
        return [
            "id": "link-1", "description": "Holidays", "password": NSNull(), "userId": "owner", "key": "a2V5",
            "type": type, "createdAt": "2024-01-01T00:00:00.000Z", "expiresAt": NSNull(), "assets": assets,
            "album": album, "allowUpload": allowUpload, "allowDownload": true, "showMetadata": showMetadata,
            "slug": "masked",
        ]
    }

    private func searchJSON(_ items: [[String: Any]], nextPage: String?) -> Data {
        data(["assets": ["count": items.count, "items": items, "nextPage": orNull(nextPage)] as [String: Any]])
    }

    // MARK: - Helpers

    private func makeClient() -> ImmichAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: base, token: nil)
        return client
    }

    private func makeVM(_ client: any ImmichClient) -> SharedLinkViewerViewModel {
        let vm = SharedLinkViewerViewModel(client: client, baseURL: base)
        vm.linkText = "https://photos.example.com/s/masked"
        return vm
    }

    private func decodeAsset(_ json: [String: Any]) throws -> SharedLinkAssetDto {
        try JSONDecoder.immich.decode(SharedLinkAssetDto.self, from: data(json))
    }

    private func assertOpened(_ vm: SharedLinkViewerViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(vm.phase, .opened, file: file, line: line)
        XCTAssertNil(vm.message, file: file, line: line)
    }

    private func assertNeutral(_ item: AssetReactItem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.ownerId, "", file: file, line: line)
        XCTAssertEqual(item.createdAt, "", file: file, line: line)
        XCTAssertEqual(item.fileCreatedAt, "", file: file, line: line)
        XCTAssertEqual(item.visibility, "", file: file, line: line)
        XCTAssertFalse(item.isFavorite, file: file, line: line)
        XCTAssertFalse(item.isTrashed, file: file, line: line)
        XCTAssertNil(item.projectionType, file: file, line: line)
        XCTAssertNil(item.city, file: file, line: line)
        XCTAssertNil(item.country, file: file, line: line)
        XCTAssertNil(item.latitude, file: file, line: line)
        XCTAssertNil(item.longitude, file: file, line: line)
        XCTAssertNil(item.pixelSize, file: file, line: line)
        XCTAssertEqual(item.localOffsetHours, 0, file: file, line: line)
    }

    // MARK: - AC-115

    func test_AC_115_reducedIndividualLinkOpens() async {
        let assets = [reducedV3("p1", width: 8000, height: 6000), reducedV3("p2", width: 4000, height: 3000)]
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = data(
            linkJSON(type: "INDIVIDUAL", showMetadata: false, assets: assets)
        )
        let vm = makeVM(makeClient())
        await vm.openLink()

        assertOpened(vm)
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
    }

    // MARK: - AC-116

    func test_AC_116_loginResponseWithReducedFormOpens() async {
        CapturingURLProtocol.nextStatus = 401
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = Data(
            #"{"message":"Password required","error":"Unauthorized","statusCode":401}"#.utf8
        )
        let vm = makeVM(makeClient())
        await vm.openLink()
        XCTAssertEqual(vm.phase, .passwordRequired)

        CapturingURLProtocol.nextStatus = 200
        CapturingURLProtocol.dataByPath["/api/shared-links/login"] = data(
            linkJSON(type: "INDIVIDUAL", showMetadata: false, assets: [reducedV3("p1"), reducedV3("p2")])
        )
        vm.password = "hunter2"
        await vm.submitPassword()

        assertOpened(vm)
        XCTAssertEqual(vm.assets.map(\.id), ["p1", "p2"])
    }

    // MARK: - AC-117

    func test_AC_117_reducedFormKeepsVideoAndLiveBadges() throws {
        let reducedVideo = AssetReactItem(
            sharedLinkAsset: try decodeAsset(reducedV3("v1", "VIDEO", duration: 65250)), linkShowsMetadata: false
        )
        XCTAssertTrue(reducedVideo.isVideo)
        XCTAssertEqual(reducedVideo.duration, 65250)
        XCTAssertEqual(VideoDurationFormatter.string(milliseconds: 65250), "1:05")

        let reducedLive = AssetReactItem(
            sharedLinkAsset: try decodeAsset(reducedV3("l1", live: "live-video")), linkShowsMetadata: false
        )
        XCTAssertTrue(reducedLive.isLivePhoto)

        // Same badges as the full form of a link that exposes its metadata.
        var fullVideo = fullV3("v1", isEdited: false)
        fullVideo["type"] = "VIDEO"
        fullVideo["duration"] = 65250
        var fullLive = fullV3("l1", isEdited: false)
        fullLive["livePhotoVideoId"] = "live-video"
        let exposedVideo = AssetReactItem(sharedLinkAsset: try decodeAsset(fullVideo), linkShowsMetadata: true)
        let exposedLive = AssetReactItem(sharedLinkAsset: try decodeAsset(fullLive), linkShowsMetadata: true)
        XCTAssertEqual(reducedVideo.isVideo, exposedVideo.isVideo)
        XCTAssertEqual(reducedVideo.duration, exposedVideo.duration)
        XCTAssertEqual(reducedLive.isLivePhoto, exposedLive.isLivePhoto)
    }

    // MARK: - AC-118

    func test_AC_118_reducedAlbumPagesListEveryPhotoOnce() async {
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = data(
            linkJSON(type: "ALBUM", showMetadata: false, albumId: albumId)
        )
        CapturingURLProtocol.dataByPath["/api/search/metadata"] = searchJSON(
            [reducedV3("a1"), reducedV3("a2"), reducedV3("a3")], nextPage: "2"
        )
        let vm = makeVM(makeClient())
        await vm.openLink()
        assertOpened(vm)
        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a2", "a3"])
        XCTAssertTrue(vm.hasMore)

        CapturingURLProtocol.dataByPath["/api/search/metadata"] = searchJSON(
            [reducedV3("a3"), reducedV3("a4"), reducedV3("a5")], nextPage: nil
        )
        await vm.loadMoreAlbumAssets()

        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a2", "a3", "a4", "a5"])
        XCTAssertFalse(vm.hasMore)
        XCTAssertNil(vm.message)
    }

    // MARK: - AC-120

    func test_AC_120_maskedPhotoKeepsUnknownSize() throws {
        let item = AssetReactItem(
            sharedLinkAsset: try decodeAsset(reducedV3("p1", width: 8000, height: 6000)), linkShowsMetadata: false
        )
        XCTAssertNil(item.pixelSize, "the zoom limit follows the EXIF, which the link hides")
        let viewport = CGSize(width: 393, height: 852)
        let max = ZoomGeometry.maxScale(pixelSize: item.pixelSize, viewport: viewport, displayScale: 3)
        XCTAssertEqual(max, 4)
        XCTAssertEqual(ZoomGeometry.doubleTapTarget(maxScale: max), 3)
    }

    // MARK: - AC-121

    func test_AC_121_maskedLinkHidesWhatAnOldServerLeaks() async throws {
        // Witness: the leaked record really carries the data when the link exposes it.
        let leaked = try decodeAsset(fullV2("f1", 1, duration: "0:00:00.00000"))
        let exposed = AssetReactItem(sharedLinkAsset: leaked, linkShowsMetadata: true)
        XCTAssertEqual(exposed.ownerId, "owner-secret")
        XCTAssertTrue(exposed.createdAt.hasPrefix("2019"))
        XCTAssertTrue(exposed.fileCreatedAt.hasPrefix("2019"))
        XCTAssertEqual(exposed.visibility, "timeline")
        XCTAssertTrue(exposed.isFavorite)
        XCTAssertEqual(exposed.projectionType, "equirectangular")
        XCTAssertEqual(exposed.city, "Lisbon")
        XCTAssertEqual(exposed.country, "Portugal")
        XCTAssertNotNil(exposed.latitude)
        XCTAssertNotNil(exposed.longitude)
        XCTAssertEqual(exposed.pixelSize, PixelSize(width: 8000, height: 6000))

        // The masking link shows none of it, whatever the server sent.
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = data(
            linkJSON(type: "ALBUM", showMetadata: false, albumId: albumId)
        )
        CapturingURLProtocol.dataByPath["/api/search/metadata"] = searchJSON(
            [fullV2("f1", 1, duration: "0:00:00.00000")], nextPage: nil
        )
        let vm = makeVM(makeClient())
        await vm.openLink()

        assertOpened(vm)
        let item = try XCTUnwrap(vm.assets.first { $0.id == "f1" })
        assertNeutral(item)
    }

    // MARK: - AC-122

    func test_AC_122_maskedFieldsReadAsAbsent() throws {
        let dto = try decodeAsset(reducedV3("p1", width: 8000, height: 6000))
        XCTAssertEqual(dto.hasMetadata, false)
        XCTAssertNil(dto.originalFileName)
        XCTAssertNil(dto.originalPath)
        XCTAssertNil(dto.ownerId)
        XCTAssertNil(dto.createdAt)
        XCTAssertNil(dto.fileCreatedAt)
        XCTAssertNil(dto.fileModifiedAt)
        XCTAssertNil(dto.updatedAt)
        XCTAssertNil(dto.isFavorite)
        XCTAssertNil(dto.isArchived)
        XCTAssertNil(dto.isTrashed)
        XCTAssertNil(dto.isOffline)
        XCTAssertNil(dto.visibility)
        XCTAssertNil(dto.checksum)
        XCTAssertNil(dto.exifInfo)

        for shows in [false, true] {
            let item = AssetReactItem(sharedLinkAsset: dto, linkShowsMetadata: shows)
            assertNeutral(item)
            XCTAssertEqual(item.ratio, 1)
            XCTAssertEqual(item.stack, [])
            XCTAssertEqual(item.id, "p1")
        }
    }

    // MARK: - AC-123

    func test_AC_123_exposingLinkConvertsAsBefore() throws {
        let cases: [(Bool, PixelSize?)] = [(false, PixelSize(width: 8000, height: 6000)), (true, nil)]
        for (edited, expected) in cases {
            let json = data(fullV3("p1", isEdited: edited))
            let link = try JSONDecoder.immich.decode(SharedLinkAssetDto.self, from: json)
            let full = try JSONDecoder.immich.decode(AssetResponseDto.self, from: json)
            let item = AssetReactItem(sharedLinkAsset: link, linkShowsMetadata: true)
            XCTAssertEqual(item, AssetReactItem(from: full))
            XCTAssertEqual(item.pixelSize, expected)
            XCTAssertTrue(item.isFavorite)
            XCTAssertEqual(item.city, "Paris")
        }
    }

    // MARK: - AC-124

    func test_AC_124_durationTextAndNumbers() throws {
        let text: [(String, Int?)] = [
            ("00:01:05.250", 65_250), ("0:00:00.00000", 0), ("0:00:12.500000", 12_500), ("1:02:03", 3_723_000),
            (" 0:00:01.5 ", 1_500), ("1:05", nil), ("", nil), ("abc", nil), ("12.50 s", nil),
            ("-0:00:01", nil), ("0:-1:00", nil), ("999999:00:00", nil),
        ]
        for (input, expected) in text {
            XCTAssertEqual(SharedLinkAssetDuration.milliseconds(fromServerText: input), expected, input)
        }
        let json: [(String, Int?)] = [
            ("65250", 65_250), ("65250.4", 65_250), ("-5", nil), ("true", nil), (#""00:01:05.250""#, 65_250),
            (#""nonsense""#, nil), ("[1]", nil), (#"{"a":1}"#, nil),
        ]
        for (input, expected) in json {
            let body = Data(#"{"id":"a","type":"IMAGE","duration":\#(input)}"#.utf8)
            let dto = try JSONDecoder.immich.decode(SharedLinkAssetDto.self, from: body)
            XCTAssertEqual(dto.durationMilliseconds, expected, input)
        }
        let nullBody = Data(#"{"id":"a","type":"IMAGE","duration":null}"#.utf8)
        XCTAssertNil(try JSONDecoder.immich.decode(SharedLinkAssetDto.self, from: nullBody).durationMilliseconds)
    }

    func test_AC_124_v2FormsOpenIndividualAndAlbumLinks() async throws {
        // Individual link, v2.0.0 and v2.7.5 reduced forms.
        let individual = [
            reducedV200("v1", "VIDEO", duration: "00:01:05.250"),
            reducedV200("p1", duration: "0:00:00.00000"),
            reducedV275("p2", duration: "0:00:00.00000"),
        ]
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = data(
            linkJSON(type: "INDIVIDUAL", showMetadata: false, assets: individual)
        )
        let vm = makeVM(makeClient())
        await vm.openLink()
        assertOpened(vm)
        let byId = Dictionary(uniqueKeysWithValues: vm.assets.map { ($0.id, $0) })
        XCTAssertTrue(try XCTUnwrap(byId["v1"]).isVideo)
        XCTAssertEqual(byId["v1"]?.duration, 65_250)
        XCTAssertTrue(try XCTUnwrap(byId["p1"]).isImage)
        XCTAssertEqual(byId["p1"]?.duration, 0)
        XCTAssertTrue(vm.assets.allSatisfy { $0.pixelSize == nil })

        // Album link: a v2.x search answers the full form, plus an unreadable duration.
        CapturingURLProtocol.reset()
        CapturingURLProtocol.dataByPath["/api/shared-links/me"] = data(
            linkJSON(type: "ALBUM", showMetadata: false, albumId: albumId)
        )
        CapturingURLProtocol.dataByPath["/api/search/metadata"] = searchJSON(
            [fullV2("f1", 1, duration: "0:00:00.00000"), reducedV200("v2", "VIDEO", duration: "12.50 s")],
            nextPage: nil
        )
        let albumVM = makeVM(makeClient())
        await albumVM.openLink()
        assertOpened(albumVM)
        let v2 = try XCTUnwrap(albumVM.assets.first { $0.id == "v2" })
        XCTAssertNil(v2.duration)
        XCTAssertTrue(v2.isVideo)

        // The full v2.x form decodes: duration 0, EXIF present.
        let full = try decodeAsset(fullV2("f1", 1, duration: "0:00:00.00000"))
        XCTAssertEqual(full.durationMilliseconds, 0)
        XCTAssertNotNil(full.exifInfo)
    }

    // MARK: - AC-125

    func test_AC_125_fullRecordUnchangedOutsideLinks() throws {
        let full = try JSONDecoder.immich.decode(AssetResponseDto.self, from: data(fullV3("p1", isEdited: false)))
        XCTAssertEqual(full.id, "p1")
        XCTAssertNil(full.duration)
        XCTAssertEqual(full.ownerId, "owner-secret")
        XCTAssertEqual(full.originalFileName, "SECRET-1.jpg")
        XCTAssertTrue(full.isFavorite)
        XCTAssertEqual(full.isEdited, false)
        XCTAssertEqual(full.exifInfo?.exifImageWidth, 8000)
        XCTAssertEqual(full.exifInfo?.city, "Paris")

        // A reduced record stays refused by the strict types.
        let reduced = data(reducedV3("p1", width: 8000, height: 6000))
        XCTAssertThrowsError(try JSONDecoder.immich.decode(AssetResponseDto.self, from: reduced)) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("\(error)") }
        }
        let search = data(["assets": ["count": 1, "items": [reducedV3("p1")], "nextPage": NSNull()] as [String: Any]])
        XCTAssertThrowsError(try JSONDecoder.immich.decode(SearchResponseDto.self, from: search)) { error in
            guard case DecodingError.keyNotFound = error else { return XCTFail("\(error)") }
        }

        // A v2 string duration stays refused outside a link.
        let v2 = data(fullV2("p1", 1, duration: "0:00:00.00000"))
        XCTAssertThrowsError(try JSONDecoder.immich.decode(AssetResponseDto.self, from: v2)) { error in
            guard case DecodingError.typeMismatch = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - AC-126

    func test_AC_126_guestUploadReloadsReducedForm() async throws {
        let mock = MockImmichClient()
        mock.sharedLinkMineResponse = try JSONDecoder.immich.decode(
            SharedLinkResponseDto.self,
            from: data(linkJSON(type: "ALBUM", showMetadata: false, albumId: albumId, allowUpload: true))
        )
        let page1 = searchJSON([reducedV3("a1")], nextPage: nil)
        let page2 = searchJSON([reducedV3("a1"), reducedV3("new")], nextPage: nil)
        mock.sharedLinkAlbumAssetsResponse = try JSONDecoder.immich.decode(SharedLinkAlbumAssetsResponseDto.self, from: page1)
        let vm = makeVM(mock)
        await vm.openLink()
        XCTAssertEqual(vm.assets.map(\.id), ["a1"])

        mock.sharedLinkAlbumAssetsResponse = try JSONDecoder.immich.decode(SharedLinkAlbumAssetsResponseDto.self, from: page2)
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("slm-\(UUID().uuidString).jpg")
        try Data("jpeg-bytes".utf8).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        await vm.upload(fileURL: photo, filename: "new.jpg", deviceAssetId: "dev-asset")

        XCTAssertEqual(vm.uploadState, .done)
        XCTAssertEqual(vm.assets.map(\.id), ["a1", "new"])
        assertOpened(vm)
        assertNeutral(try XCTUnwrap(vm.assets.last))
    }
}
