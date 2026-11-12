import SwiftUI

/// Custom segmented control for the Search tab's mode selector, styled to the
/// Immich design language. Three modes: **Résultats** (results) · **Explorer**
/// (curated suggestions) · **Carte** (map).
///
/// Custom SwiftUI control (not the native `UISegmentedControl`): the native
/// picker has a fixed height, shows one title *or* one image per segment, and
/// its sliding highlight cannot be animated off. This replacement gives us a
/// taller control (44 pt), an icon + label per segment, and an indicator that
/// **snaps instantly** — no slide animation on segment change.
struct SearchModeGlassBar: View {
    @PVReduceMotion private var reduceMotion
    @Binding var mode: SearchViewModel.ViewMode

    /// Bumped on each mode change so `.sensoryFeedback` re-fires. Mirrors the
    /// TimelineView.swift:155 selection-tick pattern (native API, no UIKit).
    @State private var modeChangeTick = 0

    static let height: CGFloat = 44
    private static let segments: [(mode: SearchViewModel.ViewMode, title: LocalizedStringKey, icon: String)] = [
        (.results, "Results", "magnifyingglass"),
        (.explore, "Explorer", "sparkles"),
        (.map, "Map", "map"),
    ]

    var body: some View {
        GlassEffectContainer {
            GeometryReader { geo in
                let segmentWidth = geo.size.width / CGFloat(Self.segments.count)
                let selectedIndex = Self.segments.firstIndex { $0.mode == mode } ?? 0

                ZStack(alignment: .leading) {
                    // Highlight thumb — smooth slide between segments.
                    Capsule()
                        .fill(PVFloating.selection)
                        .frame(
                            width: segmentWidth - PVSpacing.s8,
                            height: Self.height - PVSpacing.s8
                        )
                        .offset(x: PVSpacing.s4 + CGFloat(selectedIndex) * segmentWidth)
                        .animation(PVMotion.movement(.easeOut(duration: 0.2), reduceMotion: reduceMotion), value: selectedIndex)

                    // Segments.
                    HStack(spacing: 0) {
                        ForEach(Self.segments, id: \.mode) { segment in
                            segmentButton(segment)
                                .frame(width: segmentWidth, height: Self.height)
                        }
                    }
                }
            }
            .frame(height: Self.height)
            .pvFloating(.bar)
        }
        .appSensoryFeedback(.selection, trigger: modeChangeTick)
        .onChange(of: mode) { _, _ in
            modeChangeTick += 1
        }
    }

    private func segmentButton(
        _ segment: (mode: SearchViewModel.ViewMode, title: LocalizedStringKey, icon: String)
    ) -> some View {
        let isSelected = segment.mode == mode
        return Button {
            mode = segment.mode
        } label: {
            Label(segment.title, systemImage: segment.icon)
                .font(.pvSubhead)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? PVFloating.content : PVFloating.secondaryContent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(Self.identifier(for: segment.mode))
    }

    /// Non-localized handle of a segment, for UI scenarios.
    private static func identifier(for mode: SearchViewModel.ViewMode) -> String {
        switch mode {
        case .results: "searchModeSegment_results"
        case .explore: "searchModeSegment_explore"
        case .map: "searchModeSegment_map"
        }
    }
}

#Preview("SearchModeGlassBar") {
    @Previewable @State var mode: SearchViewModel.ViewMode = .explore
    return ZStack {
        LinearGradient(
            colors: [.blue, .purple, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        VStack {
            SearchModeGlassBar(mode: $mode)
                .padding(.horizontal, PVSpacing.s16)
            Spacer()
        }
        .padding(.top, PVSpacing.s24)
    }
}
