import XCTest
@testable import ImmichSwiftUI

final class MemoryMomentPresentationTests: XCTestCase {

    private let enUS = Locale(identifier: "en_US")
    private let frFR = Locale(identifier: "fr_FR")

    private func makeAsset(
        id: String,
        people: [PersonResponseDto] = [],
        tags: [TagResponseDto] = []
    ) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2023-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2023-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/x.jpg", originalFileName: "x.jpg",
            fileCreatedAt: "2023-07-01T00:00:00.000Z", fileModifiedAt: "2023-07-01T00:00:00.000Z",
            updatedAt: "2023-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            tags: tags.isEmpty ? nil : tags,
            people: people.isEmpty ? nil : people
        )
    }

    private func makeMemory(memoryAt: String, year: Int, assets: [AssetResponseDto]) -> MemoryResponseDto {
        MemoryResponseDto(
            id: "m1", createdAt: "2023-07-01T00:00:00.000Z", updatedAt: "2023-07-01T00:00:00.000Z",
            memoryAt: memoryAt, ownerId: "owner", type: .on_this_day,
            data: MemoryDataDto(year: year), assets: assets, isSaved: false,
            showAt: nil, hideAt: nil, seenAt: nil, deletedAt: nil
        )
    }

    private func person(_ id: String, _ name: String) -> PersonResponseDto {
        PersonResponseDto(
            id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false,
            color: nil, isFavorite: nil, updatedAt: nil
        )
    }

    private func tag(_ id: String, _ name: String) -> TagResponseDto {
        TagResponseDto(id: id, name: name, value: nil, color: nil, parentId: nil, createdAt: nil, updatedAt: nil)
    }

    // MARK: - fullDateLabel

    func test_fullDateLabel_formatsDayAndYear() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [makeAsset(id: "a0")])
        XCTAssertEqual(MemoryMomentPresentation.fullDateLabel(for: memory, locale: enUS), "July 1, 2023")
    }

    func test_fullDateLabel_localeFrench() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [makeAsset(id: "a0")])
        XCTAssertEqual(MemoryMomentPresentation.fullDateLabel(for: memory, locale: frFR), "1 juillet 2023")
    }

    func test_fullDateLabel_malformedMemoryAt_returnsNil() {
        let memory = makeMemory(memoryAt: "not-a-date", year: 2023, assets: [makeAsset(id: "a0")])
        XCTAssertNil(MemoryMomentPresentation.fullDateLabel(for: memory))
    }

    // MARK: - people

    func test_people_dedupesAcrossAssets() {
        let alice = person("p1", "Alice")
        let bob = person("p2", "Bob")
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [
            makeAsset(id: "a0", people: [alice, bob]),
            makeAsset(id: "a1", people: [alice])
        ])
        XCTAssertEqual(MemoryMomentPresentation.people(for: memory).map(\.id), ["p1", "p2"])
    }

    func test_peopleLabel_namedJoins() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [
            makeAsset(id: "a0", people: [person("p1", "Alice"), person("p2", "Bob")])
        ])
        XCTAssertEqual(MemoryMomentPresentation.peopleLabel(for: memory, locale: enUS), "Alice, Bob")
    }

    func test_peopleLabel_unnamedCounts() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [
            makeAsset(id: "a0", people: [person("p1", "  "), person("p2", "")])
        ])
        XCTAssertEqual(MemoryMomentPresentation.peopleLabel(for: memory), localizedString("%lld people", 2))
    }

    func test_peopleLabel_none_returnsNil() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [makeAsset(id: "a0")])
        XCTAssertNil(MemoryMomentPresentation.peopleLabel(for: memory))
    }

    // MARK: - tags

    func test_tags_dedupesAcrossAssets() {
        let travel = tag("t1", "travel")
        let family = tag("t2", "family")
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [
            makeAsset(id: "a0", tags: [travel, family]),
            makeAsset(id: "a1", tags: [travel])
        ])
        XCTAssertEqual(MemoryMomentPresentation.tags(for: memory).map(\.id), ["t1", "t2"])
    }

    func test_tagsLabel_joinsNames() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [
            makeAsset(id: "a0", tags: [tag("t1", "travel"), tag("t2", "family")])
        ])
        XCTAssertEqual(MemoryMomentPresentation.tagsLabel(for: memory), "travel, family")
    }

    func test_tagsLabel_none_returnsNil() {
        let memory = makeMemory(memoryAt: "2023-07-01T00:00:00.000Z", year: 2023, assets: [makeAsset(id: "a0")])
        XCTAssertNil(MemoryMomentPresentation.tagsLabel(for: memory))
    }
}
