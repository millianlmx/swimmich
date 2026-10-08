import SwiftUI
import MapKit

/// EXIF info bottom sheet (Photos-style, native Liquid Glass). Presented as a
/// `.sheet` by PhotoViewer. Owns its sub-sheets (adjust location/date, faces,
/// tags, stack) so they present over this sheet.
struct PhotoInfoPanel: View {
    let asset: AssetReactItem
    let client: any ImmichClient
    let vm: AssetDetailViewModel?
    /// Base server URL + token for face/person thumbnails (gap #5).
    let baseURL: URL
    let token: String?
    var onClose: () -> Void = {}
    /// Open the photo's place on a full-screen, interactive map (the mini-map
    /// in the info card is a snapshot).
    var onOpenLocationMap: ((Double, Double, String?) -> Void)? = nil
    /// Open in Apple Maps at the photo's coordinates (map-extras).
    var onOpenInMaps: ((Double, Double) -> Void)? = nil

    /// The asset troubleshoot page (gap G24). Built by the composition root's
    /// factory unless a host lends its own instance: the page is parameterized
    /// by the asset and reloads through `AssetTroubleshootView`'s `task(id:)`,
    /// so a presentation owns exactly the state it shows.
    var troubleshoot: AssetTroubleshootViewModel = DependencyContainer.shared.makeAssetTroubleshootViewModel()

    @State private var presentAdjustLocation = false
    @State private var presentAdjustDate = false
    @State private var selectedFace: AssetFaceResponseDto?
    @State private var presentTags = false
    @State private var presentStack = false
    @State private var presentTroubleshoot = false

