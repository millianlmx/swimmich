import SwiftUI

/// The places photographed years apart, the widest gap first. Pushed from
/// Memories.
struct ThenAndNowListView: View {
    @Bindable var vm: ThenAndNowViewModel

    var body: some View {
        Group {
            if vm.isLoading {
                VStack(spacing: 12) {
                    ProgressView(value: vm.progress)
                        .frame(width: 220)
                    Text("Finding the places you came back to…")
                        .font(.pvSubhead)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thenAndNowLoading")
            } else if let error = vm.errorMessage, vm.spots.isEmpty {
                ContentUnavailableView {
                    Label("Then & Now", systemImage: "clock.arrow.2.circlepath")
                } description: {
                    Text(error)
                }
                .accessibilityIdentifier("thenAndNowEmpty")
            } else {
                List(vm.spots) { spot in
                    NavigationLink {
                        ThenAndNowCompareView(vm: vm.pairViewModel(for: spot))
                    } label: {
                        row(spot)
                    }
                    .accessibilityLabel(Text(verbatim: "\(spot.place ?? String(localized: "Unknown place")), \(spot.thenYear) → \(spot.nowYear)"))
                    .accessibilityIdentifier("thenAndNowSpot_\(spot.id)")
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Then & Now")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    private func row(_ spot: ThenNowSpot) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                thumbnail(spot.thenIDs.first)
                thumbnail(spot.nowIDs.last)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: spot.place ?? String(localized: "Unknown place"))
                    .font(.pvSubhead.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: "\(spot.thenYear) → \(spot.nowYear)")
                    .font(.pvCaption)
                    .foregroundStyle(.secondary)
                Text("\(spot.yearGap) years apart")
                    .font(.pvCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func thumbnail(_ id: String?) -> some View {
        Color.gray.opacity(0.15)
            .frame(width: 56, height: 56)
            .overlay {
                if let id {
                    AuthenticatedAsyncImage(url: vm.thumbnailURL(for: id), token: vm.token, contentMode: .fill)
                }
            }
            .clipped()
    }
}

/// One spot, then and now: drag across the picture to sweep from one year to
/// the other (the same wipe the video plays), save the stacked image or the
/// video, or try another pair of photos.
struct ThenAndNowCompareView: View {
    @Bindable var vm: ThenAndNowPairViewModel
    /// The share of the picture the now photo covers, from the left.
    @State private var wipe = 0.5

    /// The picture's pixels: the film's shape, sharp at the screen's size.
    private static let pictureSize = CGSize(width: 720, height: 1280)

    var body: some View {
        VStack(spacing: 16) {
            if vm.isPreparing {
                Spacer()
                ProgressView("Picking the pair that matches best…")
                    .accessibilityIdentifier("thenAndNowPreparing")
                Spacer()
            } else if let then = vm.then, let now = vm.now {
                picture(then: then, now: now)
                choices(year: then.year, ids: vm.thenChoices, chosen: then.id)
                choices(year: now.year, ids: vm.nowChoices, chosen: now.id)
                controls
            } else if let error = vm.errorMessage {
                Spacer()
                Text(error)
                    .font(.pvSubhead)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
        }
        .padding(16)
        .navigationTitle(vm.spot.place ?? String(localized: "Then & Now"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.prepare() }
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
        .sheet(isPresented: savedBinding) { savedSheet }
    }

    private func picture(then: ThenNowPhoto, now: ThenNowPhoto) -> some View {
        GeometryReader { proxy in
            Image(uiImage: ThenAndNowRenderer.wipeImage(then: then, now: now, wipe: wipe, size: Self.pictureSize))
                .resizable()
                .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                wipe = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
            })
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("\(String(then.year)) and \(String(now.year))"))
        .accessibilityValue(Text(wipe.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: wipe = min(wipe + 0.1, 1)
            case .decrement: wipe = max(wipe - 0.1, 0)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("thenAndNowPicture")
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if case .rendering(let progress) = vm.exportState {
                HStack {
                    ProgressView(value: progress)
                    Button("Cancel") { vm.cancelExport() }
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        vm.saveImage()
                    } label: {
                        Label("Save Image", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("thenAndNowSaveImage")
                    Button {
                        vm.saveVideo()
                    } label: {
                        Label("Save Video", systemImage: "film")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("thenAndNowSaveVideo")
                }
                .disabled(vm.exportState != .idle)
            }
            HStack {
                Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
                    .font(.pvSubhead)
            }
        }
    }

    /// The photos of one year in a row: a tap puts one in the picture.
    private func choices(year: Int, ids: [String], chosen: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: String(year))
                .font(.pvCaption.weight(.bold))
                .frame(width: 40, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        let selected = id == chosen || id == vm.choosing
                        Button {
                            Task { await vm.choose(id) }
                        } label: {
                            Color.gray.opacity(0.15)
                                .frame(width: 52, height: 52)
                                .overlay {
                                    AuthenticatedAsyncImage(url: vm.thumbnailURL(for: id), token: vm.token, contentMode: .fill)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
                                }
                                .overlay {
                                    if id == vm.choosing { ProgressView() }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Photo from \(String(year))"))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("thenAndNowChoice_\(id)")
                    }
                }
            }
        }
        .frame(height: 52)
    }

    private var savedSheet: some View {
        VStack(spacing: 14) {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
            Text("Then & now was added to your photo library.")
                .font(.pvCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = vm.exportedURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("thenAndNowShareButton")
            }
            Button("OK") { vm.dismissExportResult() }
                .accessibilityIdentifier("thenAndNowSavedOKButton")
        }
        .padding(24)
        .presentationDetents([.height(240)])
    }

    private var savedBinding: Binding<Bool> {
        Binding(get: { vm.exportState == .done }, set: { if !$0 { vm.dismissExportResult() } })
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
