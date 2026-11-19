import SwiftUI

/// Full-screen Wrapped story: one card at a time, swiped like the stories
/// people share, a segment per card at the top; the cards saved as images or
/// as one video.
struct WrappedView: View {
    @Bindable var vm: WrappedViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                if !vm.cards.isEmpty {
                    segments
                        .padding(.horizontal, 16)
                }
                if vm.isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView(value: vm.progress)
                            .tint(.white)
                            .frame(width: 220)
                        Text("Wrapping up your year…")
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("wrappedLoading")
                    Spacer()
                } else if let error = vm.errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "gift")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(error)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("wrappedError")
                    Spacer()
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(vm.cards.enumerated()), id: \.element.card) { offset, card in
                            Image(uiImage: card.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 16)
                                .tag(offset)
                                .accessibilityLabel(Text(cardTitle(card.card)))
                                .accessibilityIdentifier("wrappedCard_\(card.card.rawValue)")
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }

            VStack {
                Spacer()
                exportOverlay
            }
        }
        .statusBarHidden(true)
        .task { await vm.load() }
        .onChange(of: vm.year) { index = 0 }
        .onDisappear {
            vm.cancelExport()
            vm.discardExport()
        }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    private func cardTitle(_ card: WrappedCard) -> String {
        switch card {
        case .intro: String(localized: "Your year in photos")
        case .months: String(localized: "Month by month")
        case .people: String(localized: "Your people")
        case .places: String(localized: "My \(String(vm.year)) on the map")
        case .colors: String(localized: "Your year in colors")
        case .best: String(localized: "Your best shots")
        case .outro: String(localized: "That was your \(String(vm.year))")
        }
    }

    /// One bar per card, filled up to the card on screen.
    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(vm.cards.indices, id: \.self) { offset in
                Capsule()
                    .fill(offset <= index ? Color.white : Color.white.opacity(0.3))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
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
            .accessibilityIdentifier("wrappedCloseButton")

            Spacer()

            Menu {
                Picker("Year", selection: $vm.year) {
                    ForEach(vm.years, id: \.self) { year in
                        Text(verbatim: String(year)).tag(year)
                    }
                }
            } label: {
                Label {
                    Text(verbatim: "Wrapped \(vm.year)")
                } icon: {
                    Image(systemName: "gift")
                }
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .pvFloating(.pill)
            }
            .disabled(vm.isLoading || vm.exportState != .idle)
            .accessibilityLabel("Year")
            .accessibilityIdentifier("wrappedYearMenu")

            Spacer()

            Menu {
                Button {
                    vm.saveImages()
                } label: {
                    Label("Save Images", systemImage: "photo.on.rectangle")
                }
                Button {
                    vm.saveVideo()
                } label: {
                    Label("Save Video", systemImage: "film")
                }
                Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .pvFloating(.circle)
            }
            .disabled(vm.cards.isEmpty || vm.exportState != .idle)
            .accessibilityLabel("Save")
            .accessibilityIdentifier("wrappedSaveMenu")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    /// The story is in the photo library: share it straight away.
    private var savedOverlay: some View {
        VStack(spacing: 14) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
                .foregroundStyle(.white)
            Text("Your Wrapped was added to your photo library.")
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
                    .accessibilityIdentifier("wrappedShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("wrappedSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("wrappedSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
