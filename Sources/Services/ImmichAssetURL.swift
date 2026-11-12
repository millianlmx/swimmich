import Foundation

/// Canonical Immich asset-media URL builders.
enum ImmichAssetURL {

    /// Builds the thumbnail URL for a given asset (AC-007 canonical form).
    /// Format: `{base}/api/assets/{id}/thumbnail?size={size}&c={thumbhash}`
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
        sharedLink: SharedLinkCredential? = nil
    ) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(ImmichAPI.assets.path("/\(assetId)/thumbnail")),
            resolvingAgainstBaseURL: false
        )
        var items = [
            URLQueryItem(name: "size", value: size.rawValue),
            URLQueryItem(name: "c", value: thumbhash)
        ]
        if let sharedLink { items.append(sharedLink.queryItem) }
        components?.queryItems = items
        return components?.url ?? baseURL
    }

    /// Original-file URL for a given asset. `edited` (when not nil) is sent explicitly: `false` asks for
    /// the file as uploaded, `true` for the server's edited rendering.
    static func original(assetId: String, baseURL: URL, sharedLink: SharedLinkCredential? = nil,
                         edited: Bool? = nil) -> URL {
        var url = baseURL.appendingPathComponent(ImmichAPI.assets.path("/\(assetId)/original"))
        var items: [URLQueryItem] = []
        if let sharedLink { items.append(sharedLink.queryItem) }
        if let edited { items.append(URLQueryItem(name: "edited", value: edited ? "true" : "false")) }
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
