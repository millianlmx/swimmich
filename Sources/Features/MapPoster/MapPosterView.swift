import SwiftUI

/// Full-screen "Everywhere I've been" poster: the map of every place in the
/// photos and its numbers, at the format it is saved in.
struct MapPosterView: View {
    @Bindable var vm: MapPosterViewModel
    @Environment(\.dismiss) private var dismiss

    /// The poster's formats: a square leaves the map no room.
    private static let formats: [MosaicFormat] = [.story, .post]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar
                Spacer(minLength: 0)
                if let poster = vm.poster {
                    Image(uiImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            if vm.isLoading { ProgressView().tint(.white) }
                        }
                        .padding(.horizontal, 16)
                        .accessibilityLabel(Text(posterDescription))
                        .accessibilityIdentifier("mapPosterPreview")
                } else if vm.isLoading {
                    ProgressView("Drawing the map…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("mapPosterLoading")
                } else if let error = vm.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "map")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(error)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mapPosterError")
                }
                Spacer(minLength: 0)
                controls
            }

            if vm.exportState == .done {
                VStack {
                    Spacer()
                    savedOverlay
                }
            }
        }
        .statusBarHidden(true)
        .task { await vm.load() }
        .onDisappear { vm.discardExportedImage() }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    private var posterDescription: String {
        guard let stats = vm.stats else { return vm.title }
        // "Everywhere I've been. Countries: 12. Cities: 87." — the poster's own words.
        return "\(vm.title). \(String(localized: "Countries")): \(stats.countryCount). "
            + "\(String(localized: "Cities")): \(stats.cityCount)."
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
            .accessibilityIdentifier("mapPosterCloseButton")

            Spacer()

            Label("Map Poster", systemImage: "map")
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
                    if vm.exportState == .saving {
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
            .disabled(vm.poster == nil || vm.isLoading || vm.exportState == .saving)
            .accessibilityLabel("Save image")
            .accessibilityIdentifier("mapPosterExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Period", selection: $vm.scope) {
                ForEach(MapPosterScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mapPosterScope")

            Picker("Format", selection: $vm.format) {
                ForEach(Self.formats) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mapPosterFormat")

            Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .accessibilityIdentifier("mapPosterCreditToggle")
        }
        .padding(16)
        .pvFloating(.bar)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The poster is in the photo library: share it straight away.
    private var savedOverlay: some View {
        VStack(spacing: 14) {
            Label("Image saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
                .foregroundStyle(.white)
            Text("The poster was added to your photo library.")
                .font(.pvCaption)
                .foregroundStyle(PVFloating.secondaryContent)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if let url = vm.exportedImageURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.pvSubhead.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .accessibilityIdentifier("mapPosterShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("mapPosterSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("mapPosterSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
