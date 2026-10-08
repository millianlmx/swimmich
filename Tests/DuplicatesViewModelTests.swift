import XCTest
@testable import ImmichSwiftUI

final class DuplicatesViewModelTests: XCTestCase {

    private func makeGroup(id: String, ids: [String], suggested: [String]) -> DuplicateResponseDto {
        let assets = ids.map { assetID in
            AssetResponseDto(
                id: assetID, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
                duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
                ownerId: "owner", originalPath: "/\(assetID).jpg", originalFileName: "\(assetID).jpg",
                fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
                updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
                isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
            )
        }
        return DuplicateResponseDto(duplicateId: id, assets: assets, suggestedKeepAssetIds: suggested)
    }

    @MainActor
    func test_load_mapsServerGroups() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups.first?.duplicateId, "g1")
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_load_failure_setsError() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        mock.globalError = APIError.serverError(500, "boom")
        await vm.load()

        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_load_emptyKeepsEmpty() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_deletableIds_excludesSuggestedKeep() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)
        let group = makeGroup(id: "g1", ids: ["a1", "a2", "a3"], suggested: ["a2"])

        XCTAssertEqual(vm.deletableIds(for: group), ["a1", "a3"])
    }

    @MainActor
    func test_deleteGroup_sendsOnlyNonKeepIds() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2", "a3"], suggested: ["a2"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        await vm.deleteGroup(id: "g1")

        let deleted = Set(mock.lastDeleteBody?.ids ?? [])
        XCTAssertEqual(deleted, ["a1", "a3"])
        XCTAssertEqual(mock.lastDeleteBody?.force, false)
        XCTAssertTrue(vm.groups.isEmpty)
    }

    @MainActor
    func test_deleteGroup_failureKeepsGroup() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1", "a2"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        mock.globalError = APIError.serverError(500, "boom")
        await vm.deleteGroup(id: "g1")

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
    }

    @MainActor
    func test_deleteGroup_allSuggestedIsLocalNoOp() async {
        let mock = MockImmichClient()
        mock.duplicatesResponse = [makeGroup(id: "g1", ids: ["a1"], suggested: ["a1"])]
        let vm = DuplicatesViewModel(client: mock)
        await vm.load()

        await vm.deleteGroup(id: "g1")

        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertTrue(vm.groups.isEmpty)
    }

    @MainActor
    func test_deleteGroup_unknownIdIsNoOp() async {
        let mock = MockImmichClient()
        let vm = DuplicatesViewModel(client: mock)

        await vm.deleteGroup(id: "ghost")

        XCTAssertNil(mock.lastDeleteBody)
        XCTAssertTrue(vm.groups.isEmpty)
    }
}
