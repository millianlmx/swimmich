import SwiftUI

/// Full-screen road-trip player + export surface. Plays the deterministic
/// timeline (opening → slideshow → map leg → … → ending) on one clock
/// (`RoadTripFilmClock`): the pictures through a `TimelineView`, the map legs
/// through the live map's own display link. The same timeline seeds the video
/// export.
struct RoadTripView: View {
    @Bindable var vm: RoadTripViewModel
    @Environment(\.dismiss) private var dismiss
    @PVReduceMotion private var reduceMotion

    /// When the film started playing: set when the player appears, i.e. once
    /// the preparation is over (a clock started with the view counted the
    /// preparation as film time). A reference shared with the live map, which
    /// reads it at every display refresh.
    @State private var clock = RoadTripFilmClock()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.isPreparing {
                ProgressView("Preparing road trip…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("roadTripPreparing")
            } else if let error = vm.errorMessage, vm.timeline == nil {
                VStack(spacing: 16) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(error)
                        .font(.pvSubhead)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("roadTripError")
            } else if let timeline = vm.timeline {
                // The map of the travel legs, under the pictures: it drives
                // itself from the clock (`RoadTripLiveMap`), and shows through
                // only while a leg plays — every other segment is opaque.
                RoadTripLiveMap(
                    timeline: timeline,
                    clock: clock,
                    photo: { index, first in
                        neighborPhoto(timeline: timeline, segmentIndex: index, edge: first ? .first : .last)
                    },
                    legLabel: { travel in
                        "\(vm.placeName(forClusterID: travel.fromClusterID)) → \(vm.placeName(forClusterID: travel.toClusterID))"
                    }
                )
                .ignoresSafeArea()

                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    content(timeline: timeline, elapsed: clock.elapsed(at: context.date))
                }
                .onAppear {
                    if clock.start == nil { clock.start = Date() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("roadTripPlayer")
            }

            chrome
        }
        .statusBarHidden(true)
        .task { await vm.prepare() }
        .onDisappear { vm.cancelExport() }
        .alert("Video saved", isPresented: doneAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            Text("The road trip was added to your photo library.")
        }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    // MARK: - Segment content

    /// The decoded photo the map's transitions show: the FIRST photo of the
    /// slideshow segment at `segmentIndex` (the arrival dive into it) or its
    /// LAST one (fading out over the next leg).
    private func neighborPhoto(timeline: RoadTripTimeline, segmentIndex: Int, edge: Edge) -> UIImage? {
        guard timeline.segments.indices.contains(segmentIndex),
              case .slideshow(let slideshow) = timeline.segments[segmentIndex],
              let cluster = vm.cluster(by: slideshow.clusterID),
              let position = edge == .first ? slideshow.assetIndices.first : slideshow.assetIndices.last,
              cluster.assets.indices.contains(position) else { return nil }
        return vm.slideImage(for: cluster.assets[position])
    }

    /// The decoded preview of `asset` (loaded by the preparation) and, should
    /// it be missing, the URL to load it from.
    private func photoSource(_ asset: AssetReactItem) -> RoadTripPhotoSource {
        RoadTripPhotoSource(
            image: vm.slideImage(for: asset),
            url: ImmichAssetURL.thumbnail(
                assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: vm.baseURL, size: .preview
            )
        )
    }

    private enum Edge {
        case first
        case last
    }

    @ViewBuilder
    private func content(timeline: RoadTripTimeline, elapsed: TimeInterval) -> some View {
        let clamped = min(elapsed, timeline.totalDuration)
        let segmentIndex = timeline.segmentIndex(at: clamped)
        let local = clamped - timeline.segmentStartTimes[segmentIndex]
        let segment = timeline.segments[segmentIndex]

        ZStack(alignment: .bottom) {
            switch segment {
            case .opening:
                openingView
            case .slideshow(let slideshow):
                if let cluster = vm.cluster(by: slideshow.clusterID) {
                    slideshowView(slideshow: slideshow, cluster: cluster, localTime: local)
                }
            case .travel:
                // The live map underneath shows through.
                EmptyView()
            case .ending:
                endingView
            }

            if timeline.totalDuration > 0 {
                bottomProgress(
                    segment: segment,
                    fraction: clamped / timeline.totalDuration,
                    finished: elapsed >= timeline.totalDuration
                )
            }
        }
    }

    @ViewBuilder
    private func slideshowView(slideshow: RoadTripTimeline.Slideshow, cluster: RoadTripCluster, localTime: TimeInterval) -> some View {
        let frame = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: localTime, reduceMotion: reduceMotion)
        ZStack {
            // Edge to edge: the live map lies underneath.
            Color.black.ignoresSafeArea()
            slideImage(position: frame.currentIndex, transform: frame.currentTransform, slideshow: slideshow, cluster: cluster)
            if frame.crossfade > 0, let next = frame.nextIndex {
                slideImage(position: next, transform: frame.nextTransform ?? .identity, slideshow: slideshow, cluster: cluster)
                    .opacity(frame.crossfade)
            }
        }
    }

