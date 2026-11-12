import SwiftUI

// MARK: - PVSkeletonGrid
//
// Animated skeleton placeholder grid — N rows × `columnCount` cols of square
// rounded rectangles with a horizontal gradient sweep (clear → white → clear)
// over `bgTertiary`. NOT a spinner. Used for first-load placeholders across
// grids (Timeline, Albums) so users see structure, not a bare `ProgressView`.
//
// Shared here so every grid screen gets identical shimmer treatment without
// each reinventing it. Promoted from TimelineView's private `SkeletonShimmerGrid`.

/// Animated shimmer skeleton for grid-based loading states.
struct PVSkeletonGrid: View {
    let rows: Int
    var columnCount: Int = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: columnCount)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
            ForEach(0..<(rows * columnCount), id: \.self) { _ in
                PVSkeletonCell()
            }
        }
    }
}

/// Single shimmer cell: square rounded rect with a narrow highlight band that
/// sweeps left → right indefinitely. The band is ~20% of the cell width for a
/// crisp sweep rather than a whole-cell brighten/dim (D4).
struct PVSkeletonCell: View {
    @State private var phase: CGFloat = -1.2
    @PVReduceMotion private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: PVRadius.xs, style: .continuous)
            .fill(Color.bgTertiary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if PVMotion.shimmerVisible(reduceMotion: reduceMotion) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.4),
                            .init(color: Color.white.opacity(0.4), location: 0.5),
                            .init(color: .clear, location: 0.6),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .offset(x: phase * 240)
                    .mask(RoundedRectangle(cornerRadius: PVRadius.xs, style: .continuous))
                }
            }
            .clipped()
            .onAppear { startShimmer() }
            .onChange(of: reduceMotion) { _, reduced in
                // Back to the start without animating, then loop again once motion is allowed.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = -1.2 }
                if !reduced { startShimmer() }
            }
    }

    /// Infinite shimmer loop; never started under Reduce Motion.
    private func startShimmer() {
        guard !reduceMotion else { return }
        withAnimation(PVMotion.shimmerLoop(duration: 1.5, reduceMotion: reduceMotion)) {
            phase = 1.2
        }
    }
}
