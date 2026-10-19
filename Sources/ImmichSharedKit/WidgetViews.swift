import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Palette

/// Widget surfaces share the app's brand gradient (the same pair the backup
/// Live Activity uses) — one identity across every system surface.
public let widgetBrandStart = backupBrandStart
public let widgetBrandEnd = backupBrandEnd
public var widgetBrandGradient: LinearGradient { backupBrandGradient }

/// Shared geometry: one radius and one gutter for every widget composition.
public enum WidgetMetrics {
    public static let tileRadius: CGFloat = 14
    public static let gutters: CGFloat = 6
}

// MARK: - Copy

/// Which day a timeline bucket belongs to, resolved against the device's
/// calendar so "Today" means the user's today, not the server's UTC day.
public enum WidgetDayLabel: Equatable {
    case today
    case yesterday
    case date(String)
}

public enum WidgetCopy {
    /// Bucket keys are `yyyy-MM-ddTHH:mm:ss.SSSZ`; only the date prefix matters,
    /// and it is read as literal digits so no timezone can shift the day.
    public static func dayLabel(
        bucket: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WidgetDayLabel? {
        guard let bucket, bucket.count >= 10 else { return nil }
        let parts = bucket.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        if parts[0] == today.year, parts[1] == today.month, parts[2] == today.day {
            return .today
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            let previous = calendar.dateComponents([.year, .month, .day], from: yesterday)
            if parts[0] == previous.year, parts[1] == previous.month, parts[2] == previous.day {
                return .yesterday
            }
        }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = calendar.date(from: components) else { return nil }
        return .date(date.formatted(.dateTime.day().month(.abbreviated)))
    }

    /// Grouped digits, so a six-figure library still reads at a glance.
    public static func grouped(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// "12 483 photos" — the library size chip.
    public static func photosText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 photo") : String(localized: "\(grouped(count)) photos")
    }

    /// "247 favorites" — the favorites chip.
    public static func favoritesText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 favorite") : String(localized: "\(grouped(count)) favorites")
    }

    /// "42 today" / "42 yesterday" / "42 on 1 Jul" — the newest day's haul.
    /// Nil when the wall has no bucket at all, so the caller falls back to the
    /// library size instead of printing a stranded count.
    public static func newestDayText(_ wall: PhotoWall, now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch dayLabel(bucket: wall.newestBucket, now: now, calendar: calendar) {
        case .today: String(localized: "\(grouped(wall.newestCount)) today")
        case .yesterday: String(localized: "\(grouped(wall.newestCount)) yesterday")
        case .date(let text): String(localized: "\(grouped(wall.newestCount)) on \(text)")
        case nil: nil
        }
    }

    /// "5 years ago" / "1 year ago" / "This year" — a memory's headline.
    public static func yearsAgoText(_ years: Int) -> String {
        switch years {
        case 0: String(localized: "This year")
        case 1: String(localized: "1 year ago")
        default: String(localized: "\(years) years ago")
        }
    }

    /// "5y" — the circular Lock Screen badge, where one word fits.
    public static func yearsAgoShort(_ years: Int) -> String {
        years == 0 ? String(localized: "now") : String(localized: "\(years)y")
    }

