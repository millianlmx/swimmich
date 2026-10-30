import SwiftUI
import MapKit

/// Interactive drag-pin map for location adjustment (map-extras).
///
/// UIKit-backed like `MiniMapView`: the SwiftUI `Map` API cannot expose
/// `isDraggable` annotations, so this wraps `MKMapView` with a draggable
/// `MKMarkerAnnotationView`. Drag end (settled) reports the new spot through
/// `onCoordinateChange` — the sheet's source of truth stays in SwiftUI state.
struct DraggablePinMapView: UIViewRepresentable {
    let latitude: Double
    let longitude: Double
    var onCoordinateChange: (Double, Double) -> Void = { _, _ in }

    private static let reuseID = "draggablePin"

    func makeCoordinator() -> Coordinator { Coordinator(onCoordinateChange: onCoordinateChange) }

    func makeUIView(context: Context) -> MKMapView {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.reuseID)
        map.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ),
            animated: false
        )
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        map.addAnnotation(annotation)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.annotations.compactMap { $0 as? MKPointAnnotation }.first?.coordinate =
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let onCoordinateChange: (Double, Double) -> Void

        init(onCoordinateChange: @escaping (Double, Double) -> Void) {
            self.onCoordinateChange = onCoordinateChange
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: DraggablePinMapView.reuseID, for: annotation) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: DraggablePinMapView.reuseID)
            view.annotation = annotation
            view.isDraggable = true
            view.markerTintColor = UIColor(Color.immichPrimary)
            view.glyphImage = UIImage(systemName: "mappin")
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending || newState == .canceling,
                  let coordinate = view.annotation?.coordinate else { return }
            onCoordinateChange(coordinate.latitude, coordinate.longitude)
        }
    }
}

/// Adjust-location sheet: drag the pin to the right spot, Save issues the
/// write (via `AssetDetailViewModel.setLocation`) and re-geocodes. Error and
/// in-flight states surface inline; `onDone` reports whether the change
/// persisted (controller dismisses only then).
struct AdjustLocationSheet: View {
    let asset: AssetReactItem
    let vm: AssetDetailViewModel
    let onDone: (Bool) -> Void

    @State private var latitude: Double
    @State private var longitude: Double
    @State private var isSaving = false

    init(asset: AssetReactItem, vm: AssetDetailViewModel, onDone: @escaping (Bool) -> Void) {
        self.asset = asset
        self.vm = vm
        self.onDone = onDone
        _latitude = State(initialValue: asset.latitude ?? 0)
        _longitude = State(initialValue: asset.longitude ?? 0)
    }

    var body: some View {
        VStack(spacing: PVSpacing.s16) {
            header
            DraggablePinMapView(latitude: latitude, longitude: longitude) { lat, lon in
                latitude = lat
                longitude = lon
                vm.errorMessage = nil
            }
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
            footer
        }
        .padding(PVSpacing.s16)
    }

    private var header: some View {
        VStack(spacing: PVSpacing.s4) {
            Text("Adjust Location")
                .font(.pvH6)
                .foregroundStyle(Color.textPrimaryPV)
            Text("Drag the pin to the photo's true location.")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
        }
    }

    private var footer: some View {
        VStack(spacing: PVSpacing.s8) {
            if let error = vm.errorMessage {
                Text(error)
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: PVSpacing.s12) {
                Button {
                    onDone(false)
                } label: {
                    Text("Cancel")
                        .font(.pvBody.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, PVSpacing.s12)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
                .disabled(isSaving)

                Button {
                    Task {
                        isSaving = true
                        await vm.setLocation(latitude: latitude, longitude: longitude)
                        isSaving = false
                        if vm.errorMessage == nil {
                            onDone(true)
                        }
                    }
                } label: {
                    HStack(spacing: PVSpacing.s8) {
                        if isSaving {
                            ProgressView()
                        }
                        Text("Save")
                            .font(.pvBody.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, PVSpacing.s12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.immichPrimary))
                .disabled(isSaving)
            }
        }
    }
}