import Foundation

/// Drives the public shared-link viewer (issue #22): opening a link someone
/// sent, unlocking it with its password, listing what it contains and — when the
/// link allows it — adding a photo to it.
///
/// Everything here runs as a **visitor**, not as the signed-in user: the client
/// calls go out without a bearer token, carrying the link's `key`/`slug`, and
/// their failures are read as facts about the link (`SharedLinkViewerViewModel.Failure`).
@Observable
@MainActor
final class SharedLinkViewerViewModel {

    /// What the screen shows. One case per thing the visitor can be looking at,
    /// so an impossible combination (a password prompt with no link) cannot be
    /// represented.
    enum Phase: Equatable {
        /// Nothing loaded yet — the visitor types or pastes a link.
        case entry
        /// The link demands a password before it shows anything.
        case passwordRequired
        case loading
        case opened
        /// 401 on a link that is not asking for a password: revoked, expired,
        /// or a key this server has never issued.
        case deadLink
        case failed(String)
    }

    enum UploadState: Equatable {
        case idle
        case uploading
        case done
        case failed(String)
    }

    /// Page size for an album link's asset list. The server caps `size` at
    /// 1000; 100 keeps a first paint light and the pagination honest.
    static let albumPageSize = 100

    private let client: any ImmichClient
    /// Server the visitor is connected to — the base every asset URL of this
    /// screen is built against.
    let baseURL: URL
    /// `ServerConfigDto.externalDomain` — the public domain the server
    /// advertises. A link received from this instance may name either that
    /// domain or the API host; both count as "this server".
    private let externalDomain: String

    /// The visitor's input, bound to the field.
    var linkText = ""
    var password = ""

    private(set) var phase: Phase = .entry
    /// Inline feedback for the entry and password forms — never a popup (PRD
    /// §5.10: errors render in context).
    var message: String?
    private(set) var link: SharedLinkResponseDto?
    private(set) var assets: [AssetReactItem] = []
    private(set) var credential: SharedLinkCredential?
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    var uploadState: UploadState = .idle

    /// Next page to request for an album link; `nil` before the first call.
    private var nextPage: Int?
    /// Ids already in `assets`, so a page overlapping the previous one cannot
    /// duplicate a cell (`Identifiable` ids must stay unique in a `ForEach`).
    private var loadedIds: Set<String> = []

    init(client: any ImmichClient, baseURL: URL, externalDomain: String = "") {
        self.client = client
        self.baseURL = baseURL
        self.externalDomain = externalDomain
    }

    /// The one album a shared link can point at, when it is an album link.
    var albumId: String? { link?.album?.id }

    var canUpload: Bool { link?.allowUpload == true }

    /// Human title of what is open: the album's name, the link's description, or
    /// the bare asset count.
    var title: String {
        if let album = link?.album { return album.albumName }
        if let description = link?.description, !description.isEmpty { return description }
        let count = assets.count
        return count == 1 ? "1 photo" : "\(count) photos"
    }

    /// Live URL of what is open, for the ShareLink / pasteboard affordances.
    var publicURL: URL? {
        guard let link else { return nil }
        return SharedLinkURL(serverURL: baseURL, externalDomain: externalDomain)
            .url(slug: link.slug, key: link.key)
    }

    // MARK: - Opening

    /// Parses what the visitor typed and loads the link it names.
    func openLink() async {
        message = nil
        uploadState = .idle

        guard let reference = SharedLinkURL.reference(from: linkText) else {
            message = String(localized: "That does not look like a shared link. Paste the link you received, or its key.")
            return
        }
        if let host = reference.host, !hostMatches(host) {
            message = String(localized: "That link belongs to \(host). Sign in to that server to open it.")
            return
        }

        credential = reference.credential
        password = ""
        await load()
    }

    /// Loads (or reloads) the current link. A 401 asking for a password moves
    /// the screen to the password phase; any other 401 means the link is dead.
    func load() async {
        guard let credential else { return }
        phase = .loading
        message = nil
        do {
            let fetched = try await client.getSharedLinkMine(credential)
            await apply(fetched)
        } catch {
            handle(error, on: .readLink)
        }
    }

