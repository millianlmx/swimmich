import SwiftUI
import XCTest
@testable import ImmichSwiftUI

/// Transitions of the full-screen memories playback (L-07, AC-60.x).
@MainActor
final class MemoryPlaybackViewModelTests: XCTestCase {

    private func makeAsset(_ id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeMemory(_ id: String, year: Int, photos: Int) -> MemoryResponseDto {
        MemoryResponseDto(
            id: id, createdAt: "2024-07-01T00:00:00.000Z", updatedAt: "2024-07-01T00:00:00.000Z",
            memoryAt: "\(year)-07-01T00:00:00.000Z", ownerId: "owner", type: .on_this_day,
            data: MemoryDataDto(year: year), assets: (0..<photos).map { makeAsset("\(id)-a\($0)") },
            isSaved: false, showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
    }

    /// Memories `m1`, `m2`, … (newest first), with the given photo counts.
    private func makeSource(_ photoCounts: [Int]) async -> (MemoriesViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        mock.memoriesResponse = photoCounts.enumerated().map { index, count in
            makeMemory("m\(index + 1)", year: 2024 - index, photos: count)
        }
        let source = MemoriesViewModel(client: mock)
        await source.load()
        return (source, mock)
    }

    func test_AC_60_opensAtTheTappedMemoryWithNoFeedback() async {
        let (source, _) = await makeSource([2, 1, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)

        XCTAssertEqual(playback.page, .memory("m2"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertNil(playback.lastFeedback)
        XCTAssertTrue(playback.isAutoPlaying)
        XCTAssertFalse(playback.isFinished)
        XCTAssertEqual(playback.pages, [.memory("m1"), .memory("m2"), .memory("m3"), .end])
    }

    func test_AC_60_unknownIdOpensTheFirstMemory() async {
        let (source, _) = await makeSource([2, 1])
        XCTAssertEqual(source.makePlayback(startingAt: "nope", autoPlays: true).page, .memory("m1"))
    }

    func test_AC_60_emptyListIsFinished() async {
        let (source, _) = await makeSource([])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        XCTAssertTrue(playback.isFinished)
        XCTAssertEqual(playback.page, .end)
    }

    func test_AC_60_4_userShowedPhoto_emitsOnlyForARealChange() async {
        let (source, _) = await makeSource([3])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)

        playback.userShowedPhoto(at: 0)
        playback.userShowedPhoto(at: 3)
        playback.userShowedPhoto(at: -1)
        XCTAssertNil(playback.lastFeedback, "same index and out-of-range indexes do nothing")
        XCTAssertTrue(playback.isAutoPlaying)

        playback.userShowedPhoto(at: 2)
        XCTAssertEqual(playback.assetIndex, 2)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .photo, serial: 1))
        XCTAssertEqual(playback.photoFeedbackTick, 1)
        XCTAssertEqual(playback.memoryFeedbackTick, 0)
        XCTAssertFalse(playback.isAutoPlaying)
    }

    func test_AC_60_userAdvancedPastLastPhoto_movesToTheNextMemoryThenTheEnd() async {
        let (source, _) = await makeSource([2, 1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        playback.userShowedPhoto(at: 1)

        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.page, .memory("m2"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 2))

        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.page, .end)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 3))

        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.lastFeedback?.serial, 3, "nothing to advance on the end screen")
    }

    func test_AC_60_2_userShowedPage_goesBackToThePreviousMemoryOnItsFirstPhoto() async {
        let (source, _) = await makeSource([2, 2, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        playback.userShowedPhoto(at: 1)

        playback.userShowedPage(.memory("m1"))
        XCTAssertEqual(playback.page, .memory("m1"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 2))

        playback.userShowedPage(.memory("m1"))
        playback.userShowedPage(.memory("unknown"))
        XCTAssertEqual(playback.lastFeedback?.serial, 2, "same page and unknown page do nothing")

        playback.userShowedPage(.end)
        XCTAssertEqual(playback.page, .end)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 3))
    }

    func test_AC_60_3_restart_returnsToTheFirstMemoryAndRestartsAutoPlay() async {
        let (source, _) = await makeSource([1, 1, 1])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        playback.userAdvancedPastLastPhoto()
        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.page, .end)
        XCTAssertFalse(playback.isAutoPlaying)

        playback.restart()

        XCTAssertEqual(playback.page, .memory("m1"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertEqual(playback.lastFeedback?.kind, .memory)
        XCTAssertTrue(playback.isAutoPlaying)
    }

    func test_AC_60_3_restart_withAutoPlayOffStaysOff() async {
        let (source, _) = await makeSource([1, 1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: false)
        XCTAssertFalse(playback.isAutoPlaying)
        playback.userAdvancedPastLastPhoto()
        playback.userAdvancedPastLastPhoto()
        playback.restart()
        XCTAssertFalse(playback.isAutoPlaying)
        XCTAssertEqual(playback.page, .memory("m1"))
    }

    func test_AC_60_3_singleMemoryAdvancesToTheEnd() async {
        let (source, _) = await makeSource([1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.page, .end)
    }

    func test_AC_60_1_autoAdvance_crossesMemoriesSilentlyAndStopsAtTheEnd() async {
        let (source, _) = await makeSource([2, 1, 2])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)

        var seen: [String] = []
        for _ in 0..<6 {
            playback.autoAdvance()
            seen.append("\(playback.page)-\(playback.assetIndex)")
        }

        XCTAssertEqual(seen, [
            "memory(\"m1\")-1", "memory(\"m2\")-0", "memory(\"m3\")-0",
            "memory(\"m3\")-1", "end-0", "end-0"
        ])
        XCTAssertNil(playback.lastFeedback)
        XCTAssertEqual(playback.photoFeedbackTick, 0)
        XCTAssertEqual(playback.memoryFeedbackTick, 0)
        XCTAssertTrue(playback.isAutoPlaying, "auto-play stays armed across memories")
    }

    func test_AC_60_1_videoDidEnd_followsTheSameRule() async {
        let (source, _) = await makeSource([2, 1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)

        playback.videoDidEnd()
        XCTAssertEqual(playback.assetIndex, 1)
        playback.videoDidEnd()
        XCTAssertEqual(playback.page, .memory("m2"))
        playback.videoDidEnd()
        XCTAssertEqual(playback.page, .end)
        playback.videoDidEnd()
        XCTAssertEqual(playback.page, .end)
        XCTAssertNil(playback.lastFeedback)
    }

    func test_AC_60_1_singleMemoryWithOnePhoto_autoPlayLeadsToTheEnd() async {
        let (source, _) = await makeSource([1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        playback.autoAdvance()
        XCTAssertEqual(playback.page, .end)
    }

    func test_AC_60_stopAutoPlay_isSilent() async {
        let (source, _) = await makeSource([2])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        playback.stopAutoPlay()
        XCTAssertFalse(playback.isAutoPlaying)
        XCTAssertNil(playback.lastFeedback)
    }

    // MARK: - Removal and deletion (AC-60.5)

    func test_AC_60_5_removeCurrentPhoto_middlePhotoKeepsTheIndexThenClampsOnTheLast() async {
        let (source, mock) = await makeSource([2, 3, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        playback.userShowedPhoto(at: 1)
        let serialBefore = playback.lastFeedback?.serial

        mock.memoryDetailResponses["m2"] = makeMemory("m2", year: 2023, photos: 2)
        await playback.removeCurrentPhoto()

        XCTAssertEqual(mock.lastRemoveAssetsMemoryIds, ["m2-a1"])
        XCTAssertEqual(playback.page, .memory("m2"))
        XCTAssertEqual(playback.assetIndex, 1, "the photo that followed takes the same index")
        XCTAssertEqual(playback.lastFeedback?.serial, serialBefore, "a removal never emits")
        XCTAssertFalse(playback.isAutoPlaying)

        mock.memoryDetailResponses["m2"] = makeMemory("m2", year: 2023, photos: 1)
        await playback.removeCurrentPhoto()
        XCTAssertEqual(playback.page, .memory("m2"))
        XCTAssertEqual(playback.assetIndex, 0, "the previous photo when the last one went")
    }

    func test_AC_60_5_removeCurrentPhoto_lastPhotoOfAMemoryShowsTheNextMemory() async {
        let (source, mock) = await makeSource([2, 1, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        mock.memoryDetailResponses["m2"] = makeMemory("m2", year: 2023, photos: 0)

        await playback.removeCurrentPhoto()

        XCTAssertEqual(playback.page, .memory("m3"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertNil(playback.lastFeedback)
        XCTAssertFalse(playback.isAutoPlaying)
    }

    func test_AC_60_5_removeCurrentPhoto_lastPhotoOfTheLastMemoryShowsTheEnd() async {
        let (source, mock) = await makeSource([2, 1])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        mock.memoryDetailResponses["m2"] = makeMemory("m2", year: 2023, photos: 0)

        await playback.removeCurrentPhoto()

        XCTAssertEqual(playback.page, .end)
        XCTAssertFalse(playback.isFinished, "other memories remain: the end screen, not a close")
        XCTAssertNil(playback.lastFeedback)
    }

    func test_AC_60_5_removeCurrentPhoto_failureMovesNothingButStopsAutoPlay() async {
        let (source, mock) = await makeSource([2, 2])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        mock.memoriesError = APIError.serverError(500, "nope")

        await playback.removeCurrentPhoto()

        XCTAssertEqual(playback.page, .memory("m1"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertEqual(source.memories.first?.assets.count, 2)
        XCTAssertFalse(playback.isAutoPlaying)
    }

    func test_AC_60_5_deleteCurrentMemory_successShowsTheNextMemory() async {
        let (source, mock) = await makeSource([2, 2, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)

        let deleted = await playback.deleteCurrentMemory()

        XCTAssertTrue(deleted)
        XCTAssertEqual(mock.lastDeleteMemoryId, "m2")
        XCTAssertEqual(playback.page, .memory("m3"))
        XCTAssertEqual(playback.assetIndex, 0)
        XCTAssertNil(playback.lastFeedback)
        XCTAssertFalse(playback.isAutoPlaying)
    }

    func test_AC_60_5_deleteCurrentMemory_lastOneShowsTheEnd() async {
        let (source, _) = await makeSource([2, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)

        let deleted = await playback.deleteCurrentMemory()

        XCTAssertTrue(deleted)
        XCTAssertEqual(playback.page, .end)
        XCTAssertFalse(playback.isFinished)
    }

    func test_AC_60_5_deleteCurrentMemory_onlyMemoryFinishesThePlayback() async {
        let (source, _) = await makeSource([2])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)

        let deleted = await playback.deleteCurrentMemory()

        XCTAssertTrue(deleted)
        XCTAssertTrue(playback.isFinished)
    }

    func test_AC_60_5_deleteCurrentMemory_failureReturnsFalseAndKeepsThePage() async {
        let (source, mock) = await makeSource([2, 2])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: true)
        mock.memoriesError = APIError.serverError(500, "nope")

        let deleted = await playback.deleteCurrentMemory()

        XCTAssertFalse(deleted)
        XCTAssertEqual(playback.page, .memory("m1"))
        XCTAssertFalse(playback.isAutoPlaying)
        XCTAssertFalse(playback.isFinished)
    }

    func test_AC_60_5_reconcile_isIdempotentAndSilent() async {
        let (source, mock) = await makeSource([2, 2, 2])
        let playback = source.makePlayback(startingAt: "m2", autoPlays: true)
        await source.deleteMemory(id: "m2")
        XCTAssertEqual(mock.deleteMemoryCallCount, 1)

        playback.reconcile()
        playback.reconcile()

        XCTAssertEqual(playback.page, .memory("m3"))
        XCTAssertNil(playback.lastFeedback)
    }

    // MARK: - Haptics

    func test_AC_60_4_fullSequenceNumbersTheFeedbacks() async {
        let (source, _) = await makeSource([2, 1, 1])
        let playback = source.makePlayback(startingAt: "m1", autoPlays: false)

        playback.userShowedPhoto(at: 1)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .photo, serial: 1))
        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 2))
        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 3))
        playback.userAdvancedPastLastPhoto()
        XCTAssertEqual(playback.page, .end)
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 4))
        playback.restart()
        XCTAssertEqual(playback.page, .memory("m1"))
        XCTAssertEqual(playback.lastFeedback, .init(kind: .memory, serial: 5))
        XCTAssertEqual(playback.photoFeedbackTick, 1)
        XCTAssertEqual(playback.memoryFeedbackTick, 4)
    }

    func test_AC_60_4_probeLabelNamesTheFeedbackActuallyReturned() {
        XCTAssertNil(MemoryPlaybackProbe.label(for: nil))
        XCTAssertEqual(MemoryPlaybackProbe.label(for: .selection), "selection")
        XCTAssertEqual(MemoryPlaybackProbe.label(for: .impact(weight: .medium)), "medium")
        XCTAssertEqual(MemoryPlaybackProbe.label(for: .success), "other")
        XCTAssertEqual(MemoryPlaybackFeedback.photo, .selection)
        XCTAssertEqual(MemoryPlaybackFeedback.memory, .impact(weight: .medium))
    }

    // MARK: - Reduce Motion

    func test_AC_60_6_reduceMotionUsesFade() {
        XCTAssertEqual(MemoryPlaybackMotion.pageChange(reduceMotion: true), .fade)
        XCTAssertEqual(MemoryPlaybackMotion.pageChange(reduceMotion: false), .slide)
    }
}
