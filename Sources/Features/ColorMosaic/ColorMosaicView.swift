import SwiftUI

/// Full-screen color mosaic: the album's photos as one picture, sorted by
/// color or by date, previewed at the format it is exported in. Each cell
/// shows the photo's color until its thumbnail is in.
struct ColorMosaicView: View {
    @Bindable var vm: ColorMosaicViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                topBar
                Spacer(minLength: 0)
                if let layout = vm.layout {
                    preview(layout)
                        .padding(.horizontal, 16)
                } else if let message = vm.missingPhotosMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "square.grid.3x3.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text(message)
                            .font(.pvSubhead)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("colorMosaicTooFew")
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
        .onDisappear { vm.cancel() }
        .alert("Export failed", isPresented: failedAlertBinding) {
            Button("OK", role: .cancel) { vm.dismissExportResult() }
        } message: {
            if case .failed(let message) = vm.exportState {
                Text(message)
            }
        }
    }

    // MARK: - Preview

    /// The mosaic at the format's shape, as large as the screen allows.
    private func preview(_ layout: MosaicLayout) -> some View {
        let size = vm.format.pixelSize
        return VStack(spacing: 0) {
            ForEach(0..<layout.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<layout.columns, id: \.self) { column in
                        cell(layout.cells[row * layout.columns + column])
                    }
                }
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .overlay(alignment: .bottom) {
            if vm.showsCredit {
                Text("Made with Swimmich")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.bottom, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.35), value: layout)
        .accessibilityElement()
        .accessibilityLabel(Text("Color mosaic of \(layout.cells.count) photos"))
        .accessibilityIdentifier("colorMosaicPreview")
    }

    private func cell(_ tile: MosaicTile) -> some View {
        Color(red: tile.color.red, green: tile.color.green, blue: tile.color.blue)
            .overlay {
                if let image = vm.image(for: tile) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeIn(duration: 0.25), value: vm.image(for: tile) != nil)
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
            .accessibilityIdentifier("colorMosaicCloseButton")

            Spacer()

            Label("Color Mosaic", systemImage: "square.grid.3x3.fill")
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
            .disabled(vm.layout == nil || vm.exportState == .rendering)
            .accessibilityLabel("Save image")
            .accessibilityIdentifier("colorMosaicExportButton")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Arrangement", selection: $vm.arrangement) {
                ForEach(MosaicArrangement.allCases) { arrangement in
                    Text(arrangement.title).tag(arrangement)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("colorMosaicArrangement")

            Picker("Format", selection: $vm.format) {
                ForEach(MosaicFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("colorMosaicFormat")

            Toggle("Show “Made with Swimmich”", isOn: $vm.showsCredit)
                .font(.pvSubhead)
                .foregroundStyle(.white)
                .accessibilityIdentifier("colorMosaicCreditToggle")
        }
        .padding(16)
        .pvFloating(.bar)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The picture is in the photo library: share it straight away.
    private var savedOverlay: some View {
        VStack(spacing: 14) {
            Label("Image saved", systemImage: "checkmark.circle.fill")
                .font(.pvHeadline)
                .foregroundStyle(.white)
            Text("The mosaic was added to your photo library.")
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
                    .accessibilityIdentifier("colorMosaicShareButton")
                }
                Button("OK") { vm.dismissExportResult() }
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("colorMosaicSavedOKButton")
            }
        }
        .padding(24)
        .pvFloating(.bar)
        .padding(.horizontal, 24)
        .padding(.bottom, 60)
        .accessibilityIdentifier("colorMosaicSaved")
    }

    private var failedAlertBinding: Binding<Bool> {
        Binding(get: { if case .failed = vm.exportState { return true } else { return false } },
                set: { if !$0 { vm.dismissExportResult() } })
    }
}
