import XCTest
@testable import ImmichSwiftUI

/// The tag sheet of a photo lists tags by full path (L-03).
final class AssetTagsSheetTests: XCTestCase {

    @MainActor
    func test_AC_80_homonymsListedByFullPath() {
        let voyagesJapon = TagResponseDto(id: "2", name: "Japon", value: "Voyages/Japon", parentId: "1")
        let cuisineJapon = TagResponseDto(id: "7", name: "Japon", value: "Cuisine/Japon", parentId: "6")
        let plage = TagResponseDto(id: "a", name: "Plage", value: nil)

        let listed = AssetTagsSheet.displayTags([voyagesJapon, plage, cuisineJapon])

        XCTAssertEqual(listed.map(\.path), ["Cuisine/Japon", "Plage", "Voyages/Japon"])
        XCTAssertEqual(Set(listed.map(\.path)).count, 3, "two homonyms, still two distinct labels")
        XCTAssertEqual(listed.first?.id, "7")
    }
}
