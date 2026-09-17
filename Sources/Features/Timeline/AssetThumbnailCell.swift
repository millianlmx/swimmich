import SwiftUI

/// Thumbnail image cell for the timeline grid — Apple-Photos-grade.
///
/// Premium visual layers:
/// - **Uniform 1:1 square cells** (no ragged grid). Image fills + clips.
/// - **Uniform material-pill badges**: favorite (heart), video (play + mm:ss),
///   360° (equirectangular projection) — all share one capsule treatment.
/// - **Pro selection**: cell scales to 0.96, blue-tint overlay on selected,
///   near-imperceptible 0.08 dim on unselected, checkmark morphs via
///   `.contentTransition(.symbolEffect(.replace))` + `.symbolEffect(.bounce)`.
/// - `scrollTransition` parallax on cell CONTENT only (FM-3 mitigation).
/// - Context menu (Favorite toggle / Delete).
struct AssetThumbnailCell: View {
    let asset: AssetReactItem
    let baseURL: URL
    let token: String?

    /// Offline cache mirror (issue #18). Read from the environment rather than
    /// passed in: this cell is instantiated from six different grids, and a
    /// parameter would eventually be forgotten at one of them.
    @Environment(OfflineAssetIndex.self) private var offline: OfflineAssetIndex?

    /// Backup-state mirror (G6). Read from the environment for the same reason
    /// as `offline` above: seven grids instantiate this cell, and a parameter
    /// would eventually be forgotten at one of them.
    @Environment(CloudBackupStatusIndex.self) private var cloudStatus: CloudBackupStatusIndex?

    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onTap: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onDelete: () -> Void = {}
    var onArchive: (() -> Void)? = nil
    /// Locked folder (gap G12): moves this asset into the PIN-protected
    /// folder. Optional like `onArchive` — surfaces that show assets the user
    /// cannot lock (trash) leave it nil and get no menu entry.
    var onMoveToLockedFolder: (() -> Void)? = nil
    /// Trash-only callbacks. When `onRestore` is set, the context menu switches
    /// to Restore + Delete Permanently (AC-301 / AC-303). Callers that leave
    /// these `nil` keep the existing Favorite + Delete menu (TimelineView).
    var onRestore: (() -> Void)? = nil
    var onDeletePermanent: (() -> Void)? = nil

    /// Set when the grid shows a **public shared link** (issue #22) instead of
    /// the signed-in library. Two consequences, one cause: the visitor reads the
    /// asset without a bearer token, so the credential rides in the thumbnail
    /// URL, and the owner's actions (favorite / delete / archive) are not the
    /// visitor's to make — the server would reject them — so the context menu is
    /// not attached at all.
    var sharedLink: SharedLinkCredential? = nil

    /// Read-only galleries (the two "recent" consult screens, gap G13) turn the
    /// context menu off entirely: they leave the action closures at their empty
    /// defaults, so the menu they would otherwise get is a dead "Favorite /
    /// Delete". Additive with a default — the six existing grids are untouched.
    var contextMenuEnabled: Bool = true

