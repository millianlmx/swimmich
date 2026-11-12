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

    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let segments: [(mode: SearchViewModel.ViewMode, title: LocalizedStringKey, icon: String)] = [
        (.results, "Results", "magnifyingglass"),
        (.explore, "Explorer", "sparkles"),
        (.map, "Map", "map"),
    ]

    private var stacksSegments: Bool { dynamicTypeSize.isAccessibilitySize }
    private var showsTitleOnly: Bool { dynamicTypeSize >= .xxLarge }

    var body: some View {
        GlassEffectContainer {
            segmentLayout
                .pvFloating(.bar)
        }
        .appSensoryFeedback(.selection, trigger: modeChangeTick)
        .onChange(of: mode) { _, _ in
            modeChangeTick += 1
        }
    }

    /// Three segments side by side; stacked in a column at accessibility sizes,
    /// where a row cannot hold three wrapped labels.
    private var segmentLayout: some View {
        let layout = stacksSegments
            ? AnyLayout(VStackLayout(spacing: PVSpacing.s4))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            ForEach(Self.segments, id: \.mode) { segment in
                segmentButton(segment)
            }
        }
    }

    private func segmentButton(
        _ segment: (mode: SearchViewModel.ViewMode, title: LocalizedStringKey, icon: String)
    ) -> some View {
        let isSelected = segment.mode == mode
        return Button {
            mode = segment.mode
        } label: {
            segmentLabel(segment)
                .font(.pvSubhead)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? PVFloating.content : PVFloating.secondaryContent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PVSpacing.s8)
                .frame(maxWidth: .infinity, minHeight: height)
                .background {
                    // The selected segment carries its own capsule: it snaps,
                    // it does not slide.
                    if isSelected {
                        Capsule()
                            .fill(PVFloating.selection)
                            .padding(PVSpacing.s4)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The label view is built per text size (title only from xxLarge): the
        // button says its mode whatever the layout.
        .accessibilityLabel(segment.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(Self.identifier(for: segment.mode))
    }

    @ViewBuilder
    private func segmentLabel(
        _ segment: (mode: SearchViewModel.ViewMode, title: LocalizedStringKey, icon: String)
    ) -> some View {
        if showsTitleOnly {
            Label(segment.title, systemImage: segment.icon)
                .labelStyle(.titleOnly)
        } else {
            Label(segment.title, systemImage: segment.icon)
        }
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
