import XCTest
@testable import ImmichSwiftUI

/// The hierarchy built from the server's flat tag list (L-03).
final class TagTreeTests: XCTestCase {

    private func tag(_ id: String, _ name: String, parent: String? = nil, value: String? = nil) -> TagResponseDto {
        TagResponseDto(id: id, name: name, value: value ?? name, parentId: parent)
    }

    private func shape(_ rows: [TagRow]) -> [String] {
        rows.map { "\($0.tag.name) \($0.depth) \($0.parentId ?? "nil")" }
    }

    func test_AC_12_childRowFollowsParentOneLevelDeeper() {
        let rows = TagTree.rows(from: [
            tag("japon", "Japon", parent: "voyages", value: "Voyages/Japon"),
            tag("voyages", "Voyages"),
        ])
        XCTAssertEqual(shape(rows), ["Voyages 0 nil", "Japon 1 voyages"])
        XCTAssertEqual(rows[1].accessibilityIdentifier, "tagRow_voyages_japon")
        XCTAssertEqual(rows[0].accessibilityIdentifier, "tagRow_root_voyages")
    }

    func test_AC_76_nestedTreeWithOrphanAtRoot() {
        let rows = TagTree.rows(from: [
            tag("tokyo", "Tokyo", parent: "japon", value: "Voyages/Japon/Tokyo"),
            tag("voyages", "Voyages"),
            tag("orphan", "Orphelin", parent: "unknown"),
            tag("japon", "Japon", parent: "voyages", value: "Voyages/Japon"),
            tag("famille", "Famille"),
        ])
        XCTAssertEqual(shape(rows), [
            "Famille 0 nil", "Orphelin 0 nil", "Voyages 0 nil", "Japon 1 voyages", "Tokyo 2 japon",
        ])
    }

    func test_AC_76_parentIdCycleNeverHidesTags() {
        let rows = TagTree.rows(from: [
            tag("a", "A", parent: "b"),
            tag("b", "B", parent: "a"),
            tag("self", "Self", parent: "self"),
        ])
        XCTAssertEqual(Set(rows.map(\.id)), ["a", "b", "self"])
        XCTAssertEqual(rows.count, 3)
    }

    func test_AC_76_duplicateIdsAppearOnce() {
        let rows = TagTree.rows(from: [tag("a", "A"), tag("a", "A")])
        XCTAssertEqual(rows.count, 1)
    }

    func test_AC_76_siblingsSortedByName() {
        let rows = TagTree.rows(from: [
            tag("z", "Zoo", parent: "p"),
            tag("b2", "bar", parent: "p"),
            tag("a", "Alpha", parent: "p"),
            tag("p", "Parent"),
            tag("h2", "Same", parent: "p"),
            tag("h1", "Same", parent: "p"),
        ])
        XCTAssertEqual(rows.map(\.id), ["p", "a", "b2", "h1", "h2", "z"])
    }
}
