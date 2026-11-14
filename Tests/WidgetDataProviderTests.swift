import ImageIO
import UIKit
import WidgetKit
import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the widget data path (issue #19).
///
/// A widget is the least forgiving surface in the app: it runs in its own
/// process, it cannot show an error, and it draws whatever the provider
/// returns. So the properties defended here are the ones a user would
/// otherwise see as a broken tile — the hero is the newest photo and it is
/// fetched at preview size while the mosaic cells stay small, the favorites
/// widget asks the server for favorites only, a shuffle offset really rotates
/// the memories, and every failure (no session, 401, 500, missing thumbnail)
/// degrades to an empty or partial wall instead of a crash.
final class WidgetDataProviderTests: XCTestCase {

    // MARK: - Doubles

    /// Records the requests the provider made and answers them from a script.
    /// Lock-protected: the provider fetches the thumbnails concurrently.
    private final class TransportSpy: WidgetDataTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let responder: @Sendable (URLRequest) -> (Int, Data)

        init(responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
            self.responder = responder
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
            let (status, data) = responder(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
    }

    /// Never answers in time: the case of a server the widget cannot reach at
    /// all, which used to leave WidgetKit with no timeline and the Home Screen
    /// stuck on its redacted placeholder.
    private struct HangingTransport: WidgetDataTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(30))
            throw WidgetDataError.transport
        }
    }

    /// A real (tiny) image: the provider re-encodes every thumbnail it carries,
    /// so a fake byte sequence would be dropped instead of drawn.
    private func tinyImage() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData() ?? Data()
    }

    private struct StubSessionStore: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    private func provider(
        _ spy: TransportSpy,
        session: WidgetSession? = WidgetSession(baseURL: "https://photos.example.com", token: "widget-jwt")
    ) -> WidgetDataProvider {
        WidgetDataProvider(sessionStore: StubSessionStore(session: session), transport: { spy })
    }
    private func url(_ request: URLRequest) -> String {
        request.url?.absoluteString ?? ""
    }

    // MARK: - Photos wall

    func test_recentPhotos_heroIsNewest_everyDrawnPhotoAtPreviewSize() async {
        let spy = TransportSpy { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/timeline/buckets":
                return (200, Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":42},{"timeBucket":"2026-09-12T00:00:00.000Z","count":100}]"#.utf8))
            case "/api/timeline/bucket":
                return (200, Data(#"{"id":["hero","second","third"],"isImage":[true,false,true]}"#.utf8))
            default:
                return (200, self.tinyImage())
            }
        }

        let wall = await provider(spy).recentPhotos(limit: 3, target: .medium)

        XCTAssertEqual(wall.photos.map(\.id), ["hero", "second", "third"])
        XCTAssertEqual(wall.totalCount, 142, "the total is the sum of every bucket, not just the newest")
        XCTAssertEqual(wall.newestBucket, "2026-09-13T00:00:00.000Z")
        XCTAssertEqual(wall.newestCount, 42)
        XCTAssertTrue(wall.photos[0].isVideo == false)
        XCTAssertTrue(wall.photos[1].isVideo, "isImage == false is a video")
        XCTAssertTrue(wall.photos.allSatisfy { $0.imageData != nil }, "every cell got bytes")

        let requests = spy.requests
        XCTAssertEqual(requests.count, 5, "2 calls + 3 thumbnails")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer widget-jwt" })

        let api = requests.filter { $0.url?.path.contains("/api/timeline/") == true }
        XCTAssertEqual(url(api[0]), "https://photos.example.com/api/timeline/buckets?visibility=timeline", "the buckets come first")
        XCTAssertFalse(url(api[0]).contains("isFavorite"), "the photos wall is not the favorites one")
        XCTAssertEqual(url(api[1]), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-09-13T00:00:00.000Z&visibility=timeline")

        // L-30: every drawn photo is one preview request, downloaded one after the other.
        let thumbnails = requests.filter { $0.url?.path.contains("/thumbnail") == true }
        XCTAssertEqual(thumbnails.count, 3)
        XCTAssertEqual(thumbnails.map { $0.url?.path }, ["/api/assets/hero/thumbnail", "/api/assets/second/thumbnail", "/api/assets/third/thumbnail"], "in drawing order, the main photo first")
        // L-21 (AC-183): a widget shows the version edited on the server, asked for explicitly.
        XCTAssertTrue(thumbnails.allSatisfy { url($0).contains("edited=true") }, "every widget thumbnail asks edited=true")
        XCTAssertTrue(thumbnails.allSatisfy { url($0).contains("size=preview") }, "every drawn photo is fetched at preview size")
        XCTAssertTrue(thumbnails.filter { url($0).contains("size=thumbnail") }.isEmpty, "no 250 px thumbnail is ever drawn")
        XCTAssertTrue(wall.photos[0].day == "2026-09-13T00:00:00.000Z", "the tile carries its bucket so a tap can deep-link")
    }

    func test_favoritePhotos_asksTheServerForFavoritesOnly() async {
        let spy = TransportSpy { request in
            if request.url?.path == "/api/timeline/buckets" {
                return (200, Data(#"[{"timeBucket":"2026-08-01T00:00:00.000Z","count":7}]"#.utf8))
            }
            if request.url?.path == "/api/timeline/bucket" {
                return (200, Data(#"{"id":["fav"],"isFavorite":[true]}"#.utf8))
            }
            return (200, self.tinyImage())
        }

        let wall = await provider(spy).favoritePhotos(limit: 2, target: .medium)

        XCTAssertEqual(wall.photos.map(\.id), ["fav"])
        XCTAssertEqual(wall.totalCount, 7)
        XCTAssertTrue(wall.photos[0].isFavorite)
        XCTAssertTrue(url(spy.requests[0]).contains("isFavorite=true"), "a favorites widget must not fetch the whole timeline")
    }

    private func bucketRequest(_ spy: TransportSpy) -> URLRequest? {
        spy.requests.first { $0.url?.path == "/api/timeline/bucket" }
    }

    private func wallSpy() -> TransportSpy {
        TransportSpy { request in
            switch request.url?.path ?? "" {
            case "/api/timeline/buckets":
                return (200, Data(#"[{"timeBucket":"2026-08-01T00:00:00.000Z","count":7}]"#.utf8))
            case "/api/timeline/bucket":
                return (200, Data(#"{"id":["p1"],"isFavorite":[true]}"#.utf8))
            default:
                return (200, self.tinyImage())
            }
        }
    }

    func test_AC7_favoritePhotos_bucketRequestAsksFavoritesToo() async {
        let spy = wallSpy()

        _ = await provider(spy).favoritePhotos(limit: 1, target: .medium)

        let bucket = bucketRequest(spy)
        XCTAssertEqual(bucket.map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&isFavorite=true&visibility=timeline")
        let buckets = spy.requests.first { $0.url?.path == "/api/timeline/buckets" }
        XCTAssertTrue(buckets.map(url)?.contains("isFavorite=true") == true, "same filter as the buckets request")
    }

    func test_AC8_recentPhotos_bucketRequestHasNoFavoriteFilter() async {
        let spy = wallSpy()

        _ = await provider(spy).recentPhotos(limit: 1, target: .medium)

        XCTAssertEqual(bucketRequest(spy).map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&visibility=timeline")
    }

    private func queryItems(_ request: URLRequest?) -> [URLQueryItem] {
        request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    private func bucketsRequest(_ spy: TransportSpy) -> URLRequest? {
        spy.requests.first { $0.url?.path == "/api/timeline/buckets" }
    }

    func test_AC1_recentPhotos_bucketsRequestAsksTimelineVisibilityOnly() async {
        let spy = wallSpy()

        _ = await provider(spy).recentPhotos(limit: 1, target: .medium)

        XCTAssertEqual(bucketsRequest(spy).map(url), "https://photos.example.com/api/timeline/buckets?visibility=timeline")
    }

    func test_AC2_recentPhotos_bucketRequestAsksTimelineVisibility() async {
        let spy = wallSpy()

        _ = await provider(spy).recentPhotos(limit: 1, target: .medium)

        XCTAssertEqual(bucketRequest(spy).map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&visibility=timeline")
    }

    func test_AC3_favoritePhotos_bothRoutesAskFavoritesInTimeline() async {
        let spy = wallSpy()

        _ = await provider(spy).favoritePhotos(limit: 1, target: .medium)

        XCTAssertEqual(bucketsRequest(spy).map(url), "https://photos.example.com/api/timeline/buckets?isFavorite=true&visibility=timeline")
        XCTAssertEqual(bucketRequest(spy).map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&isFavorite=true&visibility=timeline")
    }

    func test_AC4_bothWalls_bucketsAndBucketCarryTheSameFilters() async {
        for favorites in [false, true] {
            let spy = wallSpy()
            if favorites {
                _ = await provider(spy).favoritePhotos(limit: 1, target: .medium)
            } else {
                _ = await provider(spy).recentPhotos(limit: 1, target: .medium)
            }

            let bucketsFilters = Set(queryItems(bucketsRequest(spy)))
            let bucketItems = queryItems(bucketRequest(spy))
            XCTAssertEqual(bucketItems.filter { $0.name == "timeBucket" }.count, 1)
            XCTAssertEqual(bucketsFilters, Set(bucketItems.filter { $0.name != "timeBucket" }), "favorites: \(favorites)")
            XCTAssertTrue(bucketsFilters.contains(URLQueryItem(name: "visibility", value: "timeline")))
        }
    }

    func test_AC5_recentPhotos_totalCountsTimelineOnly() async {
        let spy = TransportSpy { request in
            switch request.url?.path ?? "" {
            case "/api/timeline/buckets":
                let timelineOnly = request.url?.query?.contains("visibility=timeline") == true
                let body = timelineOnly
                    ? #"[{"timeBucket":"2026-08-01T00:00:00.000Z","count":3},{"timeBucket":"2026-07-01T00:00:00.000Z","count":2}]"#
                    : #"[{"timeBucket":"2026-08-01T00:00:00.000Z","count":4},{"timeBucket":"2026-07-01T00:00:00.000Z","count":9}]"#
                return (200, Data(body.utf8))
            case "/api/timeline/bucket":
                return (200, Data(#"{"id":["p1"]}"#.utf8))
            default:
                return (200, self.tinyImage())
            }
        }

        let wall = await provider(spy).recentPhotos(limit: 1, target: .medium)

        XCTAssertEqual(wall.totalCount, 5)
        XCTAssertEqual(wall.newestCount, 3)
    }

    // MARK: - Memories

    func test_memories_rotateWithOffset_andDropEmptyOnes() async {
        let payload = #"""
        [
          {"id":"m2019","memoryAt":"2019-09-13T00:00:00.000Z","data":{"year":2019},
           "assets":[{"id":"a1","type":"IMAGE","isFavorite":true}]},
          {"id":"m2020","memoryAt":"2020-09-13T00:00:00.000Z","data":{"year":2020},
           "assets":[{"id":"a2","type":"VIDEO"}]},
          {"id":"empty","memoryAt":"2021-09-13T00:00:00.000Z","data":{"year":2021},"assets":[]},
          {"id":"trashed","memoryAt":"2022-09-13T00:00:00.000Z","data":{"year":2022},
           "assets":[{"id":"a3","type":"IMAGE","isTrashed":true}]}
        ]
        """#
        let spy = TransportSpy { request in
            request.url?.path == "/api/memories" ? (200, Data(payload.utf8)) : (200, self.tinyImage())
        }
        let year = Calendar.current.component(.year, from: Date())

        let first = (await provider(spy).memories(limit: 2, offset: 0, target: .medium)).cards
        let second = (await provider(spy).memories(limit: 2, offset: 1, target: .medium)).cards

        XCTAssertEqual(first.map(\.id), ["m2020", "m2019"], "empty and fully trashed memories never reach the widget, newest first")
        XCTAssertEqual(second.map(\.id), ["m2019", "m2020"], "the shuffle offset really rotates the list")
        XCTAssertEqual(first[0].yearsAgo, year - 2020)
        XCTAssertEqual(first[1].yearsAgo, year - 2019)
        XCTAssertEqual(first[0].photos.map(\.id), ["a2"])
        XCTAssertTrue(first[0].photos[0].isVideo)
        XCTAssertTrue(first[1].photos[0].isFavorite, "the payload's favorite flag rides along")
        XCTAssertNotNil(first[0].photos[0].imageData, "memory thumbnails are hydrated too")
        XCTAssertTrue(spy.requests.allSatisfy { $0.url?.path != "/api/timeline/buckets" },
                      "a memory payload already carries its assets — no bucket call")
    }

    func test_memories_withMoreCardsThanAvailable_wrapsInsteadOfCrashing() async {
        let payload = #"[{"id":"only","memoryAt":"2019-01-01T00:00:00.000Z","data":{"year":2019},"assets":[{"id":"a1","type":"IMAGE"}]}]"#
        let spy = TransportSpy { request in
            request.url?.path == "/api/memories" ? (200, Data(payload.utf8)) : (200, self.tinyImage())
        }

        let cards = (await provider(spy).memories(limit: 2, offset: 7, target: .medium)).cards

        XCTAssertEqual(cards.map(\.id), ["only"], "an offset past the end wraps instead of returning nothing")
    }

    // MARK: - Degradation

    func test_noSession_returnsEmptyAndMakesNoRequest() async {
        let spy = TransportSpy { _ in (200, Data()) }

        let wall = await provider(spy, session: nil).recentPhotos(limit: 3, target: .medium)
        let favorites = await provider(spy, session: nil).favoritePhotos(limit: 3, target: .medium)
        let feed = await provider(spy, session: nil).memories(limit: 2, offset: 0, target: .medium)

        XCTAssertTrue(wall.isEmpty)
        XCTAssertTrue(favorites.isEmpty)
        XCTAssertTrue(feed.cards.isEmpty)
        XCTAssertEqual(wall.availability, .signedOut, "the widget must say why it is empty")
        XCTAssertEqual(feed.availability, .signedOut)
        XCTAssertTrue(spy.requests.isEmpty, "signed out: the widget must not talk to the server at all")
    }

    func test_serverFailure_degradesToAnEmptyWall() async {
        let unauthorized = TransportSpy { _ in (401, Data(#"{"message":"unauthorized"}"#.utf8)) }
        let broken = TransportSpy { _ in (500, Data()) }

        let rejected = await provider(unauthorized).recentPhotos(limit: 3, target: .medium)
        let failed = await provider(broken).recentPhotos(limit: 3, target: .medium)

        XCTAssertTrue(rejected.isEmpty)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(rejected.availability, .signedOut, "a revoked token is a sign-in problem, not a network one")
        XCTAssertEqual(failed.availability, .unreachable)
        let memories = await provider(broken).memories(limit: 1, offset: 0, target: .medium)
        XCTAssertEqual(
            memories.availability,
            .unreachable,
            "a memory fetch that fails must not read as “nothing to remember”"
        )
    }

    func test_malformedPayload_degradesToAnEmptyWall() async {
        let spy = TransportSpy { request in
            request.url?.path == "/api/timeline/buckets" ? (200, Data("<html>not json</html>".utf8)) : (200, Data())
        }

        let wall = await provider(spy).recentPhotos(limit: 3, target: .medium)

        XCTAssertTrue(wall.isEmpty)
    }

    func test_thumbnailFailure_keepsTheCellWithoutBytes() async {
        let spy = TransportSpy { request in
            let path = request.url?.path ?? ""
            if path == "/api/timeline/buckets" {
                return (200, Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":2}]"#.utf8))
            }
            if path == "/api/timeline/bucket" {
                return (200, Data(#"{"id":["broken","fine"]}"#.utf8))
            }
            return request.url?.absoluteString.contains("broken") == true ? (500, Data()) : (200, self.tinyImage())
        }

        let wall = await provider(spy).recentPhotos(limit: 2, target: .medium)

        XCTAssertEqual(wall.photos.count, 2, "one failed thumbnail does not drop the photo")
        XCTAssertNil(wall.photos[0].imageData)
        XCTAssertNotNil(wall.photos[1].imageData)
    }

    // MARK: - Extension entitlement probe

    func test_probe_reportsAMissingKeychainGroupForTheExtension() {
        let profile: [String: Any] = [
            "application-identifier": "2MJF39L8VY.fr.millianlmx.immich-ios",
            "ApplicationIdentifierPrefix": ["2MJF39L8VY."],
        ]

        let verdict = WidgetExtensionProbe.verdict(
            extensionName: "ImmichWidgets.appex",
            profileEntitlements: profile
        )

        XCTAssertTrue(verdict.hasPrefix("widget: MISMATCH"), verdict)
        XCTAssertTrue(verdict.contains("2MJF39L8VY.fr.millianlmx.swimmich"), "the group the widget needs must be named")
    }

    func test_probe_acceptsATeamProfileWildcard() {
        // What a team profile actually carries: application-identifier = <team>.*
        // and a keychain group that covers the whole team.
        let profile: [String: Any] = [
            "application-identifier": "2MJF39L8VY.*",
            "ApplicationIdentifierPrefix": ["2MJF39L8VY."],
            "keychain-access-groups": ["2MJF39L8VY.*", "com.apple.token"],
        ]

        let verdict = WidgetExtensionProbe.verdict(
            extensionName: "ImmichWidgets.appex",
            profileEntitlements: profile
        )

        XCTAssertTrue(verdict.hasPrefix("widget: ok"), verdict)
    }

    func test_probe_acceptsAnAuthorisedGroup() {
        let profile: [String: Any] = [
            "application-identifier": "2MJF39L8VY.fr.millianlmx.immich-ios",
            "ApplicationIdentifierPrefix": ["2MJF39L8VY."],
            "keychain-access-groups": [
                "2MJF39L8VY.fr.millianlmx.swimmich",
                "2MJF39L8VY.fr.millianlmx.immich-ios.other",
            ],
        ]

        let verdict = WidgetExtensionProbe.verdict(
            extensionName: "ImmichWidgets.appex",
            profileEntitlements: profile
        )

        XCTAssertTrue(verdict.hasPrefix("widget: ok"), verdict)
    }

    func test_probe_survivesAProfileWithoutAnApplicationIdentifier() {
        let verdict = WidgetExtensionProbe.verdict(
            extensionName: "ImmichWidgets.appex",
            profileEntitlements: [:]
        )

        XCTAssertTrue(verdict.contains("ApplicationIdentifierPrefix"), verdict)
    }

    func test_aServerThatNeverAnswers_stillYieldsATimeline() async {
        let provider = WidgetDataProvider(
            sessionStore: StubSessionStore(session: WidgetSession(baseURL: "https://photos.example.com", token: "jwt")),
            transport: { HangingTransport() },
            deadline: .milliseconds(80)
        )

        let wall = await provider.recentPhotos(limit: 3, target: .medium)
        let feed = await provider.memories(limit: 1, offset: 0, target: .medium)

        XCTAssertTrue(wall.isEmpty)
        XCTAssertEqual(wall.availability, .unreachable, "a hung fetch must resolve, not leave the widget redacted forever")
        XCTAssertEqual(feed.availability, .unreachable)
    }

    // MARK: - Entry weight

    /// A 2000×2000 PNG, i.e. what a real server sends where the stub sends 8×8.
    private func bigImage(quality: CGFloat = 1.0) -> Data {
        let side: CGFloat = 2000
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for step in stride(from: 0, to: side, by: 40) {
                UIColor.systemPurple.setFill()
                context.fill(CGRect(x: step, y: 0, width: 20, height: side))
            }
        }
        return image.pngData() ?? Data()
    }

    func test_entryBudget_stopsAttachingBytesInsteadOfExceedingIt() {
        let tile = WidgetPixelSize(width: 1092, height: 711)
        let encoded = WidgetImageEncoder.encode(bigImage(), toCover: tile)
        XCTAssertNotNil(encoded, "the fixture must encode")
        let photos = (0..<6).map { index in
            WidgetPhoto(id: "p-\(index)", imageData: encoded, isVideo: false, isFavorite: false, day: nil)
        }

        // A budget that fits the first image and nothing else: what survives
        // must be the first, never the ones after it.
        let firstOnly = (encoded?.count ?? 0) + 1_000
        let budgeted = WidgetImageEncoder.budgeted(photos, budget: firstOnly)

        XCTAssertNotNil(budgeted[0].imageData, "the first photo is the one that matters")
        XCTAssertLessThanOrEqual(budgeted.compactMap(\.imageData).reduce(0) { $0 + $1.count }, firstOnly)
        XCTAssertTrue(budgeted.dropFirst().allSatisfy { $0.imageData == nil }, "the budget is spent by the first")
        XCTAssertEqual(budgeted.map(\.id), photos.map(\.id), "every cell survives, just without bytes")
    }

    /// L-05 / AC-101: a server that generates its thumbnails and previews as
    /// JPEG XL still gives the widget decodable bytes (the encoder re-encodes
    /// to JPEG, which is what `WidgetPhotoTile` draws), and a thumbnail that
    /// cannot be decoded leaves the branded plate instead.
    func test_AC_101_jpegXLThumbnailsReachTheWidgetDecoded() async {
        func spy(serving thumbnail: Data) -> TransportSpy {
            TransportSpy { request in
                let path = request.url?.path ?? ""
                if path == "/api/timeline/buckets" {
                    return (200, Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":3}]"#.utf8))
                }
                if path == "/api/timeline/bucket" {
                    return (200, Data(#"{"id":["a","b","c"]}"#.utf8))
                }
                return (200, thumbnail)
            }
        }

        let wall = await provider(spy(serving: JpegXLFixture.thumbnail)).recentPhotos(limit: 3, target: .medium)

        XCTAssertEqual(wall.photos.map(\.id), ["a", "b", "c"])
        let bytes = wall.photos.compactMap(\.imageData)
        XCTAssertEqual(bytes.count, 3, "every JPEG XL thumbnail carried bytes")
        for data in bytes {
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "re-encoded as JPEG")
            XCTAssertNotNil(UIImage(data: data), "WidgetPhotoTile draws UIImage(data:), so it must decode")
        }
        XCTAssertLessThanOrEqual(bytes.reduce(0) { $0 + $1.count }, WidgetImageEncoder.budget)

        let broken = await provider(spy(serving: JpegXLFixture.truncated)).recentPhotos(limit: 3, target: .medium)
        XCTAssertEqual(broken.photos.count, 3)
        XCTAssertTrue(broken.photos.allSatisfy { $0.imageData == nil }, "undecodable bytes fall back to the plate")
    }

    func test_wall_fetchedFromARealSizedServer_staysSmall() async {
        let spy = TransportSpy { request in
            let path = request.url?.path ?? ""
            if path == "/api/timeline/buckets" {
                return (200, Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":3}]"#.utf8))
            }
            if path == "/api/timeline/bucket" {
                return (200, Data(#"{"id":["a","b","c"]}"#.utf8))
            }
            return (200, self.bigImage())
        }

        let wall = await provider(spy).recentPhotos(limit: 3, target: .medium)

        let carried = wall.photos.compactMap(\.imageData).reduce(0) { $0 + $1.count }
        XCTAssertEqual(wall.photos.count, 3)
        XCTAssertGreaterThan(carried, 0, "the wall must still carry pictures")
        XCTAssertLessThanOrEqual(carried, WidgetImageEncoder.budget, "the entry has to stay archivable")
    }

    // MARK: - Copy

    func test_dayLabel_speaksTheUsersCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 15))!

        XCTAssertEqual(WidgetCopy.dayLabel(bucket: "2026-09-13T00:00:00.000Z", now: now, calendar: calendar), .today)
        XCTAssertEqual(WidgetCopy.dayLabel(bucket: "2026-09-12T00:00:00.000Z", now: now, calendar: calendar), .yesterday)
        XCTAssertNil(WidgetCopy.dayLabel(bucket: nil, now: now, calendar: calendar))
        XCTAssertNil(WidgetCopy.dayLabel(bucket: "2026-09", now: now, calendar: calendar))

        // An older bucket is a real date, in the user's locale — assert the
        // shape, not the spelling.
        guard case .date(let text)? = WidgetCopy.dayLabel(bucket: "2024-07-01T00:00:00.000Z", now: now, calendar: calendar) else {
            return XCTFail("an older bucket should render as a date")
        }
        XCTAssertEqual(text, calendar.date(from: DateComponents(year: 2024, month: 7, day: 1))!
            .formatted(.dateTime.day().month(.abbreviated)))
    }

    func test_copyReadsAsASentence() {
        let wall = PhotoWall(
            photos: [],
            totalCount: 12483,
            newestBucket: "2026-09-13T00:00:00.000Z",
            newestCount: 42
        )

        XCTAssertEqual(WidgetCopy.grouped(12483, locale: Locale(identifier: "en_US")), "12,483")
        XCTAssertEqual(WidgetCopy.grouped(12483, locale: Locale(identifier: "fr_FR")).replacingOccurrences(of: "\u{202F}", with: " "), "12 483")

        // The catalog translates these, and the test runner's language is not
        // ours to pick: assert the shape that would break (singular vs plural,
        // count carried through), not the words.
        XCTAssertNotEqual(WidgetCopy.photosText(1), WidgetCopy.photosText(2), "the singular has its own string")
        XCTAssertNotEqual(WidgetCopy.favoritesText(1), WidgetCopy.favoritesText(2))
        XCTAssertNotEqual(WidgetCopy.yearsAgoText(1), WidgetCopy.yearsAgoText(2), "“1 years ago” is the bug this catches")
        XCTAssertEqual(WidgetCopy.photosText(2), WidgetCopy.photosText(3).replacingOccurrences(of: "3", with: "2"))
        XCTAssertEqual(WidgetCopy.yearsAgoText(5), WidgetCopy.yearsAgoText(6).replacingOccurrences(of: "6", with: "5"))
        XCTAssertNotEqual(WidgetCopy.yearsAgoText(0), WidgetCopy.yearsAgoText(1), "a same-year memory is not “1 year ago”")
        XCTAssertNotNil(WidgetCopy.newestDayText(wall))
        XCTAssertNil(WidgetCopy.newestDayText(.empty), "no bucket, nothing to strand on screen")
    }

    // MARK: - Shared session

    func test_sessionStore_roundTripsAndClears() {
        // Its own service so the test never touches the real widget session.
        let store = WidgetSessionStore(service: "app.immich.swiftui.widget.tests")
        defer { store.clear() }

        store.save(WidgetSession(baseURL: "https://photos.example.com", token: "jwt", userName: "Milian", userId: "u1"))

        let loaded = store.load()
        XCTAssertEqual(loaded?.baseURL, "https://photos.example.com")
        XCTAssertEqual(loaded?.token, "jwt")
        XCTAssertEqual(loaded?.userName, "Milian")

        store.clear()
        XCTAssertNil(store.load())
    }

    func test_sessionDecodesABlobWrittenBeforeTrustedHostsExisted() throws {
        // A session stored by the previous build has no `trustedHosts` key; the
        // widget must keep reading it instead of reporting "signed out".
        let legacy = Data(#"{"baseURL":"https://photos.example.com","token":"jwt","userName":"Milian"}"#.utf8)

        let session = try JSONDecoder().decode(WidgetSession.self, from: legacy)

        XCTAssertEqual(session.token, "jwt")
        XCTAssertEqual(session.trustedHostSet, [])
    }

    func test_trustDelegate_onlyAcceptsAHostTheUserAcceptedInTheApp() {
        let spy = TransportSpy { _ in (200, Data()) }
        let trusting = WidgetTrustDelegate(sessionStore: StubSessionStore(session: WidgetSession(
            baseURL: "https://nas.local:2283", token: "jwt", trustedHosts: ["nas.local"]
        )))
        let plain = WidgetTrustDelegate(sessionStore: StubSessionStore(session: WidgetSession(
            baseURL: "https://nas.local:2283", token: "jwt"
        )))
        let anonymous = WidgetTrustDelegate(sessionStore: StubSessionStore(session: nil))

        XCTAssertTrue(trusting.trustsCertificates(for: "nas.local"), "the host the user accepted is honoured")
        XCTAssertFalse(trusting.trustsCertificates(for: "evil.example"), "trust is per host, never global")
        XCTAssertFalse(plain.trustsCertificates(for: "nas.local"), "a self-signed server is not trusted by default")
        XCTAssertFalse(anonymous.trustsCertificates(for: "nas.local"), "no session, no trust")
        _ = spy
    }

    func test_transportDefaultsToASessionThatCanHandleServerTrust() {
        // The widget reads through its own session: `URLSession.shared` has no
        // delegate, so a self-signed server the app opens fine would fail every
        // widget fetch.
        let transport = URLSessionWidgetTransport()

        XCTAssertTrue(transport.session.delegate is WidgetTrustDelegate)
    }

    func test_sessionStore_ignoresAnEmptyToken() {
        let store = WidgetSessionStore(service: "app.immich.swiftui.widget.tests")
        defer { store.clear() }

        store.save(WidgetSession(baseURL: "https://photos.example.com", token: ""))

        XCTAssertNil(store.load(), "a blank token would make every widget fetch a 401")
    }

    // MARK: - Custom HTTP headers (L-09)

    /// Answers every route a photo wall and a memory feed use.
    private func headersWallSpy() -> TransportSpy {
        TransportSpy { request in
            switch request.url?.path ?? "" {
            case "/api/timeline/buckets":
                return (200, Data(#"[{"timeBucket":"2026-09-13T00:00:00.000Z","count":2}]"#.utf8))
            case "/api/timeline/bucket":
                return (200, Data(#"{"id":["hero","second"],"isImage":[true,true]}"#.utf8))
            case "/api/memories":
                return (200, Data("[]".utf8))
            default:
                return (200, self.tinyImage())
            }
        }
    }

    /// Remembers what the app wrote, like the shared keychain would.
    private final class PublishedSession: WidgetSessionStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WidgetSession?
        func save(_ session: WidgetSession) { lock.lock(); stored = session; lock.unlock() }
        func load() -> WidgetSession? { lock.lock(); defer { lock.unlock() }; return stored }
        func clear() { lock.lock(); stored = nil; lock.unlock() }
    }

    /// The session as the widget process reads it: encoded by the app, decoded
    /// by `JSONDecoder` the way `WidgetSessionStore.load()` does.
    private func decodedFromKeychain(_ session: WidgetSession?) throws -> WidgetSession {
        let data = try JSONEncoder().encode(try XCTUnwrap(session))
        return try JSONDecoder().decode(WidgetSession.self, from: data)
    }

    private func requestsOfAFullRefresh(_ session: WidgetSession, spy: TransportSpy) async -> [URLRequest] {
        let wallProvider = provider(spy, session: session)
        _ = await wallProvider.recentPhotos(limit: 2, target: .medium)
        _ = await wallProvider.memories(limit: 1, offset: 0, target: .medium)
        return spy.requests
    }

    @MainActor
    private func publishedSession(headers: [CustomHTTPHeader]) async throws -> WidgetSession {
        let suite = "widget-headers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = LoginResponseDto(
            accessToken: "widget-jwt", userId: "u1", userEmail: "t@e.com", name: "Milian",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
        let published = PublishedSession()
        let auth = AuthViewModel(
            client: mock, keychain: MockKeychainStore(), defaults: defaults, widgetSession: published,
            reloadWidgets: {},
            customHeaders: StaticCustomHeaders(headers, for: "https://photos.example.com")
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        await auth.login(email: "t@e.com", password: "secret")
        return try decodedFromKeychain(published.load())
    }

    // S-19: from the session the app publishes to every request a widget makes.
    @MainActor
    func test_AC_19_widgetRequestsCarryHeaders() async throws {
        let session = try await publishedSession(headers: [StaticCustomHeaders.xAccess])
        XCTAssertEqual(session.customHeaders, [StaticCustomHeaders.xAccess])

        let spy = headersWallSpy()
        let requests = await requestsOfAFullRefresh(session, spy: spy)

        let paths = Set(requests.compactMap { $0.url?.path })
        XCTAssertTrue(paths.contains("/api/timeline/buckets"))
        XCTAssertTrue(paths.contains("/api/timeline/bucket"))
        XCTAssertTrue(paths.contains("/api/memories"))
        XCTAssertTrue(paths.contains { $0.hasSuffix("/thumbnail") }, "thumbnails are requests too")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret", request.url?.path ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
        }
    }

    // AC-119 (provider half): after the header is deleted and the session
    // republished, the next refresh carries nothing.
    @MainActor
    func test_AC_119_refreshAfterRemovalCarriesNoHeader() async throws {
        let without = try await publishedSession(headers: [])
        XCTAssertNil(without.customHeaders, "no list: the key is absent, like before this feature")
        let requests = await requestsOfAFullRefresh(without, spy: headersWallSpy())
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Access") == nil })
    }

    func test_AC_124_legacySessionDecodesAndSendsBearerOnly() async throws {
        let legacy = Data(#"{"baseURL":"https://photos.example.com","token":"widget-jwt","userName":"Milian"}"#.utf8)
        let session = try JSONDecoder().decode(WidgetSession.self, from: legacy)
        XCTAssertNil(session.customHeaders)

        let requests = await requestsOfAFullRefresh(session, spy: headersWallSpy())
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-immich-user-token"))
            XCTAssertLessThanOrEqual(request.allHTTPHeaderFields?.count ?? 0, 2, "Authorization and, for JSON routes, Accept")
        }
    }

    func test_AC_125_widgetUsesUserTokenHeader() async throws {
        let session = WidgetSession(
            baseURL: "https://photos.example.com", token: "widget-jwt", customHeaders: [StaticCustomHeaders.basic]
        )
        let requests = await requestsOfAFullRefresh(session, spy: headersWallSpy())
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-immich-user-token"), "widget-jwt")
        }
    }
}

/// The app publishes what the widgets read: without these, every widget shows
/// the empty state even though the user is signed in.
final class WidgetSessionPublishingTests: XCTestCase {

    private final class SessionSpy: WidgetSessionStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WidgetSession?
        private var clears = 0

        var session: WidgetSession? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var clearCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return clears
        }

        func save(_ session: WidgetSession) {
            lock.lock()
            stored = session
            lock.unlock()
        }

        func load() -> WidgetSession? { session }

        func clear() {
            lock.lock()
            stored = nil
            clears += 1
            lock.unlock()
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "widget-session-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func loginResponse(token: String, name: String) -> LoginResponseDto {
        LoginResponseDto(
            accessToken: token, userId: "u1", userEmail: "t@e.com", name: name,
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
    }

    @MainActor
    func test_login_publishesTheWidgetSession() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let auth = AuthViewModel(
            client: mock,
            keychain: MockKeychainStore(),
            defaults: defaults,
            widgetSession: spy
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "t@e.com", password: "secret")

        XCTAssertEqual(spy.session?.token, "widget-jwt")
        XCTAssertEqual(spy.session?.baseURL, "https://photos.example.com")
        XCTAssertEqual(spy.session?.userName, "Milian")
    }

    @MainActor
    func test_login_publishesTheHostTheUserAcceptedTheCertificateFor() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let trustDefaults = UserDefaults(suiteName: "widget-trust-\(UUID().uuidString)")!
        let trustStore = TrustedServerStoreImpl(defaults: trustDefaults)
        trustStore.add("photos.example.com")
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let auth = AuthViewModel(
            client: mock,
            keychain: MockKeychainStore(),
            defaults: defaults,
            trustStore: trustStore,
            widgetSession: spy
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL

        await auth.login(email: "t@e.com", password: "secret")

        XCTAssertEqual(
            spy.session?.trustedHostSet,
            ["photos.example.com"],
            "the widget cannot read the app's trust store, so the host must travel with the session"
        )
    }

    @MainActor
    func test_signOut_clearsTheWidgetSession() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let auth = AuthViewModel(
            client: mock,
            keychain: MockKeychainStore(),
            defaults: defaults,
            widgetSession: spy
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        await auth.login(email: "t@e.com", password: "secret")
        XCTAssertNotNil(spy.session)

        await auth.logout()

        XCTAssertNil(spy.session, "a widget must never keep showing a signed-out account's photos")
        XCTAssertGreaterThanOrEqual(spy.clearCount, 1)
    }

    // MARK: - Widget reload requests

    /// Records, at every reload request, what the shared store held at that
    /// moment — a reload asked *before* the write/clear would read the old session.
    private final class ReloadSpy: @unchecked Sendable {
        struct Snapshot {
            let session: WidgetSession?
            let clearCount: Int
        }

        private let lock = NSLock()
        private var snapshots: [Snapshot] = []

        var reloads: [Snapshot] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
        }

        func record(_ store: SessionSpy) {
            let snapshot = Snapshot(session: store.session, clearCount: store.clearCount)
            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
        }
    }

    private func makeOAuthConfig() -> ServerConfigDto {
        ServerConfigDto(
            oauthButtonText: "Continue with Immich SSO", loginPageMessage: "", trashDays: 30,
            userDeleteDelay: 7, isInitialized: true, isOnboarded: true, externalDomain: "",
            publicUsers: false, mapDarkStyleUrl: "", mapLightStyleUrl: "",
            maintenanceMode: false, minFaces: 0
        )
    }

    private func seedSavedAccounts(_ accounts: [SavedAccount], defaults: UserDefaults) {
        defaults.set(try! JSONEncoder.immich.encode(accounts), forKey: AuthViewModel.serverListDefaultsKey)
    }

    @MainActor
    private func makeAuth(
        mock: MockImmichClient,
        keychain: MockKeychainStore = MockKeychainStore(),
        defaults: UserDefaults,
        spy: SessionSpy,
        reloads: ReloadSpy
    ) -> AuthViewModel {
        let auth = AuthViewModel(
            client: mock,
            keychain: keychain,
            defaults: defaults,
            widgetSession: spy,
            reloadWidgets: { reloads.record(spy) }
        )
        auth.serverURLString = "https://photos.example.com"
        _ = auth.baseURL
        return auth
    }

    @MainActor
    func test_AC6_switchToAccount_reloadsWidgetsAfterPublishingTheNewAccount() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let alice = SavedAccount(url: "https://photos.example.com", email: "alice@example.com", name: "Alice", userId: "u1", isAdmin: false)
        let bob = SavedAccount(url: "https://photos.example.com", email: "bob@example.com", name: "Bob", userId: "u2", isAdmin: false)
        keychain.saveToken("alice-jwt", for: alice.id)
        keychain.saveToken("bob-jwt", for: bob.id)
        seedSavedAccounts([alice, bob], defaults: defaults)
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let mock = MockImmichClient()
        mock.validateError = nil
        let auth = makeAuth(mock: mock, keychain: keychain, defaults: defaults, spy: spy, reloads: reloads)
        auth.userEmail = "alice@example.com"
        auth.userName = "Alice"
        auth.userId = "u1"
        auth.accessToken = "alice-jwt"

        await auth.switchToAccount(bob)

        XCTAssertEqual(spy.session?.token, "bob-jwt")
        XCTAssertEqual(spy.session?.userId, "u2")
        XCTAssertFalse(reloads.reloads.isEmpty)
        XCTAssertEqual(reloads.reloads.last?.session?.token, "bob-jwt", "the reload must follow the write")
    }

    @MainActor
    func test_AC7_passwordLogin_reloadsWidgetsAfterPublishing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: mock, defaults: defaults, spy: spy, reloads: reloads)
        XCTAssertTrue(reloads.reloads.isEmpty)

        await auth.login(email: "t@e.com", password: "secret")

        XCTAssertFalse(reloads.reloads.isEmpty)
        XCTAssertEqual(reloads.reloads.last?.session?.token, "widget-jwt")
    }

    @MainActor
    func test_AC7_oauthLogin_reloadsWidgetsAfterPublishing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: MockImmichClient(), defaults: defaults, spy: spy, reloads: reloads)
        auth.serverConfig = makeOAuthConfig()
        auth.oauthSessionHandler = { _ in URL(string: "app.immich:///oauth-callback?code=abc") }
        XCTAssertTrue(reloads.reloads.isEmpty)

        await auth.startOAuthFlow()

        XCTAssertFalse(reloads.reloads.isEmpty)
        XCTAssertEqual(reloads.reloads.last?.session?.token, "oauth-token")
    }

    @MainActor
    func test_AC8_logout_reloadsWidgetsAfterClearing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: mock, defaults: defaults, spy: spy, reloads: reloads)
        await auth.login(email: "t@e.com", password: "secret")
        let before = reloads.reloads.count

        await auth.logout()

        XCTAssertNil(spy.session)
        XCTAssertGreaterThan(reloads.reloads.count, before)
        XCTAssertNil(reloads.reloads.last?.session)
        XCTAssertGreaterThanOrEqual(reloads.reloads.last?.clearCount ?? 0, 1)
    }

    @MainActor
    func test_AC9_switchToAccount_missingToken_reloadsWidgetsAfterClearing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ghost = SavedAccount(url: "https://photos.example.com", email: "ghost@example.com", name: "Ghost", userId: "u9", isAdmin: false)
        seedSavedAccounts([ghost], defaults: defaults)
        let spy = SessionSpy()
        spy.save(WidgetSession(baseURL: "https://photos.example.com", token: "current-jwt"))
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: MockImmichClient(), defaults: defaults, spy: spy, reloads: reloads)
        auth.accessToken = "current-jwt"

        await auth.switchToAccount(ghost)

        XCTAssertNil(spy.session)
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(reloads.reloads.last?.session)
        XCTAssertGreaterThanOrEqual(reloads.reloads.last?.clearCount ?? 0, 1)
    }

    @MainActor
    func test_AC9_switchToAccount_rejectedToken_reloadsWidgetsAfterClearing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        let bob = SavedAccount(url: "https://photos.example.com", email: "bob@example.com", name: "Bob", userId: "u2", isAdmin: false)
        keychain.saveToken("stale-jwt", for: bob.id)
        seedSavedAccounts([bob], defaults: defaults)
        let mock = MockImmichClient()
        mock.validateError = APIError.unauthorized
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: mock, keychain: keychain, defaults: defaults, spy: spy, reloads: reloads)
        auth.accessToken = "current-jwt"

        await auth.switchToAccount(bob)

        XCTAssertNil(spy.session)
        XCTAssertFalse(auth.isAuthenticated)
        XCTAssertNil(reloads.reloads.last?.session, "the last reload must see the cleared session")
        XCTAssertGreaterThanOrEqual(reloads.reloads.last?.clearCount ?? 0, 1)
    }

    @MainActor
    func test_AC10_restoreSession_rejectedToken_reloadsWidgetsAfterClearing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        defaults.set("https://photos.example.com", forKey: AuthViewModel.serverURLDefaultsKey)
        keychain.saveToken("saved-jwt")
        let mock = MockImmichClient()
        mock.validateError = APIError.unauthorized
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = AuthViewModel(
            client: mock, keychain: keychain, defaults: defaults,
            widgetSession: spy, reloadWidgets: { reloads.record(spy) }
        )

        await auth.restoreSession()

        XCTAssertNil(spy.session)
        XCTAssertGreaterThanOrEqual(spy.clearCount, 1)
        XCTAssertFalse(reloads.reloads.isEmpty)
        XCTAssertNil(reloads.reloads.last?.session)
    }

    @MainActor
    func test_AC12_addNewServer_reloadsWidgetsAfterClearing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: mock, defaults: defaults, spy: spy, reloads: reloads)
        await auth.login(email: "t@e.com", password: "secret")
        XCTAssertEqual(spy.session?.token, "widget-jwt")
        let before = reloads.reloads.count

        auth.addNewServer()

        XCTAssertNil(spy.session)
        XCTAssertGreaterThan(reloads.reloads.count, before)
        XCTAssertNil(reloads.reloads.last?.session)
        XCTAssertGreaterThanOrEqual(reloads.reloads.last?.clearCount ?? 0, 1)
    }

    @MainActor
    func test_AC12_removeActiveSavedAccount_reloadsWidgetsAfterClearing() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let mock = MockImmichClient()
        mock.loginResponse = loginResponse(token: "widget-jwt", name: "Milian")
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = makeAuth(mock: mock, defaults: defaults, spy: spy, reloads: reloads)
        await auth.login(email: "t@e.com", password: "secret")
        let active = try XCTUnwrap(auth.savedAccounts.first)
        XCTAssertEqual(active.id, auth.activeAccountID)
        let before = reloads.reloads.count

        auth.removeSavedAccount(active)

        XCTAssertNil(spy.session)
        XCTAssertGreaterThan(reloads.reloads.count, before)
        XCTAssertNil(reloads.reloads.last?.session)
        XCTAssertGreaterThanOrEqual(reloads.reloads.last?.clearCount ?? 0, 1)
    }

    @MainActor
    func test_AC13_restoreSession_validToken_reloadsWidgetsAfterPublishing() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychainStore()
        defaults.set("https://photos.example.com", forKey: AuthViewModel.serverURLDefaultsKey)
        keychain.saveToken("saved-jwt")
        let spy = SessionSpy()
        let reloads = ReloadSpy()
        let auth = AuthViewModel(
            client: MockImmichClient(), keychain: keychain, defaults: defaults,
            widgetSession: spy, reloadWidgets: { reloads.record(spy) }
        )
        XCTAssertTrue(reloads.reloads.isEmpty)

        await auth.restoreSession()

        XCTAssertTrue(auth.isAuthenticated)
        XCTAssertEqual(spy.session?.token, "saved-jwt")
        XCTAssertFalse(reloads.reloads.isEmpty)
        XCTAssertEqual(reloads.reloads.last?.session?.token, "saved-jwt")
    }
}

/// `ToggleFavoriteIntent.write` is the whole behaviour of the Favorites widget
/// heart: the server only accepts `PUT /api/assets/{id}` on v2.x, and a failed
/// write must neither reload the timelines nor vanish without a trace.
final class ToggleFavoriteIntentWriteTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }

        func append(_ value: String) {
            lock.lock()
            items.append(value)
            lock.unlock()
        }
    }

    private final class TransportSpy: WidgetDataTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let outcome: Result<Int, Error>

        init(status: Int) { outcome = .success(status) }
        init(error: Error) { outcome = .failure(error) }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
            switch outcome {
            case .failure(let error):
                throw error
            case .success(let status):
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
                )!
                return (Data(), response)
            }
        }
    }

    private struct StubSessionStore: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    private static let session = WidgetSession(baseURL: "https://photos.example.com", token: "widget-jwt")

    private struct Outcome {
        let transport: TransportSpy
        let reloads: [String]
        let logs: [String]
    }

    private func run(
        favorite: Bool = true,
        session: WidgetSession? = ToggleFavoriteIntentWriteTests.session,
        transport: TransportSpy
    ) async -> Outcome {
        let reloads = Recorder()
        let logs = Recorder()
        await ToggleFavoriteIntent.write(
            assetId: "a1",
            favorite: favorite,
            sessionStore: StubSessionStore(session: session),
            transport: transport,
            reloadTimelines: { reloads.append($0) },
            log: { logs.append($0) }
        )
        return Outcome(transport: transport, reloads: reloads.values, logs: logs.values)
    }

    private func isFavoriteBody(_ request: URLRequest) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        let dict = try XCTUnwrap(object)
        XCTAssertEqual(Set(dict.keys), ["isFavorite"])
        return try XCTUnwrap(dict["isFavorite"])
    }

    func test_AC7_write_sendsSinglePutWithBearerAndBody() async throws {
        let outcome = await run(favorite: true, transport: TransportSpy(status: 200))

        XCTAssertEqual(outcome.transport.requests.count, 1)
        let request = try XCTUnwrap(outcome.transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://photos.example.com/api/assets/a1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let value = try isFavoriteBody(request)
        XCTAssertEqual(value as? Bool, true)
        XCTAssertEqual(CFGetTypeID(value as CFTypeRef), CFBooleanGetTypeID(), "a JSON boolean, not 1/0")
    }

    func test_AC8_write_unfavoriteReloadsFavoritesThenPhotos() async throws {
        let outcome = await run(favorite: false, transport: TransportSpy(status: 200))

        let value = try isFavoriteBody(try XCTUnwrap(outcome.transport.requests.first))
        XCTAssertEqual(value as? Bool, false)
        XCTAssertEqual(CFGetTypeID(value as CFTypeRef), CFBooleanGetTypeID(), "a JSON boolean, not 1/0")
        XCTAssertEqual(outcome.reloads, [ImmichWidgetKind.favorites, ImmichWidgetKind.photos])
        XCTAssertEqual(outcome.logs, [])
    }

    func test_AC9_write_http404_logsStatusWithoutTokenAndSkipsReload() async {
        let outcome = await run(transport: TransportSpy(status: 404))

        XCTAssertEqual(outcome.transport.requests.count, 1)
        XCTAssertEqual(outcome.reloads, [])
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertTrue(outcome.logs.first?.contains("404") == true)
        XCTAssertFalse(outcome.logs.joined().contains("widget-jwt"), "the token must never be logged")
    }

    func test_AC10_write_transportError_logsAndSkipsReload() async {
        let outcome = await run(transport: TransportSpy(error: URLError(.notConnectedToInternet)))

        XCTAssertEqual(outcome.reloads, [])
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertFalse(outcome.logs.joined().contains("widget-jwt"), "the token must never be logged")
    }

    func test_AC11_write_noSession_sendsNothingAndLogs() async {
        let outcome = await run(session: nil, transport: TransportSpy(status: 200))

        XCTAssertEqual(outcome.transport.requests.count, 0)
        XCTAssertEqual(outcome.reloads, [])
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertTrue(outcome.logs.first?.contains("no widget session") == true)
    }

    /// `baseURL: ""` gives the relative URL `/api/assets/a1`: no scheme, no host.
    func test_S4_write_invalidBaseURL_sendsNothingAndLogs() async {
        let outcome = await run(
            session: WidgetSession(baseURL: "", token: "widget-jwt"),
            transport: TransportSpy(status: 200)
        )

        XCTAssertEqual(outcome.transport.requests.count, 0)
        XCTAssertEqual(outcome.reloads, [])
        XCTAssertEqual(outcome.logs.count, 1)
        XCTAssertTrue(outcome.logs.first?.contains("invalid server URL") == true)
    }

    // MARK: - Custom HTTP headers (L-09)

    func test_AC_19_favoriteWriteCarriesHeaders() async throws {
        let session = WidgetSession(
            baseURL: "https://photos.example.com", token: "widget-jwt", customHeaders: [StaticCustomHeaders.xAccess]
        )
        let outcome = await run(session: session, transport: TransportSpy(status: 200))
        let request = try XCTUnwrap(outcome.transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
    }

    // AC-119: the favorite carries the header; once the app republished the
    // session without it, the next favorite does not.
    func test_AC_119_favoriteCarriesHeadersThenNotAfterRemoval() async throws {
        let with = WidgetSession(
            baseURL: "https://photos.example.com", token: "widget-jwt", customHeaders: [StaticCustomHeaders.xAccess]
        )
        let first = await run(session: with, transport: TransportSpy(status: 200))
        XCTAssertEqual(first.transport.requests.first?.value(forHTTPHeaderField: "X-Access"), "secret")

        var republished = with
        republished.customHeaders = nil
        let second = await run(session: republished, transport: TransportSpy(status: 200))
        XCTAssertNil(second.transport.requests.first?.value(forHTTPHeaderField: "X-Access"))
        XCTAssertEqual(second.transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
    }

    func test_AC_125_favoriteUsesUserTokenHeader() async throws {
        let session = WidgetSession(
            baseURL: "https://photos.example.com", token: "widget-jwt", customHeaders: [StaticCustomHeaders.basic]
        )
        let outcome = await run(session: session, transport: TransportSpy(status: 200))
        let request = try XCTUnwrap(outcome.transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-immich-user-token"), "widget-jwt")
        XCTAssertFalse(outcome.logs.joined().contains("secret"))
    }
}

extension WidgetRenderTarget {
    /// A medium widget on a large iPhone (364×170 pt, 3×): the target the
    /// provider tests that do not care about sizes pass.
    static let medium = WidgetRenderTarget(family: .systemMedium, displaySize: CGSize(width: 364, height: 170), scale: 3)
}

// MARK: - L-30: images at the widget's real size

/// L-30 (B-35): every photo a widget draws is decoded at the size of its tile,
/// in pixels, instead of a fixed 900 / 320 px. The expected sizes are written as
/// literals (the reference numbers of the specification), never computed by
/// `WidgetTileLayout`.
final class WidgetDisplaySizeTests: XCTestCase {

    // MARK: Doubles

    /// Records every request and answers it from an async script, which may
    /// block (cancellably) to play a slow server.
    private final class Spy: WidgetDataTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let responder: @Sendable (URLRequest) async throws -> (Int, Data)

        init(_ responder: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
            self.responder = responder
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var thumbnailRequests: [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/thumbnail") == true } }
        var thumbnailPaths: [String] { thumbnailRequests.compactMap { $0.url?.path } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
            let (status, data) = try await responder(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    private struct Store: WidgetSessionStoring {
        let session: WidgetSession?
        func save(_ session: WidgetSession) {}
        func load() -> WidgetSession? { session }
        func clear() {}
    }

    private struct Source {
        let data: Data
        let width: Int
        let height: Int
    }

    private enum Surface { case recents, favorites, memories }

    // MARK: Reference targets (points; scale 3 unless said otherwise)

    private static let phoneSmall = WidgetRenderTarget(family: .systemSmall, displaySize: CGSize(width: 170, height: 170), scale: 3)
    private static let phoneMedium = WidgetRenderTarget(family: .systemMedium, displaySize: CGSize(width: 364, height: 170), scale: 3)
    private static let phoneLarge = WidgetRenderTarget(family: .systemLarge, displaySize: CGSize(width: 364, height: 382), scale: 3)
    private static let rectangular = WidgetRenderTarget(family: .accessoryRectangular, displaySize: CGSize(width: 172, height: 76), scale: 3)
    private static let circular = WidgetRenderTarget(family: .accessoryCircular, displaySize: CGSize(width: 76, height: 76), scale: 3)
    private static let inline = WidgetRenderTarget(family: .accessoryInline, displaySize: CGSize(width: 257, height: 26), scale: 3)
    /// A small iPhone: 321×148 pt medium widget at 2×.
    private static let smallPhoneMedium = WidgetRenderTarget(family: .systemMedium, displaySize: CGSize(width: 321, height: 148), scale: 2)
    private static let phoneMediumAt2x = WidgetRenderTarget(family: .systemMedium, displaySize: CGSize(width: 364, height: 170), scale: 2)

    // MARK: Sources

    /// Photographic noise over a gradient (deterministic LCG): heavy to encode,
    /// like a real photo. One JPEG at quality 0.9.
    private static func noisy(width: Int, height: Int) -> Data {
        var seed: UInt32 = 0x1234_5678
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let base = (x * 160 / width, y * 160 / height, (x + y) * 80 / (width + height))
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[offset] = UInt8(base.0 + (Int(seed >> 24) & 0x3F))
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[offset + 1] = UInt8(base.1 + (Int(seed >> 24) & 0x3F))
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[offset + 2] = UInt8(base.2 + (Int(seed >> 24) & 0x3F))
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)!
    }

    /// Three equal bands of pure red, green and blue along the long side.
    private static func bands(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let along = width >= height
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            let colors = [UIColor(red: 1, green: 0, blue: 0, alpha: 1), UIColor(red: 0, green: 1, blue: 0, alpha: 1), UIColor(red: 0, green: 0, blue: 1, alpha: 1)]
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(along
                    ? CGRect(x: width * index / 3, y: 0, width: width / 3, height: height)
                    : CGRect(x: 0, y: height * index / 3, width: width, height: height / 3))
            }
        }
        return image.jpegData(compressionQuality: 0.95)!
    }

    private static let landscape = Source(data: WidgetDisplaySizeTests.noisy(width: 2400, height: 1800), width: 2400, height: 1800)
    private static let portrait = Source(data: WidgetDisplaySizeTests.noisy(width: 1800, height: 2400), width: 1800, height: 2400)
    private static let tiny = Source(data: WidgetDisplaySizeTests.noisy(width: 300, height: 200), width: 300, height: 200)
    private static let panorama = Source(data: WidgetDisplaySizeTests.bands(width: 1440, height: 240), width: 1440, height: 240)
    private static let vertical = Source(data: WidgetDisplaySizeTests.bands(width: 480, height: 1440), width: 480, height: 1440)

    /// Even trailing digit in the id → landscape, odd → portrait.
    private static func alternating(_ id: String) -> Source {
        (id.last?.wholeNumberValue ?? 0) % 2 == 0 ? landscape : portrait
    }

    // MARK: Server and provider

    /// `/api/timeline/*` serves `timeline` ids (one bucket); `/api/memories`
    /// serves one card per entry of `memories` (newest first); thumbnails are
    /// `source(id)`, except for `blocked` ids, which never answer.
    private func server(
        timeline: [String] = [],
        memories: [[String]] = [],
        source: @escaping @Sendable (String) -> Data,
        blocked: Set<String> = []
    ) -> Spy {
        let year = Calendar.current.component(.year, from: Date())
        return Spy { request in
            let path = request.url?.path ?? ""
            if path == "/api/timeline/buckets" {
                return (200, Data(#"[{"timeBucket":"2026-09-01T00:00:00.000Z","count":\#(timeline.count + 37)}]"#.utf8))
            }
            if path == "/api/timeline/bucket" {
                let ids = timeline.map { "\"\($0)\"" }.joined(separator: ",")
                return (200, Data(#"{"id":[\#(ids)]}"#.utf8))
            }
            if path == "/api/memories" {
                let cards = memories.enumerated().map { index, assets in
                    let list = assets.map { #"{"id":"\#($0)","type":"IMAGE"}"# }.joined(separator: ",")
                    return #"{"id":"mem\#(index)","data":{"year":\#(year - 1 - index)},"assets":[\#(list)]}"#
                }.joined(separator: ",")
                return (200, Data("[\(cards)]".utf8))
            }
            guard path.hasSuffix("/thumbnail") else { return (404, Data()) }
            let id = request.url?.pathComponents.dropLast().last ?? ""
            if blocked.contains(id) { try await Task.sleep(for: .seconds(30)) }
            return (200, source(id))
        }
    }

    private func provider(
        _ spy: Spy,
        session: WidgetSession = WidgetSession(baseURL: "https://photos.example.com", token: "widget-jwt"),
        deadline: Duration = .seconds(10)
    ) -> WidgetDataProvider {
        WidgetDataProvider(sessionStore: Store(session: session), transport: { spy }, deadline: deadline)
    }

    private static func ids(_ count: Int) -> [String] { (0..<count).map { "p\($0)" } }

    /// Memory cards of 3 assets: the first asset of card `i` ends with digit `i`.
    private static func cards(_ count: Int, assets: Int = 3) -> [[String]] {
        (0..<count).map { card in (0..<assets).map { "m\(card)a\(card + $0)" } }
    }

    /// The image size of every photo (Memories: of every card's first photo) a
    /// surface produces for `target`, nil where no image was attached.
    private func drawn(
        _ surface: Surface,
        _ target: WidgetRenderTarget,
        received: Int,
        source: @escaping @Sendable (String) -> Data = { WidgetDisplaySizeTests.alternating($0).data }
    ) async -> [WidgetPixelSize?] {
        switch surface {
        case .recents:
            let spy = server(timeline: Self.ids(received), source: source)
            let wall = await provider(spy).recentPhotos(limit: target.family.photoLimit, target: target)
            return wall.photos.map { pixelSize($0.imageData) }
        case .favorites:
            let spy = server(timeline: Self.ids(received), source: source)
            let wall = await provider(spy).favoritePhotos(limit: target.family.photoLimit, target: target)
            return wall.photos.map { pixelSize($0.imageData) }
        case .memories:
            let spy = server(memories: Self.cards(received), source: source)
            let feed = await provider(spy).memories(limit: target.family.memoryLimit, offset: 0, target: target)
            return feed.cards.map { pixelSize($0.photos.first?.imageData) }
        }
    }

    // MARK: Measures

    private static func px(_ width: Int, _ height: Int) -> WidgetPixelSize? { WidgetPixelSize(width: width, height: height) }

    private func pixelSize(_ data: Data?) -> WidgetPixelSize? {
        guard let data, let image = UIImage(data: data)?.cgImage else { return nil }
        return WidgetPixelSize(width: image.width, height: image.height)
    }

    private func assertSizes(
        _ actual: [WidgetPixelSize?], _ expected: [WidgetPixelSize?], _ label: String,
        tolerance: Int = 1, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(label): number of photos", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            switch pair {
            case (nil, nil):
                continue
            case let (got?, want?):
                XCTAssertLessThanOrEqual(abs(got.width - want.width), tolerance, "\(label)[\(index)] width \(got.width) vs \(want.width)", file: file, line: line)
                XCTAssertLessThanOrEqual(abs(got.height - want.height), tolerance, "\(label)[\(index)] height \(got.height) vs \(want.height)", file: file, line: line)
            default:
                XCTFail("\(label)[\(index)]: got \(String(describing: pair.0)), wanted \(String(describing: pair.1))", file: file, line: line)
            }
        }
    }

    /// RGB of the middle pixel of a decoded image.
    private func centerPixel(_ data: Data) -> (red: Int, green: Int, blue: Int)? {
        guard let image = UIImage(data: data)?.cgImage,
              let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let memory = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(memory[0]), Int(memory[1]), Int(memory[2]))
    }

    /// Size in bytes of the same source reduced to cover `tile`, cropped to the
    /// size that was produced and encoded at quality 0.6 — re-implemented here,
    /// without the encoder, to catch any quality drop made to fit a budget.
    private func referenceBytes(_ source: Source, tile: WidgetPixelSize, produced: WidgetPixelSize) -> Int {
        guard let image = CGImageSourceCreateWithData(source.data as CFData, nil) else { return 0 }
        let factor = min(1, max(CGFloat(tile.width) / CGFloat(source.width), CGFloat(tile.height) / CGFloat(source.height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((CGFloat(max(source.width, source.height)) * factor - 1e-6).rounded(.up)),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return 0 }
        let crop = CGRect(
            x: (thumbnail.width - produced.width) / 2, y: (thumbnail.height - produced.height) / 2,
            width: produced.width, height: produced.height
        )
        guard let cropped = thumbnail.cropping(to: crop) else { return 0 }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.6)?.count ?? 0
    }

    /// AC-61.6 for one surface: `drawn` are the photos drawn (one per tile).
    private func assertFits(
        _ drawn: [WidgetPhoto], tiles: [WidgetPixelSize], spy: Spy, entryBytes: Int, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(drawn.count, tiles.count, "\(label): photos drawn", file: file, line: line)
        XCTAssertEqual(spy.thumbnailPaths.count, tiles.count, "\(label): one thumbnail request per drawn photo", file: file, line: line)
        XCTAssertLessThanOrEqual(entryBytes, 1_048_576, "\(label): the whole entry stays archivable", file: file, line: line)
        for (photo, tile) in zip(drawn, tiles) {
            guard let data = photo.imageData, let size = pixelSize(data) else {
                XCTFail("\(label): \(photo.id) has no decodable image", file: file, line: line)
                continue
            }
            XCTAssertLessThanOrEqual(size.width, tile.width + 1, "\(label): \(photo.id) width", file: file, line: line)
            XCTAssertLessThanOrEqual(size.height, tile.height + 1, "\(label): \(photo.id) height", file: file, line: line)
            let reference = referenceBytes(Self.alternating(photo.id), tile: tile, produced: size)
            XCTAssertGreaterThanOrEqual(
                Double(data.count), 0.85 * Double(reference),
                "\(label): \(photo.id) is \(data.count) bytes, the same source at quality 0.6 is \(reference)",
                file: file, line: line
            )
        }
    }

    private func bytes(_ photos: [WidgetPhoto]) -> Int { photos.compactMap(\.imageData).reduce(0) { $0 + $1.count } }

    // MARK: AC-61 and its sub-criteria

    /// AC-61 (per tile, decision #4): aggregates AC-61.1, .2, .3 and .8.
    func test_AC_61() async {
        await test_AC_61_1()
        await test_AC_61_2()
        await test_AC_61_3()
        await test_AC_61_8()
    }

    func test_AC_61_1() async {
        let small = await drawn(.recents, Self.phoneSmall, received: 2)
        assertSizes(small, [Self.px(510, 510), nil], "Recents small")
        let medium = await drawn(.recents, Self.phoneMedium, received: 3)
        assertSizes(medium, [Self.px(537, 510), Self.px(537, 246), Self.px(537, 246)], "Recents medium")
        let large = await drawn(.recents, Self.phoneLarge, received: 5)
        assertSizes(large, [Self.px(1092, 711), Self.px(352, 418), Self.px(352, 418), Self.px(352, 418), nil], "Recents large")
    }

    func test_AC_61_2() async {
        let small = await drawn(.favorites, Self.phoneSmall, received: 2)
        assertSizes(small, [Self.px(246, 510), Self.px(246, 510)], "Favorites small, 2")
        let smallOne = await drawn(.favorites, Self.phoneSmall, received: 1)
        assertSizes(smallOne, [Self.px(510, 510)], "Favorites small, 1")
        let medium = await drawn(.favorites, Self.phoneMedium, received: 3)
        assertSizes(medium, [Self.px(352, 510), Self.px(352, 510), Self.px(352, 510)], "Favorites medium, 3")
        let mediumOne = await drawn(.favorites, Self.phoneMedium, received: 1)
        assertSizes(mediumOne, [Self.px(1092, 510)], "Favorites medium, 1")
        let large = await drawn(.favorites, Self.phoneLarge, received: 5)
        assertSizes(large, [Self.px(352, 564), Self.px(352, 564), Self.px(352, 564), Self.px(537, 564), Self.px(537, 564)], "Favorites large, 5")
        let largeOne = await drawn(.favorites, Self.phoneLarge, received: 1)
        assertSizes(largeOne, [Self.px(1092, 1146)], "Favorites large, 1")
    }

    func test_AC_61_3() async {
        let small = await drawn(.memories, Self.phoneSmall, received: 2)
        assertSizes(small, [Self.px(510, 510)], "Memories small")
        let medium = await drawn(.memories, Self.phoneMedium, received: 2)
        assertSizes(medium, [Self.px(537, 510), Self.px(537, 510)], "Memories medium, 2 cards")
        let mediumOne = await drawn(.memories, Self.phoneMedium, received: 1)
        assertSizes(mediumOne, [Self.px(1092, 510)], "Memories medium, 1 card")
    }

    /// AC-61.4: the size follows the widget — a bigger display size or a
    /// higher screen scale gives bigger images, nothing caps them below the tile.
    func test_AC_61_4() async {
        let small = await drawn(.recents, Self.smallPhoneMedium, received: 3)
        assertSizes(small, [Self.px(315, 296), Self.px(315, 142), Self.px(315, 142)], "small iPhone")
        let large = await drawn(.recents, Self.phoneMedium, received: 3)
        XCTAssertEqual(small.count, large.count)
        for (little, big) in zip(small, large) {
            XCTAssertGreaterThan(big?.width ?? 0, little?.width ?? .max)
            XCTAssertGreaterThan(big?.height ?? 0, little?.height ?? .max)
        }

        let twoX = await drawn(.recents, Self.phoneMediumAt2x, received: 3)
        let threeX = await drawn(.recents, Self.phoneMedium, received: 3)
        XCTAssertEqual(twoX.count, threeX.count)
        for (little, big) in zip(twoX, threeX) {
            XCTAssertGreaterThan(big?.width ?? 0, little?.width ?? .max, "the same widget at 3× has more pixels than at 2×")
            XCTAssertGreaterThan(big?.height ?? 0, little?.height ?? .max)
        }
    }

    /// AC-61.5: a preview smaller than the tile is neither enlarged nor
    /// replaced by the original.
    func test_AC_61_5() async {
        let spy = server(timeline: Self.ids(5), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let wall = await provider(spy).recentPhotos(limit: 5, target: Self.phoneLarge)

        let sizes = wall.photos.map { pixelSize($0.imageData) }
        assertSizes(sizes, [Self.px(300, 200), Self.px(300, 200), Self.px(300, 200), Self.px(300, 200), nil], "tiny preview", tolerance: 0)
        XCTAssertTrue(spy.requests.allSatisfy { $0.url?.path.contains("/original") == false }, "the original is never asked for")
        XCTAssertNotNil(wall.photos[0].imageData.flatMap { UIImage(data: $0) }, "the widget has an image to draw")
    }

    func test_AC_61_6_recents() async {
        let spy = server(timeline: Self.ids(5), source: { WidgetDisplaySizeTests.alternating($0).data })
        let wall = await provider(spy).recentPhotos(limit: 5, target: Self.phoneLarge)

        assertFits(
            Array(wall.photos.prefix(4)),
            tiles: [WidgetPixelSize(width: 1092, height: 711)] + Array(repeating: WidgetPixelSize(width: 352, height: 418), count: 3),
            spy: spy, entryBytes: bytes(wall.photos), "Recents large"
        )
    }

    func test_AC_61_6_favorites() async {
        let spy = server(timeline: Self.ids(5), source: { WidgetDisplaySizeTests.alternating($0).data })
        let wall = await provider(spy).favoritePhotos(limit: 5, target: Self.phoneLarge)

        assertFits(
            wall.photos,
            tiles: Array(repeating: WidgetPixelSize(width: 352, height: 564), count: 3) + Array(repeating: WidgetPixelSize(width: 537, height: 564), count: 2),
            spy: spy, entryBytes: bytes(wall.photos), "Favorites large"
        )
    }

    func test_AC_61_6_memories() async {
        let spy = server(memories: Self.cards(2, assets: 30), source: { WidgetDisplaySizeTests.alternating($0).data })
        let feed = await provider(spy).memories(limit: 2, offset: 0, target: Self.phoneMedium)

        XCTAssertEqual(feed.cards.count, 2)
        assertFits(
            feed.cards.compactMap { $0.photos.first },
            tiles: Array(repeating: WidgetPixelSize(width: 537, height: 510), count: 2),
            spy: spy, entryBytes: feed.cards.reduce(0) { $0 + bytes($1.photos) }, "Memories medium"
        )
    }

    /// AC-61.7: an extreme aspect ratio is covered, not letterboxed, and
    /// cropped around its centre.
    func test_AC_61_7() async {
        let cases: [(name: String, source: Source, target: WidgetRenderTarget, received: Int, expected: WidgetPixelSize)] = [
            ("panorama small", Self.panorama, Self.phoneSmall, 1, WidgetPixelSize(width: 510, height: 240)),
            ("vertical small", Self.vertical, Self.phoneSmall, 1, WidgetPixelSize(width: 480, height: 510)),
            ("panorama large", Self.panorama, Self.phoneLarge, 5, WidgetPixelSize(width: 1092, height: 240)),
            ("vertical large", Self.vertical, Self.phoneLarge, 5, WidgetPixelSize(width: 480, height: 711)),
        ]
        for scenario in cases {
            let data = scenario.source.data
            let spy = server(timeline: Self.ids(scenario.received), source: { _ in data })
            let wall = await provider(spy).recentPhotos(limit: scenario.target.family.photoLimit, target: scenario.target)

            guard let main = wall.photos.first?.imageData, let size = pixelSize(main) else {
                XCTFail("\(scenario.name): the photo has no image (plate fallback)")
                continue
            }
            XCTAssertLessThanOrEqual(abs(size.width - scenario.expected.width), 1, "\(scenario.name): width \(size.width)")
            XCTAssertLessThanOrEqual(abs(size.height - scenario.expected.height), 1, "\(scenario.name): height \(size.height)")
            let centre = centerPixel(main)
            XCTAssertGreaterThanOrEqual(centre?.green ?? 0, 200, "\(scenario.name): the centre is the middle band")
            XCTAssertLessThanOrEqual(centre?.red ?? 255, 55, "\(scenario.name): no red")
            XCTAssertLessThanOrEqual(centre?.blue ?? 255, 55, "\(scenario.name): no blue")
            XCTAssertLessThanOrEqual(bytes(wall.photos), 1_048_576, "\(scenario.name): entry weight")
        }
    }

    /// AC-61.8: the Lock Screen thumbnails are the size of their pad.
    func test_AC_61_8() async {
        let recents = await drawn(.recents, Self.rectangular, received: 1)
        assertSizes(recents, [Self.px(102, 102)], "Recents rectangular")
        let circular = await drawn(.memories, Self.circular, received: 2)
        assertSizes(circular, [Self.px(192, 192)], "Memories circular")
        let memoriesRectangular = await drawn(.memories, Self.rectangular, received: 2)
        assertSizes(memoriesRectangular, [Self.px(120, 120)], "Memories rectangular")
    }

    /// AC-61.9: what the widget already guaranteed still holds.
    func test_AC_61_9() async {
        let session = WidgetSession(baseURL: "https://photos.example.com", token: "widget-jwt", customHeaders: [StaticCustomHeaders.xAccess])
        let spy = server(timeline: Self.ids(3), source: { _ in JpegXLFixture.thumbnail })
        let wall = await provider(spy, session: session).recentPhotos(limit: 3, target: Self.phoneMedium)

        XCTAssertEqual(spy.thumbnailRequests.count, 3, "one thumbnail request per drawn photo")
        for request in spy.thumbnailRequests {
            XCTAssertTrue(request.url?.query?.contains("edited=true") == true, request.url?.absoluteString ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer widget-jwt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret")
        }
        for photo in wall.photos {
            // The JPEG XL fixture is 200×200: smaller than every tile, so it keeps its size.
            XCTAssertEqual(pixelSize(photo.imageData), WidgetPixelSize(width: 200, height: 200))
        }

        let brokenSpy = server(timeline: Self.ids(3), source: { _ in JpegXLFixture.truncated })
        let broken = await provider(brokenSpy, session: session).recentPhotos(limit: 3, target: Self.phoneMedium)
        XCTAssertEqual(broken.photos.count, 3, "an undecodable image keeps its photo")
        XCTAssertTrue(broken.photos.allSatisfy { $0.imageData == nil }, "and falls back to the plate")

        let mute = Spy { _ in
            try await Task.sleep(for: .seconds(30))
            return (200, Data())
        }
        let silent = provider(mute, deadline: .milliseconds(80))
        let recents = await silent.recentPhotos(limit: 3, target: Self.phoneMedium)
        let favorites = await silent.favoritePhotos(limit: 3, target: Self.phoneMedium)
        let memories = await silent.memories(limit: 2, offset: 0, target: Self.phoneMedium)
        XCTAssertEqual(recents.availability, .unreachable)
        XCTAssertEqual(favorites.availability, .unreachable)
        XCTAssertEqual(memories.availability, .unreachable)
    }

    /// AC-61.10: only the photos a composition draws are downloaded.
    func test_AC_61_10() async {
        let memoriesSpy = server(memories: Self.cards(2, assets: 40), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let feed = await provider(memoriesSpy).memories(limit: 2, offset: 0, target: Self.phoneMedium)
        XCTAssertEqual(memoriesSpy.thumbnailRequests.count, 2, "one request per drawn card")
        XCTAssertEqual(feed.cards.map { $0.photos.count }, [40, 40], "each card still says 40 photos")
        for card in feed.cards {
            XCTAssertNotNil(card.photos[0].imageData)
            XCTAssertTrue(card.photos.dropFirst().allSatisfy { $0.imageData == nil }, "undrawn photos carry no image")
        }

        let smallSpy = server(timeline: Self.ids(2), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let small = await provider(smallSpy).recentPhotos(limit: 2, target: Self.phoneSmall)
        XCTAssertEqual(smallSpy.thumbnailRequests.count, 1)
        XCTAssertEqual(small.photos.map(\.id), ["p0", "p1"], "the undrawn photo stays in the entry")
        XCTAssertNil(small.photos[1].imageData)

        let largeSpy = server(timeline: Self.ids(5), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let large = await provider(largeSpy).recentPhotos(limit: 5, target: Self.phoneLarge)
        XCTAssertEqual(largeSpy.thumbnailRequests.count, 4)
        XCTAssertNil(large.photos[4].imageData)
    }

    /// AC-61.10: a family that draws no photo, or a widget with no size, downloads nothing.
    func test_AC_61_10_nothingDrawnNothingDownloaded() async {
        let inlineSpy = server(timeline: Self.ids(2), memories: Self.cards(1), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let recents = await provider(inlineSpy).recentPhotos(limit: 1, target: Self.inline)
        let favorites = await provider(inlineSpy).favoritePhotos(limit: 1, target: Self.circular)
        let memories = await provider(inlineSpy).memories(limit: 1, offset: 0, target: Self.inline)
        XCTAssertEqual(recents.availability, .ready)
        XCTAssertEqual(favorites.availability, .ready)
        XCTAssertEqual(memories.cards.count, 1)
        XCTAssertTrue(inlineSpy.thumbnailRequests.isEmpty)

        let zero = WidgetRenderTarget(family: .systemMedium, displaySize: .zero, scale: 3)
        let zeroSpy = server(timeline: Self.ids(3), source: { _ in WidgetDisplaySizeTests.tiny.data })
        let wall = await provider(zeroSpy).recentPhotos(limit: 3, target: zero)
        XCTAssertEqual(wall.photos.count, 3)
        XCTAssertTrue(zeroSpy.thumbnailRequests.isEmpty)
    }

    /// AC-61.11: slow previews never turn the widget "unreachable".
    func test_AC_61_11() async {
        let clock = ContinuousClock()
        let recentsSpy = server(
            timeline: Self.ids(5), source: { WidgetDisplaySizeTests.alternating($0).data },
            blocked: ["p1", "p2", "p3", "p4"]
        )
        let start = clock.now
        let wall = await provider(recentsSpy, deadline: .seconds(2)).recentPhotos(limit: 5, target: Self.phoneLarge)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2), "back before the refresh deadline")

        XCTAssertEqual(wall.availability, .ready)
        XCTAssertEqual(wall.photos.map(\.id), Self.ids(5))
        XCTAssertEqual(wall.totalCount, 42)
        XCTAssertEqual(wall.newestCount, 42)
        assertSizes(wall.photos.map { pixelSize($0.imageData) }, [Self.px(1092, 711), nil, nil, nil, nil], "Recents with slow previews")
        XCTAssertEqual(recentsSpy.thumbnailPaths, ["/api/assets/p0/thumbnail", "/api/assets/p1/thumbnail"], "one by one, none after the cutoff")

        let memoriesSpy = server(
            memories: Self.cards(2), source: { WidgetDisplaySizeTests.alternating($0).data }, blocked: ["m1a1"]
        )
        let feed = await provider(memoriesSpy, deadline: .seconds(2)).memories(limit: 2, offset: 0, target: Self.phoneMedium)
        XCTAssertEqual(feed.availability, .ready)
        XCTAssertEqual(feed.cards.count, 2)
        XCTAssertNotNil(feed.cards[0].photos[0].imageData)
        XCTAssertNil(feed.cards[1].photos[0].imageData)
        XCTAssertEqual(feed.cards.map { $0.photos.count }, [3, 3])
    }
}
