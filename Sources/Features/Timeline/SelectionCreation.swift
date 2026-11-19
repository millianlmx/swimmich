import SwiftUI

/// What the Create menu of a selection opens, full-screen: one cover per
/// screen presents any of them.
enum SelectionCreation: Identifiable {
    case colorMosaic(ColorMosaicViewModel)
    case photoDump(PhotoDumpViewModel)
    case reel(ReelViewModel)

    var id: ObjectIdentifier {
        switch self {
        case .colorMosaic(let vm): ObjectIdentifier(vm)
        case .photoDump(let vm): ObjectIdentifier(vm)
        case .reel(let vm): ObjectIdentifier(vm)
        }
    }

    @MainActor
    static func colorMosaic(assets: [AssetReactItem], baseURL: URL?, token: String?) -> SelectionCreation {
        .colorMosaic(DependencyContainer.shared.makeColorMosaicViewModel(
            assets: assets, baseURL: baseURL ?? URL(string: "https://example.com")!, token: token
        ))
    }

    @MainActor
    static func photoDump(assets: [AssetReactItem], baseURL: URL?, token: String?) -> SelectionCreation {
        .photoDump(DependencyContainer.shared.makePhotoDumpViewModel(
            assets: assets, baseURL: baseURL ?? URL(string: "https://example.com")!, token: token
        ))
    }

    /// A reel of `assets`: `title` is an album's name, nil for a selection
    /// (the reel is titled by its years).
    @MainActor
    static func reel(assets: [AssetReactItem], title: String? = nil, baseURL: URL?, token: String?) -> SelectionCreation {
        .reel(DependencyContainer.shared.makeReelViewModel(
            assets: assets, title: title, ranked: false,
            baseURL: baseURL ?? URL(string: "https://example.com")!, token: token
        ))
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .colorMosaic(let vm): ColorMosaicView(vm: vm)
        case .photoDump(let vm): PhotoDumpView(vm: vm)
        case .reel(let vm): ReelView(vm: vm)
        }
    }
}

/// The Create menu of a selection: the color mosaic, the photo dump and the
/// reel of the selected photos.
struct SelectionCreateMenu: View {
    let isDisabled: Bool
    let open: (_ make: @MainActor ([AssetReactItem], URL?, String?) -> SelectionCreation) -> Void

    var body: some View {
        Menu {
            Button {
                open(SelectionCreation.colorMosaic)
            } label: {
                Label("Color Mosaic", systemImage: "square.grid.3x3.fill")
            }
            .accessibilityIdentifier("createColorMosaicButton")
            Button {
                open(SelectionCreation.photoDump)
            } label: {
                Label("Photo Dump", systemImage: "photo.stack")
            }
            .accessibilityIdentifier("createPhotoDumpButton")
            Button {
                open { assets, baseURL, token in SelectionCreation.reel(assets: assets, baseURL: baseURL, token: token) }
            } label: {
                Label("Reel", systemImage: "film.stack")
            }
            .accessibilityIdentifier("createReelButton")
        } label: {
            Label("Create", systemImage: "sparkles")
                .labelStyle(.iconOnly)
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("selectionCreateMenu")
    }
}
