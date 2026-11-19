import SwiftUI

/// Full-screen photo dump: the photos picked for the carousel, in their order,
/// cropped to the shape they are exported at. A tap swaps a photo for the next
/// best of its moment, a drag moves it, a long press makes it the cover or
/// takes it out.
struct PhotoDumpView: View {
    @Bindable var vm: PhotoDumpViewModel
    @Environment(\.dismiss) private var dismiss
    @PVReduceMotion private var reduceMotion

    /// The photo being moved, while a finger holds it.
    @State private var dragging: DumpDrag?
    @GestureState private var isPressing = false
    @State private var lastDrop = Date.distantPast
    @State private var liftTick = 0
    @State private var reorderTick = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                if vm.isPreparing {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView(value: vm.preparationProgress)
                            .tint(.white)
                            .frame(width: 220)
                        Text("Picking the best photos…")
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("photoDumpPreparing")
                    Spacer()
                } else if let error = vm.errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(error)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("photoDumpError")
                    Spacer()
                } else {
                    grid
                    controls
                }
            }

            if vm.exportState == .done {
                VStack {
                    Spacer()
                    savedOverlay
                }
            }
        }
        .statusBarHidden(true)
        .task { await vm.prepare() }
        .onDisappear { vm.cancel() }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    // MARK: - Grid

    /// The grid's own coordinates: the drag reads its translation there, not
    /// in the moving cell's, which would follow the finger it measures.
    private static let gridSpace = "photoDumpGrid"
    private static let spacing: CGFloat = 6

    private var grid: some View {
        GeometryReader { proxy in
            let metrics = DumpGridMetrics(
                width: max(0, proxy.size.width - 32),
                columns: DumpGridMetrics.columns(forCount: vm.picks.count),
                ratio: vm.aspect.ratio ?? 1,
                spacing: Self.spacing
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(vm.picks.enumerated()), id: \.element.id) { index, pick in
                            cell(pick, index: index, metrics: metrics)
                        }
                    }
                    .frame(width: metrics.width, height: metrics.height(count: vm.picks.count), alignment: .topLeading)
                    .coordinateSpace(name: Self.gridSpace)
                    .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.picks.map(\.id))

                    Text(vm.canSwap
                         ? "Tap a photo to swap it, hold and move it to reorder."
                         : "Hold a photo and move it to reorder.")
                        .font(.pvCaption)
                        .foregroundStyle(PVFloating.secondaryContent)
                }
                .padding(.horizontal, 16)
            }
            // The finger moves the photo, not the page.
            .scrollDisabled(dragging != nil)
        }
        .appSensoryFeedback(.impact(weight: .medium), trigger: liftTick)
        .appSensoryFeedback(.selection, trigger: reorderTick)
        .onChange(of: isPressing) { _, pressing in
            // A drag the system cancelled ends here: the photo drops into its slot.
            if !pressing, dragging != nil { drop() }
        }
    }

    private func cell(_ pick: DumpCandidate, index: Int, metrics: DumpGridMetrics) -> some View {
        let lifted = dragging?.id == pick.id
        let center = lifted
            ? CGPoint(x: dragging!.start.x + dragging!.translation.width, y: dragging!.start.y + dragging!.translation.height)
            : metrics.center(of: index)
        return Button {
            // The release of a drag is not a tap.
            guard dragging == nil, Date().timeIntervalSince(lastDrop) > 0.4, vm.canSwap else { return }
            vm.swap(pick.id)
        } label: {
            Color.white.opacity(0.08)
                .overlay {
                    if let image = vm.croppedPreview(for: pick) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: vm.aspect.ratio == nil ? .fit : .fill)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) { badge(index: index) }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { options(pick, index: index) }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
        .scaleEffect(lifted ? PVMotion.scale(1.08, reduceMotion: reduceMotion) : 1)
        .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 12, y: 6)
        .simultaneousGesture(reorderGesture(pick, metrics: metrics))
        .zIndex(lifted ? 1 : 0)
        .position(center)
        .accessibilityLabel(index == 0 ? Text("Cover photo") : Text("Photo \(String(index + 1))"))
        .accessibilityHint(vm.canSwap ? Text("Swaps it for another photo of the same moment") : Text(verbatim: ""))
        .accessibilityAction(named: Text("Move Earlier")) { vm.move(pick.id, by: -1) }
        .accessibilityAction(named: Text("Move Later")) { vm.move(pick.id, by: 1) }
        .accessibilityIdentifier("photoDumpCell_\(index)")
    }

    /// Hold, then move: the photo lifts under the finger and the others make
    /// room as it passes over their slots.
    private func reorderGesture(_ pick: DumpCandidate, metrics: DumpGridMetrics) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace)))
            .updating($isPressing) { value, pressing, _ in
                if case .second(true, _) = value { pressing = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if dragging == nil, let index = vm.picks.firstIndex(where: { $0.id == pick.id }) {
                    withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
                        dragging = DumpDrag(id: pick.id, start: metrics.center(of: index), translation: .zero)
                    }
                    liftTick &+= 1
                }
                guard let drag, var current = dragging, current.id == pick.id else { return }
                current.translation = drag.translation
                dragging = current
                let point = CGPoint(x: current.start.x + drag.translation.width, y: current.start.y + drag.translation.height)
                let target = metrics.index(at: point, count: vm.picks.count)
                if let from = vm.picks.firstIndex(where: { $0.id == pick.id }), target != from {
                    vm.move(pick.id, to: vm.picks[target].id)
                    reorderTick &+= 1
                }
            }
            .onEnded { _ in drop() }
    }

    private func drop() {
        lastDrop = Date()
        withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
            dragging = nil
        }
    }

    /// Cover, swap and removal, on a small button in the photo's corner: a
    /// long press belongs to the drag.
    private func options(_ pick: DumpCandidate, index: Int) -> some View {
        Menu {
            if index > 0 {
                Button {
                    vm.makeCover(pick.id)
                } label: {
                    Label("Make Cover", systemImage: "star")
                }
            }
            if vm.canSwap {
                Button {
                    vm.swap(pick.id)
                } label: {
                    Label("Swap Photo", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if vm.picks.count > PhotoDumpPicker.countRange.lowerBound {
                Button(role: .destructive) {
                    vm.remove(pick.id)
                } label: {
                    Label("Remove from Dump", systemImage: "minus.circle")
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.pvCaption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.6)))
                .padding(5)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("photoDumpOptions_\(index)")
    }

    private func badge(index: Int) -> some View {
        Group {
            if index == 0 {
                Image(systemName: "star.fill")
            } else {
                Text(verbatim: "\(index + 1)")
            }
        }
        .font(.pvCaption.weight(.bold))
        .foregroundStyle(.white)
        .frame(minWidth: 22, minHeight: 22)
        .background(Circle().fill(.black.opacity(0.6)))
        .padding(5)
        .accessibilityHidden(true)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
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
            .accessibilityIdentifier("photoDumpCloseButton")

            Spacer()

            Label("Photo Dump", systemImage: "photo.stack")
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .pvFloating(.pill)

            Spacer()

            Button {
                vm.export()
            } label: {
                Group {
                    if vm.exportState == .rendering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.pvHeadline)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .pvFloating(.circle)
            }
            .buttonStyle(.plain)
            .disabled(vm.picks.isEmpty || vm.exportState == .rendering)
            .accessibilityLabel("Save photos")
            .accessibilityIdentifier("photoDumpExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Stepper(value: $vm.count, in: PhotoDumpPicker.countRange) {
                Text("\(vm.count) photos")
                    .font(.pvSubhead)
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("photoDumpCountStepper")

            Picker("Shape", selection: $vm.aspect) {
                ForEach(DumpAspect.allCases) { aspect in
                    Text(verbatim: aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("photoDumpAspect")
        }
        .padding(16)
        .pvFloating(.bar)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The photos are in the photo library: share them straight away.
    private var savedOverlay: some View {
        VStack(spacing: 14) {
            Label("Photos saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
                .foregroundStyle(.white)
            Text("The photo dump was added to your photo library, in order.")
                .font(.pvCaption)
                .foregroundStyle(PVFloating.secondaryContent)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if !vm.exportedURLs.isEmpty {
                    ShareLink(items: vm.exportedURLs) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.pvSubhead.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .accessibilityIdentifier("photoDumpShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("photoDumpSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("photoDumpSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}

/// A photo held by the reorder drag: the center of its slot when it was lifted,
/// and how far the finger has gone since.
private struct DumpDrag: Equatable {
    let id: String
    let start: CGPoint
    var translation: CGSize
}
