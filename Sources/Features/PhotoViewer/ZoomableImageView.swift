import SwiftUI
import UIKit

/// Photos-grade zoomable image page for the full-screen photo viewer.
///
/// Gesture surface:
/// - **Pinch** (`MagnifyGesture`) zooms from 1x up to a ceiling that follows the
///   photo's resolution (`ZoomGeometry.maxScale`): the scale where one photo
///   pixel covers one screen pixel, never below 2x for a small image. A photo of
///   unknown size, or an edited one (its EXIF describes the original, not the
///   version a shared link serves), keeps 4x. Anchored at center.
/// - **Double-tap** toggles 1x ↔ min(3x, ceiling) (Photos default zoom).
/// - **Pan** moves the image while zoomed, bounded by the *fitted image* (the
///   rectangle of the decoded picture, not the whole screen), so no edge ever
///   detaches from the viewport; an axis where the zoomed image is smaller than
///   the viewport stays centered. At 1x it is a no-op so the pager (TabView)
///   owns horizontal drags.
/// - **Single tap** toggles the viewer chrome (parent callback).
///
/// The pan gesture is attached with `.highPriorityGesture` only while zoomed
/// so it wins over the pager; at 1x it degrades to `.simultaneousGesture` (a
/// guarded no-op) so paging stays responsive. Reset-on-page-change is handled
/// by the pager giving each page a stable `.id(asset.id)` — SwiftUI recreates
/// the view (and its `@State`) when the asset changes.
///
/// The pixel size can arrive after the image (a grid item carries none, the page
/// reads the record once): when the ceiling or the fitted rect then changes, the
/// scale and offset are settled under the new values. While the image is
/// displayed the ceiling follows the original's EXIF; when L-21 shows the edited
/// version here, `AssetPixelSizeViewModel` must apply the `isEdited` rule too.
struct ZoomableImageView: View {
    @PVReduceMotion private var reduceMotion
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
    /// Reads the photo's pixel size when the item carries none. Nil (the shared
    /// link visitor) leaves the size to the item.
    var client: (any ImmichClient)? = nil
    /// Provisional image under the real one (the viewer's flying image): the
    /// page shows it from its first frame, so the hand-over from the flight to
    /// the page has neither a shimmer nor a half-transparent image.
    var placeholder: UIImage? = nil
    /// Reports the frame the image is drawn in (`.global`, zoom and pan
    /// included) each time it changes. The viewer closes onto it.
    var onDisplayedFrameChange: ((CGRect) -> Void)? = nil

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var isPinching = false
    @State private var dimensions: AssetPixelSizeViewModel?
    @State private var decodedSize: CGSize?
    @State private var pageFrame: CGRect = .zero

    /// Image-quality preference (gap G22): original file or the server's
    /// `.fullsize` rendition. Read at render time, so a page already on screen
    /// follows a change made in Preferences.
    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(\.displayScale) private var displayScale

    private var isZoomed: Bool { scale > ZoomGeometry.zoomedThreshold }

    /// The one line that decides which variant this page fetches. The offline
    /// copy (`localFileURL`) and the image cache cover both URLs unchanged —
    /// the cache key is the URL itself.
    private var imageURL: URL {
        Self.pageURL(asset: asset, baseURL: baseURL, loadOriginal: appSettings.loadOriginal, sharedLink: sharedLink)
    }

