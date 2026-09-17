import Foundation

/// Bounds-checked accessor — returns nil on out-of-bounds instead of trapping.
/// Guards optional parallel-array indexing in columnar zip (FM-1 mitigation).
private func safeIndex<T>(_ array: [T]?, _ i: Int) -> T? {
    guard let array else { return nil }
    guard i >= 0, i < array.count else { return nil }
    return array[i]
}

/// Client-side representation of a timeline asset after zipping the columnar
/// `TimeBucketAssetResponseDto`. Designed for grid rendering + detail viewer.
struct AssetReactItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let ownerId: String
    let ratio: Double
    let isFavorite: Bool
    let visibility: String
    let isTrashed: Bool
    let isImage: Bool
    let thumbhash: String?
    let createdAt: String
    let fileCreatedAt: String
    let localOffsetHours: Double
    let duration: Int?
    let livePhotoVideoId: String?
    let projectionType: String?
    let city: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    /// Raw `stack` cell of the timeline bucket (gap #1): `[stackId, assetCount]`
    /// — the server serializes the count as a *string* (`array[stacked."stackId"::text,
    /// count('stacked')::text]`). Empty for an asset that stands on its own.
    ///
    /// The column is only emitted when the request asked `withStacked: true`,
    /// and only on the **primary** of a stack — every other request omits it
    /// entirely, so other grids never carry a stack badge.
    ///
    /// Read `stackId` / `stackCount` instead of indexing this array.
    let stack: [String]

    /// True for video assets.
    var isVideo: Bool { !isImage }

    /// True for Live Photos (image with paired motion video).
    var isLivePhoto: Bool { isImage && (livePhotoVideoId.map { !$0.isEmpty } ?? false) }

    /// True when this asset stands in for a stack of 2+ assets.
    var isStacked: Bool { stackId != nil }

    /// Server id of the stack this asset represents, when `isStacked`.
    var stackId: String? { stack.count == 2 ? stack[0] : nil }

    /// Total members of the stack — primary included — when `isStacked`.
    var stackCount: Int? { stack.count == 2 ? Int(stack[1]) : nil }

    /// Photos hidden behind the stack's cover (`stackCount - 1`), when known.
    /// This is the number the timeline badge shows.
    var stackedExtraCount: Int? { stackCount.map { max(0, $0 - 1) } }

    /// True when the slide plays inline motion in the slideshow: a real video,
    /// or a Live Photo whose video pair is present and playable (a nil or empty
    /// `livePhotoVideoId` renders as a still).
    var hasPlayableMotion: Bool { isVideo || (livePhotoVideoId.map { !$0.isEmpty } ?? false) }

    /// Display aspect ratio clamped to sane bounds (avoid div-by-zero/overflow).
    var aspectRatio: Double {
        guard ratio > 0 else { return 1.0 }
        return min(max(ratio, 0.2), 5.0)
    }

    /// Zips a columnar response into objects. FM-1: enforces same index association.
    /// Returns nil if response is malformed (mismatched required-array lengths).
    static func zip(_ dto: TimeBucketAssetResponseDto) -> [AssetReactItem] {
        let count = dto.id.count
        // All required arrays must match id length.
        guard dto.ownerId.count == count,
              dto.ratio.count == count,
              dto.isFavorite.count == count,
              dto.visibility.count == count,
              dto.isTrashed.count == count,
              dto.isImage.count == count,
              dto.thumbhash.count == count,
              dto.createdAt.count == count,
              dto.fileCreatedAt.count == count,
              dto.localOffsetHours.count == count,
              dto.duration.count == count,
              dto.livePhotoVideoId.count == count,
              dto.projectionType.count == count else {
            return []
        }
        var items: [AssetReactItem] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            items.append(AssetReactItem(
                id: dto.id[i],
                ownerId: dto.ownerId[i],
                ratio: dto.ratio[i],
                isFavorite: dto.isFavorite[i],
                visibility: dto.visibility[i],
                isTrashed: dto.isTrashed[i],
                isImage: dto.isImage[i],
                thumbhash: dto.thumbhash[i],
                createdAt: dto.createdAt[i],
                fileCreatedAt: dto.fileCreatedAt[i],
                localOffsetHours: dto.localOffsetHours[i],
                duration: dto.duration[i],
                livePhotoVideoId: dto.livePhotoVideoId[i],
                projectionType: dto.projectionType[i],
                city: safeIndex(dto.city, i).flatMap { $0 },
                country: safeIndex(dto.country, i).flatMap { $0 },
                latitude: safeIndex(dto.latitude, i).flatMap { $0 },
                longitude: safeIndex(dto.longitude, i).flatMap { $0 },
                stack: (safeIndex(dto.stack, i).flatMap { $0 } ?? []).compactMap { $0 }
            ))
        }
        return items
    }

    /// Builds the thumbnail URL for this asset against a base server URL.
    ///
    /// `sharedLink` (issue #22) scopes the URL to a public link: the credential
    /// travels in the query instead of a bearer header, so a visitor's grid can
    /// load the same thumbnails the owner sees.
    func thumbnailURL(base: URL, size: AssetMediaSize = .thumbnail, sharedLink: SharedLinkCredential? = nil) -> URL {
        ImmichAssetURL.thumbnail(
            assetId: id,
            thumbhash: thumbhash ?? "",
            baseURL: base,
            size: size,
            sharedLink: sharedLink
        )
    }

    /// Copy with `isFavorite` overridden (AC-205). Backs optimistic favorite
    /// toggle from the timeline / selection toolbar — all other fields intact.
    /// Original is unchanged (immutable `let` struct).
    func with(isFavorite: Bool) -> AssetReactItem {
        AssetReactItem(
            id: id,
            ownerId: ownerId,
            ratio: ratio,
            isFavorite: isFavorite,
            visibility: visibility,
            isTrashed: isTrashed,
            isImage: isImage,
            thumbhash: thumbhash,
            createdAt: createdAt,
            fileCreatedAt: fileCreatedAt,
            localOffsetHours: localOffsetHours,
            duration: duration,
            livePhotoVideoId: livePhotoVideoId,
            projectionType: projectionType,
            city: city,
            country: country,
            latitude: latitude,
            longitude: longitude,
            stack: stack
        )
    }
}

