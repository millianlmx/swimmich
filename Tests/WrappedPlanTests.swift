import XCTest
@testable import ImmichSwiftUI

final class WrappedPlanTests: XCTestCase {

    private func asset(_ id: String, _ time: String, offset: Double = 0) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: offset, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    func test_monthCounts_onlyTheYear() {
        let buckets = [
            TimeBucketsResponseDto(timeBucket: "2026-07-01", count: 120),
            TimeBucketsResponseDto(timeBucket: "2026-01-01T00:00:00.000Z", count: 4),
            TimeBucketsResponseDto(timeBucket: "2025-07-01", count: 999),
            TimeBucketsResponseDto(timeBucket: "garbage", count: 5),
        ]
        let counts = WrappedPlan.monthCounts(buckets, year: 2026)
        XCTAssertEqual(counts.count, 12)
        XCTAssertEqual(counts[0], 4)
        XCTAssertEqual(counts[6], 120)
        XCTAssertEqual(counts.reduce(0, +), 124)
        XCTAssertEqual(WrappedPlan.busiestMonth(counts), 6)
        XCTAssertNil(WrappedPlan.busiestMonth(Array(repeating: 0, count: 12)))
    }

    func test_busiestDay_countsLocalDays() {
        // 23:30 UTC at UTC+2 is the next day where it was taken.
        let assets = [
            asset("a", "2026-07-14T10:00:00.000Z"), asset("b", "2026-07-14T12:00:00.000Z"),
            asset("c", "2026-07-13T23:30:00.000Z", offset: 2),
            asset("d", "2026-03-01T09:00:00.000Z"),
        ]
        let busiest = WrappedPlan.busiestDay(assets)
        XCTAssertEqual(busiest?.day, CalendarDay(year: 2026, month: 7, day: 14))
        XCTAssertEqual(busiest?.photos, 3)
    }

    func test_topPeople_mostPhotographedFirst_absentLeftOut() {
        let people = [
            WrappedPerson(id: "1", name: "Léa", photos: 40), WrappedPerson(id: "2", name: "Tom", photos: 0),
            WrappedPerson(id: "3", name: "Max", photos: 90), WrappedPerson(id: "4", name: "Ana", photos: 40),
        ]
        XCTAssertEqual(WrappedPlan.topPeople(people).map(\.name), ["Max", "Ana", "Léa"])
    }

    func test_cards_leaveOutTheEmptyOnes() {
        XCTAssertEqual(
            WrappedPlan.cards(hasPeople: false, hasPlaces: true, hasColors: false, hasBest: true),
            [.intro, .months, .places, .best, .outro]
        )
    }

    func test_takenRange_coversTheYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let range = try XCTUnwrap(WrappedPlan.takenRange(year: 2026, calendar: calendar))
        XCTAssertEqual(range.after, "2026-01-01T00:00:00Z")
        XCTAssertEqual(range.before, "2026-12-31T23:59:59Z")
    }

    func test_videoCard_fadesIntoTheNext() {
        let d = WrappedPlan.cardDuration
        XCTAssertEqual(WrappedPlan.card(at: 0.5, cardCount: 3).index, 0)
        XCTAssertEqual(WrappedPlan.card(at: 0.5, cardCount: 3).fade, 0)
        XCTAssertEqual(WrappedPlan.card(at: d - WrappedPlan.fadeDuration / 2, cardCount: 3).fade, 0.5, accuracy: 0.001)
        XCTAssertEqual(WrappedPlan.card(at: d + 0.1, cardCount: 3).index, 1)
        XCTAssertEqual(WrappedPlan.card(at: 100, cardCount: 3).index, 2)
        XCTAssertEqual(WrappedPlan.card(at: 100, cardCount: 3).fade, 0)
    }
}
