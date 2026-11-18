import SwiftUI

/// Full-screen "Growing Up" player: the person's faces, aligned eye to eye,
/// fading one into the next over the years, with their age under each face.
/// The film loops; the export writes it as a video (`GrowingUpRenderer`).
struct GrowingUpView: View {
    @Bindable var vm: GrowingUpViewModel
    @Environment(\.dismiss) private var dismiss

    /// When the film started playing: reset by a change of speed.
    @State private var start = Date()

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
                        Text("Finding \(vm.person.name)’s face over the years…")
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("growingUpPreparing")
                } else if let error = vm.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.rectangle.stack")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(error)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("growingUpError")
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
        .onChange(of: vm.speed) { start = Date() }
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
            let (index, blend) = GrowingUpPlan.frame(at: time, frameCount: vm.frames.count, speed: vm.speed)
            let caption = GrowingUpRenderer.caption(vm.frames, index: index, blend: blend)
            ZStack {
                Color.black
                if let image = vm.playerImage(at: index) {
                    Image(uiImage: image).resizable()
                }
                if blend > 0, let next = vm.playerImage(at: index + 1) {
                    Image(uiImage: next).resizable().opacity(blend)
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    let unit = proxy.size.width / 1080
                    VStack(spacing: 0) {
                        if let age = caption?.age {
                            Text(verbatim: age)
                                .font(.system(size: 78 * unit, weight: .heavy))
                            Text(verbatim: caption?.year ?? "")
                                .font(.system(size: 44 * unit, weight: .semibold))
                                .opacity(0.85)
                        } else {
                            Text(verbatim: caption?.year ?? "")
                                .font(.system(size: 78 * unit, weight: .heavy))
                        }
                        Spacer()
                        if vm.showsCredit, time >= duration - GrowingUpPlan.endHold {
                            Text("Made with Swimmich")
                                .font(.system(size: 30 * unit, weight: .semibold))
                                .padding(.horizontal, 24 * unit)
                                .padding(.vertical, 10 * unit)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .padding(.bottom, 84 * unit)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 6)
                    .frame(maxWidth: .infinity)
                    .padding(.top, proxy.size.height * 0.78)
                }
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("Timelapse of \(vm.person.name) from \(vm.frames.first?.year ?? "") to \(vm.frames.last?.year ?? "")"))
        .accessibilityIdentifier("growingUpPlayer")
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
            .accessibilityIdentifier("growingUpCloseButton")

            Spacer()

            Label("Growing Up", systemImage: "person.crop.rectangle.stack")
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
            .disabled(vm.frames.isEmpty || vm.exportState != .idle)
            .accessibilityLabel("Export video")
            .accessibilityIdentifier("growingUpExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Speed", selection: $vm.speed) {
                ForEach(GrowingUpSpeed.allCases) { speed in
                    Text(speed.title).tag(speed)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("growingUpSpeed")

            Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .accessibilityIdentifier("growingUpCreditToggle")
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
            Text("The timelapse was added to your photo library.")
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
                    .accessibilityIdentifier("growingUpShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("growingUpSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("growingUpSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