    var body: some View {
        VStack(spacing: PVSpacing.s0) {
            header
                .padding(.horizontal, PVSpacing.s16)
                .padding(.vertical, PVSpacing.s8)
            content
        }
        .sheet(isPresented: $presentAdjustLocation) {
            if let vm {
                AdjustLocationSheet(asset: asset, vm: vm) { _ in
                    presentAdjustLocation = false
                }
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $presentAdjustDate) {
            if let vm {
                AdjustDateSheet(asset: asset, vm: vm) { _ in
                    presentAdjustDate = false
                }
                .presentationDetents([.fraction(0.6)])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $selectedFace) { face in
            if let vm {
                FaceAssignSheet(face: face, asset: asset, vm: vm, baseURL: baseURL, token: token) {}
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $presentTags) {
            AssetTagsSheet(asset: asset, client: client) {
                Task { await vm?.loadDetail() }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $presentStack) {
            StackSheet(asset: asset, client: client, baseURL: baseURL, token: token) {
                Task { await vm?.loadDetail() }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // The panel is a sheet itself and inherits no navigation container, so
        // the troubleshoot page brings its own — local to this sheet, the same
        // shape as the two above.
        .sheet(isPresented: $presentTroubleshoot) {
            NavigationStack {
                AssetTroubleshootView(vm: troubleshoot, assetID: asset.id)
            }
        }
    }

    private var header: some View {
        HStack(spacing: PVSpacing.s16) {
            VStack(alignment: .leading, spacing: 2) {
                if let exif = vm?.detail?.exifInfo, let place = placeLabel(exif: exif) {
                    Text(place)
                        .font(.pvH6)
                        .foregroundStyle(Color.textPrimaryPV)
                        .lineLimit(1)
                }
                Text(headerDate)
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textPrimaryPV)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(.black.opacity(0.6)), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
            .accessibilityIdentifier("viewerInfoClose")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let detail = vm?.detail, let exif = detail.exifInfo {
            ScrollView {
                ratingCard
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.top, PVSpacing.s8)
                facesCard(faces: vm?.faces ?? [])
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.top, PVSpacing.s8)
                tagsCard(tags: detail.tags)
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.top, PVSpacing.s8)
                stackCard(stack: detail.stack)
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.top, PVSpacing.s8)
                troubleshootCard
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.top, PVSpacing.s8)
                ExifInfoPanel(
                    exif: exif,
                    placeName: placeLabel(exif: exif),
                    fallbackLatitude: asset.latitude,
                    fallbackLongitude: asset.longitude,
                    onOpenInMaps: onOpenInMaps,
                    onOpenLocationMap: onOpenLocationMap,
                    onAdjustLocation: { presentAdjustLocation = true },
                    onAdjustDate: { presentAdjustDate = true }
                )
                .padding(.horizontal, PVSpacing.s16)
                .padding(.bottom, PVSpacing.s24)
            }
        } else if let error = vm?.errorMessage {
            Text(error)
                .font(.pvCaption)
                .foregroundStyle(Color.immichError)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Rating card (star-ratings): the panel's first card, because five 44 pt
    /// targets take 220 pt of width and must clear the sheet's short detent.
    /// The rating is rendered here and nowhere else — hence the removal of the
    /// EXIF "star.fill" row, which showed a bare number (and nothing at all
    /// when unrated). Hidden without a ViewModel, like the other action cards.
    @ViewBuilder
    private var ratingCard: some View {
        if let vm {
            InfoCard {
                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    Label("Rating", systemImage: "star.fill")
                        .font(.pvCaption.weight(.semibold))
                        .foregroundStyle(Color.textSecondaryPV)
                    PVRatingBar(rating: vm.rating,
                                isEnabled: !vm.isSavingRating,
                                onRate: { value in Task { await vm.setRating(value) } },
                                onClear: { Task { await vm.setRating(nil) } })
                    if vm.rating != nil {
                        Button {
                            Task { await vm.setRating(nil) }
                        } label: {
                            Label("Clear rating", systemImage: "star.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PVSubtleButtonStyle())
                        .accessibilityIdentifier("assetRatingClearButton")
                    }
                    if let error = vm.errorMessage {
                        InlineErrorBadge(message: error)
                    }
                }
                .padding(PVSpacing.s16)
            }
        }
    }

    /// Faces card (gap #5): a horizontal row of face thumbnails with the
    /// person's name (or "Unnamed"). Tap a thumbnail to assign the face.
    @ViewBuilder
    private func facesCard(faces: [AssetFaceResponseDto]) -> some View {
        if !faces.isEmpty {
            InfoCard {
                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    Label("People", systemImage: "person.2")
                        .font(.pvCaption.weight(.semibold))
                        .foregroundStyle(Color.textSecondaryPV)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: PVSpacing.s12) {
                            ForEach(faces) { face in
                                Button {
                                    selectedFace = face
                                } label: {
                                    VStack(spacing: PVSpacing.s4) {
                                        FaceThumbnailView(asset: asset, face: face, baseURL: baseURL, token: token)
                                            .frame(width: 56, height: 56)
                                            .clipShape(Circle())
                                            .overlay(Circle().strokeBorder(Color.separatorPV, lineWidth: 0.5))
                                        Text(face.person?.name ?? String(localized: "Unnamed"))
                                            .font(.pvCaption)
                                            .foregroundStyle(Color.textPrimaryPV)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 68)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(face.person?.name ?? String(localized: "Unnamed face"))
                            }
                        }
                    }
                }
                .padding(PVSpacing.s16)
            }
        }
    }

    /// Tags card (gap #2): shows the asset's tags as chips + an "Edit Tags"
    /// action that opens the tag-assignment sheet.
    @ViewBuilder
    private func tagsCard(tags: [TagResponseDto]?) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                if let tags, !tags.isEmpty {
                    ForEach(tags, id: \.id) { tag in
                        HStack(spacing: PVSpacing.s8) {
                            Image(systemName: "tag.fill")
                                .font(.pvCaption)
                                .foregroundStyle((tag.color.flatMap { Color(hex: $0) }) ?? Color.immichPrimary)
                            Text(tag.name)
                                .font(.pvBody)
                                .foregroundStyle(Color.textPrimaryPV)
                        }
                    }
                } else {
                    Text("No tags")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Divider()
                Button {
                    presentTags = true
                } label: {
                    Label("Edit Tags", systemImage: "tag")
                        .frame(maxWidth: .infinity)
                }
                .font(.pvBody.weight(.medium))
                .foregroundStyle(Color.textPrimaryPV)
                .buttonStyle(.plain)
                .padding(.vertical, PVSpacing.s4)
            }
            .padding(PVSpacing.s16)
        }
    }

    /// Troubleshoot card (gap G24): the entry point of the per-asset diagnostic
    /// page. It sits with the other action cards on purpose — the page is
    /// parameterized by the asset, so it can never be a row of the settings hub.
    @ViewBuilder
    private var troubleshootCard: some View {
        InfoCard {
            Button {
                presentTroubleshoot = true
            } label: {
                Label("Troubleshoot", systemImage: "ladybug")
                    .frame(maxWidth: .infinity)
            }
            .font(.pvBody.weight(.medium))
            .foregroundStyle(Color.textPrimaryPV)
            .buttonStyle(.plain)
            .padding(PVSpacing.s16)
            .accessibilityIdentifier("assetTroubleshootRow")
        }
    }

    /// Stack card (gap #1): shown only when the asset belongs to a stack. Lists
    /// the stack size + a "Manage Stack" action (change primary / unstack).
    @ViewBuilder
    private func stackCard(stack: AssetStackResponseDto?) -> some View {
        if let stack, stack.assetCount > 1 {
            InfoCard {
                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    HStack(spacing: PVSpacing.s8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.pvBody)
                            .foregroundStyle(Color.immichPrimary)
                        Text("\(stack.assetCount) photos in stack")
                            .font(.pvBody)
                            .foregroundStyle(Color.textPrimaryPV)
                    }
                    Divider()
                    Button {
                        presentStack = true
                    } label: {
                        Label("Manage Stack", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.pvBody.weight(.medium))
                    .foregroundStyle(Color.textPrimaryPV)
                    .buttonStyle(.plain)
                    .padding(.vertical, PVSpacing.s4)
                }
                .padding(PVSpacing.s16)
            }
        }
    }

