import Photos
import SwiftUI

/// One tile of the local library: the thumbnail, the selection ring and — only
/// once the server was actually asked — the "not on the server" chip.
///
/// The cell knows nothing about the photo library: the tile arrives as a closure
/// handed down by the screen, which is what keeps `PhotoLibraryService` a
/// ViewModel dependency instead of a cell one.
struct LocalAssetCell: View {
    let asset: PHAsset
    let isSelected: Bool
    /// nil == no verdict yet (the server has not been asked): the cell then shows
    /// NO chip, because "no answer" must never read as "already saved".
    let isLocalOnly: Bool?
    let onTap: () -> Void
    let loadThumbnail: (PHAsset) async -> UIImage?

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            tile
                .overlay(alignment: .topTrailing) { selectionBadge }
                .overlay(alignment: .bottomLeading) { localOnlyBadge }
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .pvTileTextCap()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("localAssetCell_\(asset.localIdentifier)")
        .accessibilityLabel(accessibilityLabel)
        .task(id: asset.localIdentifier) { image = await loadThumbnail(asset) }
    }

    /// The tile is square and clipped by the grid, so every row lines up whether
    /// the thumbnail arrived or the asset is an iCloud-only placeholder.
    @ViewBuilder
    private var tile: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .aspectRatio(1, contentMode: .fill)
                .clipped()
        } else {
            placeholder
        }
    }

    /// Shown while the tile is missing — no copy on device (`loadThumbnail` never
    /// touches the network) or not decoded yet. Kept visible with its legend
    /// rather than left blank: a hole in the grid reads as a bug, an evicted
    /// original is a fact about the library.
    private var placeholder: some View {
        ZStack {
            Color.bgSecondary
            VStack(spacing: PVSpacing.s4) {
                Image(systemName: "icloud.slash")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textSecondaryPV)
                Text("Not downloaded from iCloud")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textTertiaryPV)
                    .multilineTextAlignment(.center)
            }
            .padding(PVSpacing.s4)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.pvHeadline)
            .padding(PVSpacing.s4)
            .foregroundStyle(isSelected ? Color.immichPrimary : Color.textSecondaryPV)
            .accessibilityHidden(true)
    }

    /// The chip that says the server does not have this file. Absent both while
    /// no verdict was asked for (`nil`) and when the server has it (`false`).
    @ViewBuilder
    private var localOnlyBadge: some View {
        if isLocalOnly == true {
            Image(systemName: "arrow.up.circle.fill")
                .font(.pvHeadline)
                .padding(PVSpacing.s4)
                .foregroundStyle(Color.immichWarning)
                .accessibilityLabel("Not on the server")
        }
    }

    /// What VoiceOver reads for the whole tile: kind, selection and the verdict —
    /// the verdict only when there is one, so an unanswered tile is never read as
    /// saved.
    private var accessibilityLabel: String {
        var parts = [asset.mediaType == .video ? String(localized: "Video") : String(localized: "Photo")]
        if isSelected { parts.append(String(localized: "Selected")) }
        if let isLocalOnly {
            parts.append(isLocalOnly ? String(localized: "Not on the server") : String(localized: "On the server"))
        }
        return parts.joined(separator: ", ")
    }
}
