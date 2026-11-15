import SwiftUI

// MARK: - InlineWarningBadge
//
// Non-blocking notice for the onboarding forms (L-28): same template as
// `InlineErrorBadge`, in the warning color, with no action — it informs, the
// form below stays usable.

/// Card-style warning banner.
struct InlineWarningBadge: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PVSpacing.s12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.immichWarning)
                .accessibilityHidden(true)

            Text(message)
                .font(.pvSubhead)
                .foregroundStyle(Color.immichWarning)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(PVSpacing.s12)
        .background(Color.immichWarning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
