import SwiftUI

/// Last page of the memories playback: "All caught up" with a "Start Over" that
/// goes back to the first memory (mirrors the official client's
/// `MemoryEpilogue(onStartOver)`).
struct MemoryEpilogueView: View {
    let playback: MemoryPlaybackViewModel
    /// The device's safe-area insets: the page itself extends under them.
    let safeInsets: EdgeInsets

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black

            VStack(spacing: PVSpacing.s16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.immichPrimary)
                    .accessibilityHidden(true)
                Text("All caught up")
                    .font(.pvH3)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Check back tomorrow for more memories")
                    .font(.pvBody)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Button("Start Over") {
                    playback.restart()
                }
                .buttonStyle(PVPrimaryButtonStyle())
                .padding(.top, PVSpacing.s8)
                .accessibilityIdentifier("memoriesStartOverButton")
            }
            .padding(.horizontal, PVSpacing.s32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("memoriesEpilogue")

            GlassEffectContainer {
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
                .accessibilityLabel(String(localized: "Close memory"))
                .accessibilityIdentifier("memoriesEpilogueClose")
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.top, safeInsets.top + PVSpacing.s8)
        }
    }
}
