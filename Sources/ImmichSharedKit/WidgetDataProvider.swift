import Foundation
import os

// MARK: - Render models

/// One photo (or video) the widget can draw: the bytes are already fetched,
/// because a widget cannot use an authenticated `AsyncImage`.
public struct WidgetPhoto: Identifiable, Equatable, Sendable {
    public let id: String
    /// JPEG bytes of the thumbnail, nil when the fetch failed (the cell then
    /// falls back to a brand-tinted placeholder instead of collapsing).
    public let imageData: Data?
    public let isVideo: Bool
    public let isFavorite: Bool
    /// Timeline bucket key of the day this asset belongs to, carried so a tap
    /// can deep-link the timeline to the right place (`WidgetDeepLink`).
    public let day: String?

    public init(id: String, imageData: Data? = nil, isVideo: Bool = false, isFavorite: Bool = false, day: String? = nil) {
        self.id = id
        self.imageData = imageData
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.day = day
    }

    /// Same photo, with bytes attached.
    func hydrating(with data: Data?) -> WidgetPhoto {
        guard let data else { return self }
        return WidgetPhoto(id: id, imageData: data, isVideo: isVideo, isFavorite: isFavorite, day: day)
    }
}

/// Why a widget has nothing to draw. A widget cannot show an error, so it must
/// at least say the truth: "sign in", "the server did not answer", or "there is
/// genuinely nothing here yet".
public enum WidgetAvailability: Equatable, Sendable {
    case ready
    /// No session published, or the server rejected the token.
    case signedOut
    /// The fetch failed (network, ATS, certificate, HTTP error, bad payload).
    case unreachable
}

/// Everything the photos/favorites widgets draw, plus the two numbers that make
/// them worth a glance: the library size and how much landed in the newest day.
public struct PhotoWall: Equatable, Sendable {
    public let photos: [WidgetPhoto]
    public let totalCount: Int
    /// Key of the newest bucket the photos come from (nil when empty).
    public let newestBucket: String?
    /// Assets in that newest bucket — "42 on 1 Jul".
    public let newestCount: Int
    public let availability: WidgetAvailability
    /// Which server was asked, and how it failed — shown *in* the widget, since
    /// a self-hosted server's owner is the only one who can act on it and the
    /// extension's log is not where they will look.
    public let failureHint: String?

    public init(
        photos: [WidgetPhoto],
        totalCount: Int,
        newestBucket: String?,
        newestCount: Int,
        availability: WidgetAvailability = .ready,
        failureHint: String? = nil
    ) {
        self.photos = photos
        self.totalCount = totalCount
        self.newestBucket = newestBucket
        self.newestCount = newestCount
        self.availability = availability
        self.failureHint = failureHint
    }

    /// A wall that has nothing to show, and why.
    public static func empty(_ availability: WidgetAvailability, hint: String? = nil) -> PhotoWall {
        PhotoWall(
            photos: [], totalCount: 0, newestBucket: nil, newestCount: 0,
            availability: availability, failureHint: hint
        )
    }

    /// Signed in, but the library (or the day) has nothing in it.
    public static let empty = PhotoWall.empty(.ready)
    public var isEmpty: Bool { photos.isEmpty }
}

/// The memories widget's payload, carrying the same "why is this empty" answer.
public struct WidgetMemoryFeed: Equatable, Sendable {
    public let cards: [WidgetMemory]
    public let availability: WidgetAvailability
    public let failureHint: String?

    public init(cards: [WidgetMemory], availability: WidgetAvailability = .ready, failureHint: String? = nil) {
        self.cards = cards
        self.availability = availability
        self.failureHint = failureHint
    }

    public static let empty = WidgetMemoryFeed(cards: [])
    public func empty(_ availability: WidgetAvailability, hint: String? = nil) -> WidgetMemoryFeed {
        WidgetMemoryFeed(cards: [], availability: availability, failureHint: hint)
    }
}

/// One "On this day" memory, ready to draw.
public struct WidgetMemory: Identifiable, Equatable, Sendable {
    public let id: String
    public let yearsAgo: Int
    public let photos: [WidgetPhoto]

    public init(id: String, yearsAgo: Int, photos: [WidgetPhoto]) {
        self.id = id
        self.yearsAgo = yearsAgo
        self.photos = photos
    }
}

