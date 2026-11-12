import SwiftUI
import MapKit
import UIKit

/// Map segment for the Search tab — MKMapView with real marker clustering
/// (MKMarkerAnnotationView.clusteringIdentifier) feeding a native photo sheet
/// (presented by RootView) with the assets inside the currently visible region.
///
/// The map renders immediately (world view); a spinner ("Chargement des
/// photos…") overlays it while markers load and while MapKit ingests them,
/// then the fit zooms to the photos.
///
/// Clustering handled by MapKit because SwiftUI's `Map` (iOS 17) has no
/// native clustering; large libraries can reach thousands of markers.
///
/// Performance: the wrapper only ever displays the *culled* subset
/// (`vm.visibleAnnotations`, grid-subsampled at world zoom), so MapKit never
/// receives the full library.
struct MapSegmentView: View {
    @Bindable var vm: MapViewModel
    /// Local loading flag — guaranteed re-render (unlike observing the VM's
    /// `isLoading`, which can miss the first pass), so the spinner always
    /// shows while markers load or refresh.
    @State private var isLoadingPhotos = false
    /// True from the moment markers arrive until MapKit has rendered the
    /// first wave of annotations — the spinner covers the annotation-render
    /// cost (thousands of markers), not just the network fetch.
    @State private var isRenderingMarkers = false
    /// Map settings sheet (gap G14b).
    @State private var presentSettings = false
    /// The photo sheet is presented by `RootView` on the same host controller,
    /// so it has to come down before the settings sheet can go up; this
    /// remembers to put it back when settings closes.
    @State private var restorePhotoSheet = false

