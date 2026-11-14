import UIKit
import XCTest
@testable import ImmichSwiftUI

/// L-26: an image seen through one address of the server serves through the other.
final class ImageCacheCanonicalKeyTests: XCTestCase {
    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!

    private func makeBook() -> ServerAddressBook {
        let book = ServerAddressBook()
        book.update(accountURL: account, addresses: [account, local], activeURL: account)
        return book
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func response(for url: URL, cacheControl: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"].merging(cacheControl.map { ["Cache-Control": $0] } ?? [:]) { $1 }
        )!
    }

    func test_AC_240_memoryImageSeenLocallyServesTheExternalAddress() async throws {
        let cache = ImageCache(addressBook: makeBook())
        let image = try XCTUnwrap(UIImage(data: pngData()))
        let seenLocally = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        let sameOnExternal = URL(string: "https://photos.example.org/api/assets/a/thumbnail?size=thumbnail")!

        await cache.store(image, for: seenLocally, epoch: await cache.epoch)

        let found = await cache.image(for: sameOnExternal)
        XCTAssertNotNil(found, "no new request for an image already seen")
        XCTAssertNotNil(cache.cachedImage(for: sameOnExternal))
    }

    func test_AC_240_anotherHostIsNotConfused() async throws {
        let cache = ImageCache(addressBook: makeBook())
        let image = try XCTUnwrap(UIImage(data: pngData()))
        await cache.store(image, for: URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail")!, epoch: await cache.epoch)

        let foreign = await cache.image(for: URL(string: "https://other.example.org/api/assets/a/thumbnail")!)
        XCTAssertNil(foreign)
        let otherQuery = await cache.image(for: URL(string: "https://photos.example.org/api/assets/a/thumbnail?size=preview")!)
        XCTAssertNil(otherQuery)
    }

    func test_AC_240_withoutAnAddressBookTheKeyIsTheURL() async throws {
        let cache = ImageCache(addressBook: ServerAddressBook())
        let image = try XCTUnwrap(UIImage(data: pngData()))
        let url = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail")!
        await cache.store(image, for: url, epoch: await cache.epoch)

        let sameAsset = await cache.image(for: URL(string: "https://photos.example.org/api/assets/a/thumbnail")!)
        XCTAssertNil(sameAsset, "no declared alias: nothing is shared")
        let found = await cache.image(for: url)
        XCTAssertNotNil(found)
    }

    func test_AC_240_otherPortOrSchemeIsNotConfused() async throws {
        let cache = ImageCache(addressBook: makeBook())
        let image = try XCTUnwrap(UIImage(data: pngData()))
        await cache.store(image, for: URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail")!, epoch: await cache.epoch)

        let otherPort = await cache.image(for: URL(string: "http://192.168.1.10:2284/api/assets/a/thumbnail")!)
        XCTAssertNil(otherPort)
        let otherScheme = await cache.image(for: URL(string: "https://192.168.1.10:2283/api/assets/a/thumbnail")!)
        XCTAssertNil(otherScheme)
        let external = await cache.image(for: URL(string: "https://photos.example.org/api/assets/a/thumbnail")!)
        XCTAssertNotNil(external, "the account's own address does find it")
    }

    func test_AC_240_diskCopyIsKeptUnderTheConnectionAddress() throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        let externalURL = URL(string: "https://photos.example.org/api/assets/a/thumbnail?size=thumbnail")!

        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: localURL), for: localURL, cache: cache, addressBook: book
        )

