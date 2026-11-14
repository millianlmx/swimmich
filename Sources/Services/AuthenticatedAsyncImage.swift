import SwiftUI

/// What a loader has on screen, for tests (L-05). `placeholder` covers the
/// shimmer, the thumbhash and a cached thumbnail shown while the real image
/// is in flight; `loaded` carries the pixel size of the image actually decoded
/// from the requested source.
enum ImageLoadState: Equatable {
    case placeholder
    case loaded(pixelWidth: Int, pixelHeight: Int)
    case failed

    init(loaded image: UIImage) {
        if let cg = image.cgImage {
            self = .loaded(pixelWidth: cg.width, pixelHeight: cg.height)
        } else {
            self = .loaded(
                pixelWidth: Int(image.size.width * image.scale),
                pixelHeight: Int(image.size.height * image.scale)
            )
        }
    }

    /// `placeholder`, `failed` or `loaded <w>x<h>`, followed by ` <extra>` when
    /// `extra` is neither nil nor empty.
    func probeValue(extra: String?) -> String {
        let base: String
        switch self {
        case .placeholder: base = "placeholder"
        case .failed: base = "failed"
        case let .loaded(w, h): base = "loaded \(w)x\(h)"
        }
        guard let extra, !extra.isEmpty else { return base }
        return base + " " + extra
    }
}

/// Outcome of one load of the requested source (offline copy, memory cache or
/// network), independent of any provisional image shown meanwhile.
enum ImageSourceOutcome: Equatable {
    case loaded, failed
}

/// UI-test probe switch (`-uiTestImageProbe YES`). Off in production and in
/// every existing scenario: the loader then adds no accessibility modifier.
enum ImageLoadProbe {
    static let defaultsKey = "uiTestImageProbe"
    static let isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
}

