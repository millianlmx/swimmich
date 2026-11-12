import CryptoKit
import Foundation
import os

/// One asset as the upload route answers it (`AssetMediaResponseDto`):
/// `status` is `created` for a fresh asset and `duplicate` when the server
/// already held that exact file — both are successes, the second one just
/// reuses an existing id.
public struct SharedUploadResult: Decodable, Sendable, Equatable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }

    public var isDuplicate: Bool { status == "duplicate" }
}

/// The slice of `AlbumResponseDto` the sheet needs: the id it will attach to,
/// and the name it shows. The server calls the field `albumName`, not `name`.
public struct ShareAlbum: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let albumName: String

    public init(id: String, albumName: String) {
        self.id = id
        self.albumName = albumName
    }
}

public enum ShareUploadError: Error, Equatable {
    /// The stored session's `baseURL` did not parse.
    case invalidServerURL
    /// The staged file is gone before the body could be assembled.
    case unreadableFile
    /// `URLSession` failed before any response (offline, TLS, timeout…).
    case transport(Int)
    /// Non-2xx answer, with the server's own message when it sent one.
    case server(Int, String)
}

/// What the share sheet is allowed to ask of a server. Deliberately narrow: the
/// extension must not carry the app's `ImmichClient`, its DTOs or its
/// `DependencyContainer` (it links `ImmichSharedKit` and nothing else).
public protocol ShareUploading: Sendable {
    func upload(
        fileURL: URL,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        duration: Int?,
        deviceAssetId: String
    ) async throws -> SharedUploadResult

    func albums() async throws -> [ShareAlbum]

    func addAssets(_ ids: [String], toAlbum albumId: String) async throws
}

/// Talks to an Immich server from a process that is not the app.
///
/// Three things make this different from a plain `URLSession` call, and all
/// three are already solved in the kit: the session comes from
/// `URLSessionWidgetTransport.interactive()` — the transport built in
/// `WidgetDataProvider.swift` for the widget's own out-of-process fetches, so a
/// self-signed server stays reachable exactly as it does in a widget — the body
/// is streamed from disk through `MultipartBody` so a video never sits in
/// memory, and the caller supplies a `deviceId` out of the shared keychain
/// session because the app's `DeviceIdentity` lives in the app's defaults.
public struct SharedUploadClient: ShareUploading {
    private let baseURL: String
    private let token: String
    private let deviceId: String
    /// The server's custom headers, read from the shared session by the caller.
    private let customHeaders: [CustomHTTPHeader]
    private let session: URLSession
    private let logger = Logger(subsystem: "app.immich.swiftui", category: "share-upload")
    /// Where the failure line goes; `nil` = `os.Logger` in clear. The line only
    /// ever carries the numeric code of the transport error (never its text,
    /// which may quote the server's URL). A test injects a collector.
    private let publicLog: (@Sendable (String) -> Void)?

