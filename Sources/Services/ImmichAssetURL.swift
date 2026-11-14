import Foundation
import Observation

/// The thumbhash an edited photo had, mapped to the one the server gave it after regenerating its
/// thumbnails (L-21). The thumbhash is the cache key of every thumbnail URL (`c`): once the
/// regeneration is seen, every URL built from the old value (a grid cell, an album, a search result,
/// a memory, the viewer) is built from the new one, so each screen loads the edited image without
/// waiting for its own list to be read again. Keyed by the OLD value on purpose: a later edit made
/// elsewhere brings a thumbhash that is not a key, and is never shadowed by a stale entry.
///
/// Observable: a `body` that builds a URL through `ImmichAssetURL` is re-evaluated when an entry is
/// recorded. Thread-safe: URLs are also built off the main actor.
final class ThumbhashSuccession: @unchecked Sendable, Observable {
    static let shared = ThumbhashSuccession()

    private let lock = NSLock()
    private let registrar = ObservationRegistrar()
    private var successors: [String: String] = [:]
    private var revision = 0

    /// Observation key path only: bumped by `record`.
    var observedRevision: Int { lock.withLock { revision } }

    /// `hash` itself, or the newest thumbhash recorded after it.
    func current(for hash: String) -> String {
        registrar.access(self, keyPath: \.observedRevision)
        return lock.withLock {
            var resolved = hash
            var steps = 0
            while let next = successors[resolved], steps < 16 {
                resolved = next
                steps += 1
            }
            return resolved
        }
    }

    /// Records that the thumbhash `old` is now `new`. No-op for an empty or unchanged value.
    func record(old: String?, new: String?) {
        guard let old, let new, !old.isEmpty, !new.isEmpty, old != new else { return }
        registrar.withMutation(of: self, keyPath: \.observedRevision) {
            lock.withLock {
                successors[old] = new
                revision += 1
            }
        }
    }

    /// Forgets every entry (tests).
    func removeAll() {
        registrar.withMutation(of: self, keyPath: \.observedRevision) {
            lock.withLock {
                successors.removeAll()
                revision += 1
            }
        }
    }
}

/// Canonical Immich asset-media URL builders.
enum ImmichAssetURL {

    /// Builds the thumbnail URL for a given asset (AC-007 canonical form).
    /// Format: `{base}/api/assets/{id}/thumbnail?size={size}&c={thumbhash}&edited={true|false}`
    ///
    /// Every display asks for the edited rendering, explicitly (L-21: `edited` defaults to `true`): the
    /// server's default differs between versions, and `edited=true` serves the original of a photo
    /// without edits. Only sharing (`ViewerShareViewModel`) asks `edited=false`: it shares the photo as uploaded.
    /// A photo edited elsewhere therefore shows edited on every surface; the `c` thumbhash
    /// changes once the server has regenerated the thumbnails, which is what busts the image cache.
    ///
    /// `sharedLink` adds the visitor's `key`/`slug` query item: a public link is
    /// read without a bearer token, and that credential is what the server
    /// authenticates the request with (`AuthService.validate`). Asking for
    /// `size=fullsize` on a shared link is safe — `AssetMediaService.viewThumbnail`
    /// forces `edited = true` for shared-link auth, which skips the redirect to
    /// `original` (a route needing `AssetDownload`, which a link may not grant).
    static func thumbnail(
        assetId: String,
        thumbhash: String,
        baseURL: URL,
        size: AssetMediaSize = .thumbnail,
        sharedLink: SharedLinkCredential? = nil,
        edited: Bool = true
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(ImmichAPI.assets.path("/\(assetId)/thumbnail")),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "size", value: size.rawValue),
            URLQueryItem(name: "c", value: ThumbhashSuccession.shared.current(for: thumbhash))
        ]
        if let sharedLink { items.append(sharedLink.queryItem) }
        items.append(URLQueryItem(name: "edited", value: edited ? "true" : "false"))
        components?.queryItems = items
        return components?.url ?? baseURL
    }

    /// Original-file URL for a given asset. `edited` (when not nil) is sent explicitly: `false` asks for
    /// the file as uploaded, `true` for the server's edited rendering. `cacheKey` (the photo's
    /// thumbhash, for a display URL) goes last as `c`, like the thumbnail's: the image caches are keyed by
    /// URL, and an edit must change what an edited display asks for.
    static func original(assetId: String, baseURL: URL, sharedLink: SharedLinkCredential? = nil,
                         edited: Bool? = nil, cacheKey: String? = nil) -> URL {
        var url = baseURL.appendingPathComponent(ImmichAPI.assets.path("/\(assetId)/original"))
        var items: [URLQueryItem] = []
        if let sharedLink { items.append(sharedLink.queryItem) }
        if let edited { items.append(URLQueryItem(name: "edited", value: edited ? "true" : "false")) }
        if let cacheKey, !cacheKey.isEmpty {
            items.append(URLQueryItem(name: "c", value: ThumbhashSuccession.shared.current(for: cacheKey)))
        }
        if !items.isEmpty { url.append(queryItems: items) }
        return url
    }

    /// Video playback URL (supports Range header on server side).
    static func videoPlayback(assetId: String, baseURL: URL, sharedLink: SharedLinkCredential? = nil) -> URL {
        var url = baseURL.appendingPathComponent(ImmichAPI.assets.path("/\(assetId)/video/playback"))
        if let sharedLink { url.append(queryItems: [sharedLink.queryItem]) }
        return url
    }

    /// Face thumbnail for a person (`GET /api/people/{id}/thumbnail`).
    static func personThumbnail(personId: String, baseURL: URL, size: AssetMediaSize = .thumbnail) -> URL {
        var url = baseURL.appendingPathComponent(ImmichAPI.people.path("/\(personId)/thumbnail"))
        if size != .thumbnail {
            url = url.appending(queryItems: [URLQueryItem(name: "size", value: size.rawValue)])
        }
        return url
    }

    /// Profile picture of a user (`GET /api/users/{id}/profile-image`, served
    /// as `application/octet-stream`; bearer-authenticated, so it loads through
    /// `AuthenticatedAsyncImage` — never a token in the query string).
    ///
    /// `changedAt` is the cache-buster, with the same role as `thumbhash` in
    /// `thumbnail(…)`: `ImageCache` is keyed by URL, so without it a photo
    /// uploaded *over* an older one would still be served from the cache.
    static func profileImage(userId: String, changedAt: String?, baseURL: URL) -> URL {
        let url = baseURL.appendingPathComponent(ImmichAPI.users.path("/\(userId)/profile-image"))
        guard let changedAt, !changedAt.isEmpty else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "v", value: changedAt)])
    }
}
