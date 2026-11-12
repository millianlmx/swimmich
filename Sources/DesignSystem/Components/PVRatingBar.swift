import SwiftUI

// MARK: - PVRatingBar
//
// Five 44 pt targets answering one question: how many stars, and how to take
// them back. `rating` is `nil` when the asset is unrated — never `0`: the
// server only accepts `1...5`, `-1` (rejected, never written from here) and
// `null`, so five hollow stars ("not rated") and one filled star ("rated 1")
// must stay visually and semantically distinct.

struct PVRatingBar: View {
    /// Current rating (1...5); `nil` = not rated.
    let rating: Int?
    /// False while the server round-trip is in flight: the bar stays legible
    /// but stops accepting taps instead of queueing them.
    var isEnabled: Bool = true
    var onRate: (Int) -> Void
    var onClear: () -> Void
    @PVReduceMotion private var reduceMotion

    var body: some View {
        HStack(spacing: PVSpacing.s4) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    // Re-tapping the current star clears the rating — the same
                    // gesture `rating_bar.widget.dart` maps to `onClearRating`.
                    if value == rating { onClear() } else { onRate(value) }
                } label: {
                    Image(systemName: value <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: 28))
                        .foregroundStyle(value <= (rating ?? 0) ? Color.immichPrimary : Color.textSecondaryPV)
                        .frame(width: 44, height: 44)
                        .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("assetRatingStar_\(value)")
                .accessibilityLabel(Self.starLabel(value: value, rating: rating))
                .accessibilityAddTraits(Self.isStarSelected(value: value, rating: rating) ? .isSelected : [])
            }
        }
        // Disabling the container disables every star: one in-flight write at a
        // time, no queued taps.
        .disabled(!isEnabled)
        .dimmedWhileBusy(!isEnabled)
        // `.contain` keeps the five stars addressable as separate elements:
        // a bare identifier on the container would swallow theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assetRatingBar")
        .animation(PVMotion.fading(PVMotion.snappy, reduceMotion: reduceMotion), value: isEnabled)
        .appSensoryFeedback(.selection, trigger: rating)
    }

    /// Spoken action of star `value`: the current rank takes the rating back,
    /// any other posts its own rank (the catalog agrees the plural).
    static func starLabel(value: Int, rating: Int?, bundle: Bundle = .main, locale: Locale = .current) -> String {
        if value == rating { return String(localized: "Remove rating", bundle: bundle, locale: locale) }
        return String(localized: "Rate \(value) stars", bundle: bundle, locale: locale)
    }

    /// Stars 1…rating are selected; an unrated asset selects none.
    static func isStarSelected(value: Int, rating: Int?) -> Bool {
        value <= (rating ?? 0)
    }
}

private extension View {
    /// While the rating write is in flight the bar is dimmed to half and stops
    /// accepting taps. The `@ViewBuilder` branch keeps the fade off the enabled
    /// path instead of layering a full-opacity modifier on every render.
    @ViewBuilder
    func dimmedWhileBusy(_ isBusy: Bool) -> some View {
        if isBusy { opacity(0.5) } else { self }
    }
}