    var body: some View {
        Group {
            if let msg = vm.errorMessage, vm.markers.isEmpty {
                errorView(msg)
            } else {
                mapContent
            }
        }
        .task {
            // AC-710: load markers once per VM lifetime.
            isLoadingPhotos = true
            await vm.loadMarkers()
            isLoadingPhotos = false
        }
        .onAppear {
            // Re-present the photo sheet when the map segment is re-entered
            // (the onChange below only fires when `isEmpty` *changes*, so
            // returning with photos already loaded would leave it closed).
            if !vm.visiblePhotos.isEmpty, !vm.isPhotoSheetPresented {
                vm.isPhotoSheetPresented = true
            }
        }
        .onChange(of: vm.markers.isEmpty) { _, isEmpty in
            // Markers just arrived (cache or network) — the annotation
            // render is about to start; ClusteredMapView signals the
            // first wave via onInitialRenderCompleted. Deferred so no
            // state is mutated during the view update.
            if !isEmpty {
                DispatchQueue.main.async { isRenderingMarkers = true }
            }
        }
        .onChange(of: vm.visiblePhotos.isEmpty) { _, isEmpty in
            // Present the native photo sheet once the region has photos.
            // Deferred one runloop so a tab switch in flight settles first;
            // RootView (stable presenter) gates the presentation.
            guard !isEmpty, !vm.isPhotoSheetPresented else { return }
            DispatchQueue.main.async {
                if !vm.visiblePhotos.isEmpty, !vm.isPhotoSheetPresented {
                    vm.isPhotoSheetPresented = true
                }
            }
        }
        // Map settings (gap G14b). A sheet, not a push — no NavigationStack.
        .sheet(isPresented: $presentSettings) {
            MapSettingsSheet(
                store: vm.settings,
                onApply: { filter in Task { await vm.applyFilter(filter) } },
                onClose: { presentSettings = false }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .onDisappear {
                // Settings and the photo sheet share one host controller, so
                // only one can be up at a time; restore what `openSettings`
                // took down.
                guard restorePhotoSheet else { return }
                restorePhotoSheet = false
                guard !vm.visiblePhotos.isEmpty else { return }
                DispatchQueue.main.async { vm.isPhotoSheetPresented = true }
            }
        }
    }

    /// Opens the settings sheet. The photo sheet is presented by `RootView` on
    /// the same host controller: presenting over it would be refused, so it is
    /// taken down first (and restored when settings closes).
    private func openSettings() {
        restorePhotoSheet = vm.isPhotoSheetPresented
        vm.isPhotoSheetPresented = false
        presentSettings = true
    }

    private var mapContent: some View {
        ZStack(alignment: .top) {
            ClusteredMapView(
                markers: vm.markers,
                annotations: vm.visibleAnnotations,
                onVisibleRectChanged: { rect in
                    // MKMapView delegate callbacks are non-isolated; hop to
                    // the MainActor ViewModel.
                    Task { @MainActor in vm.setVisibleRect(rect) }
                },
                onInitialRenderCompleted: {
                    // May fire during a view update (delegate callback);
                    // defer so no state is mutated mid-render.
                    DispatchQueue.main.async { isRenderingMarkers = false }
                },
                onMarkerSelected: { id in
                    Task { @MainActor in vm.selectMarker(id) }
                },
                onMarkerZoomRequested: { id in
                    // MKMapView delegate callbacks run on the main thread, which
                    // is the MainActor — read the VM's cell rect synchronously.
                    MainActor.assumeIsolated { vm.zoomRect(forMarker: id) }
                },
                onMarkerDeselected: {
                    Task { @MainActor in vm.deselectMarker() }
                },
                interfaceStyle: vm.settings.theme.interfaceStyle
            )
            .ignoresSafeArea()

            // Spinner while markers are genuinely missing or being rendered:
            // `vm.isLoading` stays true for the whole fetch even if this
            // `.task` gets relaunched (a relaunched task finds `loadMarkers`
            // busy and returns immediately, so the local flag alone can lie).
            // `isRenderingMarkers` covers the MapKit annotation-render cost
            // after markers arrive (thousands of markers).
            if ((isLoadingPhotos || vm.isLoading) && vm.markers.isEmpty) || isRenderingMarkers {
                HStack(spacing: PVSpacing.s8) {
                    ProgressView()
                        .tint(PVFloating.content)
                    Text("Loading photos…")
                        .font(.pvSubhead)
                        .foregroundStyle(PVFloating.secondaryContent)
                }
                .padding(.horizontal, PVSpacing.s16)
                .padding(.vertical, PVSpacing.s8)
                .pvFloating(.pill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // Filter + settings: floating glass controls, the only surface that
            // is legitimately above a full-screen map (same family as the
            // spinner capsule).
            PVAdaptiveStack(hAlignment: .center, vAlignment: .trailing, spacing: PVSpacing.s8) {
                if !vm.filter.isEmpty { activeFilterBadge }
                settingsButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, PVSpacing.s16)
            .padding(.top, PVSpacing.s8)
            // Only the badge appears/disappears with the filter — the marker
            // set itself is never animated (thousands of annotations animating
            // makes the map jump).
            .animation(PVMotion.snappy, value: vm.filter.isEmpty)

            // A filter that matches nothing is a state, not a blank map: say
            // which filter emptied it and offer the way out.
            if !vm.filter.isEmpty, vm.markers.isEmpty, !isLoadingPhotos, !vm.isLoading {
                filteredEmptyOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// Badge of the active filter — the only alert that the map is filtered,
    /// and a second way into the sheet (the way back out of a filter).
    private var activeFilterBadge: some View {
        Button { openSettings() } label: {
            Label(vm.activeFilterSummary, systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.pvCaption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PVSpacing.s12)
                .padding(.vertical, PVSpacing.s8)
        }
        .buttonStyle(.plain)
        .pvFloating(.pill)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mapFilterActiveBadge")
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private var settingsButton: some View {
        Button { openSettings() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.pvBody.weight(.semibold))
                .padding(PVSpacing.s12)
        }
        .buttonStyle(.plain)
        .pvFloating(.circle)
        .accessibilityLabel("Map settings")
        .accessibilityIdentifier("mapSettingsButton")
    }

    /// Explicit empty state for a filter that returned nothing (an inverted or
    /// over-narrow range): the map alone would read as "my photos are gone".
    private var filteredEmptyOverlay: some View {
        VStack(spacing: PVSpacing.s8) {
            Text("No photos match this filter")
                .font(.pvSubhead)
                .multilineTextAlignment(.center)
            Button("Clear filter") {
                Task { await vm.applyFilter(.all) }
            }
            .buttonStyle(PVSubtleButtonStyle())
        }
        .padding(PVSpacing.s16)
        .pvFloating(.bar)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: PVSpacing.s12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.pvTitle)
                .foregroundStyle(Color.immichWarning)
            Text(msg)
                .font(.pvBody)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await vm.reload() }
            }
            .buttonStyle(PVPrimaryButtonStyle())
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Native bottom sheet showing the photos of the current map region (or of a
/// tapped marker's cell) as a vertically scrollable 3-column grid — presented
/// by RootView above the map tab (detents, swipe-down and system corner
/// radius come for free). Photos render in a growing window (15 then +30 per
/// scroll); thumbnails fetch lazily on appearance.
struct MapPhotosSheet: View {
    let vm: MapViewModel
    @Environment(AuthViewModel.self) private var auth
    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer
    @State private var photoLimit = 15
    /// Cached `asAssetItem` mapping of `displayedPhotos` so `openViewer`
    /// doesn't re-map the whole region on every tap (audit P5). Invalidated
    /// alongside `photoLimit` when `displayedPhotos` changes.
    @State private var cachedAssets: [AssetReactItem]?
    @State private var cachedAssetsKey: [MapPhoto]?
    private static let photoLimitStep = 30

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: PVSpacing.s12) {
                PVAdaptiveStack(hAlignment: .center, spacing: PVSpacing.s8) {
                    HStack(spacing: PVSpacing.s8) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(Color.immichPrimary)
                        Text(placeName)
                            .font(.pvHeadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("mapPhotosPlaceName")
                    }
                    Spacer()
                    HStack(spacing: PVSpacing.s8) {
                        Text("\(displayedPhotos.count) photos")
                            .font(.pvSubhead)
                            .foregroundStyle(Color.textSecondaryPV)
                        if vm.selectedMarkerID != nil {
                            Button {
                                vm.deselectMarker()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.pvSubhead)
                                    .foregroundStyle(Color.textSecondaryPV)
                            }
                            .accessibilityLabel("Clear marker filter")
                        }
                    }
                }
                .padding(.horizontal)

                // "12 photos" next to a filtered map is a lie by omission: the
                // summary says what the count was computed on (no extra
                // request — it is the same filter the map queried with).
                if !vm.filter.isEmpty {
                    PVStatusBadge(
                        text: vm.activeFilterSummary,
                        color: .immichPrimary,
                        symbol: "line.3.horizontal.decrease.circle.fill"
                    )
                    .accessibilityIdentifier("mapFilterSummary")
                    .padding(.horizontal)
                }

                // One ScrollView through the empty and grid states, so the pull
                // to refresh survives a region change that empties the sheet.
                ScrollView(.vertical, showsIndicators: false) {
                    if let message = vm.refreshErrorMessage {
                        InlineErrorBadge(message: message, retry: { Task { await vm.refreshMarkers() } })
                            .padding(.horizontal)
                            .accessibilityIdentifier("mapPhotosRefreshError")
                    }
                    if displayedPhotos.isEmpty {
                        ContentUnavailableView(
                            "No photos in this area",
                            systemImage: "map",
                            description: Text("Pan the map to find photos here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, PVSpacing.s24)
                        .accessibilityIdentifier("mapPhotosEmptyState")
                    } else {
                        LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                            ForEach(shownPhotos) { photo in
                                MapThumb(photo: photo)
                                    .onTapGesture { openViewer(for: photo.asAssetItem) }
                                    .accessibilityLabel(photo.placeName.isEmpty ? "Photo" : "Photo at \(photo.placeName)")
                                    .onAppear {
                                        // Grow the window as the last shown
                                        // photo appears — thumbnails fetch
                                        // lazily on appearance.
                                        if photo.id == shownPhotos.last?.id, photoLimit < displayedPhotos.count {
                                            photoLimit += Self.photoLimitStep
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, PVSpacing.s12)
                    }
                }
                .refreshable { await vm.refreshMarkers() }
            }
            .padding(.top, PVSpacing.s12)
            .onChange(of: displayedPhotos) { _, _ in
                // New region or new marker selection: restart the window and
                // drop the viewer-assets cache (audit P5).
                photoLimit = 15
                cachedAssets = nil
                cachedAssetsKey = nil
            }
            // Full-screen photo viewer (tap any map photo → browse/zoom).
            // Favorite/delete run self-sufficient; refresh markers (silently,
            // cache preserved) so the map reflects the mutation.
            .photoViewer(
                item: $viewerItem,
                baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                token: auth.accessToken,
                onDataChanged: {
                    Task { await vm.refreshMarkers() }
                }
            )
        }
    }

    /// The photos backing the sheet: a tapped marker's cell, or the region.
    private var displayedPhotos: [MapPhoto] {
        vm.selectedMarkerID == nil ? vm.visiblePhotos : vm.selectedMarkerPhotos
    }

    /// The currently rendered slice of the displayed photos.
    private var shownPhotos: [MapPhoto] {
        Array(displayedPhotos.prefix(photoLimit))
    }

    /// Opens the Photos-style viewer at `item`, paging through the displayed
    /// photos (same order as the sheet grid). The `asAssetItem` mapping is
    /// cached per `displayedPhotos` change so repeated taps don't re-map the
    /// whole region (audit P5).
    private func openViewer(for item: AssetReactItem) {
        let photos = displayedPhotos
        let items: [AssetReactItem]
        if let cachedAssetsKey, cachedAssetsKey == photos, let cachedAssets {
            items = cachedAssets
        } else {
            items = photos.map(\.asAssetItem)
            cachedAssetsKey = photos
            cachedAssets = items
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: items, index: idx)
    }

    /// First non-empty place name among the displayed photos, else a generic
    /// label (marker selection prefers the marker's own place name).
    private var placeName: String {
        if vm.selectedMarkerID != nil, let name = vm.selectedMarkerPhotos.lazy.compactMap(\.placeName).first(where: { !$0.isEmpty }) {
            return name
        }
        return vm.visiblePhotos.lazy.compactMap(\.placeName).first { !$0.isEmpty } ?? "This area"
    }
}

/// Square thumbnail for a map photo, filling its grid column width.
/// Authenticated via bearer token like the timeline grid cells.
private struct MapThumb: View {
    let photo: MapPhoto
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AuthenticatedAsyncImage(
                    url: photo.asAssetItem.thumbnailURL(base: auth.baseURL ?? URL(string: "https://example.com")!),
                    token: auth.accessToken
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }
}

/// `MKAnnotation` carrier wrapping a `MapAnnotationMarker` (non-Sendable,
/// UIKit-owned). `representedCount` lets cluster/marker badges show the real
/// photo count of the grid cell each annotation stands for.
private final class PhotoAnnotation: NSObject, MKAnnotation {
    let marker: MapAnnotationMarker
    init(marker: MapAnnotationMarker) {
        self.marker = marker
        super.init()
    }
    var coordinate: CLLocationCoordinate2D { marker.photo.coordinate }
    var title: String? { marker.photo.placeName.isEmpty ? nil : marker.photo.placeName }
}

/// UIViewRepresentable MKMapView with MKMarkerAnnotationView clustering.
///
/// Displays only the culled `annotations` (diffed against the live MKMapView
/// annotation set), fits to all markers once on first load, and reports the
/// visible region to SwiftUI via `onVisibleRectChanged` (the ViewModel
/// debounces + filters).
struct ClusteredMapView: UIViewRepresentable {
    /// Full marker set — used once to compute the initial fit.
    let markers: [MapPhoto]
    /// Culled subset to display (region + margin), produced by the ViewModel.
    let annotations: [MapAnnotationMarker]
    let onVisibleRectChanged: (MKMapRect) -> Void
    /// Fired once MapKit has rendered the first wave of annotation views
    /// (or nothing needed adding) — lets the host drop its loading spinner.
    let onInitialRenderCompleted: () -> Void
    /// A marker was tapped — the host filters the photo sheet to its photos.
    let onMarkerSelected: (String) -> Void
    /// A high-count grid marker was tapped — the host returns the bounding
    /// rect of its cell photos so we can drill in (zoom) to reveal the spread.
    let onMarkerZoomRequested: (String) -> MKMapRect?
    /// The selected marker was deselected (tap elsewhere) — sheet goes back
    /// to the region's photos.
    let onMarkerDeselected: () -> Void
    /// Forced appearance of the map. `nil` follows the system; this is the
    /// only lever that actually repaints MapKit's tiles (a color filter over
    /// the view would leave the tiles' own rendering untouched).
    let interfaceStyle: UIUserInterfaceStyle?

    private static let photoReuseID = "photoMarker"
    private static let clusterReuseID = "photoCluster"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsUserLocation = false
        map.overrideUserInterfaceStyle = interfaceStyle ?? .unspecified
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.photoReuseID)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.clusterReuseID)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Live theme switch while the sheet is open: MapKit repaints on the
        // style change (tiles included).
        let style = interfaceStyle ?? .unspecified
        if map.overrideUserInterfaceStyle != style {
            map.overrideUserInterfaceStyle = style
        }

        // Fit to all markers once (first load). Then force a region callback
        // so culling kicks in even if the programmatic fit doesn't fire the
        // delegate's visible-region change.
        if !coordinator.didFitInitial, !markers.isEmpty {
            let rect = markers.reduce(MKMapRect.null) { partial, photo in
                let pt = MKMapPoint(photo.coordinate)
                return partial.union(MKMapRect(x: pt.x - 1, y: pt.y - 1, width: 2, height: 2))
            }
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 60),
                animated: false
            )
            coordinator.didFitInitial = true
            context.coordinator.parent.onVisibleRectChanged(map.visibleMapRect)
        }

        // Diff the live annotation set against the desired (culled) set — keyed
        // on BOTH id and representedCount. A pure id diff (the old bug) missed
        // count changes: when a zoom re-buckets the grid, a cell often keeps
        // the same representative photo id but its photo count changes, so the
        // stale `PhotoAnnotation` (whose `representedCount` is immutable) stayed
        // on the map and its badge lied. Keying on the count forces a refresh
        // of exactly those annotations, so badges always sum to the sheet total.
        let currentAnnotations = map.annotations.compactMap { $0 as? PhotoAnnotation }
        var desiredCount: [String: Int] = [:]
        desiredCount.reserveCapacity(annotations.count)
        for marker in annotations { desiredCount[marker.id] = marker.representedCount }

        // An annotation stays only if its id is still desired AND its count is
        // unchanged; everything else is removed (missing id or stale count).
        let toRemove = currentAnnotations.filter { annotation in
            desiredCount[annotation.marker.photo.id] != annotation.marker.representedCount
        }
        let liveMatch = Set(
            currentAnnotations
                .filter { desiredCount[$0.marker.photo.id] == $0.marker.representedCount }
                .map(\.marker.photo.id)
        )
        // Add every desired marker that isn't already live with the right count.
        let toAdd = annotations.filter { !liveMatch.contains($0.id) }

        guard !toRemove.isEmpty || !toAdd.isEmpty else {
            // Nothing changed — the desired set is already on the map, so an
            // in-flight render is complete from the host's point of view.
            if !annotations.isEmpty, !coordinator.didSignalInitialRender {
                coordinator.didSignalInitialRender = true
                coordinator.parent.onInitialRenderCompleted()
            }
            return
        }

        if !toRemove.isEmpty {
            map.removeAnnotations(toRemove)
        }
        if toAdd.isEmpty {
            if !annotations.isEmpty, !coordinator.didSignalInitialRender {
                coordinator.didSignalInitialRender = true
                coordinator.parent.onInitialRenderCompleted()
            }
            return
        }

        map.addAnnotations(toAdd.map(PhotoAnnotation.init(marker:)))
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ClusteredMapView
        var didFitInitial = false
        /// One-shot: true after the first render signal is delivered.
        var didSignalInitialRender = false

        init(_ parent: ClusteredMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: ClusteredMapView.clusterReuseID,
                    for: cluster
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: ClusteredMapView.clusterReuseID)
                view.annotation = cluster
                view.clusteringIdentifier = ClusteredMapView.photoReuseID
                view.markerTintColor = .systemIndigo
                // Sum the represented counts so the badge shows the real
                // number of photos, matching the photo sheet's total.
                let total = cluster.memberAnnotations.reduce(0) { sum, member in
                    guard let photoAnno = member as? PhotoAnnotation else { return sum }
                    return sum + photoAnno.marker.representedCount
                }
                view.glyphText = "\(total)"
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            if let photoAnno = annotation as? PhotoAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: ClusteredMapView.photoReuseID,
                    for: photoAnno
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: photoAnno, reuseIdentifier: ClusteredMapView.photoReuseID)
                view.annotation = photoAnno
                view.clusteringIdentifier = ClusteredMapView.photoReuseID
                view.markerTintColor = .systemIndigo
                // A single photo keeps the icon; a cell holding several photos
                // shows its count (a mini-cluster).
                if photoAnno.marker.representedCount > 1 {
                    view.glyphText = "\(photoAnno.marker.representedCount)"
                    view.glyphImage = nil
                } else {
                    view.glyphText = nil
                    view.glyphImage = UIImage(systemName: "photo")
                }
                view.canShowCallout = true
                return view
            }
            return nil
        }

        /// Documented signal that MapKit added annotation views — the initial
        /// render is underway; the host drops its spinner.
        func mapView(_ mapView: MKMapView, didAdd annotationViews: [MKAnnotationView]) {
            guard !annotationViews.isEmpty, !didSignalInitialRender else { return }
            didSignalInitialRender = true
            parent.onInitialRenderCompleted()
        }

        /// Tapping a marker filters the photo sheet to its cell's photos;
        /// tapping a cluster zooms into its members (Maps-style).
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let rect = cluster.memberAnnotations.reduce(MKMapRect.null) { partial, annotation in
                    let pt = MKMapPoint(annotation.coordinate)
                    return partial.union(MKMapRect(x: pt.x - 1, y: pt.y - 1, width: 2, height: 2))
                }
                if !rect.isNull {
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
                        animated: true
                    )
                }
                return
            }
            if let photoAnno = view.annotation as? PhotoAnnotation {
                // A single-photo pin selects (filters the sheet). A high-count
                // grid marker is a mini-cluster MapKit never merged (isolated
                // area) — drill in instead so tapping "the big Madeira badge"
                // zooms to reveal the photos, matching native Maps.
                if photoAnno.marker.representedCount > 1,
                   let rect = parent.onMarkerZoomRequested(photoAnno.marker.photo.id),
                   !rect.isNull {
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
                        animated: true
                    )
                    // Don't leave the mini-cluster stuck in a selected state.
                    mapView.deselectAnnotation(view.annotation, animated: false)
                } else {
                    parent.onMarkerSelected(photoAnno.marker.photo.id)
                }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is PhotoAnnotation {
                parent.onMarkerDeselected()
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            parent.onVisibleRectChanged(mapView.visibleMapRect)
        }
    }
}

extension MapTheme {
    /// MapKit appearance. `nil` means "follow the system"
    /// (`overrideUserInterfaceStyle = .unspecified`).
    var interfaceStyle: UIUserInterfaceStyle? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