    /// Exchanges the typed password for the link's session cookie and shows the
    /// link. A wrong password stays on the prompt with the server's own verdict.
    func submitPassword() async {
        guard let credential else { return }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = String(localized: "Enter the password you were given with this link.")
            return
        }
        phase = .loading
        message = nil
        do {
            let fetched = try await client.loginToSharedLink(credential, password: password)
            await apply(fetched)
        } catch {
            handle(error, on: .login)
        }
    }

    /// Back to the link field — the visitor wants to open a different link.
    func reset() {
        link = nil
        assets = []
        credential = nil
        linkText = ""
        password = ""
        nextPage = nil
        loadedIds = []
        hasMore = false
        message = nil
        uploadState = .idle
        phase = .entry
    }

    private func apply(_ fetched: SharedLinkResponseDto) async {
        link = fetched
        loadedIds = []
        // An INDIVIDUAL link inlines its assets in the DTO — no second call. An
        // ALBUM link cannot: `AlbumResponseDto` carries no assets, the count on
        // it is server-side metadata only.
        assets = fetched.assets.map(AssetReactItem.init(from:))
        loadedIds = Set(assets.map(\.id))
        nextPage = fetched.album == nil ? nil : 1
        hasMore = fetched.album != nil
        phase = .opened
        if fetched.album != nil { await loadMoreAlbumAssets() }
    }

    /// Loads the next page of an album link's assets (`POST /api/search/metadata`
    /// with `albumIds`, the only search the server allows under shared-link auth).
    func loadMoreAlbumAssets() async {
        guard let credential, let albumId, let page = nextPage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await client.getSharedLinkAlbumAssets(
                credential,
                albumId: albumId,
                page: page,
                size: Self.albumPageSize
            )
            let fresh = response.assets.items
                .filter { loadedIds.insert($0.id).inserted }
                .map(AssetReactItem.init(from:))
            assets.append(contentsOf: fresh)
            nextPage = response.assets.nextPage.flatMap(Int.init)
            hasMore = nextPage != nil
            message = nil
        } catch {
            // The page that already rendered stays; the failure is reported
            // inline instead of blanking the grid.
            if let text = error.userFacingMessage { message = text }
        }
    }

    // MARK: - Guest upload

    /// Uploads one photo into the link as a guest (`POST /api/assets?key=`).
    /// The server refuses with a bare 401 when `allowUpload` is false — that is
    /// the explanation the visitor gets, because nothing they could do on this
    /// screen would change it.
    func upload(fileURL: URL, filename: String, deviceAssetId: String) async {
        guard let credential else { return }
        uploadState = .uploading
        message = nil
        do {
            // Hashing streams the file off the main actor: the export of a large
            // photo must not stall the grid (`BackupEngine` hashes the same way).
            let checksum = try await Task.detached {
                try BackupEngine.streamingSHA1Base64(fileURL)
            }.value
            let now = Self.iso8601.string(from: Date())
            _ = try await client.uploadAssetToSharedLink(
                fileURL: fileURL,
                filename: filename,
                fileCreatedAt: now,
                fileModifiedAt: now,
                checksum: checksum,
                deviceAssetId: deviceAssetId,
                deviceId: DeviceIdentity.current,
                credential: credential
            )
            uploadState = .done
            // Reload so the visitor sees their own photo where it landed.
            await load()
        } catch {
            guard let failure = UserFacingError.from(error) else {
                // A cancelled upload is no event: it ends the attempt without an error.
                uploadState = .idle
                return
            }
            let text = Self.isUploadRejection(error)
                ? "This link does not allow uploads."
                : failure.message
            uploadState = .failed(text)
            message = text
        }
    }

    // MARK: - Failure handling

    /// Which visitor call failed. The same status means different things per
    /// call — a 401 on `me` asks for a password, the same 401 on `login` says the
    /// password was wrong — so the caller states which one it is.
    enum Call {
        case readLink
        case login
    }

    /// The server's verdicts on a link, as far as the client can tell them apart.
    enum Failure: Equatable {
        /// 401 `"Password required"` — the link needs `POST /shared-links/login`.
        case passwordRequired
        /// 401 `"Invalid password"` — the link exists, the password is wrong.
        case wrongPassword
        /// Any other 401: revoked, expired, or a key/slug this server never
        /// issued (all three answer `"Invalid share key"` / `"Invalid share slug"`,
        /// because `AuthService.isValidSharedLink` collapses them).
        case deadLink
        /// Cooperative cancellation: no event, so nothing changes on screen.
        case cancelled
        /// Anything else, already mapped to the copy the visitor sees.
        case other(UserFacingError)
    }

    private func handle(_ error: Error, on call: Call) {
        switch Self.classify(error, on: call) {
        case .passwordRequired:
            phase = .passwordRequired
            message = nil
        case .wrongPassword:
            phase = .passwordRequired
            message = String(localized: "That password is not right.")
        case .deadLink:
            phase = .deadLink
            message = nil
        case .cancelled:
            return
        case .other(let failure):
            message = failure.message
            // A first load that fails never reached the grid, so it belongs to
            // the entry form; later failures keep the grid on screen with the
            // error inline.
            phase = link == nil ? .failed(failure.message) : .opened
        }
    }

    /// Splits the server's answers on the shared-link path. `APIError.serverError`
    /// carries the raw response body, and the message inside it is the only
    /// discriminator the API offers — the web client keys off the same string
    /// (`loadSharedLink`: `error.data.message === 'Password required'`).
    nonisolated static func classify(_ error: Error, on call: Call = .readLink) -> Failure {
        guard let mapped = UserFacingError.from(error) else { return .cancelled }
        guard case APIError.serverError(401, let body) = error else { return .other(mapped) }
        let text = body ?? ""
        switch call {
        case .readLink:
            return text.contains("Password required") ? .passwordRequired : .deadLink
        case .login:
            return text.contains("Invalid password") ? .wrongPassword : .deadLink
        }
    }

    /// A 401 on the upload route is `requireUploadAccess` refusing: the link does
    /// not grant uploads.
    nonisolated static func isUploadRejection(_ error: Error) -> Bool {
        if case APIError.serverError(401, _) = error { return true }
        return false
    }

    /// The server formats this installation's clock; second precision is all the
    /// upload route uses it for.
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A link may only be opened against the server it names. Both the API host
    /// and the advertised public domain are ours — a proxied instance hands out
    /// the domain while the app dials the API host.
    private func hostMatches(_ host: String) -> Bool {
        let ours = [
            baseURL.host,
            SharedLinkURL(serverURL: baseURL, externalDomain: externalDomain).baseURL.host
        ]
        return ours.compactMap { $0?.lowercased() }.contains(host.lowercased())
    }
}