    /// The URL a page displays — also what the viewer looks up in the image
    /// cache for the flying image of a close.
    static func pageURL(
        asset: AssetReactItem,
        baseURL: URL,
        loadOriginal: Bool,
        sharedLink: SharedLinkCredential? = nil
    ) -> URL {
        loadOriginal
            ? ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL, sharedLink: sharedLink)
            : asset.thumbnailURL(base: baseURL, size: .preview, sharedLink: sharedLink)
    }

    var body: some View {
        GeometryReader { proxy in
            let pixelSize = dimensions?.pixelSize ?? asset.pixelSize
            let fitted = ZoomGeometry.fittedRect(
                aspect: ZoomGeometry.displayAspect(
                    decoded: decodedSize,
                    pixelSize: pixelSize,
                    fallback: CGFloat(asset.aspectRatio)
                ),
                in: proxy.size
            )
            let maxScale = ZoomGeometry.maxScale(
                pixelSize: pixelSize,
                viewport: proxy.size,
                displayScale: displayScale
            )
            // Explicit full frame: GeometryReader aligns its child top-leading,
            // so a content-sized `.fit` image would sit at the top, not centered.
            // The frame fills the page and centers the fitted image in both axes.
            let base = AuthenticatedAsyncImage(
                url: imageURL,
                token: token,
                contentMode: .fit,
                localFileURL: localFileURL,
                // Full screen: decode cap for the offline copy. The zoom ceiling
                // may exceed what these pixels support; it follows the original.
                localMaxPixelSize: 4096,
                thumbnailURL: asset.thumbnailURL(base: baseURL, size: .thumbnail, sharedLink: sharedLink),
                // Read by the test probe only (`-uiTestImageProbe`): POSIX locale
                // so the value never depends on the device's decimal separator.
                probeExtra: String(
                    format: "zoom=%.2f max=%.2f off=%.1f,%.1f fit=%.1fx%.1f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    scale, maxScale, offset.width, offset.height, fitted.width, fitted.height
                ),
                onImageSize: { decodedSize = $0 },
                placeholder: placeholder
            )
            .accessibilityIdentifier("viewerImage_\(asset.id)")
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        isPinching = true
                        scale = Self.clamp(lastScale * value.magnification, min: ZoomGeometry.minScale, max: maxScale)
                        onZoomChange(scale)
                    }
                    .onEnded { _ in
                        isPinching = false
                        lastScale = scale
                        if scale < ZoomGeometry.snapBackThreshold {
                            // Photos never rests between 1x and the zoom threshold.
                            withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
                                scale = 1
                                offset = .zero
                            }
                            lastScale = 1
                            lastOffset = .zero
                        } else {
                            // Zooming out shrinks the image under the pan: re-bound it.
                            withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
                                offset = ZoomGeometry.clampedOffset(
                                    offset, scale: scale, fitted: fitted.size, viewport: proxy.size
                                )
                            }
                            lastOffset = offset
                        }
                        onZoomChange(scale)
                    }
            )

            Group {
                if isZoomed {
                    base
                        .highPriorityGesture(panGesture(fitted: fitted.size, viewport: proxy.size))
                        .onTapGesture(count: 2) { toggleZoom(maxScale: maxScale) }
                        .onTapGesture(perform: onSingleTap)
                } else {
                    base
                        .simultaneousGesture(panGesture(fitted: fitted.size, viewport: proxy.size))
                        .onTapGesture(count: 2) { toggleZoom(maxScale: maxScale) }
                        .onTapGesture(perform: onSingleTap)
                }
            }
            .onChange(of: maxScale) {
                settle(maxScale: maxScale, fitted: fitted.size, viewport: proxy.size)
            }
            .onChange(of: fitted.size) {
                settle(maxScale: maxScale, fitted: fitted.size, viewport: proxy.size)
            }
            .onChange(
                of: ViewerZoomPlan.displayedRect(fitted: fitted, scale: scale, offset: offset, in: pageFrame),
                initial: true
            ) { _, displayed in
                // Not before the page has been measured: a frame around the
                // origin would be taken for the real one.
                guard pageFrame.width > 0, let onDisplayedFrameChange else { return }
                onDisplayedFrameChange(displayed)
            }
            // Detected text sits ON TOP of the image but OUTSIDE its
            // `.scaleEffect`, so labels keep a constant point size — while
            // still reading `scale`/`offset` to stay glued to the photo.
            .overlay {
                if showOcr {
                    OcrOverlayView(
                        boxes: ocrBoxes,
                        imageRect: fitted,
                        scale: scale,
                        offset: offset,
                        viewportSize: proxy.size
                    )
                    .transition(.opacity)
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pageFrame = $0 }
        .clipped()
        .contentShape(Rectangle())
        // The image shows at once; the size only tightens or lifts the ceiling.
        .task(id: asset.id) {
            let model = dimensions ?? AssetPixelSizeViewModel(asset: asset, client: client)
            dimensions = model
            await model.load()
        }
    }

    // MARK: - Gestures

    private func panGesture(fitted: CGSize, viewport: CGSize) -> some Gesture {
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
                withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
                    offset = ZoomGeometry.clampedOffset(offset, scale: scale, fitted: fitted, viewport: viewport)
                }
                lastOffset = offset
            }
    }

    private func toggleZoom(maxScale: CGFloat) {
        withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
            if isZoomed {
                scale = 1
            } else {
                scale = ZoomGeometry.doubleTapTarget(maxScale: maxScale)
            }
            offset = .zero
        }
        lastScale = scale
        lastOffset = offset
        onZoomChange(scale)
    }

    /// Brings scale and offset back under a ceiling or image rectangle that
    /// changed after the page was shown (size read late, image decoded, rotation).
    /// A pinch in flight is left alone: its next change already clamps to the new
    /// ceiling and its end fixes `lastScale`. A higher ceiling changes nothing;
    /// the next pinch reaches it.
    private func settle(maxScale: CGFloat, fitted: CGSize, viewport: CGSize) {
        guard !isPinching else { return }
        let next = ZoomGeometry.settled(
            scale: scale, offset: offset, maxScale: maxScale, fitted: fitted, viewport: viewport
        )
        guard next.scale != scale || next.offset != offset else { return }
        withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
            scale = next.scale
            offset = next.offset
        }
        lastScale = next.scale
        lastOffset = next.offset
        onZoomChange(next.scale)
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }
}