    public init(
        baseURL: String,
        token: String,
        deviceId: String,
        customHeaders: [CustomHTTPHeader] = [],
        session: URLSession = URLSessionWidgetTransport.interactive(),
        publicLog: (@Sendable (String) -> Void)? = nil
    ) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.token = token
        self.deviceId = deviceId
        self.customHeaders = customHeaders
        self.session = session
        self.publicLog = publicLog
    }

    /// Ends this client's session. The share extension builds one client per
    /// share and calls this when it leaves, so a second share served by the same
    /// process starts a fresh session — and a fresh TLS handshake, which
    /// presents whatever client certificate is installed by then.
    public func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - Upload

    public func upload(
        fileURL: URL,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        duration: Int?,
        deviceAssetId: String
    ) async throws -> SharedUploadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ShareUploadError.unreadableFile
        }

        // Same field set the app's own upload sends minus the fields a share
        // cannot know (`isFavorite`/`visibility` are explicitly sent as the
        // defaults: the server reads an absent `isFavorite` as false anyway, but
        // sending it keeps a shared asset indistinguishable from a backed-up
        // one in the library).
        var fields: [(name: String, value: String)] = [
            ("fileCreatedAt", SharedUploadDateFormat.string(from: createdAt)),
            ("fileModifiedAt", SharedUploadDateFormat.string(from: modifiedAt)),
            ("deviceAssetId", deviceAssetId),
            ("deviceId", deviceId),
            ("isFavorite", "false"),
        ]
        if let duration {
            fields.append(("duration", String(duration)))
        }

        var multipart = MultipartBody()
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-share-\(UUID().uuidString).multipart")
        try multipart.writeStreamed(
            fileField: ("assetData", filename, "application/octet-stream", fileURL),
            fields: fields,
            to: bodyURL
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        // The token and the server's custom headers come with the base request.
        var request = try request(.POST, path: "api/assets")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        // Drives the server's dedup table: the same bytes shared twice answer
        // `status: duplicate` instead of storing the asset twice.
        request.setValue(try Self.sha1Base64(of: fileURL), forHTTPHeaderField: "x-immich-checksum")

        let (data, response) = try await send(request, fromFile: bodyURL)
        try Self.validate(response, data: data)
        do {
            return try JSONDecoder().decode(SharedUploadResult.self, from: data)
        } catch {
            throw ShareUploadError.server(response.statusCode, Self.message(from: data))
        }
    }

    // MARK: - Albums

    public func albums() async throws -> [ShareAlbum] {
        let request = try request(.GET, path: "api/albums")
        let (data, response) = try await send(request, fromFile: nil)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode([ShareAlbum].self, from: data)
    }

    public func addAssets(_ ids: [String], toAlbum albumId: String) async throws {
        guard !ids.isEmpty else { return }
        var request = try request(.PUT, path: "api/albums/\(albumId)/assets")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BulkIds(ids: ids))
        let (data, response) = try await send(request, fromFile: nil)
        try Self.validate(response, data: data)
    }

    /// `BulkIdsDto`: `{"ids": [...]}`.
    private struct BulkIds: Encodable {
        let ids: [String]
    }

    // MARK: - Transport

    private func request(_ method: HTTPMethod, path: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/\(path)") else {
            throw ShareUploadError.invalidServerURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        ServerRequestAuthorization.apply(token: token, custom: customHeaders, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Extensions are killed quickly: fail loudly rather than hang past the
        // host's patience. `WidgetDataProvider.interactive()` already caps this,
        // but the request keeps its own ceiling so an injected session cannot
        // stretch it.
        request.timeoutInterval = 60
        return request
    }

    private enum HTTPMethod: String {
        case GET, POST, PUT
    }

    /// `fromFile` streams an on-disk body with `uploadTask`, which keeps peak
    /// memory at one chunk of the file even for a video; a nil body goes
    /// through `data(for:)`.
    private func send(_ request: URLRequest, fromFile fileURL: URL?) async throws -> (Data, HTTPURLResponse) {
        var payload: Data
        var raw: URLResponse
        do {
            if let fileURL {
                let (data, response) = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: ShareUploadError.transport(-1))
                        }
                    }
                    task.resume()
                }
                payload = data
                raw = response
            } else {
                (payload, raw) = try await session.data(for: request)
            }
        } catch let error as ShareUploadError {
            throw error
        } catch {
            let code = (error as NSError).code
            // An extension that fails silently is worse than one that fails
            // loudly: this line is what a `log stream` on device shows when a
            // share produces no visible error at all.
            let line = "share upload transport failed: \(code)"
            if let publicLog {
                publicLog(line)
            } else {
                logger.error("\(line, privacy: .public)")
            }
            throw ShareUploadError.transport(code)
        }
        guard let http = raw as? HTTPURLResponse else {
            // Not an HTTP answer at all — defensive: every route here is http(s).
            throw ShareUploadError.transport(-1)
        }
        return (payload, http)
    }

    private static func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw ShareUploadError.server(response.statusCode, message(from: data))
        }
    }

    /// The server answers `{"message": "…"}` on an error; fall back to the raw
    /// body so the sheet never shows an empty banner.
    private static func message(from data: Data) -> String {
        struct ErrorBody: Decodable { let message: String }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data) { return body.message }
        let raw = String(decoding: data.prefix(300), as: UTF8.self)
        return raw.isEmpty ? "The server refused the request." : raw
    }

    /// `base64(SHA1(file))`, streamed in 1 MiB chunks: a whole-file `hash(data:)`
    /// would pull a video into memory for nothing.
    private static func sha1Base64(of fileURL: URL) throws -> String {
        var hasher = Insecure.SHA1()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }
}

/// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, the shape the server emits and the app sends
/// (Node's `Date.toISOString()`). The kit cannot reach the app's `ISO8601`
/// helper — a different module — so it carries its own copy of the format.
private enum SharedUploadDateFormat {
    nonisolated(unsafe) static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}
