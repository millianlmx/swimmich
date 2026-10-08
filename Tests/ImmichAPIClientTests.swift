import XCTest
@testable import ImmichSwiftUI

/// URLProtocol that captures the most recent request + returns a canned response.
final class CapturingURLProtocol: URLProtocol {
    /// Most recent captured URLRequest (thread-safe via lock).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastRequest: URLRequest?
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return _lastRequest }

    nonisolated(unsafe) static var nextData: Data = Data()
    nonisolated(unsafe) static var nextStatus: Int = 200
    nonisolated(unsafe) static var nextHeaders: [String: String] = ["Content-Type": "application/json"]

    /// Snapshot of the captured body bytes (URLSession may move httpBody → httpBodyStream).
    nonisolated(unsafe) private static var _lastBody: Data = Data()
    static var lastBody: Data { lock.lock(); defer { lock.unlock() }; return _lastBody }

    static func reset() {
        lock.lock(); _lastRequest = nil; _lastBody = Data(); lock.unlock()
        nextData = Data()
        nextStatus = 200
        nextHeaders = ["Content-Type": "application/json"]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._lastRequest = request
        Self._lastBody = Self.captureBody(from: request)
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.nextStatus, httpVersion: "HTTP/1.1",
            headerFields: Self.nextHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.nextData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Reads httpBody, falling back to httpBodyStream (URLSession may convert large bodies).
    private static func captureBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class ImmichAPIClientTests: XCTestCase {

    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Captured request body as a JSON object. Compares decoded values, not
    /// source text — `JSONEncoder` escapes `/` as `\/`, so raw substring checks
    /// on URL-bearing fields are unreliable.
    private func decodedBody() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: CapturingURLProtocol.lastBody)
        return try XCTUnwrap(object as? [String: Any])
    }

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    // AC-008: multipart upload shape + checksum header.
    func test_AC_008_multipartUploadShape() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = #"{"id":"new","status":"created"}"#.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 201
        CapturingURLProtocol.nextHeaders = ["Content-Type": "application/json"]

        let payload = Data(repeating: 0xAB, count: 1024) // 1KB
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("upload-test-\(UUID().uuidString).bin")
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await client.uploadAsset(
            fileURL: tmp,
            fileCreatedAt: "2024-07-01T00:00:00.000Z",
            fileModifiedAt: "2024-07-01T00:00:00.000Z",
            filename: "photo.jpg",
            duration: nil,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoId: nil,
            checksum: "Y2hlY2tzdW0=",
            deviceAssetId: "local://asset-1",
            deviceId: "device-uuid"
        )

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertTrue(captured.url?.absoluteString.contains("/api/assets") == true)

        let contentType = captured.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data"), "got \(contentType)")

        // x-immich-checksum header present.
        XCTAssertFalse((captured.value(forHTTPHeaderField: "x-immich-checksum") ?? "").isEmpty)

        // Body contains required field names.
        let body = CapturingURLProtocol.lastBody
        // Lossy decode: payload is binary, but field-name ASCII survives.
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains(#"name="assetData""#), "assetData field missing")
        XCTAssertTrue(bodyString.contains(#"name="fileCreatedAt""#), "fileCreatedAt missing")
        XCTAssertTrue(bodyString.contains(#"name="fileModifiedAt""#), "fileModifiedAt missing")
        XCTAssertTrue(bodyString.contains(#"name="deviceAssetId""#), "deviceAssetId missing")
        XCTAssertTrue(bodyString.contains(#"name="deviceId""#), "deviceId missing")

        // isFavorite sent as string "false".
        XCTAssertTrue(bodyString.contains(#"name="isFavorite""#))

        // Body length strictly greater than multipart overhead (boundaries + field headers).
        // Overhead computed below covers all 5 emitted text fields + the binary assetData part.
        let boundary = contentType.components(separatedBy: "boundary=").last ?? ""
        let crlf = 2
        let overhead = (
            "--\(boundary)--\r\n".utf8.count
            + "--\(boundary)\r\n".utf8.count * 7 // 7 parts: assetData, fileCreatedAt, fileModifiedAt, deviceAssetId, deviceId, isFavorite, visibility
            + ("Content-Disposition: form-data; name=\"assetData\"; filename=\"photo.jpg\"\r\n".utf8.count)
            + ("Content-Type: application/octet-stream\r\n\r\n".utf8.count)
            + ("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n".utf8.count)
            + ("2024-07-01T00:00:00.000Z".utf8.count + crlf)
            + ("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n".utf8.count)
            + ("2024-07-01T00:00:00.000Z".utf8.count + crlf)
            + ("Content-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n".utf8.count)
            + ("local://asset-1".utf8.count + crlf)
            + ("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".utf8.count)
            + ("device-uuid".utf8.count + crlf)
            + ("Content-Disposition: form-data; name=\"isFavorite\"\r\n\r\n".utf8.count)
            + ("false".utf8.count + crlf)
            + ("Content-Disposition: form-data; name=\"visibility\"\r\n\r\n".utf8.count)
            + ("timeline".utf8.count + crlf)
        )
        XCTAssertGreaterThan(body.count, overhead, "body length must exceed multipart overhead")
        XCTAssertGreaterThan(body.count, payload.count, "body must contain the payload")
    }

    // AC-014: any 401 triggers auth reset (Keychain cleared + isAuthenticated false).
    @MainActor
    func test_AC_014_global401ResetsAuth() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        let keychain = MockKeychainStore()
        keychain.saveToken("expired-jwt")
        // Configure the client with the token so authed calls actually dispatch
        // (otherwise sendAuthedRaw throws .unauthorized before any HTTP call,
        // bypassing the delegate path).
        client.configure(baseURL: URL(string: "https://example.com")!, token: "expired-jwt")
        let suite = "ImmichAPIClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = AuthViewModel(client: client, keychain: keychain, defaults: defaults)
        auth.serverURLString = "https://example.com"
        _ = auth.baseURL
        auth.accessToken = "expired-jwt"

        // Any authed call returns 401.
        CapturingURLProtocol.nextData = "{}".data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 401
        CapturingURLProtocol.nextHeaders = ["Content-Type": "application/json"]

        // Fire a call; expect APIError.unauthorized + delegate-triggered reset.
        let timeline = TimelineViewModel(client: client)
        await timeline.load() // triggers getTimeBuckets → 401

        // Spin the runloop briefly so the MainActor Task in didReceiveUnauthorized runs.
        try await Task.sleep(nanoseconds: 300_000_000)

        // SP-4 / AC-7: a 401 expires the session but keeps the stored token.
        XCTAssertEqual(keychain.savedToken, "expired-jwt", "401 must keep the stored session token")
        XCTAssertFalse(auth.isAuthenticated, "auth should be reset on 401")
        XCTAssertTrue(auth.sessionExpired)
        XCTAssertEqual(auth.errorMessage, localizedString("Your session has expired. Please sign in again."))
    }

    // AC-007: thumbnail URL via ImmichAssetURL helper.
    func test_AC_007_thumbnailURLHelper() {
        let url = ImmichAssetURL.thumbnail(
            assetId: "abc123", thumbhash: "xyz",
            baseURL: URL(string: "https://photos.example.com")!
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://photos.example.com/api/assets/abc123/thumbnail?size=thumbnail&c=xyz"
        )
    }

    // AC-710: map markers request path + optional query params + decoding.
    func test_AC_710_mapMarkersRequest() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = #"""
        [{"id":"a1","lat":48.8566,"lon":2.3522,"city":"Paris","state":null,"country":"France"}]
        """#.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 200

        let markers = try await client.getMapMarkers(filter: MapMarkerFilter(onlyFavorites: true))

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertTrue(captured.url?.absoluteString.contains("/api/map/markers") == true)
        XCTAssertTrue(captured.url?.absoluteString.contains("isFavorite=true") == true, "favorite filter must be encoded")
        XCTAssertFalse(captured.url?.absoluteString.contains("isArchived") == true, "nil filter must be omitted")

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.id, "a1")
        XCTAssertEqual(markers.first?.lat, 48.8566)
        XCTAssertEqual(markers.first?.city, "Paris")
        XCTAssertNil(markers.first?.state)
    }

    // AC-710: map markers without filters → no query params.
    func test_AC_710_mapMarkersNoFilters() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!

        _ = try await client.getMapMarkers(filter: .all)

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.url?.query, nil, "no query params expected")
    }

    // AC-5141: the marker route is the only carrier of a time range — the
    // filter's bounds must reach the URL as date-time query items.
    func test_AC_5141_mapMarkersRequest_carriesTheCustomTimeRange() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 200

        let calendar = Calendar.current
        let from = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let to = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_600_000))
        _ = try await client.getMapMarkers(filter: MapMarkerFilter(from: from, to: to))

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        let query = captured.url?.query ?? ""
        XCTAssertTrue(query.contains("fileCreatedAfter="), "the range must travel on the marker route: \(query)")
        XCTAssertTrue(query.contains("fileCreatedBefore="), "the range must travel on the marker route: \(query)")
        XCTAssertFalse(query.contains("takenAfter"), "the metadata-search parameter is not the marker route's")
    }

    // Photo share: GET /api/users returns the instance users.
    func test_photoShare_getUsers_hitsUsersEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        let usersJSON = """
        [{"id":"u1","name":"Alice","email":"alice@example.com","profileImagePath":"","avatarColor":"#4250AF","profileChangedAt":"2024-01-01T00:00:00.000Z"}]
        """
        CapturingURLProtocol.nextData = usersJSON.data(using: .utf8)!

        let users = try await client.getUsers()

        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users.first?.id, "u1")
        XCTAssertEqual(users.first?.name, "Alice")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/users")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    // G18: the change-password call posts the three DTO fields to the real
    // route. This is the only place the URL itself is proven.
    func test_G18_changePassword_postsTheThreeFieldsToTheAuthRoute() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = #"{"id":"me","name":"Me","email":"me@example.com","shouldChangePassword":false}"#.data(using: .utf8)!

        let user = try await client.changePassword(
            currentPassword: "old-secret",
            newPassword: "new-secret-1",
            invalidateSessions: true
        )

        XCTAssertEqual(user.id, "me")
        XCTAssertEqual(user.shouldChangePassword, false, "the reply carries the flag the caller clears")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/auth/change-password")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let body = try decodedBody()
        XCTAssertEqual(body["password"] as? String, "old-secret")
        XCTAssertEqual(body["newPassword"] as? String, "new-secret-1")
        XCTAssertEqual(body["invalidateSessions"] as? Bool, true)
    }

    // G18: the server-side shouldChangePassword flag is re-read from /users/me.
    func test_G18_currentUser_readsTheUsersMeEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = #"{"id":"me","name":"Me","email":"me@example.com","shouldChangePassword":true}"#.data(using: .utf8)!

        let user = try await client.currentUser()

        XCTAssertEqual(user.shouldChangePassword, true)

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/users/me")
    }

    // MARK: - Album update (cover) + album users

    private static let albumJSON = """
    {
      "id": "alb-1",
      "albumName": "Trip",
      "description": "",
      "createdAt": "2024-01-01T00:00:00.000Z",
      "updatedAt": "2024-01-01T00:00:00.000Z",
      "albumThumbnailAssetId": "a1",
      "shared": true,
      "hasSharedLink": false,
      "assetCount": 2,
      "isActivityEnabled": false,
      "albumUsers": [
        {"user": {"id": "me", "name": "Me", "email": "me@example.com", "profileImagePath": "", "avatarColor": "#FF0000", "profileChangedAt": "2024-01-01T00:00:00.000Z"}, "role": "owner"}
      ]
    }
    """

    func test_album_setCover_patchesThumbnailAssetId() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = Self.albumJSON.data(using: .utf8)!

        let album = try await client.updateAlbum(
            id: "alb-1",
            dto: UpdateAlbumDto(albumName: nil, description: nil, albumThumbnailAssetId: "a9", isActivityEnabled: nil, order: nil)
        )

        XCTAssertEqual(album.id, "alb-1")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PATCH")
        XCTAssertEqual(captured.url?.path, "/api/albums/alb-1")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""albumThumbnailAssetId":"a9""#), "cover id must be sent")
        XCTAssertFalse(body.contains("albumName"), "nil fields must be omitted")
    }

    func test_album_addUsers_hitsPutUsersEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = Self.albumJSON.data(using: .utf8)!

        _ = try await client.addUsersToAlbum(
            albumId: "alb-1",
            dto: AddUsersDto(albumUsers: [AlbumUserDto(userId: "u1", role: .viewer)])
        )

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/albums/alb-1/users")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""userId":"u1""#), "user id must be sent")
        XCTAssertTrue(body.contains(#""role":"viewer""#), "role must be sent")
    }

    func test_album_updateUserRole_hitsPutUserEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.updateAlbumUserRole(
            albumId: "alb-1",
            userId: "u1",
            dto: UpdateAlbumUserDto(role: .editor)
        )

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/albums/alb-1/user/u1")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""role":"editor""#))
    }

    func test_album_removeUser_hitsDeleteUserEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.removeUserFromAlbum(albumId: "alb-1", userId: "u1")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/albums/alb-1/user/u1")
    }

    // MARK: - P0 api-surface-expansion endpoints

    private static let personJSON = """
    {"id": "p1", "name": "Alice", "birthDate": "1990-01-01", "thumbnailPath": "/thumbs/p1.jpg", "isHidden": false, "color": "#FF0000", "isFavorite": true, "updatedAt": "2024-01-01T00:00:00.000Z"}
    """

    func test_P0_getPeople_hitsPeopleEndpointWithQuery() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = ("{\"people\": [\(Self.personJSON)], \"hidden\": 0, \"total\": 1, \"hasNextPage\": false}").data(using: .utf8)!

        let page = try await client.getPeople(page: 2, withHidden: true)

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.people.first?.name, "Alice")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/people")
        let query = captured.url?.query ?? ""
        XCTAssertTrue(query.contains("page=2"))
        XCTAssertTrue(query.contains("withHidden=true"))
    }

    func test_P0_mergePeople_usesPostMergeEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = "[{\"id\":\"p2\",\"success\":true}]".data(using: .utf8)!

        let results = try await client.mergePeople(ids: ["p2", "p3"], into: "p1")

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.success == true)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST", "merge is POST, not PUT")
        XCTAssertEqual(captured.url?.path, "/api/people/p1/merge")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""ids":["p2","p3"]"#), "source ids must be sent")
    }

    func test_P0_getMemories_hitsMemoriesEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id": "m1", "createdAt": "2024-01-01T00:00:00.000Z", "updatedAt": "2024-01-01T00:00:00.000Z", "memoryAt": "2023-06-15T00:00:00.000Z", "ownerId": "me", "type": "on_this_day", "data": {"year": 2023}, "assets": [], "isSaved": false}]
        """.data(using: .utf8)!

        let memories = try await client.getMemories()

        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.data.year, 2023)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/memories")
    }

    // MARK: - Memories CRUD (issue #15)

    func test_mem_getMemory_getsMemoryById() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "m1", "createdAt": "2024-01-01T00:00:00.000Z", "updatedAt": "2024-01-01T00:00:00.000Z", "memoryAt": "2023-06-15T00:00:00.000Z", "ownerId": "me", "type": "on_this_day", "data": {"year": 2023}, "assets": [], "isSaved": false}
        """.data(using: .utf8)!

        let memory = try await client.getMemory(id: "m1")

        XCTAssertEqual(memory.id, "m1")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/memories/m1")
    }

    /// The server exposes `put` on `/memories/{id}` and no PATCH — a PATCH is a
    /// 404, the same trap the shared-link edit had.
    func test_mem_updateMemory_putsIsSaved() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "m1", "createdAt": "2024-01-01T00:00:00.000Z", "updatedAt": "2024-01-01T00:00:00.000Z", "memoryAt": "2023-06-15T00:00:00.000Z", "ownerId": "me", "type": "on_this_day", "data": {"year": 2023}, "assets": [], "isSaved": true}
        """.data(using: .utf8)!

        let memory = try await client.updateMemory(id: "m1", dto: MemoryUpdateDto(isSaved: true))

        XCTAssertTrue(memory.isSaved)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/memories/m1")
        XCTAssertEqual(try decodedBody()["isSaved"] as? Bool, true)
    }

    func test_mem_deleteMemory_deletesById() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.deleteMemory(id: "m1")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/memories/m1")
    }

    /// `data`, `memoryAt` and `type` are all required by `MemoryCreateDto`, and
    /// the app sends `isSaved: true` so the server's 30-day cleanup cannot claim
    /// a memory the user asked for.
    func test_mem_createMemory_postsTheRequiredFields() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "new", "createdAt": "2024-01-01T00:00:00.000Z", "updatedAt": "2024-01-01T00:00:00.000Z", "memoryAt": "2019-05-04T00:00:00.000Z", "ownerId": "me", "type": "on_this_day", "data": {"year": 2019}, "assets": [], "isSaved": true}
        """.data(using: .utf8)!

        let memory = try await client.createMemory(dto: MemoryCreateDto(
            assetIds: ["a1", "a2"],
            data: OnThisDayDto(year: 2019),
            memoryAt: "2019-05-04T00:00:00.000Z",
            type: .on_this_day,
            isSaved: true
        ))

        XCTAssertEqual(memory.id, "new")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/memories")
        let body = try decodedBody()
        XCTAssertEqual(body["assetIds"] as? [String], ["a1", "a2"])
        XCTAssertEqual(body["memoryAt"] as? String, "2019-05-04T00:00:00.000Z")
        XCTAssertEqual(body["type"] as? String, "on_this_day")
        XCTAssertEqual((body["data"] as? [String: Any])?["year"] as? Int, 2019)
        XCTAssertEqual(body["isSaved"] as? Bool, true)
    }

    /// Both asset routes take `BulkIdsDto` (`{ids}`) — not the `AssetIdsDto`
    /// (`{assetIds}`) the shared-link route uses — and both answer
    /// `BulkIdResponseDto`, whose field is `id`.
    func test_mem_addAssetsToMemory_putsBulkIds() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id": "a1", "success": true}, {"id": "a2", "success": false, "error": "NO_PERMISSION"}]
        """.data(using: .utf8)!

        let results = try await client.addAssetsToMemory(id: "m1", assetIds: ["a1", "a2"])

        XCTAssertEqual(results.map(\.id), ["a1", "a2"])
        XCTAssertEqual(results[1].success, false)
        XCTAssertEqual(results[1].error, .noPermission, "memories answer BulkIdErrorReason, which is uppercase")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/memories/m1/assets")
        let body = try decodedBody()
        XCTAssertEqual(body["ids"] as? [String], ["a1", "a2"])
        XCTAssertNil(body["assetIds"], "this route takes ids, unlike the shared-link one")
    }

    func test_mem_removeAssetsFromMemory_deletesBulkIds() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id": "a1", "success": true}]
        """.data(using: .utf8)!

        let results = try await client.removeAssetsFromMemory(id: "m1", assetIds: ["a1"])

        XCTAssertEqual(results.count, 1)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/memories/m1/assets")
        XCTAssertEqual(try decodedBody()["ids"] as? [String], ["a1"])
    }

    func test_mem_getMemoriesStatistics_hitsStatistics() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = #"{"total": 12}"#.data(using: .utf8)!

        let stats = try await client.getMemoriesStatistics()

        XCTAssertEqual(stats.total, 12)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/memories/statistics")
    }

    func test_P0_getDuplicates_hitsDuplicatesEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"duplicateId": "d1", "assets": [], "suggestedKeepAssetIds": ["keep-1"]}]
        """.data(using: .utf8)!

        let duplicates = try await client.getDuplicates()

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates.first?.suggestedKeepAssetIds, ["keep-1"])
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.url?.path, "/api/duplicates")
    }

    /// `GET /api/partners` — `direction` is a **required** query param. Without
    /// it the server answers 400, which is what this client used to do (the app
    /// shipped a call with no query at all until 2026-09-13).
    func test_P0_getPartners_sendsRequiredDirection() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id": "u9", "name": "Pat", "email": "pat@test", "profileImagePath": "", "avatarColor": "#00FF00", "profileChangedAt": "2024-01-01T00:00:00.000Z", "inTimeline": true}]
        """.data(using: .utf8)!

        let incoming = try await client.getPartners(direction: .sharedWith)
        XCTAssertEqual(incoming.count, 1)
        XCTAssertTrue(incoming.first?.inTimeline == true)
        guard let incomingRequest = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(incomingRequest.httpMethod, "GET")
        XCTAssertEqual(incomingRequest.url?.path, "/api/partners")
        XCTAssertTrue(incomingRequest.url?.query?.contains("direction=shared-with") == true,
                      "direction is required — a direction-less call is a 400")

        CapturingURLProtocol.reset()
        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!
        _ = try await client.getPartners(direction: .sharedBy)
        guard let outgoingRequest = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertTrue(outgoingRequest.url?.query?.contains("direction=shared-by") == true,
                      "the two directions are distinct queries")
    }

    /// `POST /api/partners` — the server takes `{sharedWithId}`, a user id.
    func test_partners_createPartnerPostsSharedWithId() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 201
        CapturingURLProtocol.nextData = """
        {"id": "u2", "name": "Bob", "email": "bob@test", "profileImagePath": "", "avatarColor": "#FF0000", "profileChangedAt": "2024-01-01T00:00:00.000Z", "inTimeline": false}
        """.data(using: .utf8)!

        let created = try await client.createPartner(sharedWithId: "u2")

        XCTAssertEqual(created.id, "u2")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/partners")
        XCTAssertEqual(captured.url?.query, nil, "the id travels in the body, not the query")
        XCTAssertEqual(try decodedBody()["sharedWithId"] as? String, "u2")
    }

    /// `PUT /api/partners/{id}` — the timeline toggle.
    func test_P0_updatePartner_putsPartnerPath() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "p1", "name": "Pat", "email": "pat@test", "profileImagePath": "", "avatarColor": "#00FF00", "profileChangedAt": "2024-01-01T00:00:00.000Z", "inTimeline": true}
        """.data(using: .utf8)!

        _ = try await client.updatePartner(id: "p1", isInTimeline: true)

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/partners/p1")
        XCTAssertEqual(try decodedBody()["inTimeline"] as? Bool, true)
    }

    /// `DELETE /api/partners/{id}` — 204, no body to decode.
    func test_P0_removePartner_deletesPartnerPath() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204
        CapturingURLProtocol.nextData = Data()

        try await client.removePartner(id: "p1")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/partners/p1")
    }

    func test_P0_getActivities_hitsActivitiesEndpointWithQuery() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id": "a1", "createdAt": "2024-01-01T00:00:00.000Z", "type": "comment", "user": {"id": "u1", "name": "U", "email": "u@t", "profileImagePath": "", "avatarColor": "#000000", "profileChangedAt": "2024-01-01T00:00:00.000Z"}, "assetId": "as1", "comment": "Nice!"}]
        """.data(using: .utf8)!

        let activities = try await client.getActivities(albumId: "alb-1", assetId: "as1")

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.type, .comment)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/activities")
        let query = captured.url?.query ?? ""
        XCTAssertTrue(query.contains("albumId=alb-1"), "albumId is required")
        XCTAssertTrue(query.contains("assetId=as1"))
    }

    func test_P0_getServerStatistics_hitsStatisticsEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"photos": 100, "videos": 10, "usage": 1073741824, "usagePhotos": 1000000000, "usageVideos": 73741824, "usageByUser": []}
        """.data(using: .utf8)!

        let stats = try await client.getServerStatistics()

        XCTAssertEqual(stats.photos, 100)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/server/statistics")
    }

    /// `PATCH /api/shared-links/{id}` — the verb the server actually exposes
    /// (`@Patch(':id')`). The client sent `PUT` for months, which answered 404
    /// at runtime while the old test happily asserted the wrong verb.
    func test_SL_updateSharedLink_sendsSlugToPatchEndpoint() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "l1", "description": "Updated", "password": null, "userId": "me", "key": "a2V5", "type": "ALBUM", "createdAt": "2024-01-01T00:00:00.000Z", "expiresAt": null, "assets": [], "album": null, "allowUpload": true, "allowDownload": true, "showMetadata": true, "slug": "trip-2026"}
        """.data(using: .utf8)!

        let link = try await client.updateSharedLink(
            id: "l1",
            dto: SharedLinkEditDto(description: "Updated", slug: "trip-2026")
        )

        XCTAssertEqual(link.slug, "trip-2026")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PATCH")
        XCTAssertEqual(captured.url?.path, "/api/shared-links/l1")
        let body = try decodedBody()
        XCTAssertEqual(body["slug"] as? String, "trip-2026")
        XCTAssertEqual(body["description"] as? String, "Updated")
    }

    /// `POST /api/shared-links` carries the custom slug — the field the client
    /// never sent, so a custom URL could not be created at all.
    func test_SL_createSharedLink_sendsSlug() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id": "l1", "description": "Trip", "password": null, "userId": "me", "key": "a2V5", "type": "ALBUM", "createdAt": "2024-01-01T00:00:00.000Z", "expiresAt": null, "assets": [], "album": null, "allowUpload": true, "allowDownload": true, "showMetadata": true, "slug": "trip-2026"}
        """.data(using: .utf8)!

        let link = try await client.createSharedLink(dto: SharedLinkCreateDto(
            type: .album,
            albumId: "a1",
            description: "Trip",
            expiresAt: "2026-12-31T23:59:59.000Z",
            slug: "trip-2026"
        ))

        XCTAssertEqual(link.slug, "trip-2026")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/shared-links")
        let body = try decodedBody()
        XCTAssertEqual(body["slug"] as? String, "trip-2026")
        XCTAssertEqual(body["albumId"] as? String, "a1")
        XCTAssertEqual(body["expiresAt"] as? String, "2026-12-31T23:59:59.000Z")
    }

    /// `PUT /api/shared-links/{id}/assets` — the owner's add route. Its body is
    /// `AssetIdsDto` (`assetIds`, NOT the album routes' `ids`) and its response
    /// is `AssetIdsResponseDto` (`assetId`, and the **lowercase** error values
    /// of the deprecated enum — not `BulkIdResponseDto`'s).
    func test_SL_addAssetsToSharedLink_putsAssetIdsDto() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"assetId": "a1", "success": true}, {"assetId": "a2", "success": false, "error": "no_permission"}]
        """.data(using: .utf8)!

        let results = try await client.addAssetsToSharedLink(id: "l1", assetIds: ["a1", "a2"])

        XCTAssertEqual(results.map(\.assetId), ["a1", "a2"])
        XCTAssertEqual(results[0].error, nil)
        XCTAssertEqual(results[1].error, .noPermission)
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/shared-links/l1/assets")
        let body = try decodedBody()
        XCTAssertEqual(body["assetIds"] as? [String], ["a1", "a2"])
        XCTAssertNil(body["ids"], "this route takes assetIds, unlike the album routes")
    }

    func test_P0_bulkUpdateAssets_hitsPutAssets204() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(
            ids: ["a1", "a2"], dateTimeOriginal: nil, dateTimeRelative: nil, description: nil,
            isFavorite: nil, latitude: nil, longitude: nil, rating: nil, timeZone: nil,
            visibility: .archive, duplicateId: nil
        ))

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/assets")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains(#""ids":["a1","a2"]"#))
        XCTAssertTrue(body.contains(#""visibility":"archive""#))
    }

    func test_P0_timelineFilterExpansion_encodesNewParams() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 200

        _ = try await client.getTimeBuckets(
            isFavorite: nil, isTrashed: nil,
            personId: "p1", withPartners: true, visibility: "archive", withStacked: false, orderBy: nil
        )

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.url?.path, "/api/timeline/buckets")
        let query = captured.url?.query ?? ""
        XCTAssertTrue(query.contains("personId=p1"))
        XCTAssertTrue(query.contains("withPartners=true"))
        XCTAssertTrue(query.contains("visibility=archive"))
        XCTAssertTrue(query.contains("withStacked=false"))
        XCTAssertFalse(query.contains("isFavorite"), "nil filters must be omitted")
    }

    // OAuth served 404s while these pinned the wrong routes: Immich exposes
    // POST /api/oauth/authorize and POST /api/oauth/callback — there is no
    // /api/auth/oauth/* controller.
    func test_oauth_authorizePostsConfigDtoToOAuthController() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)

        CapturingURLProtocol.nextData = #"{"url":"https://sso.example.com/authorize?x=1"}"#.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 201

        let response = try await client.authorizeOAuth(
            redirectURI: "app.immich:///oauth-callback",
            state: "state-1",
            codeChallenge: "challenge-1"
        )

        XCTAssertEqual(response.url, "https://sso.example.com/authorize?x=1")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/oauth/authorize")
        let body = try decodedBody()
        XCTAssertEqual(body["redirectUri"] as? String, "app.immich:///oauth-callback")
        XCTAssertEqual(body["state"] as? String, "state-1")
        XCTAssertEqual(body["codeChallenge"] as? String, "challenge-1")
    }

    func test_oauth_callbackPostsCodeVerifierAndDecodesLoginResponse() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)

        CapturingURLProtocol.nextData = """
        {"accessToken":"jwt","userId":"u1","userEmail":"a@b.c","name":"Alice",
         "profileImagePath":"","isAdmin":false,"shouldChangePassword":false,"isOnboarded":true}
        """.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 201

        let response = try await client.exchangeOAuthCode(
            url: "app.immich:///oauth-callback?code=abc&state=state-1",
            state: "state-1",
            codeVerifier: "verifier-1"
        )

        XCTAssertEqual(response.accessToken, "jwt")
        XCTAssertEqual(response.userId, "u1")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/oauth/callback")
        let body = try decodedBody()
        XCTAssertEqual(body["url"] as? String, "app.immich:///oauth-callback?code=abc&state=state-1")
        XCTAssertEqual(body["state"] as? String, "state-1")
        XCTAssertEqual(body["codeVerifier"] as? String, "verifier-1")
    }

    // MARK: - Stacks (gap #1)

    /// The routes were pinned by names in the acceptance card; these four
    /// exercise them on a recorded transport so a wrong path or verb fails the
    /// suite instead of silently 404ing a live server (the OAuth-route defect
    /// this repo shipped once already).
    func test_stacks_searchStacksHitsGetStacks() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        [{"id":"s1","primaryAssetId":"a1","assets":[]}]
        """.data(using: .utf8)!

        let stacks = try await client.searchStacks(primaryAssetId: nil)

        XCTAssertEqual(stacks.map(\.id), ["s1"])
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/stacks")
        XCTAssertEqual(captured.url?.query, nil, "no filter unless asked")
    }

    func test_stacks_searchStacksEncodesPrimaryAssetFilter() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!

        _ = try await client.searchStacks(primaryAssetId: "asset-9")

        let query = CapturingURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("primaryAssetId=asset-9"))
    }

    func test_stacks_createPostsAssetIds() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id":"s1","primaryAssetId":"a1","assets":[]}
        """.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 201

        let stack = try await client.createStack(assetIds: ["a1", "a2"])

        XCTAssertEqual(stack.id, "s1")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.path, "/api/stacks")
        XCTAssertEqual(try decodedBody()["assetIds"] as? [String], ["a1", "a2"])
    }

    func test_stacks_updatePrimaryPutsStacksId() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = """
        {"id":"s1","primaryAssetId":"a2","assets":[]}
        """.data(using: .utf8)!

        let stack = try await client.updateStack(id: "s1", primaryAssetId: "a2")

        XCTAssertEqual(stack.primaryAssetId, "a2")
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.url?.path, "/api/stacks/s1")
        XCTAssertEqual(try decodedBody()["primaryAssetId"] as? String, "a2")
    }

    func test_stacks_deleteRemovesStack() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.deleteStack(id: "s1")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/stacks/s1")
    }

    func test_stacks_removeAssetHitsStackAssetsAnd() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextStatus = 204

        try await client.removeAssetFromStack(stackId: "s1", assetId: "a2")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.url?.path, "/api/stacks/s1/assets/a2")
    }

    /// `withStacked` is the switch that collapses stacks server-side — the
    /// timeline must send `true`, not only check the box in the query builder.
    func test_stacks_timelineRequestsStackedPrimaries() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!

        _ = try await client.getTimeBuckets(
            isFavorite: nil, isTrashed: nil, personId: nil,
            withPartners: nil, visibility: nil, withStacked: true, orderBy: nil
        )
        let bucketsQuery = CapturingURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(bucketsQuery.contains("withStacked=true"))

        CapturingURLProtocol.nextData = """
        {"id":[],"ownerId":[],"ratio":[],"isFavorite":[],"visibility":[],"isTrashed":[],
         "isImage":[],"thumbhash":[],"createdAt":[],"fileCreatedAt":[],"localOffsetHours":[],
         "duration":[],"livePhotoVideoId":[],"projectionType":[],"stack":[]}
        """.data(using: .utf8)!

        _ = try await client.getTimeBucket(
            timeBucket: "2024-07-01", personId: nil,
            withPartners: nil, visibility: nil, withStacked: true
        )
        let bucketQuery = CapturingURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(bucketQuery.contains("withStacked=true"))
    }

    /// RFC 7636: S256 challenge is base64url(SHA256(verifier)) with no padding,
    /// and stays stable for a given verifier.
    func test_pkceChallengeIsS256OfVerifier() {
        XCTAssertEqual(
            OAuthPKCE.challenge(for: "abc"),
            "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
        )
        let pkce = OAuthPKCE()
        XCTAssertEqual(pkce.codeChallenge, OAuthPKCE.challenge(for: pkce.codeVerifier))
        XCTAssertFalse(pkce.codeChallenge.contains("="), "base64url must be unpadded")
        XCTAssertFalse(pkce.codeChallenge.contains("+"))
        XCTAssertFalse(pkce.codeChallenge.contains("/"))
        XCTAssertNotEqual(OAuthPKCE().state, OAuthPKCE().state, "state must be fresh per attempt")
    }

    // MARK: - Opening a shared link (issue #22 — visitor side)

    /// A visitor request must go out **without** a bearer token: the credential
    /// travels in the query (`?key=`) and the server authenticates on it
    /// (`AuthService.validate`). Sending `Authorization` here would either fail
    /// or, worse, silently read the link as the signed-in user.
    func test_SLV_getMine_sendsKeyWithoutBearer() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: "signed-in-token")
        CapturingURLProtocol.nextData = Self.sharedLinkJSON(key: "a2V5")

        let link = try await client.getSharedLinkMine(.key("a2V5"))

        XCTAssertEqual(link.key, "a2V5")
        guard let request = CapturingURLProtocol.lastRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/shared-links/me")
        XCTAssertEqual(request.url?.query, "key=a2V5")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "a shared link is read as a visitor, never as the signed-in session")
        XCTAssertNil(request.value(forHTTPHeaderField: ImmichHeader.cookie),
                     "no login has happened yet, so there is no cookie to send")
    }

    /// A slug link addresses the same route with `slug=` — the credential enum
    /// decides which one goes out, and the server reads either.
    func test_SLV_getMine_sendsSlugWhenTheLinkHasOne() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)
        CapturingURLProtocol.nextData = Self.sharedLinkJSON(key: "a2V5")

        _ = try await client.getSharedLinkMine(.slug("my-album"))

        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.path, "/api/shared-links/me")
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url?.query, "slug=my-album")
    }

    /// The login posts `{password}` and — this is the whole point of the call —
    /// keeps the session cookie the server answers with, so the *next* request
    /// can pass `GET /shared-links/me` on a protected link. Without the cookie
    /// the visit can never get past "Password required" (the web client relies
    /// on the browser storing exactly this one).
    func test_SLV_login_postsPasswordAndKeepsCookie() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)
        CapturingURLProtocol.nextData = Self.sharedLinkJSON(key: "a2V5")
        CapturingURLProtocol.nextStatus = 201
        CapturingURLProtocol.nextHeaders = [
            "Content-Type": "application/json",
            "Set-Cookie": "\(ImmichCookie.sharedLinkToken)=tok123; Path=/; HttpOnly; SameSite=Lax"
        ]

        _ = try await client.loginToSharedLink(.slug("secured"), password: "hunter2")

        guard let loginRequest = CapturingURLProtocol.lastRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(loginRequest.httpMethod, "POST")
        XCTAssertEqual(loginRequest.url?.path, "/api/shared-links/login")
        XCTAssertEqual(loginRequest.url?.query, "slug=secured")
        XCTAssertNil(loginRequest.value(forHTTPHeaderField: "Authorization"))
        let body = try decodedBody()
        XCTAssertEqual(body["password"] as? String, "hunter2")

        CapturingURLProtocol.reset()
        CapturingURLProtocol.nextData = Self.sharedLinkJSON(key: "a2V5")
        _ = try await client.getSharedLinkMine(.slug("secured"))

        guard let replay = CapturingURLProtocol.lastRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(replay.value(forHTTPHeaderField: ImmichHeader.cookie),
                       "\(ImmichCookie.sharedLinkToken)=tok123",
                       "the login cookie must be replayed, or the link stays locked")
        XCTAssertNil(replay.value(forHTTPHeaderField: "Authorization"))
    }

    /// A 401 on this path is about the *link*, not the session — so it must not
    /// reach `authDelegate`, which resets the whole app session (FM-4). The raw
    /// server message is preserved because it is the only way to tell "needs a
    /// password" from "dead link".
    func test_SLV_getMine_surfacesTheLinksOwn401WithoutSigningOut() async throws {
        let spy = UnauthorizedSpy()
        let client = ImmichAPIClient(session: makeMockedSession())
        client.authDelegate = spy
        client.configure(baseURL: URL(string: "https://example.com")!, token: "signed-in-token")
        CapturingURLProtocol.nextStatus = 401
        CapturingURLProtocol.nextData = #"{"message":"Password required","error":"Unauthorized","statusCode":401}"#
            .data(using: .utf8)!

        do {
            _ = try await client.getSharedLinkMine(.key("a2V5"))
            XCTFail("a 401 must throw")
        } catch let error as APIError {
            guard case .serverError(let status, let body) = error else {
                return XCTFail("expected .serverError, got \(error)")
            }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(SharedLinkViewerViewModel.classify(error), .passwordRequired)
            XCTAssertTrue(body?.contains("Password required") == true)
        }
        XCTAssertEqual(spy.count, 0, "a link's 401 must never sign the user out")
    }

    /// An album link's assets cannot come from the link DTO — `AlbumResponseDto`
    /// has no `assets` array — and the server refuses an unfiltered metadata
    /// search under shared-link auth, so `albumIds` is required, not optional.
    func test_SLV_albumAssets_searchesByAlbumIdWithKey() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)
        CapturingURLProtocol.nextData = #"{"assets":{"count":0,"items":[],"nextPage":null}}"#
            .data(using: .utf8)!

        _ = try await client.getSharedLinkAlbumAssets(.key("a2V5"), albumId: "alb-1", page: 2, size: 100)

        guard let request = CapturingURLProtocol.lastRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/search/metadata")
        XCTAssertEqual(request.url?.query, "key=a2V5")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try decodedBody()
        XCTAssertEqual(body["albumIds"] as? [String], ["alb-1"])
        XCTAssertEqual(body["page"] as? Int, 2)
        XCTAssertEqual(body["size"] as? Int, 100)
    }

    /// A guest upload is a multipart POST carrying the credential in the query —
    /// the route the server guards with `requireUploadAccess` (a bare 401 when
    /// the link has `allowUpload: false`).
    func test_SLV_upload_postsMultipartWithKeyAndNoBearer() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("slv-\(UUID().uuidString).jpg")
        try Data("jpeg-bytes".utf8).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        CapturingURLProtocol.nextData = #"{"id":"asset-new","status":"created"}"#.data(using: .utf8)!
        CapturingURLProtocol.nextStatus = 201

        let uploaded = try await client.uploadAssetToSharedLink(
            fileURL: photo,
            filename: "holiday.jpg",
            fileCreatedAt: "2026-09-13T00:00:00.000Z",
            fileModifiedAt: "2026-09-13T00:00:00.000Z",
            checksum: "c2hhMQ==",
            deviceAssetId: "dev-asset",
            deviceId: "dev",
            credential: .key("a2V5")
        )

        XCTAssertEqual(uploaded.id, "asset-new")
        guard let request = CapturingURLProtocol.lastRequest else { return XCTFail("no request captured") }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/assets")
        XCTAssertEqual(request.url?.query, "key=a2V5")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: ImmichHeader.checksum), "c2hhMQ==")
        let body = String(decoding: CapturingURLProtocol.lastBody, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"assetData\""))
        XCTAssertTrue(body.contains("name=\"deviceAssetId\""))
    }

    /// `requireUploadAccess` answers a bare 401 when the link forbids uploads.
    func test_SLV_upload_refusalKeepsTheRawStatusForTheCaller() async throws {
        let client = ImmichAPIClient(session: makeMockedSession())
        client.configure(baseURL: URL(string: "https://example.com")!, token: nil)
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("slv-\(UUID().uuidString).jpg")
        try Data("jpeg-bytes".utf8).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        CapturingURLProtocol.nextStatus = 401
        CapturingURLProtocol.nextData = #"{"message":"Unauthorized","error":"Unauthorized","statusCode":401}"#
            .data(using: .utf8)!

        do {
            _ = try await client.uploadAssetToSharedLink(
                fileURL: photo, filename: "holiday.jpg",
                fileCreatedAt: "2026-09-13T00:00:00.000Z", fileModifiedAt: "2026-09-13T00:00:00.000Z",
                checksum: "c2hhMQ==", deviceAssetId: "dev-asset", deviceId: "dev", credential: .key("a2V5")
            )
            XCTFail("a 401 must throw")
        } catch let error as APIError {
            XCTAssertTrue(SharedLinkViewerViewModel.isUploadRejection(error))
        }
    }

    // Folder view (gap G11): GET /api/view/folder carries the path verbatim as
    // a query item — a client-side "tidying" of the leading slash would make the
    // server answer with the wrong level, and nothing else would catch it.
    func test_folderView_sendsThePathQueryItemVerbatim() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = "[]".data(using: .utf8)!

        _ = try await client.getFolderAssets(path: "/mnt/media/Photos 2024")

        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/view/folder")
        let components = URLComponents(url: try XCTUnwrap(captured.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "path", value: "/mnt/media/Photos 2024")])
    }

    /// `GET /api/view/folder/unique-paths` takes no parameter at all.
    func test_folderView_uniquePathsCarriesNoParameter() async throws {
        let session = makeMockedSession()
        let client = ImmichAPIClient(session: session)
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")

        CapturingURLProtocol.nextData = #"["/mnt/media/Photos",""]"#.data(using: .utf8)!

        let paths = try await client.getUniqueFolderPaths()

        XCTAssertEqual(paths, ["/mnt/media/Photos", ""])
        guard let captured = CapturingURLProtocol.lastRequest else {
            return XCTFail("no request captured")
        }
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.path, "/api/view/folder/unique-paths")
        XCTAssertNil(captured.url?.query, "no query params expected")
    }

    /// Minimal `SharedLinkResponseDto` the visitor routes decode.
    private static func sharedLinkJSON(key: String) -> Data {
        """
        {"id":"link-1","description":"Holidays","password":null,"userId":"owner","key":"\(key)",
         "type":"ALBUM","createdAt":"2024-01-01T00:00:00.000Z","expiresAt":null,"assets":[],
         "album":{"id":"alb-1","albumName":"Holidays","description":"","createdAt":"2024-01-01T00:00:00.000Z",
                  "updatedAt":"2024-01-01T00:00:00.000Z","albumThumbnailAssetId":null,"shared":true,
                  "hasSharedLink":true,"assetCount":2,"isActivityEnabled":false,"order":null,
                  "albumUsers":[]},
         "allowUpload":true,"allowDownload":true,"showMetadata":true,"slug":null}
        """.data(using: .utf8)!
    }
}

/// Counts `didReceiveUnauthorized` notifications so a test can prove a
/// visitor-side 401 never resets the app session.
private final class UnauthorizedSpy: AuthSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func didReceiveUnauthorized() { lock.lock(); _count += 1; lock.unlock() }
}
