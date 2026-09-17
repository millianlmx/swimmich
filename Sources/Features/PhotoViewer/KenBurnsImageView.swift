import SwiftUI

/// Slow Ken Burns drift for slideshow stills — the image gently zooms and pans
/// over a long period (16 s ping-pong). Driven by `TimelineView`, not a `Timer`,
/// and fully disabled under Reduce Motion (static image). The phase math is a
/// pure, unit-testable struct (`KenBurnsPhase` in SlideshowViewModel.swift).
struct KenBurnsImageView: View {
    let asset: AssetReactItem
    let baseURL: URL
    let token: String?
    /// Offline copy (issue #18): a slide whose asset is cached reads the file
    /// instead of the network, so a slideshow still works with no server.
    var localFileURL: URL? = nil
    var onSingleTap: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `SwiftUI.` qualification: the app ships its own `TimelineView` (photo
        // timeline feature), which shadows SwiftUI's continuous-update container.
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = KenBurnsPhase.progress(
                elapsed: context.date.timeIntervalSinceReferenceDate,
                reduceMotion: reduceMotion
            )
            image
                .scaleEffect(phase.scale)
                .offset(phase.offset)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onSingleTap)
    }

    private var image: some View {
        GeometryReader { proxy in
            AuthenticatedAsyncImage(
                url: asset.thumbnailURL(base: baseURL, size: .preview),
                token: token,
                contentMode: .fit,
                localFileURL: localFileURL,
                localMaxPixelSize: 4096,
                thumbnailURL: asset.thumbnailURL(base: baseURL, size: .thumbnail)
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
