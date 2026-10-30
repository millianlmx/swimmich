import SwiftUI
import UIKit

/// Non-destructive photo editor (cahier §5 L117-130).
///
/// MVP scope: crop (rule-of-thirds + predefined ratios), rotation fine slider (-45..+45)
/// + 90° buttons, adjustments (exposure/contrast/saturation/warmth), local EditState persistence,
/// "Revenir à l'original". Save renders the full-resolution edit and uploads it as a NEW asset
/// (the original is untouched); Cancel closes without sending anything. The settings draft is
/// saved on disappear, except after a successful copy save.
struct PhotoEditorView: View {
    @Bindable var vm: PhotoEditorViewModel
    var onSavedCopy: () -> Void = {}
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss

    // V1.5 polish — haptic triggers (AC-707/708/719).
    @State private var aspectTick = 0
    @State private var rotateTick = 0
    @State private var revertTick = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PVSpacing.s16) {
                    previewSection
                    CropAspectPickerView(selectedRatio: Binding(
                        get: { vm.editState.aspectRatio },
                        set: {
                            vm.setAspectRatio($0)
                            aspectTick &+= 1
                        }
                    ))
                    RotationSliderView(
                        straightenDeg: Binding(
                            get: { vm.editState.straightenDeg },
                            set: { vm.setStraighten($0) }
                        ),
                        onRotate90CW: {
                            vm.rotate90CW()
                            rotateTick &+= 1
                        },
                        onRotate90CCW: {
                            vm.rotate90CCW()
                            rotateTick &+= 1
                        }
                    )
                    AdjustmentSlidersView(
                        exposure: Binding(get: { vm.editState.exposure }, set: { vm.setExposure($0) }),
                        contrast: Binding(get: { vm.editState.contrast }, set: { vm.setContrast($0) }),
                        saturation: Binding(get: { vm.editState.saturation }, set: { vm.setSaturation($0) }),
                        warmth: Binding(get: { vm.editState.warmth }, set: { vm.setWarmth($0) })
                    )
                    Button("Revert to original") {
                        vm.resetToOriginal()
                        revertTick &+= 1
                    }
                    .buttonStyle(.borderedProminent) // DS-exempt: destructive CTA, no DS token
                    .tint(.red)
                    .disabled(!vm.canRevert)
                    .accessibilityIdentifier("revertToOriginalButton")
                }
                .padding()
                .disabled(vm.isSaving)
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.cancel() }
                        .disabled(!vm.canCancel)
                        .accessibilityIdentifier("editorCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSaving {
                        ProgressView()
                            .accessibilityIdentifier("editorSaveProgress")
                    } else {
                        Button("Save") { vm.saveCopyToServer() }
                            .fontWeight(.semibold)
                            .disabled(!vm.canSave)
                            .accessibilityIdentifier("editorSaveButton")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: PVSpacing.s8) {
                    if let step = vm.saveStep {
                        HStack(spacing: PVSpacing.s8) {
                            ProgressView()
                            Text(stepLabel(step)).font(.pvCaption)
                        }
                    }
                    if let err = vm.errorMessage, !err.isEmpty {
                        InlineErrorBadge(message: err)
                    }
                }
                .padding(.horizontal, PVSpacing.s16)
            }
        }
        .interactiveDismissDisabled(vm.isSaving)
        .appSensoryFeedback(.selection, trigger: aspectTick)
        .appSensoryFeedback(.impact, trigger: rotateTick)
        .appSensoryFeedback(.impact(weight: .light), trigger: revertTick)
        .appSensoryFeedback(.error, trigger: vm.errorMessage)
        .onChange(of: vm.dismissReason) { _, reason in
            guard let reason else { return }
            if reason == .savedCopy { onSavedCopy() }
            dismiss()
        }
        .task {
            // AC-616: read the draft first (local, fast) so a close during the original's
            // download never runs `saveState()` against an unread draft.
            await vm.loadState()
            if let baseURL = auth.baseURL {
                let url = ImmichAssetURL.original(assetId: vm.assetId, baseURL: baseURL)
                await vm.loadOriginal(url: url, token: auth.accessToken)
            }
        }
        .onDisappear {
            // AC-616: save the draft on disappear (no-op after a successful copy save).
            vm.saveState()
        }
    }

    private func stepLabel(_ step: EditorSaveStep) -> LocalizedStringKey {
        switch step {
        case .rendering: return "Rendering edited photo…"
        case .uploading: return "Uploading edited copy…"
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        GeometryReader { geo in
            ZStack {
                if let img = vm.previewImage ?? vm.originalImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.width)
                } else if vm.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Image", systemImage: "photo")
                }
                if vm.isGridVisible {
                    RuleOfThirdsOverlay()
                        .frame(width: geo.size.width, height: geo.size.width)
                        .accessibilityIdentifier("ruleOfThirdsOverlay")
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - RuleOfThirdsOverlay (AC-608)

struct RuleOfThirdsOverlay: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1)
            let thirdsX = size.width / 3
            let thirdsY = size.height / 3
            var path = Path()
            // Vertical lines
            path.move(to: CGPoint(x: thirdsX, y: 0))
            path.addLine(to: CGPoint(x: thirdsX, y: size.height))
            path.move(to: CGPoint(x: 2 * thirdsX, y: 0))
            path.addLine(to: CGPoint(x: 2 * thirdsX, y: size.height))
            // Horizontal lines
            path.move(to: CGPoint(x: 0, y: thirdsY))
            path.addLine(to: CGPoint(x: size.width, y: thirdsY))
            path.move(to: CGPoint(x: 0, y: 2 * thirdsY))
            path.addLine(to: CGPoint(x: size.width, y: 2 * thirdsY))
            context.stroke(path, with: .color(.white.opacity(0.6)), style: stroke)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - RotationSliderView (AC-609)

struct RotationSliderView: View {
    @Binding var straightenDeg: Double
    let onRotate90CW: () -> Void
    let onRotate90CCW: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            Text("Rotation").font(.pvHeadline)
            HStack {
                Button(action: onRotate90CCW) {
                    Image(systemName: "rotate.left")
                }
                .accessibilityIdentifier("rotate90CCWButton")
                Slider(value: $straightenDeg, in: -45...45, step: 1) {
                    Text("Straighten")
                }
                Text(String(format: "%+.0f°", straightenDeg))
                    .frame(width: 48, alignment: .trailing)
                    .font(.pvCaption).monospacedDigit()
                Button(action: onRotate90CW) {
                    Image(systemName: "rotate.right")
                }
                .accessibilityIdentifier("rotate90CWButton")
            }
        }
    }
}