    /// VoiceOver label for a photo tile — the widget shows no date, so the
    /// spoken one carries the meaning. Phrases come from the catalog (the
    /// extension ships the same key set as the app), the date from the locale.
    public static func photoAccessibilityLabel(isVideo: Bool, isFavorite: Bool, day: WidgetDayLabel?) -> String {
        var parts = [isVideo ? String(localized: "Video") : String(localized: "Photo")]
        if isFavorite { parts.append(String(localized: "favorite")) }
        switch day {
        case .today: parts.append(String(localized: "from today"))
        case .yesterday: parts.append(String(localized: "from yesterday"))
        case .date(let text): parts.append(String(localized: "from \(text)"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Atoms

/// A photo cell: fills its frame, crops what overflows, and never collapses —
/// a failed thumbnail falls back to a brand-tinted plate.
public struct WidgetPhotoTile: View {
    private let photo: WidgetPhoto
    private let radius: CGFloat

    public init(photo: WidgetPhoto, radius: CGFloat = WidgetMetrics.tileRadius) {
        self.photo = photo
        self.radius = radius
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let data = photo.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Full brand strength, not a washed-out tint: a pale plate is
                    // indistinguishable from the redacted placeholder WidgetKit
                    // shows before a timeline lands, which cost a whole round of
                    // "is it broken?" on 2026-09-14.
                    LinearGradient(
                        colors: [widgetBrandStart, widgetBrandEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: photo.isVideo ? "video" : "photo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .overlay(alignment: .bottomLeading) {
            if photo.isVideo {
                Image(systemName: "video.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if photo.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(widgetBrandGradient, in: Circle())
                    .padding(5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetCopy.photoAccessibilityLabel(
            isVideo: photo.isVideo,
            isFavorite: photo.isFavorite,
            day: WidgetCopy.dayLabel(bucket: photo.day)
        ))
    }
}

/// Frosted capsule with an SF Symbol and one short line — the widget's voice.
public struct WidgetChip: View {
    private let systemImage: String
    private let text: String
    private let emphasized: Bool

    public init(systemImage: String, text: String, emphasized: Bool = false) {
        self.systemImage = systemImage
        self.text = text
        self.emphasized = emphasized
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .widgetAccentable()
            Text(verbatim: text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                // A widget tile is narrow and Dynamic Type can be huge: shrink
                // the label before the capsule eats it.
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if emphasized {
                Capsule().fill(widgetBrandGradient)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(emphasized ? 0.24 : 0.16), lineWidth: 0.5)
        }
    }
}

/// The heart that makes the Home Screen interactive: one tap hearts the hero
/// photo without opening the app.
public struct WidgetHeartButton: View {
    private let assetId: String
    private let isFavorite: Bool

    public init(assetId: String, isFavorite: Bool) {
        self.assetId = assetId
        self.isFavorite = isFavorite
    }

    public var body: some View {
        Button(intent: ToggleFavoriteIntent(assetId: assetId, favorite: !isFavorite)) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isFavorite ? widgetBrandStart : .white)
                .frame(width: 28, height: 28)
                .background(isFavorite ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        .padding(7)
    }
}

/// Shuffle a memory in place — new content on every tap.
public struct WidgetShuffleButton: View {
    public init() {}

    public var body: some View {
        Button(intent: ShuffleMemoriesIntent()) {
            Image(systemName: "shuffle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle memories")
        .padding(7)
    }
}

/// What an empty widget says. A widget cannot raise an error, so the copy has
/// to name the cause — "sign in" and "the server did not answer" need very
/// different reactions from the user, and a bare "No photos yet" hid both
/// behind a lie (issue #19).
enum WidgetEmptyCopy {
    static func state(
        for availability: WidgetAvailability,
        readyIcon: String,
        readyTitle: LocalizedStringKey,
        readySubtitle: LocalizedStringKey
    ) -> (icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        switch availability {
        case .ready:
            (readyIcon, readyTitle, readySubtitle)
        case .signedOut:
            (
                "person.crop.circle.badge.exclamationmark",
                "Sign in to Immich",
                "Open the app once and your photos appear here."
            )
        case .unreachable:
            (
                "wifi.exclamationmark",
                "Server unreachable",
                "Swimmich could not reach your server. Check the app can open it."
            )
        }
    }
}

public struct WidgetEmptyState: View {
    private let systemImage: String
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey
    /// "nas.local · certificate refused" — which server was asked and how it
    /// failed. Verbatim on purpose: it is a diagnostic, not a sentence.
    private let hint: String?

    public init(
        systemImage: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        hint: String? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.hint = hint
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(widgetBrandGradient)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hint {
                Text(hint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 14)
    }
}

/// The bottom scrim: photos stay the subject, the chips stay readable.
private struct WidgetScrim: View {
    var body: some View {
        LinearGradient(
            colors: [.black.opacity(0), .black.opacity(0.15), .black.opacity(0.66)],
            startPoint: .center,
            endPoint: .bottom
        )
    }
}

// MARK: - Photos widget

/// Newest photos, composed around one hero instead of a uniform grid — the
/// Home Screen gets a photo, not a thumbnail sheet.
public struct WidgetPhotosView: View {
    private let wall: PhotoWall
    /// `\.widgetFamily` is read-only, so previews (and `RenderPreview`) pass the
    /// family explicitly to show the Lock Screen compositions; inside a widget
    /// this stays nil and the environment wins.
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    private var widgetFamily: WidgetFamily { familyOverride ?? environmentFamily }

    public init(wall: PhotoWall, family: WidgetFamily? = nil) {
        self.wall = wall
        self.familyOverride = family
    }

    public var body: some View {
        if wall.isEmpty {
            let copy = WidgetEmptyCopy.state(
                for: wall.availability,
                readyIcon: "photo.on.rectangle.angled",
                readyTitle: "No photos yet",
                readySubtitle: "Photos show up here once they are backed up."
            )
            WidgetEmptyState(
                systemImage: copy.icon,
                title: copy.title,
                subtitle: copy.subtitle,
                hint: wall.failureHint
            )
        } else {
            composed
        }
    }

    @ViewBuilder
    private var composed: some View {
        switch widgetFamily {
        case .systemSmall:
            hero(fill: true)
        case .systemLarge:
            GeometryReader { proxy in
                VStack(spacing: WidgetMetrics.gutters) {
                    hero(fill: false)
                        .frame(height: proxy.size.height * 0.62)
                    HStack(spacing: WidgetMetrics.gutters) {
                        ForEach(wall.photos.dropFirst().prefix(3)) { photo in
                            tile(photo)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        case .accessoryRectangular:
            accessoryRow
        case .accessoryInline:
            Text(verbatim: inlineSummary)
        default:
            HStack(spacing: WidgetMetrics.gutters) {
                hero(fill: true)
                VStack(spacing: WidgetMetrics.gutters) {
                    ForEach(wall.photos.dropFirst().prefix(2)) { photo in
                        tile(photo)
                    }
                }
            }
        }
    }

    private func hero(fill: Bool) -> some View {
        guard let photo = wall.photos.first else { return AnyView(EmptyView()) }
        return AnyView(
            WidgetPhotoTile(photo: photo, radius: WidgetMetrics.tileRadius)
                .overlay(WidgetScrim())
                .overlay(alignment: .topTrailing) {
                    WidgetHeartButton(assetId: photo.id, isFavorite: photo.isFavorite)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 5) {
                        WidgetChip(
                            systemImage: "photo.stack",
                            text: WidgetCopy.photosText(wall.totalCount)
                        )
                        if let newest = WidgetCopy.newestDayText(wall) {
                            WidgetChip(systemImage: "sparkles", text: newest, emphasized: true)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: fill ? .infinity : nil, maxHeight: fill ? .infinity : nil)
        )
    }

    private func tile(_ photo: WidgetPhoto) -> some View {
        Link(destination: WidgetDeepLink.asset(id: photo.id, day: photo.day).url) {
            WidgetPhotoTile(photo: photo)
        }
    }

    private var accessoryRow: some View {
        HStack(spacing: 8) {
            if let photo = wall.photos.first {
                WidgetPhotoTile(photo: photo, radius: 8)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WidgetCopy.photosText(wall.totalCount))
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(verbatim: inlineSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineSummary: String {
        WidgetCopy.newestDayText(wall) ?? WidgetCopy.photosText(wall.totalCount)
    }
}

// MARK: - Memories widget

/// "On this day", one memory at a time, with a shuffle that costs nothing.
public struct WidgetMemoriesView: View {
    private let feed: WidgetMemoryFeed
    private var cards: [WidgetMemory] { feed.cards }
    /// See `WidgetPhotosView`: the preview seam for Lock Screen families.
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    private var widgetFamily: WidgetFamily { familyOverride ?? environmentFamily }

    public init(feed: WidgetMemoryFeed, family: WidgetFamily? = nil) {
        self.feed = feed
        self.familyOverride = family
    }

    public var body: some View {
        if cards.isEmpty {
            let copy = WidgetEmptyCopy.state(
                for: feed.availability,
                readyIcon: "sparkles",
                readyTitle: "No memories today",
                readySubtitle: "Photos you took on this day will show up here."
            )
            WidgetEmptyState(
                systemImage: copy.icon,
                title: copy.title,
                subtitle: copy.subtitle,
                hint: feed.failureHint
            )
        } else {
            composed
        }
    }

    @ViewBuilder
    private var composed: some View {
        switch widgetFamily {
        case .systemSmall:
            if let memory = cards.first { card(memory, fill: true) }
        case .accessoryCircular:
            accessoryCircle
        case .accessoryRectangular:
            accessoryRow
        case .accessoryInline:
            Text(verbatim: inlineSummary)
        default:
            HStack(spacing: WidgetMetrics.gutters) {
                ForEach(cards.prefix(2)) { memory in
                    card(memory, fill: true)
                }
            }
        }
    }

    private func card(_ card: WidgetMemory, fill: Bool) -> some View {
        Group {
            if let photo = card.photos.first {
                WidgetPhotoTile(photo: photo, radius: WidgetMetrics.tileRadius)
                    .overlay(WidgetScrim())
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            WidgetChip(
                                systemImage: "calendar.badge.clock",
                                text: WidgetCopy.yearsAgoText(card.yearsAgo),
                                emphasized: true
                            )
                            Text(verbatim: WidgetCopy.photosText(card.photos.count))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(8)
                    }
                    .overlay(alignment: .topTrailing) { WidgetShuffleButton() }
                    .frame(maxWidth: fill ? .infinity : nil, maxHeight: fill ? .infinity : nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(verbatimAccessibilityLabel(card))
    }

    private var accessoryCircle: some View {
        Group {
            if let photo = cards.first?.photos.first {
                WidgetPhotoTile(photo: photo, radius: 30)
                    .frame(width: 64, height: 64)
                    .overlay(WidgetScrim().clipShape(Circle()))
                    .overlay(alignment: .bottom) {
                        Text(verbatim: WidgetCopy.yearsAgoShort(cards.first?.yearsAgo ?? 0))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .widgetAccentable()
                            .padding(.bottom, 5)
                    }
            }
        }
    }

    private var accessoryRow: some View {
        HStack(spacing: 8) {
            if let photo = cards.first?.photos.first {
                WidgetPhotoTile(photo: photo, radius: 8)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WidgetCopy.yearsAgoText(cards.first?.yearsAgo ?? 0))
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(verbatim: WidgetCopy.photosText(cards.first?.photos.count ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineSummary: String {
        "\(WidgetCopy.yearsAgoText(cards.first?.yearsAgo ?? 0)) · \(WidgetCopy.photosText(cards.first?.photos.count ?? 0))"
    }

    private func verbatimAccessibilityLabel(_ card: WidgetMemory) -> String {
        "\(WidgetCopy.yearsAgoText(card.yearsAgo)), \(WidgetCopy.photosText(card.photos.count))"
    }
}

// MARK: - Favorites widget

/// The favorites, with the heart as the subject rather than a badge.
public struct WidgetFavoritesView: View {
    private let wall: PhotoWall
    /// See `WidgetPhotosView`: the preview seam for Lock Screen families.
    private let familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    private var widgetFamily: WidgetFamily { familyOverride ?? environmentFamily }

    public init(wall: PhotoWall, family: WidgetFamily? = nil) {
        self.wall = wall
        self.familyOverride = family
    }

    public var body: some View {
        if wall.isEmpty {
            let copy = WidgetEmptyCopy.state(
                for: wall.availability,
                readyIcon: "heart",
                readyTitle: "No favorites yet",
                readySubtitle: "Tap the heart on a photo to keep it here."
            )
            WidgetEmptyState(
                systemImage: copy.icon,
                title: copy.title,
                subtitle: copy.subtitle,
                hint: wall.failureHint
            )
        } else {
            composed
        }
    }

    @ViewBuilder
    private var composed: some View {
        switch widgetFamily {
        case .systemSmall:
            mosaic(columns: 2, limit: 4, fill: true)
                .overlay(watermark)
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(widgetBrandGradient)
                Text(verbatim: WidgetCopy.grouped(wall.totalCount))
                    .font(.caption2.weight(.bold))
                    .widgetAccentable()
            }
        case .accessoryRectangular:
            accessoryRow(systemImage: "heart.fill")
        case .accessoryInline:
            Text(verbatim: inlineSummary)
        case .systemLarge:
            mosaic(columns: 3, limit: 9, fill: true)
        default:
            mosaic(columns: 3, limit: 6, fill: true)
        }
    }

    /// Brand mark over the mosaic: a heart the size of the tile, kept faint
    /// enough to read as a watermark instead of a sticker. (Under the photos it
    /// would be invisible — a full mosaic has no gap to show it through.)
    private var watermark: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 128, weight: .bold))
            .foregroundStyle(.white.opacity(0.34))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
            .offset(x: 26, y: -20)
            .allowsHitTesting(false)
    }

    private func mosaic(columns: Int, limit: Int, fill: Bool) -> some View {
        let photos = Array(wall.photos.prefix(limit))
        let rows = stride(from: 0, to: photos.count, by: columns).map { Array(photos[$0..<min($0 + columns, photos.count)]) }
        return VStack(spacing: WidgetMetrics.gutters) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: WidgetMetrics.gutters) {
                    ForEach(row) { photo in
                        Link(destination: WidgetDeepLink.asset(id: photo.id, day: photo.day).url) {
                            WidgetPhotoTile(photo: photo, radius: 12)
                        }
                    }
                }
                .frame(maxHeight: fill ? .infinity : nil)
            }
        }
        .overlay(alignment: .bottomLeading) {
            WidgetChip(
                systemImage: "heart.fill",
                text: widgetFamily == .systemSmall
                    ? WidgetCopy.grouped(wall.totalCount)
                    : WidgetCopy.favoritesText(wall.totalCount),
                emphasized: true
            )
            .padding(8)
        }
    }

    private func accessoryRow(systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(widgetBrandGradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WidgetCopy.favoritesText(wall.totalCount))
                    .font(.headline)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(verbatim: inlineSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var inlineSummary: String {
        WidgetCopy.newestDayText(wall) ?? WidgetCopy.favoritesText(wall.totalCount)
    }
}

// MARK: - Gallery sample

/// What the widget gallery shows before the first fetch. Real numbers, painted
/// plates — the gallery is a shop window, and an empty state sells nothing.
/// (Same idea as Apple's own widgets: sample data, never a blank tile.)
public enum WidgetPlaceholder {
    public static func wall(favorite: Bool = false) -> PhotoWall {
        let photos = (0..<6).map { index in
            WidgetPhoto(
                id: "placeholder-\(index)",
                isVideo: index == 2,
                isFavorite: favorite || index == 1,
                day: nil
            )
        }
        return PhotoWall(photos: photos, totalCount: 12_483, newestBucket: nil, newestCount: 42)
    }

    public static func memories() -> WidgetMemoryFeed {
        WidgetMemoryFeed(cards: [
            WidgetMemory(id: "placeholder-1", yearsAgo: 5, photos: (0..<4).map { WidgetPhoto(id: "placeholder-m1-\($0)") }),
            WidgetMemory(id: "placeholder-2", yearsAgo: 2, photos: (0..<3).map { WidgetPhoto(id: "placeholder-m2-\($0)") }),
        ])
    }
}

// MARK: - Widget platter

/// Family maths, in one place: how many photos a composition needs, and whether
/// the family is a Lock Screen accessory (which keeps its system margins even
/// when the widget disables content margins for a full-bleed Home Screen look).
public extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }

    /// Photos to fetch — one hero plus the satellites the layout actually draws.
    var photoLimit: Int {
        switch self {
        case .systemLarge: 5
        case .systemMedium: 3
        case .systemSmall: 2
        case .accessoryRectangular, .accessoryInline: 1
        case .accessoryCircular: 1
        default: 3
        }
    }

    /// Memories to fetch — the small family shows one, the medium two.
    var memoryLimit: Int {
        switch self {
        case .systemMedium: 2
        default: 1
        }
    }
}

/// Applies the widget's own platter: a neutral canvas behind a full-bleed
/// composition, plus the system content margins for Lock Screen families —
/// `contentMarginsDisabled()` gives every family the whole rect, and an
/// accessory widget that ignores that ends up clipped.
public struct WidgetCanvas: ViewModifier {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins

    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(family.isAccessory ? margins : EdgeInsets())
            .containerBackground(for: .widget) { Color(.secondarySystemBackground) }
    }
}

public extension View {
    /// Wrap the widget's content once, in the widget declaration.
    func widgetCanvas() -> some View { modifier(WidgetCanvas()) }
}

// MARK: - Previews

#if DEBUG
/// Painted stand-ins so the previews (and `RenderPreview`) show the real
/// composition without a server.
enum WidgetPreviewFixtures {
    static func photo(id: String, color: UIColor, isVideo: Bool = false, isFavorite: Bool = false, day: String? = nil) -> WidgetPhoto {
        WidgetPhoto(id: id, imageData: jpeg(color), isVideo: isVideo, isFavorite: isFavorite, day: day)
    }

    static func wall(favorite: Bool = false) -> PhotoWall {
        let colors: [UIColor] = favorite
            ? [.systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemYellow, .systemGreen]
            : [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal, .systemRed]
        let photos = colors.enumerated().map { index, color in
            photo(id: "asset-\(index)", color: color, isVideo: index == 2, isFavorite: favorite || index == 1, day: "2026-09-13T00:00:00.000Z")
        }
        return PhotoWall(photos: photos, totalCount: 12_483, newestBucket: "2026-09-13T00:00:00.000Z", newestCount: 42)
    }

    static func cards() -> WidgetMemoryFeed {
        WidgetMemoryFeed(cards: [
            WidgetMemory(id: "m1", yearsAgo: 5, photos: (0..<4).map { photo(id: "m1-\($0)", color: [UIColor.systemOrange, .systemPink, .systemBrown, .systemIndigo][$0]) }),
            WidgetMemory(id: "m2", yearsAgo: 1, photos: (0..<3).map { photo(id: "m2-\($0)", color: [UIColor.systemTeal, .systemPurple, .systemGreen][$0]) }),
        ])
    }

    private static func jpeg(_ color: UIColor) -> Data? {
        let size = CGSize(width: 240, height: 240)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.25).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}

#Preview("Photos — small") {
    WidgetPhotosView(wall: WidgetPreviewFixtures.wall(), family: .systemSmall)
        .frame(width: 170, height: 170)
        .background(Color(.secondarySystemBackground))
}

#Preview("Photos — medium") {
    WidgetPhotosView(wall: WidgetPreviewFixtures.wall(), family: .systemMedium)
        .frame(width: 338, height: 158)
        .background(Color(.secondarySystemBackground))
}

#Preview("Photos — large") {
    WidgetPhotosView(wall: WidgetPreviewFixtures.wall(), family: .systemLarge)
        .frame(width: 338, height: 345)
        .background(Color(.secondarySystemBackground))
}

#Preview("Photos — no thumbnails") {
    WidgetPhotosView(
        wall: PhotoWall(
            photos: (0..<6).map { WidgetPhoto(id: "x-\($0)", isVideo: $0 == 2, isFavorite: $0 == 1) },
            totalCount: 12_483,
            newestBucket: "2026-09-13T00:00:00.000Z",
            newestCount: 42
        ),
        family: .systemSmall
    )
    .frame(width: 170, height: 170)
    .background(Color(.secondarySystemBackground))
}

#Preview("Photos — unreachable") {
    WidgetPhotosView(wall: .empty(.unreachable, hint: "nas.local · certificate refused"), family: .systemSmall)
        .frame(width: 170, height: 170)
        .background(Color(.secondarySystemBackground))
}

#Preview("Photos — empty") {
    WidgetPhotosView(wall: .empty, family: .systemSmall)
        .frame(width: 170, height: 170)
        .background(Color(.secondarySystemBackground))
}

#Preview("Memories — small") {
    WidgetMemoriesView(feed: WidgetPreviewFixtures.cards(), family: .systemSmall)
        .frame(width: 170, height: 170)
        .background(Color(.secondarySystemBackground))
}

#Preview("Memories — medium") {
    WidgetMemoriesView(feed: WidgetPreviewFixtures.cards(), family: .systemMedium)
        .frame(width: 338, height: 158)
        .background(Color(.secondarySystemBackground))
}

#Preview("Favorites — small") {
    WidgetFavoritesView(wall: WidgetPreviewFixtures.wall(favorite: true), family: .systemSmall)
        .frame(width: 170, height: 170)
        .background(Color(.secondarySystemBackground))
}

#Preview("Favorites — medium") {
    WidgetFavoritesView(wall: WidgetPreviewFixtures.wall(favorite: true), family: .systemMedium)
        .frame(width: 338, height: 158)
        .background(Color(.secondarySystemBackground))
}

#Preview("Lock Screen — rectangular") {
    VStack(spacing: 10) {
        WidgetMemoriesView(feed: WidgetPreviewFixtures.cards(), family: .accessoryRectangular)
        WidgetPhotosView(wall: WidgetPreviewFixtures.wall(), family: .accessoryRectangular)
        WidgetFavoritesView(wall: WidgetPreviewFixtures.wall(favorite: true), family: .accessoryRectangular)
    }
    .frame(width: 172, height: 90)
    .padding(12)
    .background(Color.black)
}

#Preview("Lock Screen — circular") {
    HStack(spacing: 14) {
        WidgetMemoriesView(feed: WidgetPreviewFixtures.cards(), family: .accessoryCircular)
        WidgetFavoritesView(wall: WidgetPreviewFixtures.wall(favorite: true), family: .accessoryCircular)
    }
    .padding(16)
    .background(Color.black)
}
#endif
