import SwiftUI

/// Photos-grade zoomable image page for the full-screen photo viewer.
///
/// Gesture surface:
/// - **Pinch** (`MagnifyGesture`) zooms in [1, 4], anchored at center.
/// - **Double-tap** toggles 1x ↔ 3x (Photos default zoom).
/// - **Pan** moves the image while zoomed; at 1x it is a no-op so the pager
///   (TabView) owns horizontal drags.
/// - **Single tap** toggles the viewer chrome (parent callback).
///
/// The pan gesture is attached with `.highPriorityGesture` only while zoomed
/// so it wins over the pager; at 1x it degrades to `.simultaneousGesture` (a
/// guarded no-op) so paging stays responsive. Reset-on-page-change is handled
/// by the pager giving each page a stable `.id(asset.id)` — SwiftUI recreates
/// the view (and its `@State`) when the asset changes.
struct ZoomableImageView: View {
    let asset: AssetReactItem
    let baseURL: URL
    let token: String?
    var onSingleTap: () -> Void = {}
    /// Reports the current scale so the parent can gate swipe-to-dismiss.
    var onZoomChange: (CGFloat) -> Void = { _ in }
    /// Public-link scope (issue #22): the visitor's credential goes in the
    /// fullsize image URL instead of a bearer header.
    var sharedLink: SharedLinkCredential? = nil

    /// Offline copy (issue #18): when present the full-size page is served from
    /// disk, which is what makes a cached photo viewable with no connection.
    var localFileURL: URL? = nil

    /// Detected text boxes of this asset (ocr-text). Empty → nothing is drawn;
    /// the defaults leave every existing call site unchanged.
    var ocrBoxes: [AssetOcrResponseDto] = []
    /// Whether the detected-text layer is on. Drawn here — and only here —
    /// because `scale`/`offset` live in this view, so the boxes follow the
    /// photo through pinch, double-tap and pan instead of freezing under it.
    var showOcr: Bool = false

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Image-quality preference (gap G22): original file or the server's
    /// `.fullsize` rendition. Read at render time, so a page already on screen
    /// follows a change made in Preferences.
    @Environment(AppSettingsStore.self) private var appSettings

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 4

    private var isZoomed: Bool { scale > 1.01 }

    /// The one line that decides which variant this page fetches. The offline
    /// copy (`localFileURL`) and the image cache cover both URLs unchanged —
    /// the cache key is the URL itself.
    private var imageURL: URL {
        appSettings.loadOriginal
            ? ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL, sharedLink: sharedLink)
            : asset.thumbnailURL(base: baseURL, size: .preview, sharedLink: sharedLink)
    }

    var body: some View {
        GeometryReader { proxy in
            // Explicit full frame: GeometryReader aligns its child top-leading,
            // so a content-sized `.fit` image would sit at the top, not centered.
            // The frame fills the page and centers the fitted image in both axes.
            let base = AuthenticatedAsyncImage(
                url: imageURL,
                token: token,
                contentMode: .fit,
                localFileURL: localFileURL,
                // Full screen: keep enough pixels for pinch-zoom to 4x without
                // re-decoding, still far below the original's own size.
                localMaxPixelSize: 4096,
                thumbnailURL: asset.thumbnailURL(base: baseURL, size: .thumbnail, sharedLink: sharedLink)
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = Self.clamp(lastScale * value.magnification, min: minScale, max: maxScale)
                        onZoomChange(scale)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale < 1.05 {
                            // Photos never rests between 1x and the zoom threshold.
                            withAnimation(PVMotion.snappy) {
                                scale = 1
                                offset = .zero
                            }
                            lastScale = 1
                            lastOffset = .zero
                        }
                        onZoomChange(scale)
                    }
            )

            Group {
                if isZoomed {
                    base
                        .highPriorityGesture(panGesture(size: proxy.size))
                        .onTapGesture(count: 2, perform: toggleZoom)
                        .onTapGesture(perform: onSingleTap)
                } else {
                    base
                        .simultaneousGesture(panGesture(size: proxy.size))
                        .onTapGesture(count: 2, perform: toggleZoom)
                        .onTapGesture(perform: onSingleTap)
                }
            }
            // Detected text sits ON TOP of the image but OUTSIDE its
            // `.scaleEffect`, so labels keep a constant point size — while
            // still reading `scale`/`offset` to stay glued to the photo.
            .overlay {
                if showOcr {
                    OcrOverlayView(
                        boxes: ocrBoxes,
                        imageRect: Self.imageRect(for: asset, in: proxy.size),
                        scale: scale,
                        offset: offset,
                        viewportSize: proxy.size
                    )
                    .transition(.opacity)
                }
            }
        }
        .clipped()
        .contentShape(Rectangle())
    }

    // MARK: - Gestures

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard isZoomed else { return }
                lastOffset = offset
                withAnimation(PVMotion.snappy) {
                    offset = clampedOffset(for: size)
                }
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(PVMotion.snappy) {
            if isZoomed {
                scale = 1
                offset = .zero
            } else {
                scale = 3
            }
        }
        lastScale = scale
        lastOffset = offset
        onZoomChange(scale)
    }

    // MARK: - Helpers

    /// Aspect-fit rect of the asset inside the viewport, in viewport points and
    /// **before** zoom — the same rect `.fit` lays the image into. It is the
    /// bridge between the normalized (0–1) OCR coordinates and screen points,
    /// and it is recomputed by the `GeometryReader` on rotation.
    static func imageRect(for asset: AssetReactItem, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let ratio = CGFloat(asset.aspectRatio)
        let fitted = CGSize(
            width: min(size.height * ratio, size.width),
            height: min(size.height, size.width / ratio)
        )
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Clamps the pan so the image never detaches from the viewport edge.
    private func clampedOffset(for size: CGSize) -> CGSize {
        let excessW = max(0, (size.width * scale - size.width) / 2)
        let excessH = max(0, (size.height * scale - size.height) / 2)
        return CGSize(
            width: Self.clamp(offset.width, min: -excessW, max: excessW),
            height: Self.clamp(offset.height, min: -excessH, max: excessH)
        )
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }
}
