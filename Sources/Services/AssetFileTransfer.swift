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
        if let originalName, let safe = safeFileName(originalName) {
            let base = (safe as NSString).deletingPathExtension
            return base.isEmpty ? safe : base
        }
        return "Photo-\(datePrefix)"
    }

    /// A name that is one path component and nothing else: what is left of
    /// `name` after its last separator, without control characters. Nil when
    /// nothing usable is left (empty, `.`, `..`).
    ///
    /// The server's `originalFileName` is whatever the person who uploaded the
    /// photo sent — a partner, a member of a shared album. Joined to a folder
    /// as it comes, `../../Library/x` would land the file outside that folder.
    static func safeFileName(_ name: String) -> String? {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(
            last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned
    }

    /// `safeFileName`, or a fixed name when nothing usable is left: the last
    /// gate before a name the caller built is joined to a folder.
    private static func component(_ name: String) -> String {
        safeFileName(name) ?? "file"
    }

    /// Writes bytes into a UNIQUE temp directory so the file's basename is the
    /// real name — no `immich-share-UUID-` prefix pollutes the filename.
    static func writeTempFile(data: Data, name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(component(name))
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Moves a file a transport streamed to disk into a UNIQUE temp directory,
    /// under its real name, for the share sheet. The body is never loaded in
    /// memory. On failure the directory is removed and the source is left where
    /// it was (the caller deletes it).
    static func moveToShareFile(_ source: URL, name: String, fileManager: FileManager = .default) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-share-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(component(name))
        do {
            try fileManager.moveItem(at: source, to: fileURL)
        } catch {
            try? fileManager.removeItem(at: dir)
            throw error
        }
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