    /// Photos-style header date: EXIF date + time when available ("1 août 2026,
    /// 14:32"), else the long-form file creation date.
    private var headerDate: String {
        vm?.detail?.exifInfo?.dateFormatted ?? dateLabel
    }

    /// Reverse-geocoded place, else EXIF place, else the list item's place.
    private func placeLabel(exif: ExifResponseDto) -> String? {
        if let place = vm?.placeName, !place.isEmpty { return place }
        if let city = exif.city ?? asset.city, !city.isEmpty { return city }
        if let country = exif.country ?? asset.country, !country.isEmpty { return country }
        return nil
    }

    /// Long-form localized date for the current photo ("July 29, 2024").
    private var dateLabel: String {
        LongDateFormatter.format(isoPrefix: asset.fileCreatedAt)
    }
}

/// EXIF info grouped into Photos-style rounded cards. Each card holds an
/// adaptive icon+value grid (wrap-around automatic; long values truncate
/// with "…"). Cards with no data are dropped entirely. AC-202: ≥12 rows
/// covered.
struct ExifInfoPanel: View {
    let exif: ExifResponseDto
    let placeName: String?
    let fallbackLatitude: Double?
    let fallbackLongitude: Double?
    /// map-extras: wired at the PhotoViewer root; nil hides the action row.
    var onOpenInMaps: ((Double, Double) -> Void)? = nil
    /// Wired at the PhotoViewer root; nil keeps the mini-map untappable.
    var onOpenLocationMap: ((Double, Double, String?) -> Void)? = nil
    var onAdjustLocation: (() -> Void)? = nil
    /// gap #3: wired at the PhotoViewer root; nil hides the action row.
    var onAdjustDate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s12) {
            if !cameraItems.isEmpty { InfoCard { InfoGrid(items: cameraItems) } }
            if !fileItems.isEmpty { InfoCard { InfoGrid(items: fileItems) } }
            whenCard
            whereCard
            descriptionCard
        }
    }

    private var cameraItems: [(symbol: String, value: String)] {
        [
            ("camera.fill", exif.cameraFormatted),
            ("scope", exif.focalLengthFormatted),
            ("camera.aperture", exif.apertureFormatted),
            ("speedometer", exif.isoFormatted),
            ("timer", exif.exposureFormatted),
        ].compactMap { symbol, value in value.map { (symbol, $0) } }
    }

    private var fileItems: [(symbol: String, value: String)] {
        [
            ("photo", exif.dimensionsFormatted),
            ("internaldrive.fill", exif.fileSizeFormatted),
            ("aspectratio", exif.orientation),
            ("viewfinder", exif.projectionType),
        ].compactMap { symbol, value in value.map { (symbol, $0) } }
    }

    private var whenItems: [(symbol: String, value: String)] {
        [
            ("calendar", exif.dateFormatted),
            ("globe", exif.timeZone),
        ].compactMap { symbol, value in value.map { (symbol, $0) } }
    }

    /// When card — date/time grid + an "Adjust Date" action row (gap #3) when
    /// the viewer wired a presenter. Mirrors the where-card's action row.
    @ViewBuilder
    private var whenCard: some View {
        if !whenItems.isEmpty || onAdjustDate != nil {
            InfoCard {
                VStack(spacing: 0) {
                    if !whenItems.isEmpty {
                        InfoGrid(items: whenItems)
                    }
                    if let onAdjustDate {
                        if !whenItems.isEmpty {
                            InfoCardDivider()
                        }
                        HStack(spacing: PVSpacing.s8) {
                            Button {
                                onAdjustDate()
                            } label: {
                                Label("Adjust Date", systemImage: "calendar.badge.clock")
                                    .frame(maxWidth: .infinity)
                            }
                            .accessibilityLabel("Adjust Date")
                        }
                        .font(.pvBody.weight(.medium))
                        .foregroundStyle(Color.textPrimaryPV)
                        .buttonStyle(.plain)
                        .padding(.horizontal, PVSpacing.s16)
                        .padding(.vertical, PVSpacing.s12)
                        .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
                        .padding(PVSpacing.s12)
                    }
                }
            }
        }
    }

    private var whereItems: [(symbol: String, value: String)] {
        [("location.fill", placeName ?? exif.city ?? exif.country)]
            .compactMap { symbol, value in value.map { (symbol, $0) } }
    }

    /// Where card — location grid + embedded map. The map uses EXIF coords
    /// first, else the list item's (bucket response), else none.
    @ViewBuilder
    private var whereCard: some View {
        let lat = exif.latitude ?? fallbackLatitude
        let lon = exif.longitude ?? fallbackLongitude
        if !whereItems.isEmpty || lat != nil {
            InfoCard {
                VStack(spacing: 0) {
                    if !whereItems.isEmpty {
                        InfoGrid(items: whereItems)
                    }
                    if let lat, let lon {
                        if !whereItems.isEmpty {
                            InfoCardDivider()
                        }
                        MiniMapView(latitude: lat, longitude: lon)
                            .frame(height: 180)
                            .overlay {
                                if let onOpenLocationMap {
                                    // Transparent layer over the 180pt map only
                                    // — wrapping the UIKit map in a `Button`
                                    // swallows its taps, and the action row
                                    // below keeps its own.
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture { onOpenLocationMap(lat, lon, placeName) }
                                        .accessibilityElement()
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityLabel(String(localized: "Open full screen map"))
                                        .accessibilityIdentifier("locationMapPreviewButton")
                                }
                            }
                        if onOpenInMaps != nil || onAdjustLocation != nil {
                            InfoCardDivider()
                            actionRow(latitude: lat, longitude: lon)
                        }
                    }
                }
            }
        }
    }

    /// Map-extras: "Open in Maps" launches Apple Maps at the photo spot;
    /// "Adjust Location" presents the drag-pin sheet (wired by the viewer).
    private func actionRow(latitude lat: Double, longitude lon: Double) -> some View {
        HStack(spacing: PVSpacing.s8) {
            if let onOpenInMaps {
                Button {
                    onOpenInMaps(lat, lon)
                } label: {
                    Label("Open in Maps", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Open in Maps")
            }
            if let onAdjustLocation {
                Button {
                    onAdjustLocation()
                } label: {
                    Label("Adjust Location", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Adjust Location")
            }
        }
        .font(.pvBody.weight(.medium))
        .foregroundStyle(Color.textPrimaryPV)
        .buttonStyle(.plain)
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s12)
        .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
        .padding(PVSpacing.s12)
    }

    /// Free-text description on its own card (Photos-style), when present.
    @ViewBuilder
    private var descriptionCard: some View {
        if let desc = exif.description {
            InfoCard {
                VStack(alignment: .leading, spacing: PVSpacing.s4) {
                    Label("Description", systemImage: "doc.text")
                        .font(.pvBody)
                        .foregroundStyle(Color.textSecondaryPV)
                    Text(desc)
                        .font(.pvBody)
                        .foregroundStyle(Color.textPrimaryPV)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(PVSpacing.s16)
            }
        }
    }
}

/// A rounded group (gray translucent background, Photos-style) wrapping any
/// content — grid, map, or text. Cards with no data are not rendered at all.
private struct InfoCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }
}

/// Icon + value grid: items spread evenly ("space evenly"), wrap-around
/// automatic, long values truncated with "…". Single-line sections render as
/// a natural-size centered HStack; multiline sections use a plain leading
/// grid (wrap stays aligned with the row above — no lopsided centering).
private struct InfoGrid: View {
    let items: [(symbol: String, value: String)]

    /// Min item width + spacing — mirrors the `GridItem(.adaptive(minimum:))`
    /// math so the computed column count matches the rendered grid.
    private static let minItemWidth: CGFloat = 96
    private static let columnSpacing: CGFloat = PVSpacing.s8
    /// Panel horizontal padding (16 + 16) applied to the grid's parent card.
    private static let panelInsets: CGFloat = PVSpacing.s16 * 2

    private var columnCount: Int {
        let available = UIScreen.main.bounds.width - Self.panelInsets
        return max(1, Int((available + Self.columnSpacing) / (Self.minItemWidth + Self.columnSpacing)))
    }

    @ViewBuilder
    var body: some View {
        if items.count <= columnCount {
            // Single line — natural-size items spread across the FULL width
            // (flexible spacers), so a short section doesn't cluster in the
            // middle with cramped gaps: one item centers, two go to the edges.
            HStack(spacing: 0) {
                Spacer(minLength: PVSpacing.s8)
                ForEach(items.indices, id: \.self) { i in
                    if i > 0 { Spacer(minLength: PVSpacing.s24) }
                    InfoGridItem(symbol: items[i].symbol, value: items[i].value)
                        .fixedSize()
                }
                Spacer(minLength: PVSpacing.s8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, PVSpacing.s16)
            .padding(.vertical, PVSpacing.s8)
        } else {
            // Multiline — plain leading grid; wrapped rows align with the row
            // above (standard grid look, no phantom-cell shuffling).
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Self.columnSpacing), count: columnCount),
                alignment: .leading,
                spacing: PVSpacing.s12
            ) {
                ForEach(items.indices, id: \.self) { i in
                    InfoGridItem(symbol: items[i].symbol, value: items[i].value)
                }
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.vertical, PVSpacing.s8)
        }
    }
}

