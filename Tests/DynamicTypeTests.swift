import SwiftUI
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// L-13 (AC-26.x): text follows the system text size, labels are shown whole,
/// and the capped surfaces (tiles, full-screen chrome) stop where they must.
/// Views are hosted in a `UIHostingController` and measured with
/// `sizeThatFits`; nothing here reads source text.
@MainActor
final class DynamicTypeTests: XCTestCase {

    // MARK: - Hosting

    private static let screenWidth: CGFloat = 393
    private static let longText = "Summer holidays in the Gorges du Verdon with the whole family"
    private static let shortText = "Paris"

    /// Hosts `view` at `width` with the given Dynamic Type size and returns the
    /// size it asks for. The vertical `fixedSize` makes flexible views
    /// (`GeometryReader`, `Spacer`) take their ideal height instead of the
    /// infinite one proposed.
    private func hostedSize(
        _ view: some View,
        width: CGFloat = 393,
        size: DynamicTypeSize
    ) -> CGSize {
        let hosted = view
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, size)
        let controller = UIHostingController(rootView: hosted)
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    /// "Shown whole": the long text adds at least one line over the short text
    /// and the view stays within the screen width.
    private func assertWraps(
        long: some View,
        short: some View,
        token: Font,
        at size: DynamicTypeSize = .accessibility5,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let longSize = hostedSize(long, size: size)
        let shortSize = hostedSize(short, size: size)
        let oneLine = PVFontMetrics.lineHeight(token, at: size)
        XCTAssertGreaterThanOrEqual(
            longSize.height - shortSize.height, oneLine,
            "\(message): the long text must take at least one more line", file: file, line: line
        )
        XCTAssertLessThanOrEqual(longSize.width, Self.screenWidth, "\(message): wider than the screen", file: file, line: line)
    }

    // MARK: - Fixtures

    private func makeAsset(id: String = "a1", localDateTime: String = "2020-07-01T10:00:00.000Z") -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: localDateTime,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: localDateTime,
            ownerId: "owner", originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: localDateTime, fileModifiedAt: localDateTime,
            updatedAt: localDateTime, isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makePartner(name: String, inTimeline: Bool = true) -> PartnerResponseDto {
        PartnerResponseDto(
            id: "p1", name: name, email: "partner@example.org",
            profileImagePath: "", avatarColor: "#3366FF",
            profileChangedAt: "2024-01-01T00:00:00.000Z", inTimeline: inTimeline
        )
    }

