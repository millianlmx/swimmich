import AppIntents
import Foundation
import os
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
    public static var description = IntentDescription("Show the next memory of the day in the Immich widget.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        WidgetMemoriesShuffle.advance()
        WidgetCenter.shared.reloadTimelines(ofKind: ImmichWidgetKind.memories)
        return .result()
    }
}

/// Hearts a photo straight from the Home Screen.
///
/// The heart is the one action worth a widget: it is one small `PUT`, it
/// shows up immediately in the app, and the timeline reload paints the new
/// state. A failure is not shown (a widget cannot show an alert): it is
/// logged, and the timelines are not reloaded as after a success.
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
        let logger = Logger(subsystem: "app.immich.swiftui", category: "widget-intent")
        await Self.write(
            assetId: assetId,
            favorite: favorite,
            sessionStore: WidgetSessionStore(),
            transport: URLSessionWidgetTransport(session: URLSessionWidgetTransport.interactive()),
            reloadTimelines: { WidgetCenter.shared.reloadTimelines(ofKind: $0) },
            log: { logger.error("\($0, privacy: .public)") }
        )
        return .result()
    }

    /// The write behind `perform()`, with every side effect injected so a test
    /// can observe the request, the reloads and the failure line. Never throws:
    /// a failure (no session, bad URL, transport error, non-2xx) is logged and
    /// the timelines are left alone. The token is never logged.
    static func write(
        assetId: String,
        favorite: Bool,
        sessionStore: any WidgetSessionStoring,
        transport: any WidgetDataTransport,
        reloadTimelines: @Sendable (String) -> Void,
        log: @Sendable (String) -> Void
    ) async {
        guard let session = sessionStore.load() else {
            log("favorite write skipped for asset \(assetId): no widget session")
            return
        }
        guard let url = URL(string: session.baseURL + "/api/assets/\(assetId)"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            log("favorite write skipped for asset \(assetId): invalid server URL")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["isFavorite": favorite])

            let (_, http) = try await transport.send(request)
            guard (200...299).contains(http.statusCode) else {
                log("favorite write failed for asset \(assetId): HTTP \(http.statusCode)")
                return
            }
        } catch {
            log("favorite write failed for asset \(assetId): \(String(describing: error))")
            return
        }

        reloadTimelines(ImmichWidgetKind.favorites)
        reloadTimelines(ImmichWidgetKind.photos)
    }
}
