import XCTest
@testable import ImmichSwiftUI

/// L-33 (B-38) — correct a photo's date with a time zone. Registry ids: AC-66.1…AC-66.6.
@MainActor
final class AdjustDateViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func makeItem(id: String = "a1") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "me", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-14T08:00:00.000Z",
            fileCreatedAt: "2024-07-14T08:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeResponse(
        id: String = "a1", dateTimeOriginal: String?, timeZone: String?,
        fileCreatedAt: String = "2024-07-14T08:00:00.000Z"
    ) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: fileCreatedAt,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: fileCreatedAt,
            ownerId: "me", originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: fileCreatedAt, fileModifiedAt: fileCreatedAt,
            updatedAt: fileCreatedAt, isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            exifInfo: ExifResponseDto(dateTimeOriginal: dateTimeOriginal, timeZone: timeZone)
        )
    }

    private func loadedDetail(
        timeZone: String? = "Europe/Paris",
        dateTimeOriginal: String? = "2024-07-14T08:00:00.000Z",
        fileCreatedAt: String = "2024-07-14T08:00:00.000Z",
        mock: MockImmichClient = MockImmichClient()
    ) async -> (AssetDetailViewModel, MockImmichClient) {
        mock.getAssetResponse["a1"] = makeResponse(
            dateTimeOriginal: dateTimeOriginal, timeZone: timeZone, fileCreatedAt: fileCreatedAt
        )
        let detail = AssetDetailViewModel(asset: makeItem(), client: mock)
        await detail.loadDetail()
        return (detail, mock)
    }

    private func makeVM(
        _ detail: AssetDetailViewModel, device: TimeZone, now: Date = Date(timeIntervalSince1970: 0)
    ) -> AdjustDateViewModel {
        AdjustDateViewModel(detail: detail, deviceTimeZone: device, now: now)
    }

    /// Wall clock helper: the instant whose UTC components are the given ones.
    private func wall(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: - AC-66 (mother criterion): open on the photo's zone, then save in Tokyo

    func test_AC_66() async {
        let (detail, mock) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        XCTAssertEqual(vm.selectedEntry.identifier, "Europe/Paris")
        XCTAssertEqual(vm.zoneEntries.first { $0.identifier == "Europe/Paris" }?.offsetText, "+02:00")
        vm.wallClock = wall(2024, 7, 14, 10, 0, 0)
        vm.selectZone("Asia/Tokyo")
        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(mock.lastUpdateAssetId, "a1")
        XCTAssertEqual(mock.lastUpdateAssetBody?.dateTimeOriginal, "2024-07-14T10:00:00+09:00")
    }

    // MARK: - AC-66.1: proposed zone is the photo's, date shown in that zone

    func test_AC_66_1() async {
        let (detail, _) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        XCTAssertEqual(vm.selectedEntry.identifier, "Europe/Paris")
        XCTAssertEqual(vm.selectedEntry.offsetText, "+02:00")
        XCTAssertEqual(vm.wallClock, wall(2024, 7, 14, 10, 0, 0))
    }

    // MARK: - AC-66.2: fixed offsets, device fallback

    func test_AC_66_2() async {
        let (detail, _) = await loadedDetail(timeZone: "UTC+2")
        let onTokyo = makeVM(detail, device: tokyo)
        XCTAssertNotEqual(onTokyo.selectedEntry.identifier, "UTC+2")
        XCTAssertTrue(onTokyo.zoneEntries.contains { $0.identifier == onTokyo.selectedEntry.identifier })
        XCTAssertEqual(onTokyo.selectedEntry.offsetText, "+02:00")
        XCTAssertEqual(onTokyo.wallClock, wall(2024, 7, 14, 10, 0, 0))

        let onParis = makeVM(detail, device: paris)
        XCTAssertEqual(onParis.selectedEntry.identifier, "Europe/Paris")
    }

    func test_AC_66_2_garbageFallsBackToDevice() async {
        for exifZone: String? in [nil, "", "garbage", "UTC+15"] {
            let (detail, _) = await loadedDetail(timeZone: exifZone)
            let vm = makeVM(detail, device: newYork)
            XCTAssertEqual(vm.selectedEntry.identifier, "America/New_York", "exif zone \(exifZone ?? "nil")")
        }
    }

    func test_AC_66_2_fixedOffsetParsing() {
        let parse = AdjustDateViewModel.fixedOffsetMinutes(exifTimeZone:)
        XCTAssertEqual(parse("UTC+2"), 120)
        XCTAssertEqual(parse("UTC-3:30"), -210)
        XCTAssertEqual(parse("UTC+05:45"), 345)
        for bad in ["UTC+15", "UTC+2:60", "GMT+2", "+02:00", "UTC", "", "garbage"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    func test_AC_66_2_noExifDateUsesFileCreation() async {
        let (detail, _) = await loadedDetail(
            timeZone: "Europe/Paris", dateTimeOriginal: nil, fileCreatedAt: "2024-07-14T08:00:00.000Z"
        )
        let vm = makeVM(detail, device: tokyo)
        XCTAssertEqual(vm.wallClock, wall(2024, 7, 14, 10, 0, 0))
    }

    /// Immich writes canonical names (`Asia/Kolkata`) that iOS's own list only knows as an
    /// alias (`Asia/Calcutta`): the photo's zone must still be the one proposed.
    func test_AC_66_2_canonicalExifZoneIsProposed() async {
        for exifZone in ["Asia/Kolkata", "Asia/Calcutta"] {
            let (detail, _) = await loadedDetail(timeZone: exifZone)
            let vm = AdjustDateViewModel(
                detail: detail, deviceTimeZone: tokyo,
                knownIdentifiers: ["Asia/Calcutta", "Europe/Paris", "Asia/Tokyo"], now: Date(timeIntervalSince1970: 0)
            )
            XCTAssertEqual(vm.selectedEntry.identifier, "Asia/Kolkata", exifZone)
            XCTAssertEqual(vm.selectedEntry.offsetText, "+05:30", exifZone)
            XCTAssertEqual(vm.wallClock, wall(2024, 7, 14, 13, 30, 0), exifZone)
            XCTAssertEqual(vm.zoneEntries.filter { $0.offsetMinutes == 330 }.map(\.identifier), ["Asia/Kolkata"])
        }
    }

    /// A zone the system list lacks but `TimeZone` resolves is still offered.
    func test_AC_66_2_resolvableExifZoneOutsideListIsAdded() async {
        let (detail, _) = await loadedDetail(timeZone: "Europe/Paris")
        let vm = AdjustDateViewModel(
            detail: detail, deviceTimeZone: tokyo, knownIdentifiers: ["Asia/Tokyo"], now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(vm.selectedEntry.identifier, "Europe/Paris")
        XCTAssertTrue(vm.zoneEntries.contains { $0.identifier == "Europe/Paris" })
    }

    // MARK: - AC-66.3: sorted, labelled, filterable list

    func test_AC_66_3() async {
        let (detail, _) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        vm.wallClock = wall(2024, 7, 14, 10, 0, 0)
        let entries = vm.zoneEntries

        for (a, b) in zip(entries, entries.dropFirst()) {
            XCTAssertTrue(
                a.offsetMinutes < b.offsetMinutes || (a.offsetMinutes == b.offsetMinutes && a.identifier < b.identifier),
                "\(a.identifier) \(a.offsetText) before \(b.identifier) \(b.offsetText)"
            )
        }
        func entry(_ id: String) -> AdjustDateViewModel.TimeZoneEntry? { entries.first { $0.identifier == id } }
        XCTAssertEqual(entry("Asia/Tokyo")?.offsetText, "+09:00")
        XCTAssertEqual(entry("Europe/Paris")?.offsetText, "+02:00")
        XCTAssertEqual(entry("Europe/London")?.offsetText, "+01:00")

        let indexOf = { (id: String) in entries.firstIndex { $0.identifier == id }! }
        let lastUTCish = entries.lastIndex { $0.offsetMinutes == 0 }!
        let firstPlusTwo = entries.firstIndex { $0.offsetMinutes == 120 }!
        XCTAssertLessThan(lastUTCish, indexOf("Europe/London"))
        XCTAssertLessThan(indexOf("Europe/London"), firstPlusTwo)
        XCTAssertLessThan(indexOf("Asia/Seoul"), indexOf("Asia/Tokyo"))
        XCTAssertLessThan(indexOf("Europe/Berlin"), indexOf("Europe/Paris"))

        vm.filterText = "Tokyo"
        XCTAssertTrue(vm.zoneEntries.contains { $0.identifier == "Asia/Tokyo" })
        XCTAssertTrue(vm.zoneEntries.allSatisfy { $0.identifier.localizedCaseInsensitiveContains("Tokyo") })
        vm.filterText = ""

        XCTAssertTrue(vm.dateTimeOriginal.hasSuffix(vm.selectedEntry.offsetText))
        vm.wallClock = wall(2024, 1, 14, 10, 0, 0)
        XCTAssertEqual(vm.zoneEntries.first { $0.identifier == "Europe/Paris" }?.offsetText, "+01:00")
        XCTAssertEqual(vm.zoneEntries.first { $0.identifier == "Europe/London" }?.offsetText, "+00:00")
        XCTAssertEqual(vm.selectedEntry.offsetText, "+01:00")
        XCTAssertTrue(vm.dateTimeOriginal.hasSuffix(vm.selectedEntry.offsetText))
    }

    func test_AC_66_3_filterNormalization() async {
        let (detail, _) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        vm.filterText = "tokyo"
        XCTAssertTrue(vm.zoneEntries.contains { $0.identifier == "Asia/Tokyo" })
        vm.filterText = "  new york "
        XCTAssertTrue(vm.zoneEntries.contains { $0.identifier == "America/New_York" })
        vm.filterText = ""
        XCTAssertEqual(vm.zoneEntries.count, Set(vm.zoneEntries.map(\.identifier)).count)
        XCTAssertGreaterThan(vm.zoneEntries.count, 100)
        vm.filterText = "zzzz-nothing"
        XCTAssertTrue(vm.zoneEntries.isEmpty)
    }

    // MARK: - AC-66.4: changing zone keeps the wall clock; save sends the offset

    func test_AC_66_4() async {
        let mock = MockImmichClient()
        let response = makeResponse(dateTimeOriginal: "2024-07-14T01:00:00.000Z", timeZone: "UTC+9")
        mock.updateAssetResponse = response
        let (detail, _) = await loadedDetail(mock: mock)
        let vm = makeVM(detail, device: tokyo)
        let ten = wall(2024, 7, 14, 10, 0, 0)
        vm.wallClock = ten
        vm.selectZone("Asia/Tokyo")
        XCTAssertEqual(vm.wallClock, ten)
        XCTAssertEqual(vm.selectedEntry.identifier, "Asia/Tokyo")

        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(mock.lastUpdateAssetId, "a1")
        XCTAssertEqual(mock.lastUpdateAssetBody, UpdateAssetDto(dateTimeOriginal: "2024-07-14T10:00:00+09:00"))
        XCTAssertEqual(detail.detail, response)
    }

    func test_AC_66_4_unknownZoneIgnored() async {
        let (detail, _) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        vm.filterText = "abc"
        vm.selectZone("Mars/Olympus")
        XCTAssertEqual(vm.selectedZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(vm.filterText, "abc")
    }

    func test_AC_66_4_failureKeepsSheetStateAndRetrySucceeds() async {
        let mock = MockImmichClient()
        let (detail, _) = await loadedDetail(mock: mock)
        let vm = makeVM(detail, device: tokyo)
        mock.updateAssetError = NSError(domain: "test", code: 500)
        mock.updateAssetErrorAfterSuccesses = 0

        let failed = await vm.save()
        XCTAssertFalse(failed)
        XCTAssertNotNil(detail.errorMessage)
        XCTAssertNil(detail.savedDateCorrection)

        mock.updateAssetError = nil
        let retried = await vm.save()
        XCTAssertTrue(retried)
        XCTAssertNil(detail.errorMessage)
    }

    // MARK: - AC-66.5: offsets in the sent string

    func test_AC_66_5() async {
        let (detail, mock) = await loadedDetail()
        let vm = makeVM(detail, device: tokyo)
        let cases: [(zone: String, wall: Date, expected: String)] = [
            ("Europe/Paris", wall(2024, 7, 14, 10, 0, 0), "2024-07-14T10:00:00+02:00"),
            ("Europe/Paris", wall(2024, 1, 14, 10, 0, 0), "2024-01-14T10:00:00+01:00"),
            ("America/New_York", wall(2024, 1, 14, 10, 0, 0), "2024-01-14T10:00:00-05:00"),
            ("Asia/Kolkata", wall(2024, 1, 14, 10, 0, 0), "2024-01-14T10:00:00+05:30"),
            ("UTC", wall(2024, 1, 14, 10, 0, 0), "2024-01-14T10:00:00+00:00"),
        ]
        for c in cases {
            vm.wallClock = c.wall
            vm.selectZone(c.zone)
            let ok = await vm.save()
            XCTAssertTrue(ok)
            let sent = mock.lastUpdateAssetBody?.dateTimeOriginal
            XCTAssertEqual(sent, c.expected)
            XCTAssertFalse(sent?.contains("Z") ?? true)
            XCTAssertFalse(sent?.contains(".") ?? true)
        }
    }

    func test_AC_66_5_dstEdges() {
        func minutes(_ zone: TimeZone, _ w: Date) -> Int { AdjustDateViewModel.offsetMinutes(of: zone, atWallClock: w) }
        XCTAssertEqual(minutes(paris, wall(2024, 7, 14, 10, 0, 0)), 120)
        XCTAssertEqual(minutes(paris, wall(2024, 1, 14, 10, 0, 0)), 60)
        XCTAssertEqual(minutes(paris, wall(2024, 3, 31, 1, 30, 0)), 60)
        XCTAssertEqual(minutes(paris, wall(2024, 3, 31, 2, 30, 0)), 120, "skipped hour: offset after the change")
        XCTAssertEqual(minutes(paris, wall(2024, 3, 31, 10, 0, 0)), 120)
        XCTAssertEqual(minutes(paris, wall(2024, 10, 27, 2, 30, 0)), 120, "repeated hour: first occurrence")
        XCTAssertEqual(minutes(paris, wall(2024, 10, 27, 10, 0, 0)), 60)
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(minutes(london, wall(2024, 7, 14, 10, 0, 0)), 60)
        XCTAssertEqual(minutes(london, wall(2024, 1, 14, 10, 0, 0)), 0)
        XCTAssertEqual(minutes(TimeZone(identifier: "Asia/Kolkata")!, wall(2024, 1, 14, 10, 0, 0)), 330)
    }

    func test_AC_66_5_offsetText() {
        XCTAssertEqual(AdjustDateViewModel.offsetText(minutes: 0), "+00:00")
        XCTAssertEqual(AdjustDateViewModel.offsetText(minutes: 540), "+09:00")
        XCTAssertEqual(AdjustDateViewModel.offsetText(minutes: 330), "+05:30")
        XCTAssertEqual(AdjustDateViewModel.offsetText(minutes: -300), "-05:00")
        XCTAssertEqual(AdjustDateViewModel.offsetText(minutes: -210), "-03:30")
    }

    func test_AC_66_5_keepsSeconds() {
        XCTAssertEqual(
            AdjustDateViewModel.dateTimeOriginal(wallClock: wall(2024, 7, 14, 10, 0, 37), offsetMinutes: 120),
            "2024-07-14T10:00:37+02:00"
        )
    }

    // MARK: - AC-66.6: reopening after a save

    func test_AC_66_6() async {
        let mock = MockImmichClient()
        mock.updateAssetResponse = makeResponse(
            dateTimeOriginal: "2024-07-14T01:00:00.000Z", timeZone: "Europe/Paris"
        )
        let (detail, _) = await loadedDetail(mock: mock)
        let vm = makeVM(detail, device: tokyo)
        vm.wallClock = wall(2024, 7, 14, 10, 0, 0)
        vm.selectZone("Asia/Tokyo")
        let saved = await vm.save()
        XCTAssertTrue(saved)

        let reopened = makeVM(detail, device: tokyo)
        XCTAssertEqual(reopened.selectedZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(reopened.wallClock, wall(2024, 7, 14, 10, 0, 0))
    }

    func test_AC_66_6_cancelAndFailureKeepMemory() async {
        let mock = MockImmichClient()
        let response = makeResponse(dateTimeOriginal: "2024-07-14T01:00:00.000Z", timeZone: "Europe/Paris")
        mock.updateAssetResponse = response
        let (detail, _) = await loadedDetail(mock: mock)

        // A sheet closed without saving leaves no memory.
        let cancelled = makeVM(detail, device: tokyo)
        cancelled.selectZone("Asia/Tokyo")
        XCTAssertNil(detail.savedDateCorrection)
        XCTAssertEqual(makeVM(detail, device: tokyo).selectedZoneIdentifier, "Europe/Paris")

        // Save once, then fail: the first correction stays.
        let vm = makeVM(detail, device: tokyo)
        vm.wallClock = wall(2024, 7, 14, 10, 0, 0)
        vm.selectZone("Asia/Tokyo")
        let first = await vm.save()
        XCTAssertTrue(first)
        let remembered = detail.savedDateCorrection
        mock.updateAssetError = NSError(domain: "test", code: 500)
        mock.updateAssetErrorAfterSuccesses = mock.updateAssetCalls.count
        vm.selectZone("Europe/Paris")
        let second = await vm.save()
        XCTAssertFalse(second)
        XCTAssertEqual(detail.savedDateCorrection, remembered)

        // Another viewer on the same photo has no memory: it reads the server's data.
        let other = AssetDetailViewModel(asset: makeItem(), client: mock)
        mock.getAssetResponse["a1"] = response
        await other.loadDetail()
        XCTAssertNil(other.savedDateCorrection)
        let fresh = makeVM(other, device: tokyo)
        XCTAssertEqual(fresh.selectedZoneIdentifier, "Europe/Paris")
        XCTAssertEqual(fresh.wallClock, wall(2024, 7, 14, 3, 0, 0))
    }
}
