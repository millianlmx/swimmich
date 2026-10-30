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
        WidgetDataProvider(sessionStore: StubSessionStore(session: session), transport: spy)
    }
    private func url(_ request: URLRequest) -> String {
        request.url?.absoluteString ?? ""
    }

    // MARK: - Photos wall

    func test_recentPhotos_heroIsNewest_fetchedAtPreviewSize() async {
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

        let wall = await provider(spy).recentPhotos(limit: 3)

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

        // The thumbnails are fetched concurrently, so assert the set, not the order.
        let thumbnails = requests.filter { $0.url?.path.contains("/thumbnail") == true }
        XCTAssertEqual(thumbnails.count, 3)
        let previews = thumbnails.filter { url($0).contains("size=preview") }
        XCTAssertEqual(previews.count, 1, "the hero is the one big render")
        XCTAssertTrue(url(previews[0]).contains("/api/assets/hero/thumbnail"))
        XCTAssertEqual(thumbnails.filter { url($0).contains("size=thumbnail") }.count, 2)
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

        let wall = await provider(spy).favoritePhotos(limit: 2)

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

        _ = await provider(spy).favoritePhotos(limit: 1)

        let bucket = bucketRequest(spy)
        XCTAssertEqual(bucket.map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&isFavorite=true&visibility=timeline")
        let buckets = spy.requests.first { $0.url?.path == "/api/timeline/buckets" }
        XCTAssertTrue(buckets.map(url)?.contains("isFavorite=true") == true, "same filter as the buckets request")
    }

    func test_AC8_recentPhotos_bucketRequestHasNoFavoriteFilter() async {
        let spy = wallSpy()

        _ = await provider(spy).recentPhotos(limit: 1)

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

        _ = await provider(spy).recentPhotos(limit: 1)

        XCTAssertEqual(bucketsRequest(spy).map(url), "https://photos.example.com/api/timeline/buckets?visibility=timeline")
    }

    func test_AC2_recentPhotos_bucketRequestAsksTimelineVisibility() async {
        let spy = wallSpy()

        _ = await provider(spy).recentPhotos(limit: 1)

        XCTAssertEqual(bucketRequest(spy).map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&visibility=timeline")
    }

    func test_AC3_favoritePhotos_bothRoutesAskFavoritesInTimeline() async {
        let spy = wallSpy()

        _ = await provider(spy).favoritePhotos(limit: 1)

        XCTAssertEqual(bucketsRequest(spy).map(url), "https://photos.example.com/api/timeline/buckets?isFavorite=true&visibility=timeline")
        XCTAssertEqual(bucketRequest(spy).map(url), "https://photos.example.com/api/timeline/bucket?timeBucket=2026-08-01T00:00:00.000Z&isFavorite=true&visibility=timeline")
    }

    func test_AC4_bothWalls_bucketsAndBucketCarryTheSameFilters() async {
        for favorites in [false, true] {
            let spy = wallSpy()
            if favorites {
                _ = await provider(spy).favoritePhotos(limit: 1)
            } else {
                _ = await provider(spy).recentPhotos(limit: 1)
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

        let wall = await provider(spy).recentPhotos(limit: 1)

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

        let first = (await provider(spy).memories(limit: 2, offset: 0)).cards
        let second = (await provider(spy).memories(limit: 2, offset: 1)).cards

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

        let cards = (await provider(spy).memories(limit: 2, offset: 7)).cards

        XCTAssertEqual(cards.map(\.id), ["only"], "an offset past the end wraps instead of returning nothing")
    }

    // MARK: - Degradation

    func test_noSession_returnsEmptyAndMakesNoRequest() async {
        let spy = TransportSpy { _ in (200, Data()) }

        let wall = await provider(spy, session: nil).recentPhotos(limit: 3)
        let favorites = await provider(spy, session: nil).favoritePhotos(limit: 3)
        let feed = await provider(spy, session: nil).memories(limit: 2, offset: 0)

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

        let rejected = await provider(unauthorized).recentPhotos(limit: 3)
        let failed = await provider(broken).recentPhotos(limit: 3)

        XCTAssertTrue(rejected.isEmpty)
        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(rejected.availability, .signedOut, "a revoked token is a sign-in problem, not a network one")
        XCTAssertEqual(failed.availability, .unreachable)
        let memories = await provider(broken).memories(limit: 1, offset: 0)
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

        let wall = await provider(spy).recentPhotos(limit: 3)

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

        let wall = await provider(spy).recentPhotos(limit: 2)

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
            transport: HangingTransport(),
            deadline: .milliseconds(80)
        )

        let wall = await provider.recentPhotos(limit: 3)
        let feed = await provider.memories(limit: 1, offset: 0)

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

    func test_entryImages_areShrunkToWidgetSize() {
        let original = bigImage()
        XCTAssertGreaterThan(original.count, 200_000, "the fixture must be heavy enough to matter")

        let hero = WidgetImageEncoder.encode(original, at: .hero)
        let cell = WidgetImageEncoder.encode(original, at: .cell)

        XCTAssertNotNil(hero)
        XCTAssertNotNil(cell)
        XCTAssertLessThan(hero!.count, 220_000, "a 900 px re-encode must not carry the original weight")
        XCTAssertLessThan(cell!.count, 40_000)
        XCTAssertLessThan(hero!.count, original.count / 2)
        guard let decoded = UIImage(data: hero!) else { return XCTFail("hero must stay decodable") }
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 900)
    }

    func test_entryBudget_stopsAttachingBytesInsteadOfExceedingIt() {
        let heavy = bigImage()
        let photos = (0..<6).map { index in
            WidgetPhoto(id: "p-\(index)", imageData: heavy, isVideo: false, isFavorite: false, day: nil)
        }

        // A budget that fits the hero and nothing else: what survives must be
        // the hero, never the satellites.
        let heroOnly = (WidgetImageEncoder.encode(heavy, at: .hero)?.count ?? 0) + 1_000
        let budgeted = WidgetImageEncoder.budgeted(photos, budget: heroOnly)

        XCTAssertNotNil(budgeted[0].imageData, "the hero is the one that matters")
        XCTAssertLessThanOrEqual(budgeted.compactMap(\.imageData).reduce(0) { $0 + $1.count }, heroOnly)
        XCTAssertTrue(budgeted.dropFirst().allSatisfy { $0.imageData == nil }, "the budget is spent by the hero")
        XCTAssertEqual(budgeted.map(\.id), photos.map(\.id), "every cell survives, just without bytes")
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

        let wall = await provider(spy).recentPhotos(limit: 3)

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
}
