import SwiftUI
import MapKit

/// `.sheet(item:)` payload for the viewer's full-screen location map.
/// A tuple cannot drive an item-based presentation — the sheet would never
/// open — so the coordinates travel as this small identifiable request.
struct AssetLocationMapRequest: Identifiable {
    let latitude: Double
    let longitude: Double
    let placeName: String?

    var id: String { "\(latitude),\(longitude)" }
}

/// Full-screen, **interactive** map of one asset's location.
///
/// The info panel already shows this spot, but its `MiniMapView` is a
/// non-interactive snapshot (it disables MapKit's gestures) — tapping a
/// photo's location to look around is what this sheet adds. Same place, same
/// 0.01° framing as the mini-map, with pan/zoom left on.
struct AssetLocationMapSheet: View {
    let latitude: Double
    let longitude: Double
    let placeName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition

    init(latitude: Double, longitude: Double, placeName: String?) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
    }

    var body: some View {
        Map(position: $position) {
            Marker(
                placeName ?? String(localized: "Photo"),
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
        }
        .mapStyle(.standard)
        .ignoresSafeArea()
        .accessibilityIdentifier("assetLocationMap")
        .overlay(alignment: .topTrailing) { doneButton }
    }

    /// Plain glass close button rather than a navigation bar: the map is the
    /// screen, and a bar would add chrome the panel's mini-map doesn't have.
    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.pvBody.weight(.semibold))
                .padding(PVSpacing.s12)
        }
        .buttonStyle(.plain)
        .pvFloating(.circle)
        .accessibilityLabel("Done")
        .accessibilityIdentifier("assetLocationMapDoneButton")
        .padding(PVSpacing.s16)
    }
}
