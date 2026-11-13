import SwiftUI
import MapKit

/// Interactive drag-pin map for location adjustment (map-extras).
///
/// UIKit-backed like `MiniMapView`: the SwiftUI `Map` API cannot expose
/// `isDraggable` annotations, so this wraps `MKMapView` with a draggable
/// `MKMarkerAnnotationView`. The map follows `pin` (typed coordinates move
/// it); a settled drag reports the new spot through `onPinDragged`. With no
/// `pin` (photo without a location) it shows the world and no annotation.
struct DraggablePinMapView: UIViewRepresentable {
    let pin: PhotoCoordinate?
    let reduceMotion: Bool
    var onPinDragged: (PhotoCoordinate) -> Void = { _ in }

    private static let reuseID = "draggablePin"
    private static let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    func makeCoordinator() -> Coordinator { Coordinator(onPinDragged: onPinDragged) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.reuseID)
        if let pin {
            let coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            map.setRegion(MKCoordinateRegion(center: coordinate, span: Self.span), animated: false)
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            map.addAnnotation(annotation)
        } else {
            map.setVisibleMapRect(.world, animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onPinDragged = onPinDragged
        let existing = map.annotations.compactMap { $0 as? MKPointAnnotation }.first
        guard let pin else {
            if let existing { map.removeAnnotation(existing) }
            return
        }
        let target = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        if let existing {
            if abs(existing.coordinate.latitude - pin.latitude) > 1e-9
                || abs(existing.coordinate.longitude - pin.longitude) > 1e-9 {
                existing.coordinate = target
                if !map.visibleMapRect.contains(MKMapPoint(target)) {
                    map.setCenter(target, animated: !reduceMotion)
                }
            }
            map.view(for: existing)?.accessibilityValue = AdjustLocationViewModel.accessibilityValue(pin)
        } else {
            let annotation = MKPointAnnotation()
            annotation.coordinate = target
            map.addAnnotation(annotation)
            map.setRegion(MKCoordinateRegion(center: target, span: Self.span), animated: !reduceMotion)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPinDragged: (PhotoCoordinate) -> Void

        init(onPinDragged: @escaping (PhotoCoordinate) -> Void) {
            self.onPinDragged = onPinDragged
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: DraggablePinMapView.reuseID, for: annotation) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: DraggablePinMapView.reuseID)
            view.annotation = annotation
            view.isDraggable = true
            view.markerTintColor = UIColor(Color.immichPrimary)
            view.glyphImage = UIImage(systemName: "mappin")
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "adjustLocationPin"
            view.accessibilityLabel = String(localized: "Photo location")
            view.accessibilityValue = AdjustLocationViewModel.accessibilityValue(
                PhotoCoordinate(latitude: annotation.coordinate.latitude, longitude: annotation.coordinate.longitude)
            )
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard newState == .ending || newState == .canceling,
                  let coordinate = view.annotation?.coordinate else { return }
            onPinDragged(PhotoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
    }
}

/// Adjust-location sheet: the two typed fields and the draggable pin stay in
/// step (`AdjustLocationViewModel`); Save writes whatever the fields read at
/// that instant, keyboard open or not. `onDone` reports whether the change
/// persisted (the host dismisses only then). Pushed content: no navigation
/// stack of its own, Cancel/Save sit in the header.
struct AdjustLocationSheet: View {
    @Bindable var vm: AdjustLocationViewModel
    let onDone: (Bool) -> Void

    @FocusState private var focus: CoordinateAxis?
    @PVReduceMotion private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                header
                Text("Drag the pin or enter the coordinates.")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .frame(maxWidth: .infinity, alignment: .leading)
                fields
                myLocationButton
                DraggablePinMapView(pin: vm.pin, reduceMotion: reduceMotion, onPinDragged: vm.pinDragged)
                    .frame(minHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
                if let error = vm.detail.errorMessage {
                    Text(error)
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("adjustLocationServerError")
                }
            }
            .padding(PVSpacing.s16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .alert(
            vm.locationNotice?.title ?? "",
            isPresented: Binding(
                get: { vm.locationNotice != nil },
                set: { if !$0 { vm.locationNotice = nil } }
            ),
            presenting: vm.locationNotice
        ) { notice in
            if notice.offersSettings {
                Button("Open Settings") { openAppSettings() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(notice.message)
        }
    }

    /// Puts the pin and the two fields on the device's position. Nothing is
    /// written until Save, like for a dragged pin.
    private var myLocationButton: some View {
        Button {
            focus = nil
            Task { await vm.useMyLocation() }
        } label: {
            HStack(spacing: PVSpacing.s8) {
                if vm.isLocating {
                    ProgressView()
                } else {
                    Image(systemName: "location")
                }
                Text("My Location")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PVSubtleButtonStyle())
        .disabled(vm.isLocating || vm.isSaving)
        .accessibilityIdentifier("adjustLocationMyLocationButton")
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var header: some View {
        HStack(spacing: PVSpacing.s12) {
            Button {
                onDone(false)
            } label: {
                Text("Cancel")
                    .font(.pvBody.weight(.medium))
                    .foregroundStyle(Color.textPrimaryPV)
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
            .accessibilityIdentifier("adjustLocationCancelButton")

            Group {
                if vm.startedWithoutLocation {
                    Text("Add Location")
                } else {
                    Text("Adjust Location")
                }
            }
            .font(.pvH6)
            .foregroundStyle(Color.textPrimaryPV)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)

            Button {
                Task {
                    if await vm.save() {
                        onDone(true)
                    } else if let message = firstFieldMessage {
                        AccessibilityNotification.Announcement(message).post()
                    }
                }
            } label: {
                HStack(spacing: PVSpacing.s8) {
                    if vm.isSaving {
                        ProgressView()
                    }
                    Text("Save")
                        .font(.pvBody.weight(.semibold))
                        .foregroundStyle(Color.immichPrimary)
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isSaving)
            .accessibilityIdentifier("adjustLocationSaveButton")
        }
    }

    private var firstFieldMessage: String? {
        if let error = vm.latitudeError {
            return AdjustLocationViewModel.message(for: error, axis: .latitude)
        }
        if let error = vm.longitudeError {
            return AdjustLocationViewModel.message(for: error, axis: .longitude)
        }
        return nil
    }

    private var fields: some View {
        PVAdaptiveStack(spacing: PVSpacing.s12) {
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text("Latitude")
                    .font(.pvCaption.weight(.semibold))
                    .foregroundStyle(Color.textSecondaryPV)
                TextField("Latitude", text: $vm.latitudeText, prompt: Text("Between -90 and 90"))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .latitude)
                    .submitLabel(.next)
                    .onSubmit { focus = .longitude }
                    .font(.pvBody)
                    .padding(PVSpacing.s12)
                    .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
                    .accessibilityIdentifier("adjustLocationLatitudeField")
                if let error = vm.latitudeError {
                    errorText(error, axis: .latitude)
                        .accessibilityIdentifier("adjustLocationLatitudeError")
                }
            }
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text("Longitude")
                    .font(.pvCaption.weight(.semibold))
                    .foregroundStyle(Color.textSecondaryPV)
                TextField("Longitude", text: $vm.longitudeText, prompt: Text("Between -180 and 180"))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .longitude)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .font(.pvBody)
                    .padding(PVSpacing.s12)
                    .background(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous).fill(Color.gray.opacity(0.12)))
                    .accessibilityIdentifier("adjustLocationLongitudeField")
                if let error = vm.longitudeError {
                    errorText(error, axis: .longitude)
                        .accessibilityIdentifier("adjustLocationLongitudeError")
                }
            }
        }
    }

    private func errorText(_ error: CoordinateFieldError, axis: CoordinateAxis) -> some View {
        Text(AdjustLocationViewModel.message(for: error, axis: axis))
            .font(.pvCaption)
            .foregroundStyle(Color.immichError)
            .fixedSize(horizontal: false, vertical: true)
    }
}