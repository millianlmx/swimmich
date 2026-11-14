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

    func test_AC_240_diskCopyIsKeptUnderTheConnectionAddress() throws {
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let book = makeBook()
        let localURL = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        let externalURL = URL(string: "https://photos.example.org/api/assets/a/thumbnail?size=thumbnail")!

        AuthenticatedAsyncImage.storeCanonicalDiskCopy(
            data: pngData(), response: response(for: localURL), for: localURL, cache: cache, addressBook: book
        )

        XCTAssertNotNil(cache.cachedResponse(for: URLRequest(url: externalURL)), "the session finds it on the external address")
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
}