/// Media sizes the widget asks the server for. Separate from the app's
/// `AssetMediaSize` because the kit cannot see the app target.
public enum WidgetMediaSize: String, Sendable {
    /// ~250 px — plenty for the small mosaic cells.
    case thumbnail
    /// ~1440 px — for the one hero photo the composition is built around.
    case preview
}

// MARK: - Transport

/// HTTP seam. Injectable so the tests can assert the exact contract (path,
/// query items, bearer header, decoded shape) without a server.
public protocol WidgetDataTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionWidgetTransport: WidgetDataTransport {
    /// Internal (not private) so a test can assert the delegate is attached.
    let session: URLSession

    /// Defaults to a session carrying `WidgetTrustDelegate`: a self-signed
    /// Immich (accepted by the user in the app) is unreachable from a widget
    /// that fetches through `URLSession.shared`.
    public init(
        session: URLSession? = nil,
        sessionStore: any WidgetSessionStoring = WidgetSessionStore(),
        timeout: TimeInterval = 12
    ) {
        self.session = session ?? Self.makeSession(sessionStore: sessionStore, timeout: timeout)
    }

    static func makeSession(sessionStore: any WidgetSessionStoring, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        let delegate = WidgetTrustDelegate(sessionStore: sessionStore)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WidgetDataError.transport }
        return (data, http)
    }

    /// Short-timeout session for the interactive intents: a widget button must
    /// answer fast, and a hung request would leave the user staring at a Home
    /// Screen that never updates. Same trust policy as the read path.
    public static func interactive(sessionStore: any WidgetSessionStoring = WidgetSessionStore()) -> URLSession {
        makeSession(sessionStore: sessionStore, timeout: 15)
    }
}

public enum WidgetDataError: Error, Equatable {
    case transport
    case unauthorized
    case http(Int)
    case decoding
}

// MARK: - Provider

/// Fetches and hydrates everything the three widgets render.
///
/// Each surface costs a handful of small calls: the timeline buckets (which
/// already carry the per-day counts the "42 on 1 Jul" chip needs, so no
/// separate statistics call), one bucket of assets, and one thumbnail per cell.
/// Every failure degrades to an empty wall or an empty memory list — a widget
/// must never render an error, and must never crash on a malformed payload.
public struct WidgetDataProvider: Sendable {
    /// How long the whole fetch may take, network included.
    ///
    /// WidgetKit gives a timeline request a budget of about half a minute, and a
    /// request that misses it does not fail — the widget simply keeps showing
    /// the redacted placeholder it was born with. A bounded fetch that gives up
    /// and *reports* is always better than a fetch that never lands.
    public static let defaultDeadline: Duration = .seconds(10)

    private let sessionStore: any WidgetSessionStoring
    private let transport: any WidgetDataTransport
    private let deadline: Duration
    private let logger = Logger(subsystem: "app.immich.swiftui", category: "widget-data")

    public init(
        sessionStore: any WidgetSessionStoring = WidgetSessionStore(),
        transport: any WidgetDataTransport = URLSessionWidgetTransport(),
        deadline: Duration = WidgetDataProvider.defaultDeadline
    ) {
        self.sessionStore = sessionStore
        self.transport = transport
        self.deadline = deadline
    }

    // MARK: Public surfaces

    /// Newest photos of the library, hero first, with the library total and the
    /// newest day's count.
    public func recentPhotos(limit: Int) async -> PhotoWall {
        await bounded { await wall(isFavorite: nil, limit: limit) }
    }

    /// Newest favorites, same shape.
    public func favoritePhotos(limit: Int) async -> PhotoWall {
        await bounded { await wall(isFavorite: true, limit: limit) }
    }

    /// Today's memories, rotated by `offset` so the shuffle intent shows a
    /// different one on every tap.
    public func memories(limit: Int, offset: Int) async -> WidgetMemoryFeed {
        await bounded { await loadMemories(limit: limit, offset: offset) }
    }

    private func loadMemories(limit: Int, offset: Int) async -> WidgetMemoryFeed {
        guard let session = sessionStore.load() else {
            logger.error("no widget session in the keychain — sign in in the app, or the widget process cannot read the shared group")
            return .empty.empty(.signedOut, hint: "keychain")
        }
        do {
            let payload: [MemoryPayload] = try await get(
                path: "/api/memories",
                token: session.token,
                baseURL: session.baseURL
            )
            let currentYear = Calendar.current.component(.year, from: Date())
            let cards = payload
                .map { $0.card(currentYear: currentYear) }
                .filter { !$0.photos.isEmpty }
                .sorted { $0.yearsAgo < $1.yearsAgo }
            guard !cards.isEmpty else { return .empty.empty(.ready) }
            let start = ((offset % cards.count) + cards.count) % cards.count
            let selected = Array((cards[start...] + cards[..<start]).prefix(max(1, limit)))
            return WidgetMemoryFeed(cards: await hydrate(selected, session: session))
        } catch {
            logger.error("memories fetch failed: \(String(describing: error), privacy: .public)")
            return .empty.empty(availability(for: error), hint: hint(for: error, session: session))
        }
    }

