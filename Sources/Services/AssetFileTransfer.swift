import Foundation

/// File-transfer helpers shared by the viewer's system share sheet and the
/// save-to-photos / download-to-files flows (single source of truth for the
/// temp-file + naming conventions).
enum AssetFileTransfer {

    /// Maps a MIME type (or falls back to `jpg`) to a file extension so the
    /// system resolves the correct UTI for the QuickLook preview.
    static func fileExtension(forMime mime: String?) -> String {
        guard let mime else { return "jpg" }
        switch mime.lowercased() {
        case let m where m.contains("png"): return "png"
        case let m where m.contains("webp"): return "webp"
        case let m where m.contains("heic"), let m where m.contains("heif"): return "heic"
        case let m where m.contains("gif"): return "gif"
        case let m where m.contains("avif"): return "avif"
        case let m where m.contains("mp4"): return "mp4"
        case let m where m.contains("quicktime"): return "mov"
        case let m where m.contains("mpeg"): return "mpg"
        case let m where m.contains("jxl"): return "jxl"
        default: return "jpg"
        }
    }

    /// Extension of the file the native share sheet hands over. It follows the
    /// bytes actually shared (the preview's `Content-Type`), and only falls back
    /// to the original's MIME when the response carried none.
    static func sharedFileExtension(sharedContentType: String?, originalMime: String?) -> String {
        fileExtension(forMime: sharedContentType ?? originalMime)
    }

    /// The transfer file's base name (no extension): the server's original
    /// file name stripped of its extension, else a readable date-based fallback
    /// ("Photo-yyyy-MM-dd").
    static func baseName(originalName: String?, datePrefix: String) -> String {
        if let originalName, !originalName.isEmpty {
            let base = (originalName as NSString).deletingPathExtension
            return base.isEmpty ? originalName : base
        }
        return "Photo-\(datePrefix)"
    }

    /// Writes bytes into a UNIQUE temp directory so the file's basename is the
    /// real name — no `immich-share-UUID-` prefix pollutes the filename.
    static func writeTempFile(data: Data, name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(name)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Downloads URL-requested bytes with an optional session token and the
    /// server's custom headers, verifying a 2xx status and non-empty payload.
    /// Returns bytes + Content-Type.
    static func fetchData(
        from url: URL,
        token: String?,
        session: URLSession,
        customHeaders: any CustomHeadersProviding = CustomHeadersRegistry.shared
    ) async throws -> (Data, String?) {
        var request = URLRequest(url: url)
        ServerRequestAuthorization.apply(token: token, custom: customHeaders.headers(for: url), to: &request)
        let (data, response) = try await ServerRedirectTaskDelegate.data(for: request, on: session)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode, nil)
        }
        guard !data.isEmpty else {
            throw APIError.decoding("Downloaded payload is empty")
        }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return (data, contentType)
    }
}