        XCTAssertNotNil(cache.cachedResponse(for: URLRequest(url: externalURL)), "an entry exists under the connection address")
        XCTAssertNotNil(AuthenticatedAsyncImage.canonicalDiskImage(for: localURL, cache: cache, addressBook: book))
    }

    func test_AC_240_noStoreAnswersAreNeverCopied() {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail")!

        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: localURL, cacheControl: "private, no-store"),
            for: localURL, cache: cache, addressBook: book
        )

        XCTAssertNil(AuthenticatedAsyncImage.canonicalDiskImage(for: localURL, cache: cache, addressBook: book))
    }

    func test_AC_240_theConnectionAddressItselfIsLeftToTheSession() {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let externalURL = URL(string: "https://photos.example.org/api/assets/a/thumbnail")!

        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: externalURL), for: externalURL, cache: cache, addressBook: book
        )

        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: externalURL)), "URLSession stores this one itself")
        XCTAssertNil(AuthenticatedAsyncImage.canonicalDiskImage(for: externalURL, cache: cache, addressBook: book))
    }

    // MARK: - Disk tier through the session

    private func imageSession(cache: URLCache, protocolClass: AnyClass) -> URLSession {
        let configuration = ServerSessions.imageConfiguration(cache: cache)
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    private func image(
        _ url: URL, cache: URLCache, session: URLSession, book: ServerAddressBook
    ) async -> UIImage? {
        await AuthenticatedAsyncImage.fetchImage(
            for: url, token: "tok", customHeaders: [StaticCustomHeaders.xAccess],
            session: session, cache: cache, addressBook: book
        )
    }

    override func tearDown() {
        CapturingURLProtocol.reset()
        ConnectionCopyProtocol.reset()
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        CapturingURLProtocol.reset()
        ConnectionCopyProtocol.reset()
    }

    func test_AC_240_localURLReadsTheConnectionCopyWithoutTheSession() async {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: localURL), for: localURL, cache: cache, addressBook: book
        )
        CapturingURLProtocol.nextStatus = 500

        let found = await image(localURL, cache: cache, session: imageSession(cache: cache, protocolClass: CapturingURLProtocol.self), book: book)

        XCTAssertNotNil(found, "served from the copy under the connection address")
        XCTAssertNil(CapturingURLProtocol.lastRequest, "no request left the app")
    }

    func test_AC_240_connectionAddressServesTheCopyWithoutNetwork() async throws {
        let connection = URL(string: "https://photos.l26.invalid")!
        let book = ServerAddressBook()
        book.update(accountURL: connection, addresses: [connection, local], activeURL: connection)
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        let connectionURL = URL(string: "https://photos.l26.invalid/api/assets/a/thumbnail?size=thumbnail")!
        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: localURL), for: localURL, cache: cache, addressBook: book
        )
        // The real HTTP stack, no test protocol: a request to `.invalid` fails.
        let session = URLSession(configuration: ServerSessions.imageConfiguration(cache: cache))

        let found = await image(connectionURL, cache: cache, session: session, book: book)

        let decoded = try XCTUnwrap(found, "the session went to the network instead of serving the copy")
        let stored = try XCTUnwrap(UIImage(data: pngData()))
        XCTAssertEqual(decoded.size, stored.size)
    }

    func test_AC_240_sessionCopyOfTheConnectionAddressServesTheLocalOne() async throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let connectionURL = URL(string: "https://photos.example.org/api/assets/a/thumbnail?size=thumbnail")!
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        let session = imageSession(cache: cache, protocolClass: ConnectionCopyProtocol.self)

        let first = await image(connectionURL, cache: cache, session: session, book: book)
        XCTAssertNotNil(first)
        let request = try XCTUnwrap(ConnectionCopyProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Access"), "secret")

        // The session may store the answer a moment after it returns.
        var stored = false
        for _ in 0..<40 where !stored {
            stored = cache.cachedResponse(for: URLRequest(url: connectionURL)) != nil
            if !stored { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(stored, "the session did not store the connection answer")

        let onLocal = await image(localURL, cache: cache, session: session, book: book)

        XCTAssertNotNil(onLocal)
        XCTAssertEqual(ConnectionCopyProtocol.requests.count, 1, "the local address was served without a second request")
    }

    func test_AC_240_fetchedLocalAnswerIsCopiedUnlessNoStore() async {
        let book = makeBook()
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        CapturingURLProtocol.nextData = pngData()
        CapturingURLProtocol.nextHeaders = ["Content-Type": "image/png"]

        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let fetched = await image(localURL, cache: cache, session: imageSession(cache: cache, protocolClass: CapturingURLProtocol.self), book: book)
        XCTAssertNotNil(fetched)
        XCTAssertNotNil(AuthenticatedAsyncImage.canonicalDiskImage(for: localURL, cache: cache, addressBook: book))

        CapturingURLProtocol.nextHeaders = ["Content-Type": "image/png", "Cache-Control": "private, no-store"]
        let freshCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let noStore = await image(localURL, cache: freshCache, session: imageSession(cache: freshCache, protocolClass: CapturingURLProtocol.self), book: book)
        XCTAssertNotNil(noStore, "the image is still shown")
        XCTAssertNil(AuthenticatedAsyncImage.canonicalDiskImage(for: localURL, cache: freshCache, addressBook: book))
    }

    func test_AC_240_withoutAddressesNothingExtraIsWritten() async {
        let url = URL(string: "https://photos.example.org/api/assets/a/thumbnail")!
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        CapturingURLProtocol.nextData = pngData()
        CapturingURLProtocol.nextHeaders = ["Content-Type": "image/png"]

        let fetched = await image(
            url, cache: cache, session: imageSession(cache: cache, protocolClass: CapturingURLProtocol.self),
            book: ServerAddressBook()
        )

        XCTAssertNotNil(fetched)
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.url, url)
        XCTAssertNil(cache.cachedResponse(for: URLRequest(url: url)), "the captured answer is not storable: any entry would be the app's")
    }

    func test_AC_240_connectionAddressWithoutAliasIsLeftToTheSession() {
        let book = ServerAddressBook()
        book.update(accountURL: account, addresses: [account], activeURL: account)
        let url = URL(string: "https://photos.example.org/api/people/p/thumbnail")!
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        cache.storeCachedResponse(CachedURLResponse(response: response(for: url), data: pngData()), for: URLRequest(url: url))

        XCTAssertNil(
            AuthenticatedAsyncImage.canonicalDiskImage(for: url, cache: cache, addressBook: book),
            "an account without alias leaves its images to the session"
        )

        let fresh = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: url), for: url, cache: fresh, addressBook: book
        )
        XCTAssertNil(fresh.cachedResponse(for: URLRequest(url: url)), "nothing is written under the connection address")
    }
}

/// Answers a cacheable image and keeps every request it receives. The answer
/// goes to the session's cache like a real HTTP answer would.
private final class ConnectionCopyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func reset() { lock.lock(); _requests = []; lock.unlock() }

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requests.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Cache-Control": "private, max-age=86400"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