    var body: some View {
        let url = asset.thumbnailURL(base: baseURL, sharedLink: sharedLink)

        // Square frame: Color.clear w/ aspectRatio(1,.fit) becomes a perfect
        // square sized to the column width. Image overlays fill + clip.
        let cell = Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AuthenticatedAsyncImage(
                    url: url,
                    token: token,
                    localFileURL: offline?.localURL(for: asset.id),
                    thumbhash: asset.thumbhash
                )
                    // Identifier on the image LAYER, never on the whole cell: an
                    // identifier on a container replaces its descendants', which
                    // would hide `stackBadge` / `offlineBadge` — the very
                    // elements the UI scenarios assert on.
                    .accessibilityIdentifier("assetTile_\(asset.id)")
                    .scrollTransition { content, phase in
                        // Parallax: scale + fade slightly as the cell exits viewport.
                        // Applied to image CONTENT only (FM-3), never the Section.
                        content
                            .scaleEffect(phase.isIdentity ? 1.0 : 0.94)
                            .opacity(phase.isIdentity ? 1.0 : 0.9)
                    }
            }
            .overlay { selectionTint }
            .overlay { favoriteBadge }
            .overlay(alignment: .topLeading) { topLeadingBadges }
            .overlay(alignment: .bottomLeading) { livePhotoBadge }
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .overlay(alignment: .bottomTrailing) { checkmark }
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.xs, style: .continuous))
            // Pro selection: selected cells recede slightly (scale 0.96) w/ spring.
            .scaleEffect(selectionMode && isSelected ? 0.96 : 1.0)
            .animation(PVMotion.snappy, value: isSelected)
            .animation(PVMotion.snappy, value: selectionMode)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

        // Context menu suppressed in selection mode: it would compete with the
        // long-press toggle gesture and its actions (delete/restore) make no
        // sense mid-selection (audit fix). Same for a public shared link — the
        // actions belong to the owner, not to the visitor — and for a grid that
        // asked for `contextMenuEnabled: false` (read-only galleries).
        if selectionMode || sharedLink != nil || !contextMenuEnabled {
            cell
        } else {
            cell.contextMenu {
                if let onRestore {
                    // Trash tab menu (AC-301 / AC-303).
                    Button {
                        onRestore()
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        onDeletePermanent?()
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                } else {
                    // Timeline menu (existing behaviour, AC-202 / AC-203).
                    Button {
                        onToggleFavorite()
                    } label: {
                        Label(
                            asset.isFavorite ? "Unfavorite" : "Favorite",
                            systemImage: asset.isFavorite ? "heart.slash" : "heart"
                        )
                    }
                    if let onArchive {
                        Button {
                            onArchive()
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                    if onMoveToLockedFolder != nil {
                        Button {
                            onMoveToLockedFolder?()
                        } label: {
                            Label("Move to Locked Folder", systemImage: "lock")
                        }
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Badges (uniform material-pill treatment, V4)

    /// Favorite heart — small material pill, top-trailing. Always visible in
    /// selection mode (users must see which photos are already liked) while
    /// the checkmark sits bottom-trailing on the selected cell (D1).
    @ViewBuilder
    private var favoriteBadge: some View {
        if asset.isFavorite {
            badge {
                Image(systemName: "heart.fill")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(4)
        }
    }

    /// 360° pill + stack cover — top-leading, stacked vertically when both
    /// apply (rare). A stacked tile is the stack's **cover**: the badge carries
    /// how many photos sit behind it (gap #1, Photos parity), since `withStacked`
    /// keeps only the primary in the bucket.
    @ViewBuilder
    private var topLeadingBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if asset.projectionType == "equirectangular" {
                badge { Text("360°") }
            }
            if isCachedOffline {
                offlineBadge
            }
            cloudBadge
            if asset.isStacked {
                badge {
                    HStack(spacing: 3) {
                        Image(systemName: "square.stack.fill").font(.system(size: 8)) // DS-exempt: badge micro-glyph §8.6
                        if let extra = asset.stackedExtraCount, extra > 0 {
                            Text("+\(extra)").monospacedDigit()
                        }
                    }
                }
                // One element, one sentence: the glyph and the count are a
                // single piece of information, not two.
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("stackBadge")
                .accessibilityLabel(accessibilityStackLabel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(4)
    }

    /// True when this asset's original is cached for offline viewing.
    private var isCachedOffline: Bool {
        offline?.isCached(asset.id) ?? false
    }

    /// Backup pill (G6) — top-leading, between the offline pill and the stack
    /// badge; draws nothing when the ledger has no answer for this asset.
    /// `asset.id` is a **server** UUID here, and an unknown one is not "not
    /// backed up": the tile may show a photo another device uploaded, so the
    /// absence of an answer stays an absence of a badge.
    @ViewBuilder
    private var cloudBadge: some View {
        if cloudStatus?.isEnabled == true,
           let status = cloudStatus?.status(forServerAssetID: asset.id) {
            badge {
                Image(systemName: status.systemImage).font(.system(size: 10)) // DS-exempt: badge micro-glyph §8.6
            }
            // One element, one sentence: the glyph is the whole badge, and its
            // meaning has to reach VoiceOver through the label rather than the
            // SF Symbol's name. The identifier goes on the badge itself — on
            // the enclosing `VStack` it would replace the children's own.
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(status == .uploaded ? "cloudBackedUpBadge" : "cloudLocalOnlyBadge")
            .accessibilityLabel(status.localizedLabel)
        }
    }

    /// Offline pill (issue #18) — top-leading, above the stack badge. Icon+text
    /// share one accessibility element: a label on the container would fold the
    /// children's own labels away, and a test then finds nothing.
    private var offlineBadge: some View {
        badge {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 10)) // DS-exempt: badge micro-glyph §8.6
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("offlineBadge")
        .accessibilityLabel("Available offline")
    }

    /// Spoken form of the stack badge ("5 photos in a stack").
    private var accessibilityStackLabel: String {
        guard let count = asset.stackCount else { return String(localized: "In a stack") }
        return count == 1
            ? String(localized: "1 photo in a stack")
            : String(localized: "\(count) photos in a stack")
    }

    /// Video play + duration — bottom-trailing. Hidden in selection mode:
    /// the checkmark owns the corner and the duration text would compete
    /// with it (Photos parity).
    @ViewBuilder
    private var videoBadge: some View {
        if asset.isVideo && !selectionMode {
            badge {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 8)) // DS-exempt: badge micro-glyph §8.6
                    if let d = asset.duration, d > 0 {
                        Text(Self.formattedDuration(d)).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(4)
        }
    }

    /// "LIVE" pill for Live Photos — bottom-leading (Photos parity; the video
    /// badge owns bottom-trailing). Hidden in selection mode with the others.
    @ViewBuilder
    private var livePhotoBadge: some View {
        if asset.livePhotoVideoId != nil && !selectionMode {
            badge {
                Text("LIVE")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(4)
        }
    }

    /// Shared capsule treatment — `.ultraThinMaterial` + thin border.
    /// All badges share this for visual consistency (V4 uniformity).
    @ViewBuilder
    private func badge<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .font(.pvCaption)
            .foregroundStyle(.white) // DS-exempt: badge contrast on material
            .padding(.horizontal, PVSpacing.s8)
            .padding(.vertical, 3) // DS-exempt: badge micro-padding
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5) // DS-exempt: micro-badge shadow
    }

    // MARK: - Selection (V5)

    /// Blue tint on selected, near-imperceptible dim on unselected (not the
    /// old 0.35 black crush).
    @ViewBuilder
    private var selectionTint: some View {
        if selectionMode {
            if isSelected {
                Color.immichPrimary.opacity(0.15)
            } else {
                Color.black.opacity(0.06) // DS-exempt: structural dim overlay
            }
        }
    }

    /// Checkmark morphs circle → checkmark.circle.fill via symbol replace.
    /// The bare `"circle"` SF Symbol is already a clean outline ring — no
    /// custom stroke overlay (avoids the double-circle defect D2).
    @ViewBuilder
    private var checkmark: some View {
        if selectionMode {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.pvHeadline)
                .symbolEffect(.bounce, value: isSelected)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isSelected ? Color.immichPrimary : Color.white) // DS-exempt: badge contrast on material (white branch)
                .shadow(color: .black.opacity(0.25), radius: 1.5) // DS-exempt: micro-badge shadow
                .padding(8)
                .accessibilityLabel(isSelected ? String(localized: "Selected") : String(localized: "Not selected"))
        }
    }

    /// mm:ss if ≥60s, else 0:ss (V11).
    static func formattedDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
