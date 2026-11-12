import SwiftUI

/// Floating download capsule (gap G10): how much of what you asked for is
/// done, visible from every tab.
///
/// It owns **no state**: the view model holds the queue, this view reads it.
/// The whole capsule is a single `Button` — opening the detail screen is the
/// panel's action, and a button nested in a button is inert (the measured
/// `AssetThumbnailCell` trap), so nothing inside is interactive.
struct DownloadProgressPanel: View {
    @PVReduceMotion private var reduceMotion
    let vm: DownloadQueueViewModel
    let onOpenInfo: () -> Void

    var body: some View {
        Button(action: onOpenInfo) {
            HStack(spacing: PVSpacing.s8) {
                Image(systemName: "arrow.down.circle")
                    .font(.pvHeadline)
                Text("\(vm.completedCount) of \(vm.totalCount)")
                    .font(.pvSubhead)
                    .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                    .accessibilityIdentifier("downloadPanelSummary")
                // No bar when no row knows its length: the count stays true,
                // a frozen 0 % bar would not.
                if let fraction = vm.aggregateProgress {
                    ProgressView(value: fraction)
                        .tint(PVFloating.content)
                        .frame(width: 72)
                        .accessibilityIdentifier("downloadPanelProgress")
                }
                Image(systemName: "chevron.up")
                    .font(.pvCaption)
            }
            .padding(PVSpacing.s12)
            .pvFloating(.pill)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, PVSpacing.s16)
        .padding(.bottom, PVSpacing.s8)
        .accessibilityIdentifier("downloadPanel")
        // One element, one sentence: the panel must not read as three
        // fragments (title, count, bar) to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(vm.panelAccessibilityLabel)
    }
}
