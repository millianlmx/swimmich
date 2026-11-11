import XCTest
@testable import ImmichSwiftUI

/// Type-aware memory titles (L-07, AC-17.x). The test host's own language
/// varies by runner (French on the CI simulator), so every localized
/// assertion pins the compiled French catalog and checks its values.
final class MemoryTitlePresentationTests: XCTestCase {

    /// `fr.lproj` of the app bundle (the unit tests are hosted by the app);
    /// `LocalizationTests` guarantees it is compiled in.
    private func french() throws -> Bundle {
        let app = Bundle(for: AppLanguageStore.self)
        let path = try XCTUnwrap(app.path(forResource: "fr", ofType: "lproj"), "fr.lproj missing")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func makeAsset(localDateTime: String, fileCreatedAt: String = "2020-07-01T10:00:00.000Z") -> AssetResponseDto {
        AssetResponseDto(
            id: "a1", type: "IMAGE", thumbhash: nil, localDateTime: localDateTime,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: fileCreatedAt,
            ownerId: "owner", originalPath: "/a1.jpg", originalFileName: "a1.jpg",
            fileCreatedAt: fileCreatedAt, fileModifiedAt: fileCreatedAt,
            updatedAt: fileCreatedAt, isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeMemory(
        type: MemoryType, year: Int, personName: String? = nil, memoryAt: String = "2026-07-01T00:00:00.000Z"
    ) -> MemoryResponseDto {
        MemoryResponseDto(
            id: "m1", createdAt: memoryAt, updatedAt: memoryAt, memoryAt: memoryAt, ownerId: "owner",
            type: type, data: MemoryDataDto(year: year, personId: nil, personName: personName),
            assets: [makeAsset(localDateTime: "2020-07-01T10:00:00.000Z")], isSaved: false
        )
    }

    func test_AC_17_2_birthdayTitle_followsTheAgeAtThePhoto() throws {
        let fr = try french()
        XCTAssertEqual(
            MemoryTitlePresentation.birthdayTitle(personName: "Alice", ageYear: 2020, birthYear: 1990, bundle: fr),
            "Anniversaire de Alice · 30 ans"
        )
        XCTAssertEqual(
            MemoryTitlePresentation.birthdayTitle(personName: "Alice", ageYear: 1991, birthYear: 1990, bundle: fr),
            "Anniversaire de Alice · 1 an"
        )
    }

    func test_AC_17_2_birthdayTitle_namesOnlyWhenTheAgeIsBelowOneOrUnknown() throws {
        let fr = try french()
        XCTAssertEqual(
            MemoryTitlePresentation.birthdayTitle(personName: "Alice", ageYear: 1990, birthYear: 1990, bundle: fr),
            "Anniversaire de Alice"
        )
        XCTAssertEqual(
            MemoryTitlePresentation.birthdayTitle(personName: "Alice", ageYear: nil, birthYear: 1990, bundle: fr),
            "Anniversaire de Alice"
        )
    }

    func test_AC_17_3_birthdayTitle_fallsBackToUnknownWithoutAName() throws {
        let fr = try french()
        for name in [nil, "", "  "] as [String?] {
            XCTAssertEqual(
                MemoryTitlePresentation.birthdayTitle(personName: name, ageYear: 2020, birthYear: 1990, bundle: fr),
                "Inconnu"
            )
        }
    }

    func test_AC_17_2_takenYear_readsTheWallClockYearWithAFallback() {
        XCTAssertEqual(
            MemoryTitlePresentation.takenYear(of: makeAsset(localDateTime: "2020-07-01T10:00:00.000Z")), 2020
        )
        XCTAssertEqual(
            MemoryTitlePresentation.takenYear(of: makeAsset(localDateTime: "??", fileCreatedAt: "2019-01-01T00:00:00.000Z")),
            2019
        )
    }

    func test_AC_17_1_birthdayNeverShowsTheBirthYearOrAnElapsedCount() throws {
        let fr = try french()
        let memory = makeMemory(type: .birthday, year: 1990, personName: "Alice")
        let ago = MemoryCardPresentation.yearsAgoText(
            count: Calendar.current.component(.year, from: .now) - 1990
        )
        let lines = [
            MemoryTitlePresentation.cardTitle(for: memory),
            MemoryTitlePresentation.cardSubtitle(for: memory),
            MemoryTitlePresentation.momentTitle(for: memory, asset: memory.assets.first),
            MemoryTitlePresentation.momentSubtitle(for: memory)
        ].compactMap { $0 }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertFalse(line.contains("1990"), line)
            if let ago { XCTAssertFalse(line.contains(ago), line) }
        }
        XCTAssertEqual(MemoryTitlePresentation.cardTitle(for: memory, bundle: fr), "Anniversaire de Alice")
        XCTAssertEqual(
            MemoryTitlePresentation.momentTitle(for: memory, asset: memory.assets.first, bundle: fr),
            "Anniversaire de Alice · 30 ans"
        )
    }

    func test_AC_17_4_unknownTypeTitleComesFromItsDate() {
        let memory = makeMemory(type: .unknown, year: 2021, memoryAt: "2021-07-01T00:00:00.000Z")
        let title = MemoryTitlePresentation.cardTitle(for: memory)
        XCTAssertEqual(title, MemoryMomentPresentation.fullDateLabel(for: memory))
        XCTAssertFalse((title ?? "").isEmpty)
        XCTAssertNil(MemoryTitlePresentation.cardSubtitle(for: memory))
        XCTAssertNil(MemoryTitlePresentation.momentSubtitle(for: memory))
        XCTAssertEqual(MemoryTitlePresentation.momentTitle(for: memory, asset: nil), title)
    }

    func test_AC_17_4_unknownTypeWithUnreadableDateFallsBackToTheYear() {
        let memory = makeMemory(type: .unknown, year: 2021, memoryAt: "not a date")
        XCTAssertEqual(MemoryTitlePresentation.cardTitle(for: memory), "2021")
    }

    func test_AC_17_5_onThisDayKeepsToday_sTitles() {
        let memory = makeMemory(type: .on_this_day, year: 2022, memoryAt: "2022-07-01T00:00:00.000Z")
        XCTAssertEqual(MemoryTitlePresentation.cardTitle(for: memory), MemoryMomentPresentation.fullDateLabel(for: memory))
        XCTAssertEqual(MemoryTitlePresentation.momentTitle(for: memory, asset: nil), "2022")
        let ago = MemoryCardPresentation.yearsAgoCount(year: 2022).flatMap { MemoryCardPresentation.yearsAgoText(count: $0) }
        XCTAssertEqual(MemoryTitlePresentation.cardSubtitle(for: memory), ago)
        let day = MemoryCardPresentation.dayLabel(for: memory)
        XCTAssertEqual(
            MemoryTitlePresentation.momentSubtitle(for: memory),
            [day, ago].compactMap { $0 }.joined(separator: " · ")
        )
    }

    func test_AC_17_badgeIsOwnedByTheType() throws {
        let fr = try french()
        XCTAssertEqual(MemoryTitlePresentation.badge(for: makeMemory(type: .on_this_day, year: 2022), bundle: fr).label, "Ce jour-là")
        XCTAssertEqual(MemoryTitlePresentation.badge(for: makeMemory(type: .birthday, year: 1990), bundle: fr).label, "Anniversaire")
        XCTAssertEqual(MemoryTitlePresentation.badge(for: makeMemory(type: .unknown, year: 2022), bundle: fr).label, "Souvenir")
        XCTAssertEqual(MemoryTitlePresentation.badge(for: makeMemory(type: .birthday, year: 1990)).symbol, "birthday.cake")
    }
}
