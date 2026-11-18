import SwiftUI

/// Full-screen reel player: the title card, then one photo per beat, pushed
/// in around its subject, drawn by the same code as the export
/// (`ReelRenderer.drawFrame`). The film loops.
struct ReelView: View {
    @Bindable var vm: ReelViewModel
    @Environment(\.dismiss) private var dismiss
    @PVReduceMotion private var reduceMotion

    /// When the film started playing: reset by a change of length.
    @State private var start = Date()
    @State private var editingPhotos = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                Spacer(minLength: 0)
                if vm.isPreparing {
                    VStack(spacing: 12) {
                        ProgressView(value: vm.preparationProgress)
                            .tint(.white)
                            .frame(width: 220)
                        Text("Picking the best photos…")
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("reelPreparing")
                } else if let error = vm.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(error)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("reelError")
                } else {
                    player
                        .padding(.horizontal, 16)
                }
                Spacer(minLength: 0)
                if !vm.isPreparing && vm.errorMessage == nil {
                    controls
                }
            }

            VStack {
                Spacer()
                exportOverlay
            }
        }
        .statusBarHidden(true)
        .task { await vm.prepare() }
        .sheet(isPresented: $editingPhotos) {
            ReelPhotosSheet(vm: vm)
        }
        .onChange(of: vm.shots.map(\.id)) { start = Date() }
        .onDisappear {
            vm.cancelExport()
            vm.discardExportedVideo()
        }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    // MARK: - Player

    private var player: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let duration = max(vm.duration, 0.1)
            let time = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: duration)
            let (segment, progress) = ReelPlan.segment(at: time, photoCount: vm.shots.count)
            let shot: ReelShot? = switch segment {
            case .title: vm.cover
            case .photo(let index): vm.shots.indices.contains(index) ? vm.shots[index] : nil
            }
            let image = shot.flatMap { vm.playerImage(for: $0) }
            let credit = vm.showsCredit && time >= duration - ReelPlan.endHold
            Canvas { canvas, size in
                canvas.withCGContext { cg in
                    UIGraphicsPushContext(cg)
                    ReelRenderer.drawFrame(
                        segment: segment, progress: progress, image: image, shot: shot,
                        title: vm.title, subtitle: vm.subtitle, credit: credit,
                        showsPlace: vm.showsPlaces, zooms: !reduceMotion, in: size
                    )
                    UIGraphicsPopContext()
                }
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("Reel of \(vm.shots.count) photos: \(vm.title)"))
        .accessibilityIdentifier("reelPlayer")
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                vm.cancelExport()
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
            .accessibilityIdentifier("reelCloseButton")

            Spacer()

            Label("Reel", systemImage: "film.stack")
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .pvFloating(.pill)

            Spacer()

            Button {
                vm.startExport()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .pvFloating(.circle)
            }
            .buttonStyle(.plain)
            .disabled(vm.shots.isEmpty || vm.exportState != .idle)
            .accessibilityLabel("Export video")
            .accessibilityIdentifier("reelExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Length", selection: $vm.length) {
                    ForEach(ReelLength.allCases) { length in
                        Text(length.title).tag(length)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reelLength")

                Button {
                    editingPhotos = true
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.pvSubhead.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("reelEditPhotos")
            }

            Toggle("Show places", isOn: $vm.showsPlaces)
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .accessibilityIdentifier("reelPlacesToggle")

            Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .accessibilityIdentifier("reelCreditToggle")
        }
        .padding(16)
        .pvFloating(.bar)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .disabled(vm.exportState != .idle)
    }

    @ViewBuilder
    private var exportOverlay: some View {
        switch vm.exportState {
        case .rendering(let progress):
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
        case .saving:
            Label("Saving…", systemImage: "square.and.arrow.down")
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .padding(16)
                .pvFloating(.bar)
                .padding(.bottom, 60)
        case .done:
            savedOverlay
        case .idle, .failed:
            EmptyView()
        }
    }

    /// The film is in the photo library: share it straight away.
    private var savedOverlay: some View {
        VStack(spacing: 14) {
            Label("Video saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
                .foregroundStyle(.white)
            Text("The reel was added to your photo library.")
                .font(.pvCaption)
                .foregroundStyle(PVFloating.secondaryContent)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let url = vm.exportedVideoURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.pvSubhead.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .accessibilityIdentifier("reelShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("reelSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("reelSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
