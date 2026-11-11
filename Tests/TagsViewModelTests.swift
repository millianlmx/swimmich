import XCTest
@testable import ImmichSwiftUI

/// Creating tags under a parent, and what the tree shows afterwards (L-03).
final class TagsViewModelTests: XCTestCase {

    private struct BoomError: Error {}

    private let voyages = TagResponseDto(id: "voyages", name: "Voyages", value: "Voyages")
    private let famille = TagResponseDto(id: "famille", name: "Famille", value: "Famille")

    @MainActor
    private func loadedViewModel(_ mock: MockImmichClient) async -> TagsViewModel {
        mock.tagsResponse = [voyages, famille]
        let vm = TagsViewModel(client: mock)
        await vm.load()
        return vm
    }

    private func shape(_ vm: TagsViewModel) -> [String] {
        vm.rows.map { "\($0.tag.id)@\($0.depth)" }
    }

    @MainActor
    func test_AC_13_createUnderParentSendsParentIdAndInsertsRow() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        mock.createTagResponse = TagResponseDto(id: "italie", name: "Italie", value: "Voyages/Italie", parentId: "voyages")
        let loads = mock.getAllTagsCallCount

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertTrue(created)
        XCTAssertEqual(mock.createTagCalls.last?.parentId, "voyages")
        XCTAssertEqual(mock.createTagCalls.last?.name, "Italie")
        XCTAssertEqual(shape(vm), ["famille@0", "voyages@0", "italie@1"])
        XCTAssertEqual(mock.getAllTagsCallCount, loads, "no reload: the answer is inserted in place")
    }

    @MainActor
    func test_AC_77_createAtRootSendsNoParent() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)

        let created = await vm.create(name: "  Animaux ", parentId: nil)

        XCTAssertTrue(created)
        XCTAssertEqual(mock.createTagCalls.count, 1)
        XCTAssertEqual(mock.createTagCalls.last?.name, "Animaux")
        XCTAssertNil(mock.createTagCalls.last?.parentId)
        XCTAssertEqual(shape(vm), ["tag-new@0", "famille@0", "voyages@0"])
    }

    @MainActor
    func test_AC_77_blankNameSendsNothing() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        let before = shape(vm)

        for blank in ["", "   ", "\n\t "] {
            let created = await vm.create(name: blank, parentId: "voyages")
            XCTAssertFalse(created)
        }

        XCTAssertTrue(mock.createTagCalls.isEmpty)
        XCTAssertEqual(shape(vm), before)
        XCTAssertNil(vm.createErrorMessage)
    }

    @MainActor
    func test_AC_78_readOnlyRefusesBeforeWire() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [voyages, famille]
        let vm = TagsViewModel(client: ReadOnlyGuardClient(inner: mock, isEnabled: { true }))
        await vm.load()
        let before = vm.rows

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertFalse(created)
        XCTAssertTrue(mock.createTagCalls.isEmpty)
        XCTAssertEqual(vm.createErrorMessage, APIError.readOnlyMode.userFacingMessage)
        XCTAssertEqual(vm.rows, before)
    }

    @MainActor
    func test_AC_78_serverErrorKeepsTree() async {
        let mock = MockImmichClient()
        let vm = await loadedViewModel(mock)
        let before = vm.rows
        mock.createTagError = BoomError()

        let created = await vm.create(name: "Italie", parentId: "voyages")

        XCTAssertFalse(created)
        XCTAssertEqual(mock.createTagCalls.count, 1, "the call is attempted, then refused")
        XCTAssertNotNil(vm.createErrorMessage)
        XCTAssertEqual(vm.rows, before)

        vm.clearCreateError()
        XCTAssertNil(vm.createErrorMessage)
    }

    @MainActor
    func test_parentChoices_listedByFullPath() async {
        let mock = MockImmichClient()
        mock.tagsResponse = [
            TagResponseDto(id: "j", name: "Japon", value: "Voyages/Japon", parentId: "voyages"),
            voyages,
            TagResponseDto(id: "c", name: "Cuisine", value: "Cuisine"),
        ]
        let vm = TagsViewModel(client: mock)
        await vm.load()

        XCTAssertEqual(vm.parentChoices.map(\.path), ["Cuisine", "Voyages", "Voyages/Japon"])
    }
}
