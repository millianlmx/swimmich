import SwiftUI

/// A partner row. The action depends on which side of the relation the row
/// came from, because the two mutations the server exposes do not apply to the
/// same rows (see `PartnersViewModel`) — a row therefore renders **either** the
/// timeline switch **or** the remove button, never both.
///
/// Try-then-mutate lives in the view model: the switch reads server state and
/// flips only once the `PUT` succeeded, so a failure leaves it where it was.
struct PartnerRow: View {
    enum Mode {
        /// From `getPartners(direction: .sharedWith)` — the partner shares their
        /// library with me, so I control whether it shows in my timeline.
        case incoming
        /// From `getPartners(direction: .sharedBy)` — I share with them, so the
        /// only action is to stop.
        case outgoing
    }

    let partner: PartnerResponseDto
    let mode: Mode
    /// Required for `.incoming`, ignored otherwise.
    var onToggle: ((Bool) -> Void)?
    /// Required for `.outgoing`, ignored otherwise.
    var onRemove: (() -> Void)?
    /// Opens the partner's library. Set only for rows that can: when `nil`
    /// the identity zone is plain text.
    var onOpenLibrary: (() -> Void)?

    init(
        partner: PartnerResponseDto,
        mode: Mode,
        onToggle: ((Bool) -> Void)? = nil,
        onRemove: (() -> Void)? = nil,
        onOpenLibrary: (() -> Void)? = nil
    ) {
        self.partner = partner
        self.mode = mode
        self.onToggle = onToggle
        self.onRemove = onRemove
        self.onOpenLibrary = onOpenLibrary
    }

    var body: some View {
        HStack(spacing: PVSpacing.s12) {
            if let onOpenLibrary {
                Button(action: onOpenLibrary) {
                    HStack(spacing: PVSpacing.s12) {
                        identity
                        Spacer(minLength: PVSpacing.s8)
                        Image(systemName: "chevron.right")
                            .font(.pvCaption)
                            .foregroundStyle(Color.textTertiaryPV)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows their photos")
                .accessibilityIdentifier("partnerLibraryLink-\(partner.id)")
            } else {
                identity
                Spacer(minLength: PVSpacing.s8)
            }
            action
        }
        .padding(.vertical, PVSpacing.s4)
    }

    /// Avatar, name and subtitle — the zone that opens the partner's library
    /// when `onOpenLibrary` is set, plain text otherwise.
    private var identity: some View {
        HStack(spacing: PVSpacing.s12) {
            PartnerAvatarCircle(partner: partner)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(partner.name)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                    // Inside the open-library button the text merges into the
                    // button's own element, which carries its identifier.
                    .accessibilityIdentifier(onOpenLibrary == nil ? "partnerName-\(partner.id)" : "")
                Text(subtitle)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        switch mode {
        case .incoming: partner.inTimeline ? "Shown in timeline" : "Hidden from timeline"
        case .outgoing: partner.email
        }
    }

    @ViewBuilder
    private var action: some View {
        switch mode {
        case .incoming:
            Toggle("Show in timeline", isOn: Binding(
                get: { partner.inTimeline },
                set: { onToggle?($0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show in timeline")
            .accessibilityIdentifier("partnerTimelineToggle-\(partner.id)")

        case .outgoing:
            Button {
                onRemove?()
            } label: {
                Image(systemName: "trash")
                    .font(.pvBody)
                    .foregroundStyle(Color.immichError)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop sharing with \(partner.name)")
            .accessibilityIdentifier("partnerRemove-\(partner.id)")
        }
    }
}

/// Initials avatar for a partner, same look as `UserAvatarCircle` (avatarColor
/// hex, fallback primary) — partners carry their own DTO shape, so the view is
/// separate, but the initials rule is shared with `UserAvatarCircle.initials`.
struct PartnerAvatarCircle: View {
    let partner: PartnerResponseDto
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: partner.avatarColor) ?? Color.immichPrimary)
            Text(UserAvatarCircle.initials(from: partner.name))
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
    }
}