/// Icon above value — the icon carries the meaning (no label), the value is
/// the anchor: medium-weight primary text, one line, "…" when too long.
private struct InfoGridItem: View {
    let symbol: String
    let value: String

    var body: some View {
        VStack(spacing: PVSpacing.s4) {
            Image(systemName: symbol)
                .font(.pvBody)
                .foregroundStyle(Color.immichPrimary)
            Text(value)
                .font(.pvCaption.weight(.medium))
                .foregroundStyle(Color.textPrimaryPV)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PVSpacing.s4)
    }
}

/// Hairline separator inside an info card (e.g. between the location grid and
/// the map).
private struct InfoCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 0.5)
            .padding(.horizontal, PVSpacing.s16)
    }
}

/// Non-interactive MapKit snapshot view (VM-1) with a branded pin.
///
/// UIKit-backed (`MKMapView` + `MKMarkerAnnotationView`, same mechanism as the
/// search map): the SwiftUI `Map` silently drops its annotations when
/// hit-testing is disabled (panel context), while the UIKit renderer always
/// draws the pin. cornerRadius 0 per Timeline tweak consistency (NOT 12pt).
struct MiniMapView: UIViewRepresentable {
    let latitude: Double
    let longitude: Double

    private static let reuseID = "miniMapPin"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .satellite
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isUserInteractionEnabled = false
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.reuseID)
        map.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ),
            animated: false
        )
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        map.addAnnotation(annotation)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Static snapshot — nothing to update.
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: MiniMapView.reuseID, for: annotation) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: MiniMapView.reuseID)
            view.annotation = annotation
            view.markerTintColor = UIColor(Color.immichPrimary)
            view.glyphImage = UIImage(systemName: "mappin")
            return view
        }
    }
}
