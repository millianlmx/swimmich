import SwiftUI

/// Loads images from authenticated Immich endpoints (Bearer token in header).
///
/// Premium pipeline (AC-200 integration):
/// 1. `ImageCache.shared` (in-memory NSCache) — instant hit on scroll-back.
/// 2. `imageSession` (URLCache-backed URLSession) — HTTP-level disk dedup,
///    honors server `Cache-Control` so repeated entries don't always re-hit net.
/// 3. Network fetch w/ Bearer header — only on cold load.
/// While in-flight a shimmer placeholder sweeps; on success the image crossfades.
struct AuthenticatedAsyncImage: View {
    let url: URL?
    let token: String?

    /// Fitting mode: `.fill` (default, thumbnails) vs `.fit` (full-screen viewer).
    var contentMode: ContentMode = .fill

    /// Offline copy (issue #18). When a file exists here it wins over every
    /// network tier: that is what makes a cached asset readable with no
    /// connection at all. Downsampled through ImageIO — a cached asset is an
    /// *original*, and decoding a 12-megapixel photo per grid cell would put
    /// tens of megabytes of bitmap in the scroll path.
    var localFileURL: URL? = nil
    var localMaxPixelSize: Int = 2048

    /// ThumbHash string (base64) from server used as instant placeholder while loading.
    var thumbhash: String? = nil

    @State private var image: UIImage?
    @State private var placeholderImage: UIImage?
    @State private var didFail = false

    init(
        url: URL?,
        token: String?,
        contentMode: ContentMode = .fill,
        localFileURL: URL? = nil,
        localMaxPixelSize: Int = 2048,
        thumbhash: String? = nil
    ) {
        self.url = url
        self.token = token
        self.contentMode = contentMode
        self.localFileURL = localFileURL
        self.localMaxPixelSize = localMaxPixelSize
        self.thumbhash = thumbhash
        if let thumbhash, let cached = ThumbHashDecoder.shared.cachedImage(for: thumbhash) {
            _placeholderImage = State(initialValue: cached)
        }
    }

    var body: some View {
        ZStack {
            if let placeholderImage {
                Image(uiImage: placeholderImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if image == nil && !didFail {
                ShimmerPlaceholder()
            }

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if didFail {
                Rectangle().fill(Color.bgTertiary.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundStyle(Color.textSecondaryPV))
            }
        }
        .animation(PVMotion.gentle, value: image != nil)
        // Keyed on the offline copy too: going offline→cached (or removing the
        // cached file) must re-run the load, even though the URL is unchanged.
        .task(id: localFileURL?.path ?? url?.absoluteString) {
            await load()
        }
    }

    /// `UIImage` isn't `Sendable`, so the detached hop hands back a box.
    private struct ImageBox: @unchecked Sendable {
        let image: UIImage?
    }

    private func load() async {
        // Reset state for the new URL (drives `.task(id:)` re-evals on URL change).
        if image != nil { image = nil }
        didFail = false

        if placeholderImage == nil, let thumbhash {
            if let cached = ThumbHashDecoder.shared.cachedImage(for: thumbhash) {
                self.placeholderImage = cached
            } else {
                let box = await Task.detached(priority: .userInitiated) {
                    ImageBox(image: ThumbHashDecoder.shared.image(for: thumbhash))
                }.value
                if let decoded = box.image {
                    self.placeholderImage = decoded
                }
            }
        }

        // Tier 0 — offline copy. Downsampling a multi-megapixel original is
        // real work: keep it off the main actor. A cached *video* has no still
        // frame in ImageIO, so it falls back to its first frame — otherwise the
        // tile would show the failure placeholder offline, since its thumbnail
        // normally comes from the server.
        if let localFileURL {
            let maxPixelSize = localMaxPixelSize
            let box = await Task.detached(priority: .userInitiated) {
                let image = ImageDownsampler.image(at: localFileURL, maxPixelSize: maxPixelSize)
                    ?? ImageDownsampler.videoPoster(at: localFileURL, maxPixelSize: maxPixelSize)
                return ImageBox(image: image)
            }.value
            if let local = box.image {
                self.image = local
                return
            }
        }

        guard let url else { return }

        // Tier 1 — in-memory cache. No await cost beyond actor hop.
        if let cached = await ImageCache.shared.image(for: url) {
            self.image = cached
            return
        }

        do {
            var request = URLRequest(url: url)
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            // Tiers 2+3 — URLCache dedup + network.
            let (data, response) = try await Self.imageSession.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                didFail = true
                return
            }
            guard let img = UIImage(data: data) else { didFail = true; return }
            // Populate both tiers for subsequent hits.
            await ImageCache.shared.store(img, for: url)
            self.image = img
        } catch {
            didFail = true
        }
    }

    /// Shared image session with a generous URLCache so the OS dedups HTTP
    /// traffic across scroll churn. Bearer header is per-request, so this
    /// session is safe to share between all authenticated image loads.
    private static let imageSession: URLSession = {
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,   // 50MB
            diskCapacity: 200 * 1024 * 1024,    // 200MB
            diskPath: "immich-image-cache"
        )
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
}

/// Animated shimmer sweep for the loading state — far more premium than a
/// bare `ProgressView`. Uses phase-animated gradient so it reads as "alive"
/// even on slow networks.
struct ShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(Color.bgTertiary.opacity(0.12))
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.35), // DS-exempt: infinite shimmer, not interactive
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 320)
                .mask(Rectangle())
            )
            .clipped()
            .onAppear {
                // DS-exempt: infinite shimmer, not interactive
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
