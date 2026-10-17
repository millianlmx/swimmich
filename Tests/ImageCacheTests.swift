import XCTest
@testable import ImmichSwiftUI

/// AC-200: ImageCache thread-safety + store/retrieve semantics.
final class ImageCacheTests: XCTestCase {

    private func makeImage(color: UIColor = .red, size: CGSize = CGSize(width: 32, height: 32)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // store then retrieve returns the SAME instance.
    func test_cacheStoreAndRetrieve() async {
        let cache = ImageCache()
        let url = URL(string: "https://example.com/img/a")!
        let img = makeImage(color: .blue)
        await cache.removeAll()

        // Miss before store.
        let pre = await cache.image(for: url)
        XCTAssertNil(pre)

        await cache.store(img, for: url, epoch: await cache.epoch)
        let hit = await cache.image(for: url)
        XCTAssertNotNil(hit)
        // Reference equality — NSCache retains the stored object.
        XCTAssertTrue(hit === img)
    }

    // Unknown URL → nil (no false positives).
    func test_cacheMissReturnsNil() async {
        let cache = ImageCache()
        await cache.removeAll()
        let a = URL(string: "https://example.com/a")!
        let b = URL(string: "https://example.com/b")!
        await cache.store(makeImage(), for: a, epoch: await cache.epoch)

        let miss = await cache.image(for: b)
        XCTAssertNil(miss)
        let hit = await cache.image(for: a)
        XCTAssertNotNil(hit)
    }

    // Concurrent store/retrieve across many URLs must not crash or corrupt.
    func test_cacheThreadSafety() async {
        let cache = ImageCache()
        await cache.removeAll()
        let epoch = await cache.epoch

        let urls = (0..<60).map { URL(string: "https://example.com/c/\($0)")! }
        let images = urls.map { _ in makeImage() }

        // Seed half the entries, leave the other half missing.
        for i in stride(from: 0, to: urls.count, by: 2) {
            await cache.store(images[i], for: urls[i], epoch: epoch)
        }

        await withTaskGroup(of: Void.self) { group in
            // Concurrent writers + readers on the same actor.
            for i in 0..<urls.count {
                let cache = cache
                let url = urls[i]
                let img = images[i]
                group.addTask {
                    await cache.store(img, for: url, epoch: epoch)
                }
                group.addTask {
                    _ = await cache.image(for: url)
                }
            }
        }

        // After concurrent writes, every URL should resolve to a non-nil image.
        for url in urls {
            let v = await cache.image(for: url)
            XCTAssertNotNil(v, "cache missing entry after concurrent seed: \(url)")
        }
    }

    // A load that read the epoch before a purge must not repopulate the cache
    // with pre-purge data; a load that starts after the purge stores normally.
    func test_storeWithStaleEpoch_isDroppedAfterRemoveAll() async {
        let cache = ImageCache()
        let url = URL(string: "https://example.com/img/stale")!
        let staleEpoch = await cache.epoch

        await cache.removeAll()
        await cache.store(makeImage(), for: url, epoch: staleEpoch)
        let dropped = await cache.image(for: url)
        XCTAssertNil(dropped, "a store carrying a pre-purge epoch must be dropped")

        let freshEpoch = await cache.epoch
        XCTAssertNotEqual(freshEpoch, staleEpoch)
        await cache.store(makeImage(), for: url, epoch: freshEpoch)
        let stored = await cache.image(for: url)
        XCTAssertNotNil(stored, "a store carrying the current epoch must succeed")
    }
}
