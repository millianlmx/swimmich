import ImmichSharedKit
import SwiftUI
import WidgetKit

/// The favorites, with the heart as the subject. Views live in
/// `ImmichSharedKit`, see `ImmichGridWidget` for why.
struct ImmichFavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ImmichWidgetKind.favorites, provider: FavoritesTimelineProvider()) { entry in
            WidgetFavoritesView(wall: entry.wall)
                .widgetCanvas()
        }
        .configurationDisplayName("Swimmich Favorites")
        .description("The photos you kept.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

struct FavoritesEntry: TimelineEntry {
    let date: Date
    let wall: PhotoWall
}

struct FavoritesTimelineProvider: TimelineProvider {
    private let provider = WidgetDataProvider()

    func placeholder(in context: Context) -> FavoritesEntry {
        FavoritesEntry(date: .now, wall: WidgetPlaceholder.wall(favorite: true))
    }

    func getSnapshot(in context: Context, completion: @escaping (FavoritesEntry) -> Void) {
    /// The gallery's snapshot is a *live* self-test: it fetches like the Home
    /// Screen does and shows whatever comes back — photos, or the reason they
    /// did not. Apple suggests a sample for the gallery, and a sample is exactly
    /// what hid this bug for two days: the gallery looked fine while the real
    /// fetch never worked (issue #19 follow-up). `placeholder(in:)` still serves
    /// the redacted first render.
        Task {
            let wall = await provider.favoritePhotos(limit: context.family.photoLimit)
            completion(FavoritesEntry(date: .now, wall: wall))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FavoritesEntry>) -> Void) {
        Task {
            let wall = await provider.favoritePhotos(limit: context.family.photoLimit)
            completion(Timeline(
                entries: [FavoritesEntry(date: .now, wall: wall)],
                policy: .after(.now.addingTimeInterval(wall.availability == .ready ? 60 * 60 : 5 * 60))
            ))
        }
    }
}