    private func makeLink(description: String) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: "l1", description: description, password: nil, userId: "owner", key: "kl1",
            type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: false, allowDownload: true,
            showMetadata: true, slug: nil
        )
    }

    private func makeMemory(personName: String) -> MemoryResponseDto {
        let at = "2026-07-01T00:00:00.000Z"
        return MemoryResponseDto(
            id: "m1", createdAt: at, updatedAt: at, memoryAt: at, ownerId: "owner",
            type: .birthday, data: MemoryDataDto(year: 1996, personId: nil, personName: personName),
            assets: [], isSaved: false
        )
    }

    /// 65 characters.
    private static let longPersonName = "Maximiliana Wilhelmina Konstantinopoulou-Featherstonehaugh Junior"

    /// `Font.Weight` keeps its numeric value private; a resolved font stores it
    /// as a `Float` (bold resolves to 0.4000000059604645), so weights compare
    /// with a tolerance through their reflected `value` field.
    private func weightValue(_ w: Font.Weight, file: StaticString = #filePath, line: UInt = #line) -> Double {
        let raw = Mirror(reflecting: w).children.first { $0.label == "value" }?.value
        switch raw {
        case let value as CGFloat: return Double(value)
        case let value as Double: return value
        case let value as Float: return Double(value)
        default:
            XCTFail("Font.Weight has no readable `value` field: \(String(describing: raw))", file: file, line: line)
            return .nan
        }
    }

    // MARK: - AC-26.1 / AC-26.2

    func test_AC_26_1_tokensKeepDefaultSizeAndFollowSetting() {
        let tokens: [(name: String, font: Font, size: CGFloat, weight: Font.Weight)] = [
            ("pvTitleXL", .pvTitleXL, 34, .bold),
            ("pvTitle", .pvTitle, 28, .bold),
            ("pvHeadline", .pvHeadline, 17, .semibold),
            ("pvBody", .pvBody, 17, .regular),
            ("pvSubhead", .pvSubhead, 15, .regular),
            ("pvCaption", .pvCaption, 13, .regular),
            ("pvNumeric", .pvNumeric, 17, .semibold),
            ("pvBodyLarge", .pvBodyLarge, 16, .semibold),
            ("pvH6", .pvH6, 18, .semibold),
            ("pvH5", .pvH5, 20, .semibold),
            ("pvH4", .pvH4, 24, .bold),
            ("pvH3", .pvH3, 30, .bold),
            ("pvH2", .pvH2, 36, .bold),
            ("pvH1", .pvH1, 48, .bold),
        ]
        XCTAssertEqual(tokens.count, 14)
        for token in tokens {
            let regular = PVFontMetrics.resolved(token.font, at: .large)
            XCTAssertEqual(regular.pointSize, token.size, accuracy: 0.01, "\(token.name) default size")
            XCTAssertEqual(weightValue(regular.weight), weightValue(token.weight), accuracy: 0.001, "\(token.name) weight")
            XCTAssertLessThan(
                PVFontMetrics.resolved(token.font, at: .xSmall).pointSize, regular.pointSize,
                "\(token.name) must shrink at xSmall"
            )
            XCTAssertGreaterThan(
                PVFontMetrics.resolved(token.font, at: .accessibility5).pointSize, regular.pointSize,
                "\(token.name) must grow at accessibility5"
            )
        }
    }

    func test_AC_26_2_hostedTextGrowsWhenCategoryChangesAtRuntime() {
        // The Preferences row elements, with their real styles.
        let rows = VStack {
            Text("Group By").font(.pvBody)
            LabeledContent("Columns") { Text("3").font(.pvNumeric) }
        }
        .labeledContentStyle(.pvAdaptive)

        let controller = UIHostingController(rootView: rows)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let proposal = CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude)
        controller.view.layoutIfNeeded()
        let before = controller.sizeThatFits(in: proposal).height

        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let after = controller.sizeThatFits(in: proposal).height

        XCTAssertGreaterThan(after, before, "the same controller must re-measure taller after the category change")
    }

    // MARK: - AC-26.3

    func test_AC_26_3_inlineErrorBadgeWrapsAtAX5() {
        assertWraps(
            long: InlineErrorBadge(message: Self.longText, retry: {}),
            short: InlineErrorBadge(message: Self.shortText, retry: {}),
            token: .pvSubhead, "InlineErrorBadge"
        )
    }

    func test_AC_26_3_partnerRowWrapsAtAX5() {
        for mode in [PartnerRow.Mode.incoming, .outgoing] {
            assertWraps(
                long: PartnerRow(partner: makePartner(name: Self.longText), mode: mode, onToggle: { _ in }, onRemove: {}),
                short: PartnerRow(partner: makePartner(name: Self.shortText), mode: mode, onToggle: { _ in }, onRemove: {}),
                token: .pvBody, "PartnerRow \(mode)"
            )
        }
    }

    func test_AC_26_3_sharedLinkRowGrowsAtAX5() {
        let base = SharedLinkURL(serverURL: URL(string: "https://example.org")!)
        func row(_ description: String) -> SharedLinkRow {
            SharedLinkRow(
                link: makeLink(description: description), sharedLinkBase: base,
                isPendingRevoke: false, onRevoke: {}
            )
        }
        assertWraps(long: row(Self.longText), short: row(Self.shortText), token: .pvSubhead, "SharedLinkRow")
        // No fixed height any more: the long row is taller than the old 84 pt.
        XCTAssertGreaterThan(hostedSize(row(Self.longText), size: .accessibility5).height, 84)
    }

    func test_AC_26_3_languageToastWrapsAtAX5() {
        let large = hostedSize(LanguageToast(onDismiss: {}), size: .large)
        let ax5 = hostedSize(LanguageToast(onDismiss: {}), size: .accessibility5)
        XCTAssertLessThanOrEqual(ax5.width, Self.screenWidth)
        // The message wraps over several lines and the button sits under it.
        XCTAssertGreaterThanOrEqual(
            ax5.height - large.height, PVFontMetrics.lineHeight(.pvSubhead, at: .accessibility5),
            "the toast must grow by at least one line at AX5"
        )
        XCTAssertGreaterThanOrEqual(ax5.height, 2 * PVFontMetrics.lineHeight(.pvSubhead, at: .accessibility5) + 44)
    }

    func test_AC_26_3_adaptiveLabeledContentStacksAtAccessibilitySizes() {
        let styled = LabeledContent("Columns") { Text("3") }.labeledContentStyle(.pvAdaptive)
        let plain = LabeledContent("Columns") { Text("3") }

        let ax5 = hostedSize(styled, size: .accessibility5)
        XCTAssertLessThanOrEqual(ax5.width, Self.screenWidth)
        XCTAssertGreaterThanOrEqual(
            ax5.height, 2 * PVFontMetrics.lineHeight(.body, at: .accessibility5),
            "label and value must be stacked (two lines) at AX5"
        )

        let styledLarge = hostedSize(styled, size: .large)
        let plainLarge = hostedSize(plain, size: .large)
        XCTAssertEqual(styledLarge.height, plainLarge.height, accuracy: 0.5, "default rendering is the system's")
        XCTAssertEqual(styledLarge.width, plainLarge.width, accuracy: 0.5)
    }

    func test_AC_26_3_searchModeBarNotCappedAtAX5() {
        let ax5 = hostedSize(SearchModeGlassBar(mode: .constant(.results)), size: .accessibility5)
        XCTAssertGreaterThanOrEqual(
            ax5.height, 3 * PVFontMetrics.lineHeight(.pvSubhead, at: .accessibility5),
            "three stacked segments at the uncapped Subhead size"
        )
        let large = hostedSize(SearchModeGlassBar(mode: .constant(.results)), size: .large)
        XCTAssertEqual(large.height, 44, accuracy: 0.5)
    }

    // MARK: - AC-26.4

    func test_AC_26_4_uploadAssetRowWrapsAtAX5() {
        func row(_ name: String) -> some View {
            UploadAssetRow(
                thumbnailID: nil, name: name, detail: "Waiting", detailColor: .secondary,
                size: "1.2 MB", nameIdentifier: "uploadDetailRowName_x",
                trailing: { Button("Retry") {} }
            )
        }
        assertWraps(
            long: row("IMG_20260901_Summer_holidays_in_the_Gorges_du_Verdon_with_the_whole_family.heic"),
            short: row("a.jpg"),
            token: .pvBody, "UploadAssetRow"
        )
    }

    func test_AC_26_4_infoGridItemWrapsAtAX5() {
        assertWraps(
            long: InfoGridItem(symbol: "camera", value: "Hasselblad Photographic Instruments X2D 100C Medium Format Edition"),
            short: InfoGridItem(symbol: "camera", value: "Stub"),
            token: .pvCaption.weight(.medium), "InfoGridItem"
        )
        // The grid itself is a single column at accessibility sizes.
        let grid = InfoGrid(items: [("camera", "Stub"), ("mappin", "Paris"), ("calendar", "Sep 1, 2026")])
        let large = hostedSize(grid, size: .large)
        let ax5 = hostedSize(grid, size: .accessibility5)
        XCTAssertGreaterThan(ax5.height, large.height)
        XCTAssertLessThanOrEqual(ax5.width, Self.screenWidth)
    }

    func test_AC_26_4_memoryCardGrowsPastFixedHeight() {
        let card = MemoryCard(
            memory: makeMemory(personName: Self.longPersonName),
            baseURL: URL(string: "https://example.org")!, token: nil,
            onOpen: {}, onToggleSaved: {}, onAddPhotos: {}, onDelete: {}
        )
        XCTAssertEqual(Self.longPersonName.count, 65)
        let size = hostedSize(card, size: .accessibility5)
        XCTAssertGreaterThan(size.height, 320, "a long title makes the card grow past 320 pt")
        XCTAssertLessThanOrEqual(size.width, Self.screenWidth)
    }

    func test_AC_26_4_appLockPromptWrapsAtAX5() {
        let titleFont = PVFontMetrics.uiFont(.pvTitle, at: .accessibility5)
        let title = String(localized: AppLockCoverView.title)
        let oneLineWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        XCTAssertGreaterThan(
            oneLineWidth, Self.screenWidth - 2 * PVSpacing.s24,
            "precondition: the title does not fit on one line at AX5"
        )
        let size = hostedSize(AppLockPrompt(onUnlock: {}), size: .accessibility5)
        let expected = 56 + 2 * PVFontMetrics.lineHeight(.pvTitle, at: .accessibility5) + 50
        XCTAssertGreaterThanOrEqual(size.height, expected, "glyph, a two-line title and the 50 pt button")
        XCTAssertLessThanOrEqual(size.width, Self.screenWidth)
    }

    func test_AC_26_4_pinnedHeaderDropsBelowToolbarWhenTheyDontFit() {
        let group = CGSize(width: 186, height: 44)
        let header: CGFloat = 200
        let exact = PVSpacing.s16 + header + PVSpacing.s8 + group.width + PVSpacing.s16
        XCTAssertEqual(
            TimelinePinnedHeaderPlacement.topPadding(containerWidth: exact, headerWidth: header, group: group),
            PVSpacing.s8
        )
        XCTAssertEqual(
            TimelinePinnedHeaderPlacement.topPadding(containerWidth: exact - 1, headerWidth: header, group: group),
            PVSpacing.s8 + group.height + PVSpacing.s8
        )
        XCTAssertEqual(
            TimelinePinnedHeaderPlacement.topPadding(containerWidth: 100, headerWidth: 500, group: .zero),
            PVSpacing.s8
        )
    }

    // MARK: - AC-26.5

    func test_AC_26_5_memoryChipShowsWholeText() {
        let panelWidth = Self.screenWidth - 2 * PVSpacing.s16
        let long = MemoryChip(symbol: "mappin.and.ellipse", text: "Saint-Rémy-de-Provence-sur-la-Mer-Lointaine, France")
        let short = MemoryChip(symbol: "mappin.and.ellipse", text: "Paris")
        let longSize = hostedSize(long, width: panelWidth, size: .accessibility5)
        let shortSize = hostedSize(short, width: panelWidth, size: .accessibility5)
        let oneLine = PVFontMetrics.lineHeight(.pvCaption.weight(.medium), at: .accessibility2)
        XCTAssertGreaterThanOrEqual(
            longSize.height - shortSize.height, oneLine,
            "the long chip wraps inside the proposed width instead of running off screen"
        )
        XCTAssertLessThanOrEqual(longSize.width, panelWidth)
    }

    // MARK: - AC-26.7

    func test_AC_26_7_viewerBadgeWidthFollowsCappedSize() {
        func width(_ size: DynamicTypeSize) -> CGFloat {
            PhotoViewerTopBarLayout.badgeWidth(place: "Paris, France", date: "Sep 1, 2026", dynamicTypeSize: size)
        }
        XCTAssertGreaterThan(width(.xxxLarge), width(.large))
        XCTAssertGreaterThan(width(.accessibility1), width(.xxxLarge))
        XCTAssertGreaterThan(width(.accessibility2), width(.accessibility1))
        XCTAssertEqual(width(.accessibility5), width(.accessibility2), "capped at AX2")

        // A place name this long cannot sit in a two-line badge next to the
        // four pills on 393 pt once the text is at AX2.
        let longPlaceWidth = PhotoViewerTopBarLayout.badgeWidth(
            place: "Saint-Rémy-de-Provence, France", date: "Sep 1, 2026", dynamicTypeSize: .accessibility5
        )
        let plan = PhotoViewerTopBarLayout.plan(
            availableWidth: Self.screenWidth, badgeWidth: longPlaceWidth, actionCount: 4
        )
        XCTAssertEqual(plan.badge, .singleLineTruncated)
    }

    func test_AC_26_7_tileBadgeStopsGrowingAtDefaultSize() {
        let badge = VideoDurationBadge(text: "1:05")
        let large = hostedSize(badge, size: .large).height
        let ax5 = hostedSize(badge, size: .accessibility5).height
        let xSmall = hostedSize(badge, size: .xSmall).height
        XCTAssertEqual(ax5, large, accuracy: 0.5)
        // Caption 2 is 11 pt from xSmall to Large (HIG table): never taller below the default.
        XCTAssertLessThanOrEqual(xSmall, large)
    }

    // MARK: - AC-26.9

    private func assertCappedAtAX2(
        _ view: some View, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let large = hostedSize(view, size: .large).height
        let ax2 = hostedSize(view, size: .accessibility2).height
        let ax5 = hostedSize(view, size: .accessibility5).height
        XCTAssertEqual(ax5, ax2, accuracy: 0.5, "\(name) must stop growing at AX2", file: file, line: line)
        XCTAssertGreaterThan(ax5, large, "\(name) must still be taller than at the default size", file: file, line: line)
    }

    func test_AC_26_9_fullscreenTextStopsGrowingAtAX2() {
        assertCappedAtAX2(SlideshowCounterLabel(index: 3, count: 12, isVideo: false), "SlideshowCounterLabel")
        assertCappedAtAX2(SlideshowSpeedLabel(text: "5 s"), "SlideshowSpeedLabel")
        assertCappedAtAX2(MemoryTypeBadge(text: "Birthday", symbol: "gift"), "MemoryTypeBadge")
        assertCappedAtAX2(MemoryChip(symbol: "camera", text: "Stub"), "MemoryChip")
    }

    func test_AC_26_9_memoryTitleNotTruncatedUnderCap() {
        let memory = makeMemory(personName: Self.longPersonName)
        let block = MemoryTitleBlock(memory: memory, heroAsset: makeAsset())
        let ax5 = hostedSize(block, size: .accessibility5).height
        let ax2 = hostedSize(block, size: .accessibility2).height
        XCTAssertGreaterThanOrEqual(
            ax5, PVFontMetrics.lineHeight(.pvH3, at: .accessibility2) * 3,
            "the whole title shows on at least three lines"
        )
        XCTAssertEqual(ax5, ax2, accuracy: 0.5, "capped at AX2")
    }
}