private struct ImageLoadProbeModifier: ViewModifier {
    let state: ImageLoadState
    let extra: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if ImageLoadProbe.isEnabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityValue(Text(verbatim: state.probeValue(extra: extra)))
        } else {
            content
        }
    }
}

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

    /// Progressive placeholder: cached thumbnail URL to display immediately
    /// while the full-resolution preview is in-flight.
    var thumbnailURL: URL? = nil

    /// ThumbHash string (base64) from server used as instant placeholder while loading.
    var thumbhash: String? = nil

    /// Appended to the probe value (the viewer reports its zoom there).
    var probeExtra: String? = nil

    /// Called with the oriented size (`UIImage.size`, what `Image(uiImage:)`
    /// draws — not the raw pixels of `ImageLoadState`) each time the real image
    /// lands: offline copy, memory cache or network. Never for the thumbhash or
    /// the provisional cached thumbnail. The viewer fits its zoom geometry to it.
    var onImageSize: ((CGSize) -> Void)? = nil

    /// Bumping it re-runs the load and makes the request bypass the URL cache
    /// (the viewer's "Try Again").
    var reloadToken: Int = 0

    /// Result of the *requested* source, whatever provisional image is on
    /// screen. Once per `load()`; silent on cancellation and when `url` is nil.
    var onSourceOutcome: ((ImageSourceOutcome) -> Void)? = nil

    @State private var image: UIImage?
    @State private var placeholderImage: UIImage?
    @State private var didFail = false
    @State private var loadState: ImageLoadState = .placeholder
    @PVReduceMotion private var reduceMotion

    init(
        url: URL?,
        token: String?,
        contentMode: ContentMode = .fill,
        localFileURL: URL? = nil,
        localMaxPixelSize: Int = 2048,
        thumbnailURL: URL? = nil,
        thumbhash: String? = nil,
        probeExtra: String? = nil,
        onImageSize: ((CGSize) -> Void)? = nil,
        placeholder: UIImage? = nil,
        reloadToken: Int = 0,
        onSourceOutcome: ((ImageSourceOutcome) -> Void)? = nil
    ) {
        self.url = url
        self.token = token
        self.contentMode = contentMode
        self.localFileURL = localFileURL
        self.localMaxPixelSize = localMaxPixelSize
        self.thumbnailURL = thumbnailURL
        self.thumbhash = thumbhash
        self.probeExtra = probeExtra
        self.onImageSize = onImageSize
        self.reloadToken = reloadToken
        self.onSourceOutcome = onSourceOutcome
        // A caller-provided provisional image (the viewer's flying image) wins
        // over the ThumbHash: `load()` never clears `placeholderImage`, so it
        // stays under the real image until that one is ready.
        if let placeholder {
            _placeholderImage = State(initialValue: placeholder)
        } else if let thumbhash, let cached = ThumbHashDecoder.shared.cachedImage(for: thumbhash) {
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
        .animation(PVMotion.fading(PVMotion.gentle, reduceMotion: reduceMotion), value: image != nil)
        // Keyed on the offline copy too: going offline→cached (or removing the
        // cached file) must re-run the load, even though the URL is unchanged.
        .task(id: loadKey) {
            await load()
        }
        .modifier(ImageLoadProbeModifier(state: loadState, extra: probeExtra))
    }

    /// What `.task(id:)` watches. The offline copy keeps its path when it is downloaded again (after an
    /// edit was saved or removed, L-21), so the file's modification date is part of the key: the
    /// replaced file is decoded again. Read with `FileManager`, which does not cache the value.
    private var loadKey: String {
        let base: String
        if let localFileURL {
            let modified = (try? FileManager.default.attributesOfItem(atPath: localFileURL.path))?[.modificationDate] as? Date
            base = "\(localFileURL.path)|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
        } else {
            base = url?.absoluteString ?? ""
        }
        // The default token keeps every other screen's key unchanged.
        return reloadToken == 0 ? base : "\(base)#\(reloadToken)"
    }

    /// `UIImage` isn't `Sendable`, so the detached hop hands back a box.
    private struct ImageBox: @unchecked Sendable {
        let image: UIImage?
    }

    private func load() async {
        // Reset state for the new URL (drives `.task(id:)` re-evals on URL change).
        if image != nil { image = nil }
        didFail = false
        loadState = .placeholder

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
                loadState = ImageLoadState(loaded: local)
                onImageSize?(local.size)
                onSourceOutcome?(.loaded)
                return
            }
        }

        // Tier 0.5 — in-memory cached thumbnail placeholder for instant display.
        if let thumbnailURL, let cachedThumb = await ImageCache.shared.image(for: thumbnailURL) {
            self.image = cachedThumb
        }

        guard let url else { return }

        // Tier 1 — in-memory cache. No await cost beyond actor hop.
        if let cached = await ImageCache.shared.image(for: url) {
            self.image = cached
            loadState = ImageLoadState(loaded: cached)
            onImageSize?(cached.size)
            onSourceOutcome?(.loaded)
            return
        }

        // Read before the network await: a purge that lands while the request is
        // in flight bumps the epoch and `store` then drops this stale image.
        let epoch = await ImageCache.shared.epoch
        do {
            var request = URLRequest(url: url)
            // An explicit retry must reach the server: the session's
            // `.returnCacheDataElseLoad` would replay a cached failure.
            if reloadToken > 0 { request.cachePolicy = .reloadIgnoringLocalCacheData }
            ServerRequestAuthorization.apply(
                token: token, custom: CustomHeadersRegistry.shared.headers(for: url), to: &request
            )
            // Tiers 2+3 — URLCache dedup + network.
            let (data, response) = try await Self.imageSession.data(for: request)
            if Task.isCancelled { return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if self.image == nil { didFail = true; loadState = .failed }
                onSourceOutcome?(.failed)
                return
            }
            guard let img = UIImage(data: data) else {
                if self.image == nil { didFail = true; loadState = .failed }
                onSourceOutcome?(.failed)
                return
            }
            // Populate both tiers for subsequent hits.
            await ImageCache.shared.store(img, for: url, epoch: epoch)
            self.image = img
            loadState = ImageLoadState(loaded: img)
            onImageSize?(img.size)
            onSourceOutcome?(.loaded)
        } catch {
            if self.image == nil { didFail = true; loadState = .failed }
            if !UserFacingError.isCancellation(error) { onSourceOutcome?(.failed) }
        }
    }

    /// Disk tier of the image pipeline. Exposed so the voluntary-logout purge can
    /// empty it (`LocalDataPurger`).
    static let imageDiskCache = URLCache(
        memoryCapacity: 50 * 1024 * 1024,   // 50MB
        diskCapacity: 200 * 1024 * 1024,    // 200MB
        diskPath: "immich-image-cache"
    )

    /// Shared image session (`ServerSessions.images`): `imageDiskCache` so the OS
    /// dedups HTTP traffic across scroll churn, the trust-store TLS rule, and
    /// Authorization re-applied on same-host redirects. Bearer header is
    /// per-request. Read on the MainActor from `load()`.
    private static var imageSession: URLSession {
        DependencyContainer.shared.serverSessions.images
    }
}

/// Animated shimmer sweep for the loading state — far more premium than a
/// bare `ProgressView`. Uses phase-animated gradient so it reads as "alive"
/// even on slow networks.
struct ShimmerPlaceholder: View {
    @State private var phase: CGFloat = -1
    @PVReduceMotion private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color.bgTertiary.opacity(0.12))
            .overlay {
                if PVMotion.shimmerVisible(reduceMotion: reduceMotion) {
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
                }
            }
            .clipped()
            .onAppear { startShimmer() }
            .onChange(of: reduceMotion) { _, reduced in
                // Back to the start without animating, then loop again once motion is allowed.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = -1 }
                if !reduced { startShimmer() }
            }
    }

    /// Infinite shimmer loop; never started under Reduce Motion.
    private func startShimmer() {
        guard !reduceMotion else { return }
        withAnimation(PVMotion.shimmerLoop(duration: 1.1, reduceMotion: reduceMotion)) {
            phase = 1
        }
    }
}
