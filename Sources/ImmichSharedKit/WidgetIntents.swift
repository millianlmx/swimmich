import AppIntents
import Foundation
import WidgetKit

/// Widget kinds, in one place so the intents that redraw them and the widget
/// declarations that own them cannot drift apart.
public enum ImmichWidgetKind {
    public static let photos = "ImmichGridWidget"
    public static let memories = "ImmichMemoriesWidget"
    public static let favorites = "ImmichFavoritesWidget"
}

/// Where the memories widget is in its shuffle, persisted in the widget
/// extension's own defaults (the extension is the only reader, so it needs no
/// App Group container and no extra entitlement).
public enum WidgetMemoriesShuffle {
    private static let key = "widget.memories.shuffle.offset"

    public static var offset: Int { UserDefaults.standard.integer(forKey: key) }

    public static func advance() {
        UserDefaults.standard.set(offset + 1, forKey: key)
    }
}

/// "Show me a different memory" — the widget's own button, no app launch.
///
/// Deliberately does no network work: it moves the rotation and asks WidgetKit
/// to redraw, and the timeline provider fetches on its own schedule.
public struct ShuffleMemoriesIntent: AppIntent {
    public static var title: LocalizedStringResource = "Shuffle Memories"
    public static var description = IntentDescription("Show the next memory of the day in the Swimmich widget.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        WidgetMemoriesShuffle.advance()
        WidgetCenter.shared.reloadTimelines(ofKind: ImmichWidgetKind.memories)
        return .result()
    }
}

/// Hearts a photo straight from the Home Screen.
///
/// The heart is the one action worth a widget: it is one small `PATCH`, it
/// shows up immediately in the app, and the timeline reload paints the new
/// state. Failures are silent on purpose — a widget cannot show an alert, and
/// the next reload renders the server's truth either way.
public struct ToggleFavoriteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Favorite Photo"
    public static var description = IntentDescription("Add or remove a photo from the Immich favorites.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Asset")
    public var assetId: String

    @Parameter(title: "Favorite")
    public var favorite: Bool

    public init() {}

    public init(assetId: String, favorite: Bool) {
        self.assetId = assetId
        self.favorite = favorite
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$favorite) on \(\.$assetId)")
    }

    public func perform() async throws -> some IntentResult {
        guard let session = WidgetSessionStore().load(),
              let url = URL(string: session.baseURL + "/api/assets/\(assetId)")
        else { return .result() }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["isFavorite": favorite])

        let transport = URLSessionWidgetTransport(session: URLSessionWidgetTransport.interactive())
        _ = try? await transport.send(request)

        WidgetCenter.shared.reloadTimelines(ofKind: ImmichWidgetKind.favorites)
        WidgetCenter.shared.reloadTimelines(ofKind: ImmichWidgetKind.photos)
        return .result()
    }
}