    // MARK: Internals

    private func wall(isFavorite: Bool?, limit: Int) async -> PhotoWall {
        guard let session = sessionStore.load() else {
            logger.error("no widget session in the keychain — sign in in the app, or the widget process cannot read the shared group")
            return .empty(.signedOut, hint: "keychain")
        }
        // Both routes must carry the same filters: the server applies its
        // defaults (every asset, not only favorites) to a filter left out.
        let filters = isFavorite.map { [URLQueryItem(name: "isFavorite", value: $0 ? "true" : "false")] } ?? []
        do {
            let buckets: [BucketPayload] = try await get(
                path: "/api/timeline/buckets",
                query: filters,
                token: session.token,
                baseURL: session.baseURL
            )
            // Bucket 0 is the newest day (the app indexes the same way: it
            // starts at 0 and walks towards older buckets).
            guard let newest = buckets.first else { return .empty(.ready) }
            let columnar: ColumnarAssets = try await get(
                path: "/api/timeline/bucket",
                query: [URLQueryItem(name: "timeBucket", value: newest.timeBucket)] + filters,
                token: session.token,
                baseURL: session.baseURL
            )
            let photos = await hydrate(columnar.photos(day: newest.timeBucket, limit: limit), session: session)
            return PhotoWall(
                photos: photos,
                totalCount: buckets.reduce(0) { $0 + $1.count },
                newestBucket: newest.timeBucket,
                newestCount: newest.count
            )
        } catch {
            logger.error("wall fetch failed: \(String(describing: error), privacy: .public)")
            return .empty(availability(for: error), hint: hint(for: error, session: session))
        }
    }