// MARK: - AdjustmentSlidersView (AC-610)

struct AdjustmentSlidersView: View {
    @Binding var exposure: Double
    @Binding var contrast: Double
    @Binding var saturation: Double
    @Binding var warmth: Double

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s12) {
            Text("Adjustments").font(.pvHeadline)
            adjustmentRow(label: "Exposure", value: $exposure, range: -2...2)
            adjustmentRow(label: "Contrast", value: $contrast, range: -1...1)
            adjustmentRow(label: "Saturation", value: $saturation, range: -1...1)
            adjustmentRow(label: "Warmth", value: $warmth, range: -1...1)
        }
    }

    private func adjustmentRow(label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: 0.05)
            Text(String(format: "%+.2f", value.wrappedValue))
                .frame(width: 56, alignment: .trailing)
                .font(.pvCaption).monospacedDigit()
        }
    }
}

// MARK: - CropAspectPickerView (AC-611)

struct CropAspectPickerView: View {
    @Binding var selectedRatio: CropAspectRatio?

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            Text("Crop Ratio").font(.pvHeadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PVSpacing.s8) {
                    ForEach(CropAspectRatio.allCases, id: \.self) { ratio in
                        Button {
                            selectedRatio = (selectedRatio == ratio) ? nil : ratio
                        } label: {
                            Text(displayName(ratio))
                                .font(.pvCaption)
                                .padding(.horizontal, PVSpacing.s8)
                                .padding(.vertical, PVSpacing.s8)
                                .background(selectedRatio == ratio ? Color.immichPrimary.opacity(0.3) : Color.bgTertiary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .accessibilityIdentifier("ratioButton.\(ratio.rawValue)")
                    }
                }
            }
        }
    }

    private func displayName(_ r: CropAspectRatio) -> String {
        switch r {
        case .freeform:     return "Free"
        case .square:       return "1:1"
        case .fourByThree:  return "4:3"
        case .threeByTwo:   return "3:2"
        case .twoByThree:   return "2:3"
        case .sixteenByNine: return "16:9"
        case .nineBySixteen: return "9:16"
        }
    }
}