    @ViewBuilder
    private func slideImage(position: Int, transform: KenBurnsTransform, slideshow: RoadTripTimeline.Slideshow, cluster: RoadTripCluster) -> some View {
        if slideshow.assetIndices.indices.contains(position),
           cluster.assets.indices.contains(slideshow.assetIndices[position]) {
            let asset = cluster.assets[slideshow.assetIndices[position]]
            GeometryReader { proxy in
                RoadTripPhoto(source: photoSource(asset), token: vm.token)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(transform.scale)
                    .offset(x: transform.offsetX * proxy.size.width, y: transform.offsetY * proxy.size.height)
                    .clipped()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("roadTripSlide_\(asset.id)")
        } else {
            Color.black
        }
    }

    private var openingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("Road Trip")
                    .font(.pvCaption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.7))
                Text(vm.albumTitle)
                    .font(.pvH2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(openingSubtitle)
                    .font(.pvSubhead)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(48)
        }
    }

    private var openingSubtitle: String {
        let photoCount = vm.clusters.reduce(0) { $0 + $1.assets.count }
        let placeCount = vm.clusters.count
        return String(localized: "\(photoCount) photos · \(placeCount) places")
    }

    private var endingView: some View {
        let places = RoadTripTimeline.dedupedPlaceNames(vm.clusters.indices.map { vm.placeName(forClusterIndex: $0) })
        return ZStack {
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.07, blue: 0.05), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Text("Road Trip")
                    .font(.pvCaption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(Color(red: 1, green: 0.82, blue: 0.62).opacity(0.9))
                Text(vm.albumTitle)
                    .font(.pvH3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                VStack(spacing: 10) {
                    ForEach(Array(places.enumerated()), id: \.offset) { index, place in
                        Text(place)
                            .font(.pvSubhead)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
            }
            .padding(48)
        }
    }

    private func bottomProgress(segment: RoadTripTimeline.Segment, fraction: Double, finished: Bool) -> some View {
        VStack(spacing: 12) {
            if finished {
                Button {
                    clock.start = Date()
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .font(.pvCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .pvFloating(.pill)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("roadTripReplayButton")
            } else if let label = placeLabel(segment) {
                Text(label)
                    .font(.pvCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .pvFloating(.pill)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white).frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 48)
    }

    private func placeLabel(_ segment: RoadTripTimeline.Segment) -> String? {
        switch segment {
        case .slideshow(let slideshow):
            return vm.placeName(forClusterID: slideshow.clusterID)
        case .travel(let travel):
            return "\(vm.placeName(forClusterID: travel.fromClusterID)) → \(vm.placeName(forClusterID: travel.toClusterID))"
        case .opening, .ending:
            return nil
        }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if vm.isExporting { exportOverlay }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                if vm.isExporting { vm.cancelExport() }
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .pvFloating(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("roadTripCloseButton")

            Spacer()

            Label("Road Trip", systemImage: "car.fill")
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .pvFloating(.pill)

            Spacer()

            Button {
                vm.startExport(reduceMotion: reduceMotion)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .pvFloating(.circle)
            }
            .buttonStyle(.plain)
            .disabled(vm.isExporting || vm.timeline == nil)
            .accessibilityLabel("Export video")
            .accessibilityIdentifier("roadTripExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var exportOverlay: some View {
        if case .rendering(let progress) = vm.exportState {
            VStack(spacing: 16) {
                Text("Exporting video…")
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                ProgressView(value: progress)
                    .tint(.white)
                    .frame(width: 220)
                Button("Cancel") { vm.cancelExport() }
                    .font(.pvCaption)
                    .foregroundStyle(PVFloating.secondaryContent)
            }
            .padding(24)
            .pvFloating(.bar)
            .padding(.bottom, 60)
        } else if vm.exportState == .saving {
            Label("Saving…", systemImage: "square.and.arrow.down")
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .padding(16)
                .pvFloating(.bar)
                .padding(.bottom, 60)
        }
    }

    // MARK: - Alerts

    private var doneAlertBinding: Binding<Bool> {
        Binding(get: { vm.exportState == .done }, set: { if !$0 { vm.dismissExportResult() } })
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}

/// A photo of the film: its decoded preview when the preparation loaded it,
/// otherwise the URL to load it from.
struct RoadTripPhotoSource {
    let image: UIImage?
    let url: URL
}

/// Draws a road-trip photo aspect-filled. The preloaded image is drawn on the
/// very frame it is needed — no placeholder, no fade-in — which is what keeps
/// the cuts, crossfades and arrival dives clean; the asynchronous loader is
/// only the fallback for a photo the preparation did not hold.
struct RoadTripPhoto: View {
    let source: RoadTripPhotoSource
    let token: String?

    var body: some View {
        if let image = source.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            AuthenticatedAsyncImage(url: source.url, token: token, contentMode: .fill)
        }
    }
}
