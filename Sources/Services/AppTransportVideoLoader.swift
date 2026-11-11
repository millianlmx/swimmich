import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves AVFoundation's byte-range requests through the app's own `URLSession`
/// (L-10).
///
/// AVFoundation opens its own connections for a media URL: they apply neither
/// the app's server-trust rule nor a TLS client certificate. For a server that
/// has a certificate attached, the player is given a URL on a private scheme
/// (`swimmich-https` / `swimmich-http`) that AVFoundation cannot load itself,
/// so it asks this delegate for every byte range, and the ranges are fetched
/// with `ServerSessions.video`. The session is read again for every request —
/// AVFoundation keeps asking throughout playback, including after a session
/// renewal.
final class AppTransportVideoLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let httpsScheme = "swimmich-https"
    static let httpScheme = "swimmich-http"

    let queue = DispatchQueue(label: "app.immich.swiftui.video-loader")

    private let session: @Sendable () -> URLSession
    private let token: String?
    private let customHeaders: any CustomHeadersProviding
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        session: @escaping @Sendable () -> URLSession,
        token: String?,
        customHeaders: any CustomHeadersProviding = NoCustomHeaders()
    ) {
        self.session = session
        self.token = token
        self.customHeaders = customHeaders
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    // MARK: Pure helpers

    /// The URL AVFoundation is given: the same URL on the private scheme.
    static func loaderURL(for url: URL) -> URL? {
        swapScheme(of: url, from: ["https": httpsScheme, "http": httpScheme])
    }

    /// The URL to fetch for a request AVFoundation made on the private scheme.
    static func networkURL(for loaderURL: URL) -> URL? {
        swapScheme(of: loaderURL, from: [httpsScheme: "https", httpScheme: "http"])
    }

    private static func swapScheme(of url: URL, from table: [String: String]) -> URL? {
        guard let scheme = url.scheme?.lowercased(), let replacement = table[scheme],
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = replacement
        return components.url
    }

    /// `Range` header value: `bytes=<o>-` to the end of the resource, otherwise
    /// `bytes=<o>-<o+length-1>`.
    static func rangeHeader(offset: Int64, length: Int, toEnd: Bool) -> String {
        toEnd ? "bytes=\(offset)-" : "bytes=\(offset)-\(offset + Int64(max(length, 1)) - 1)"
    }

    /// The `total` of `Content-Range: bytes a-b/total`; nil for `*` or any
    /// malformed value.
    static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        let total = contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(total)
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requested = loadingRequest.request.url,
              let url = Self.networkURL(for: requested)
        else { return false }

        var request = URLRequest(url: url)
        ServerRequestAuthorization.apply(token: token, custom: customHeaders.headers(for: url), to: &request)
        let range: (offset: Int64, length: Int, toEnd: Bool)
        if let data = loadingRequest.dataRequest {
            range = (data.requestedOffset, data.requestedLength, data.requestsAllDataToEndOfResource)
        } else {
            // Only the content information: two bytes are enough to read the
            // total length out of `Content-Range`.
            range = (0, 2, false)
        }
        request.setValue(Self.rangeHeader(offset: range.offset, length: range.length, toEnd: range.toEnd),
                         forHTTPHeaderField: "Range")

        let identifier = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            await self?.load(loadingRequest, request: request, offset: range.offset, length: range.length, toEnd: range.toEnd)
            self?.forget(identifier)
        }
        lock.lock()
        tasks[identifier] = task
        lock.unlock()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
    }

    private func forget(_ identifier: ObjectIdentifier) {
        lock.lock()
        tasks[identifier] = nil
        lock.unlock()
    }

    // MARK: Loading

    private func load(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        request: URLRequest,
        offset: Int64,
        length: Int,
        toEnd: Bool
    ) async {
        do {
            let (bytes, response) = try await session().bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                throw http.statusCode == 401 ? APIError.unauthorized : APIError.serverError(http.statusCode, nil)
            }
            let partial = http.statusCode == 206

            if let info = loadingRequest.contentInformationRequest {
                let mime = http.mimeType ?? "video/mp4"
                info.contentType = UTType(mimeType: mime)?.identifier ?? UTType.mpeg4Movie.identifier
                if let total = Self.totalLength(contentRange: http.value(forHTTPHeaderField: "Content-Range")) {
                    info.contentLength = total
                } else if !partial, http.expectedContentLength > 0 {
                    info.contentLength = http.expectedContentLength
                }
                let acceptsRanges = http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") ?? false
                info.isByteRangeAccessSupported = partial || acceptsRanges
            }

            if let dataRequest = loadingRequest.dataRequest {
                // A server that ignored `Range` answers 200 with the whole body:
                // skip up to the requested offset, then stop at the length.
                var toSkip: Int64 = partial ? 0 : offset
                var remaining: Int64? = toEnd ? nil : Int64(length)
                var chunk = Data()
                chunk.reserveCapacity(Self.chunkSize)
                for try await byte in bytes {
                    if Task.isCancelled { return }
                    if toSkip > 0 { toSkip -= 1; continue }
                    chunk.append(byte)
                    if let left = remaining {
                        remaining = left - 1
                        if left - 1 <= 0 { break }
                    }
                    if chunk.count >= Self.chunkSize {
                        dataRequest.respond(with: chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { dataRequest.respond(with: chunk) }
            }
            if Task.isCancelled { return }
            loadingRequest.finishLoading()
        } catch {
            if Task.isCancelled { return }
            loadingRequest.finishLoading(with: error)
        }
    }

    private static let chunkSize = 64 * 1024
}