extension AssetReactItem {
    /// Adapts a full `AssetResponseDto` (search/getAsset response) into the
    /// grid-rendering type. Used by SearchViewModel to feed `AssetThumbnailCell`
    /// without a parallel columnar pipeline.
    ///
    /// Placed in an extension so the synthesized memberwise initializer stays
    /// available to the rest of the codebase (zip/with factories rely on it).
    ///
    /// Defaults for fields absent on `AssetResponseDto`:
    /// - `ratio = 1.0` (square cell; full DTO lacks aspect ratio — AC-410 FM-3)
    /// - `localOffsetHours = 0.0` (full DTO has ISO `localDateTime` w/ tz, not
    ///   a numeric offset; date headers in search may be off by ±12h, accepted MVP)
    init(from dto: AssetResponseDto) {
        self.id = dto.id
        self.ownerId = dto.ownerId
        self.ratio = 1.0
        self.isFavorite = dto.isFavorite
        self.visibility = dto.visibility
        self.isTrashed = dto.isTrashed
        self.isImage = (dto.type == "IMAGE")
        self.thumbhash = dto.thumbhash
        self.createdAt = dto.createdAt
        self.fileCreatedAt = dto.fileCreatedAt
        self.localOffsetHours = 0.0
        self.duration = dto.duration
        self.livePhotoVideoId = dto.livePhotoVideoId
        self.projectionType = dto.exifInfo?.projectionType
        self.city = dto.exifInfo?.city
        self.country = dto.exifInfo?.country
        self.latitude = dto.exifInfo?.latitude
        self.longitude = dto.exifInfo?.longitude
        self.stack = []
    }
}
