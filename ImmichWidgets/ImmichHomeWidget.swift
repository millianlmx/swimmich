import ImmichSharedKit
import SwiftUI
import WidgetKit

/// Launcher tile: opens the app and starts a backup.
///
/// The widget process cannot reach the app's view models and holds no photo
/// cache of its own, so this one stays data-free — the Live Activity covers the
/// progress, the other three widgets cover the content. Its whole job is the
/// `app.immich://backup` deep link, which the app routes to the Photos tab and
/// the gated engine.
struct ImmichHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ImmichHomeWidget", provider: ImmichHomeTimelineProvider()) { _ in
            VStack(spacing: 8) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(widgetBrandGradient)
                Text("Swimmich")
                    .font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Back up now")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(widgetBrandGradient))
            }
            .widgetCanvas()
            .widgetURL(WidgetDeepLink.backup.url)
        }
        .configurationDisplayName("Swimmich Backup")
        .description("Start a backup from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct ImmichHomeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry() }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry()], policy: .never))
    }
}

private struct SimpleEntry: TimelineEntry {
    let date = Date()
}
