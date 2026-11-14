import AVFoundation
import XCTest
@testable import ImmichSwiftUI

/// The real engine on throwaway files (no network, no mock). The fixtures are
/// written by `VideoFixture`; each test checks its own preconditions on the file
/// first, so a simulator that reads the fixture differently fails loudly there
/// instead of passing for the wrong reason.
@MainActor
final class AVVideoPlaybackEngineReadabilityTests: XCTestCase {

    private var files: [URL] = []

    override func tearDown() {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
        super.tearDown()
    }

    private func write(_ data: Data, pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url)
        files.append(url)
        return url
    }

    /// A copy that loads a duration but cannot be played: the case of AC-59.6,
    /// an intact file in a format the device does not read.
    func test_AC_59_6_unsupportedCodecIsNotPlayable() async throws {
        let url = try write(try VideoFixture.makeUnsupportedCodecMovieData(), pathExtension: "mov")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "precondition: the container is intact, its duration loads")
        let playable = try await asset.load(.isPlayable)
        XCTAssertFalse(playable, "precondition: no decoder for this track")

        let engine = AVVideoPlaybackEngine()
        let ready = TestBox(0)
        engine.onReady = { _ in ready.value += 1 }

        do {
            try await engine.prepare(url: url, token: nil)
            XCTFail("an unplayable file must not prepare")
        } catch {
            XCTAssertEqual(error as? VideoPlaybackEngineError, .notPlayable)
        }
        XCTAssertEqual(ready.value, 0)
    }

    /// A file that is ready, then fails while it plays: the engine says so once.
    func test_AC_59_3_itemFailingAfterReadyEmitsOnFailureOnce() async throws {
        let url = try write(try VideoFixture.makeTruncatedMovieData(), pathExtension: "mp4")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0, "precondition: moov first, the duration loads")
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "precondition: the format itself is playable")

        let engine = AVVideoPlaybackEngine()
        let ready = TestBox(0)
        let failures = TestBox(0)
        let ended = TestBox(0)
        let failed = expectation(description: "onFailure")
        failed.assertForOverFulfill = false
        engine.onReady = { _ in ready.value += 1 }
        engine.onEnded = { ended.value += 1 }
        engine.onFailure = { _ in
            failures.value += 1
            failed.fulfill()
        }
        let player = engine.makePlayerLayer().player

        try await engine.prepare(url: url, token: nil)
        XCTAssertEqual(ready.value, 1)
        engine.play()

        let outcome = await XCTWaiter().fulfillment(of: [failed], timeout: 10)
        // What the player did, so a red run says why instead of only timing out.
        let item = player?.currentItem
        let facts: [String] = [
            "item status \(item?.status.rawValue ?? -1)",
            "error \(String(describing: item?.error))",
            "timeControlStatus \(player?.timeControlStatus.rawValue ?? -1)",
            "waiting \(String(describing: player?.reasonForWaitingToPlay))",
            "rate \(player?.rate ?? -1)",
            "time \(player?.currentTime().seconds ?? -1)",
            "ended \(ended.value)",
            "errorLog \(String(describing: item?.errorLog()?.events.map(\.errorComment)))",
        ]
        let state = facts.joined(separator: ", ")
        XCTAssertEqual(outcome, .completed, "the engine never reported the failure — \(state)")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(failures.value, 1)
    }

    /// Guard-rail of the path that already existed: nothing to decode, the
    /// duration load itself throws. Tied to no acceptance criterion.
    func test_garbageFileFailsPreparation() async throws {
        let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let url = try write(noise, pathExtension: "mp4")
        let engine = AVVideoPlaybackEngine()
        let ready = TestBox(0)
        engine.onReady = { _ in ready.value += 1 }

        do {
            try await engine.prepare(url: url, token: nil)
            XCTFail("random bytes must not prepare")
        } catch {
            // Expected.
        }
        XCTAssertEqual(ready.value, 0)
    }

    func test_readableMovieBecomesReady() async throws {
        let url = try write(try VideoFixture.makeMovieData(), pathExtension: "mp4")
        let engine = AVVideoPlaybackEngine()
        let duration = TestBox(0.0)
        engine.onReady = { duration.value = $0 }

        try await engine.prepare(url: url, token: nil)

        XCTAssertGreaterThan(duration.value, 0)
    }
}