    /// Runs `work` but never longer than `deadline`: past it the widget reports
    /// "server unreachable" instead of leaving WidgetKit with nothing to show.
    /// (`Task.sleep` wins the race on timeout, and cancelling the group cancels
    /// the in-flight URLSession calls.)
    private func bounded(_ work: @escaping @Sendable () async -> PhotoWall) async -> PhotoWall {
        await withTaskGroup(of: PhotoWall?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            logger.error("widget fetch exceeded \(deadline, privacy: .public) — reporting the server as unreachable")
            let host = sessionStore.load().flatMap { URL(string: $0.baseURL)?.host }
            return .empty(.unreachable, hint: [host, "no answer in \(deadline)"].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private func bounded(_ work: @escaping @Sendable () async -> WidgetMemoryFeed) async -> WidgetMemoryFeed {
        await withTaskGroup(of: WidgetMemoryFeed?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            logger.error("widget fetch exceeded \(deadline, privacy: .public) — reporting the server as unreachable")
            let host = sessionStore.load().flatMap { URL(string: $0.baseURL)?.host }
            return WidgetMemoryFeed(
                cards: [],
                availability: .unreachable,
                failureHint: [host, "no answer in \(deadline)"].compactMap { $0 }.joined(separator: " · ")
            )
        }
    }

    /// "What was asked, and what came back" in one short line: the widget's own
    /// diagnostic. The owner of a self-hosted server can read "nas.local ·
    /// certificate" and know where to look; nothing else in the widget can.
    private func hint(for error: Error, session: WidgetSession) -> String {
        let host = URL(string: session.baseURL)?.host ?? session.baseURL
        guard let urlError = error as? URLError else {
            if case WidgetDataError.decoding = error { return "\(host) · bad payload" }
            if case WidgetDataError.http(let status) = error { return "\(host) · HTTP \(status)" }
            return host
        }
        let reason: String
        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection: reason = String(localized: "ATS (plain HTTP)")
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            reason = String(localized: "certificate refused")
        case .cannotConnectToHost, .cannotFindHost: reason = String(localized: "cannot connect")
        case .notConnectedToInternet, .networkConnectionLost: reason = String(localized: "offline")
        case .timedOut: reason = String(localized: "timeout")
        default: reason = String(localized: "URLError \(urlError.code.rawValue)")
        }
        return "\(host) · \(reason)"
    }

    /// A 401 means the token the widget holds is no longer good (a sign-out the
    /// widget missed); everything else is "the server did not answer", which
    /// includes ATS and certificate failures.
    private func availability(for error: Error) -> WidgetAvailability {
        if case WidgetDataError.unauthorized = error { return .signedOut }
        return .unreachable
    }

    private func hydrate(_ photos: [WidgetPhoto], session: WidgetSession) async -> [WidgetPhoto] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, photo) in photos.enumerated() {
                // Only the hero gets the big render; the mosaic cells are tiny.
                let size: WidgetMediaSize = index == 0 ? .preview : .thumbnail
                group.addTask {
                    (index, await thumbnail(photo: photo, size: size, session: session))
                }
            }
            var bytes: [Int: Data] = [:]
            for await (index, data) in group {
                bytes[index] = data
            }
            let hydrated = photos.enumerated().map { index, photo in
                photo.hydrating(with: bytes[index] ?? nil)
            }
            // WidgetKit archives the entry to disk before it renders: full-size
            // thumbnails make an entry that can fail to archive, and a widget
            // whose entry was never archived shows its placeholder forever.
            return WidgetImageEncoder.budgeted(hydrated)
        }
    }

    private func hydrate(_ cards: [WidgetMemory], session: WidgetSession) async -> [WidgetMemory] {
        await withTaskGroup(of: (Int, [WidgetPhoto]).self) { group in
            for (index, card) in cards.enumerated() {
                group.addTask {
                    (index, await hydrate(card.photos, session: session))
                }
            }
            var photos: [Int: [WidgetPhoto]] = [:]
            for await (index, hydrated) in group {
                photos[index] = hydrated
            }
            return cards.enumerated().map { index, card in
                WidgetMemory(id: card.id, yearsAgo: card.yearsAgo, photos: photos[index] ?? card.photos)
            }
        }
    }

    private func thumbnail(photo: WidgetPhoto, size: WidgetMediaSize, session: WidgetSession) async -> Data? {
        guard var components = URLComponents(string: session.baseURL + "/api/assets/\(photo.id)/thumbnail") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, http) = try await transport.send(request)
            guard http.statusCode == 200, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private func get<T: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        token: String,
        baseURL: String
    ) async throws -> T {
        guard var components = URLComponents(string: baseURL + path) else { throw WidgetDataError.transport }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw WidgetDataError.transport }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, http) = try await transport.send(request)
        guard http.statusCode != 401 else { throw WidgetDataError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw WidgetDataError.http(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw WidgetDataError.decoding }
        return decoded
    }
}

// MARK: - Wire payloads (the subset the widgets read)

private struct BucketPayload: Decodable {
    let timeBucket: String
    let count: Int
}

/// `GET /api/timeline/bucket` is columnar: parallel arrays zipped by index, and
/// the widgets only need four of them. Every optional array is tolerated as
/// missing or short — a server-side addition must not blank the widget.
private struct ColumnarAssets: Decodable {
    let id: [String]
    let isImage: [Bool]?
    let isFavorite: [Bool]?

    private func at<T>(_ array: [T]?, _ index: Int) -> T? {
        guard let array, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    func photos(day: String, limit: Int) -> [WidgetPhoto] {
        id.indices.prefix(max(0, limit)).map { index in
            WidgetPhoto(
                id: id[index],
                isVideo: !(at(isImage, index) ?? true),
                isFavorite: at(isFavorite, index) ?? false,
                day: day
            )
        }
    }
}

private struct MemoryPayload: Decodable {
    struct OnThisDay: Decodable { let year: Int }
    struct Asset: Decodable {
        let id: String
        let type: String
        let isFavorite: Bool?
        let isTrashed: Bool?
    }

    let id: String
    let data: OnThisDay
    let assets: [Asset]

    /// The memory payload already carries its assets, so a card costs no extra
    /// bucket call — only the thumbnails.
    func card(currentYear: Int) -> WidgetMemory {
        let photos = assets
            .filter { !($0.isTrashed ?? false) }
            .map {
                WidgetPhoto(
                    id: $0.id,
                    isVideo: $0.type.uppercased().contains("VIDEO"),
                    isFavorite: $0.isFavorite ?? false
                )
            }
        return WidgetMemory(id: id, yearsAgo: max(0, currentYear - data.year), photos: photos)
    }
}
