import SwiftUI

/// Brand palette for the backup Live Activity (matches `Color.immichPrimary`).
public let backupBrandStart = Color(red: 0.259, green: 0.314, blue: 0.686)
public let backupBrandEnd = Color(red: 0.486, green: 0.361, blue: 1.0)
public var backupBrandGradient: LinearGradient {
    LinearGradient(colors: [backupBrandStart, backupBrandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}
public let backupSuccessGreen = Color(red: 0.196, green: 0.780, blue: 0.349)
/// Success palette as a gradient, so ternaries stay one type.
public let backupSuccessGradient = LinearGradient(
    colors: [backupSuccessGreen, Color.teal],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

/// Phase glyph, shared by every backup surface (lock screen badge, compact
/// island ring, minimal island).
public func backupGlyphName(for state: BackupActivityAttributes.ContentState) -> String {
    switch state.phase {
    case .done: return state.failed == 0 ? "checkmark" : "exclamationmark"
    case .cancelled: return "stop.fill"
    default: return "icloud.and.arrow.up.fill"
    }
}

/// Bouncy app glyph — the dopamine beat: it pops on every processed asset.
public struct BackupGlyph: View {
    public let state: BackupActivityAttributes.ContentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: BackupActivityAttributes.ContentState) {
        self.state = state
    }

    private var glyphName: String { backupGlyphName(for: state) }

    private var tint: LinearGradient {
        switch state.phase {
        case .done where state.failed == 0:
            return backupSuccessGradient
        case .cancelled:
            return LinearGradient(colors: [.gray, .gray.opacity(0.6)],
                                  startPoint: .top, endPoint: .bottom)
        default:
            return backupBrandGradient
        }
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint)
                .frame(width: 34, height: 34)
            Image(systemName: glyphName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .speed(reduceMotion ? 0.4 : 1.4),
                              value: state.processed)
        }
        .accessibilityLabel(state.phase == .done ? "Backup complete" : "Backing up")
    }
}

/// Compact-island indicator: the glyph wrapped in a progress *contour* that
/// fills indigo clockwise as the backup advances. The compact presentation
/// has room for one glyph per side, so the ring around it carries the
/// progress — the island itself stays black instead of being flood-tinted.
///
/// Geometry matters here: the island's compact leading region butts against
/// the TrueDepth sensor, so the ring MUST paint inside its declared frame.
/// A centered `stroke` on a `Circle()` bleeds half a line width past the
/// frame — 22 pt of layout, 25 pt of ink — and that overhang is what slides
/// under the sensor and gets clipped. Hence `strokeBorder` / `inset(by:)`.
public struct BackupCompactRing: View {
    public let state: BackupActivityAttributes.ContentState
    public var diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: BackupActivityAttributes.ContentState, diameter: CGFloat = 20) {
        self.state = state
        self.diameter = diameter
    }

    private var lineWidth: CGFloat { diameter * 0.16 }

    private var succeeded: Bool { state.phase == .done && state.failed == 0 }

    /// Ring stroke follows the arc, not the frame: an angular gradient keeps the
    /// bright violet at the *leading* end of the contour, so a 5% arc reads as
    /// indigo just as clearly as a 90% one (a top-to-bottom linear gradient
    /// dims short arcs into the black pill). Angles are local to the circle —
    /// 0° is where `trim` starts, which the -90° rotation below puts at 12
    /// o'clock, so gradient and arc stay in phase.
    private var ringStyle: AnyShapeStyle {
        if succeeded { return AnyShapeStyle(backupSuccessGradient) }
        return AnyShapeStyle(AngularGradient(
            colors: [backupBrandEnd, backupBrandStart, backupBrandEnd],
            center: .center,
            startAngle: .zero, endAngle: .degrees(360)
        ))
    }

    /// A hair of fill at 0 so the contour is legible the moment the island
    /// appears (the scan phase has no denominator yet).
    private var filled: Double { max(0.04, min(1, state.progress)) }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: filled)
                .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15),
                           value: state.progress)
            Image(systemName: backupGlyphName(for: state))
                .font(.system(size: diameter * 0.40, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, options: .speed(reduceMotion ? 0.4 : 1.4),
                              value: state.processed)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Backing up, \(Int((state.progress * 100).rounded())) percent")
    }
}

/// One-line status for the island's center region.
public func backupIslandSubtitle(_ state: BackupActivityAttributes.ContentState) -> String {
    switch state.phase {
    case .checking: return "Scanning…"
    case .uploading: return state.fileName ?? "Uploading…"
    case .done: return state.failed == 0 ? "All done" : "\(state.failed) failed"
    case .cancelled: return "Cancelled"
    }
}

/// Trailing expanded region: big animated percent + count.
public struct BackupIslandTrailing: View {
    public let state: BackupActivityAttributes.ContentState

    public init(state: BackupActivityAttributes.ContentState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            BackupPercent(progress: state.progress, size: 24)
            Text("\(state.processed) of \(state.total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(state.processed)))
        }
    }
}

/// Center expanded region: file in flight + live ETA countdown.
public struct BackupIslandCenter: View {
    public let state: BackupActivityAttributes.ContentState

    public init(state: BackupActivityAttributes.ContentState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 3) {
            Text(backupIslandSubtitle(state))
                .font(.caption)
                .lineLimit(1)
            if state.phase == .uploading {
                BackupETA(estimatedDone: state.estimatedDone)
            }
        }
    }
}

/// Bottom expanded region: the real progress bar. Expanded has the width for
/// a determinate bar, so that — not the compact ring — is the primary progress
/// read, with the outcome chips underneath.
public struct BackupIslandBottom: View {
    public let state: BackupActivityAttributes.ContentState

    public init(state: BackupActivityAttributes.ContentState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 6) {
            BackupProgressBar(progress: state.progress, height: 10)
            HStack(spacing: 5) {
                if state.uploaded > 0 { chip(count: state.uploaded, tint: .green) }
                if state.onServer > 0 { chip(count: state.onServer, tint: .white.opacity(0.7)) }
                if state.waiting > 0 { chip(count: state.waiting, tint: .orange) }
                if state.failed > 0 { chip(count: state.failed, tint: .red) }
            }
        }
        .padding(.horizontal, 8)
    }

    private func chip(count: Int, tint: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
    }
}

/// Animated percentage — numeric roll on every tick.
public struct BackupPercent: View {
    public let progress: Double
    public var size: CGFloat = 30

    public init(progress: Double, size: CGFloat = 30) {
        self.progress = progress
        self.size = size
    }

    public var body: some View {
        Text("\(Int((progress * 100).rounded()))%")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: progress))
            .animation(.spring(duration: 0.4, bounce: 0.3), value: progress)
            .accessibilityLabel("\(Int((progress * 100).rounded())) percent")
    }
}

/// Gradient capsule progress bar with a spring settle per tick.
public struct BackupProgressBar: View {
    public let progress: Double
    public var height: CGFloat

    public init(progress: Double, height: CGFloat = 7) {
        self.progress = progress
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(backupBrandGradient)
                    .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5, bounce: 0.15), value: progress)
    }
}

/// Live countdown to the estimated end of the upload phase.
public struct BackupETA: View {
    public let estimatedDone: Date?

    public init(estimatedDone: Date?) {
        self.estimatedDone = estimatedDone
    }

    public var body: some View {
        if let eta = estimatedDone, eta > Date.now {
            Label {
                // Valid countdown range: now...end (lowerBound <= upperBound);
                // countsDown displays the time remaining until `eta`.
                Text(timerInterval: Date.now...eta, countsDown: true)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Lock Screen rendering of the backup Live Activity: brand gradient glyph
/// with a bounce per processed asset, animated percentage, spring progress
/// bar, outcome chips, a live ETA countdown, and a green completion
/// celebration. Motion sticks to primitives Live Activities support — no
/// `repeatForever`, no island-to-island transitions.
public struct BackupLockScreenView: View {
    public let state: BackupActivityAttributes.ContentState

    public init(state: BackupActivityAttributes.ContentState) {
        self.state = state
    }

    private var subtitle: String {
        switch state.phase {
        case .checking: return "Scanning your library…"
        case .uploading:
            return state.fileName ?? "Uploading your memories…"
        case .done:
            return state.failed == 0 ? "Backup complete — library safe"
                                     : "Finished with \(state.failed) failed"
        case .cancelled: return "Backup cancelled"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                BackupGlyph(state: state)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Swimmich Backup")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if state.phase != .done && state.phase != .cancelled {
                    BackupPercent(progress: state.progress)
                }
            }
            BackupProgressBar(progress: state.progress)
            footer
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swimmich backup, \(state.processed) of \(state.total), \(subtitle)")
    }

    @ViewBuilder
    private var footer: some View {
        if state.phase == .done {
            Label(
                state.failed == 0
                    ? "\(state.uploaded) photos safe on Immich"
                    : "\(state.uploaded) uploaded · \(state.failed) failed",
                systemImage: state.failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state.failed == 0 ? backupSuccessGreen : .orange)
        } else {
            HStack(spacing: 6) {
                statusChips
                Spacer(minLength: 8)
                if state.phase == .uploading {
                    BackupETA(estimatedDone: state.estimatedDone)
                }
            }
        }
    }

    @ViewBuilder
    private var statusChips: some View {
        if state.uploaded > 0 { chip(icon: "arrow.up.circle.fill", count: state.uploaded, tint: .green) }
        if state.onServer > 0 { chip(icon: "checkmark.circle.fill", count: state.onServer, tint: .white.opacity(0.7)) }
        if state.waiting > 0 { chip(icon: "icloud.and.arrow.down", count: state.waiting, tint: .orange) }
        if state.failed > 0 { chip(icon: "xmark.circle.fill", count: state.failed, tint: .red) }
    }

    private func chip(icon: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text("\(count)").monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
    }
}

// MARK: - Previews

#Preview("Lock screen — uploading", traits: .fixedLayout(width: 360, height: 130)) {
    BackupLockScreenView(state: BackupActivityAttributes.ContentState(
        progress: 0.62, processed: 62, total: 100,
        uploaded: 48, onServer: 10, waiting: 3, failed: 1,
        phase: .uploading, fileName: "IMG_2314.HEIC",
        estimatedDone: Date.now.addingTimeInterval(95)
    ))
}

#Preview("Lock screen — checking", traits: .fixedLayout(width: 360, height: 130)) {
    BackupLockScreenView(state: BackupActivityAttributes.ContentState(
        progress: 0, processed: 0, total: 0,
        uploaded: 0, onServer: 0, waiting: 0, failed: 0,
        phase: .checking, fileName: nil, estimatedDone: nil
    ))
}

#Preview("Lock screen — done", traits: .fixedLayout(width: 360, height: 130)) {
    BackupLockScreenView(state: BackupActivityAttributes.ContentState(
        progress: 1, processed: 100, total: 100,
        uploaded: 87, onServer: 13, waiting: 0, failed: 0,
        phase: .done, fileName: nil, estimatedDone: nil
    ))
}

/// Mock of the compact Dynamic Island pill — the real regions only render on
/// device, so this composes them the same way `BackupLiveActivity` does
/// (ring leading, percent trailing, indigo keyline) to check the look.
#Preview("Island compact", traits: .fixedLayout(width: 300, height: 250)) {
    VStack(spacing: 14) {
        ForEach([0.0, 0.38, 0.87, 1.0], id: \.self) { p in
            HStack(spacing: 8) {
                BackupCompactRing(state: BackupActivityAttributes.ContentState(
                    progress: p, processed: Int(p * 100), total: 100,
                    uploaded: Int(p * 90), onServer: 0, waiting: 0, failed: 0,
                    phase: p >= 1 ? .done : (p == 0 ? .checking : .uploading),
                    fileName: nil, estimatedDone: nil
                ))
                Spacer(minLength: 26)
                BackupPercent(progress: p, size: 14).foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .frame(width: 220, height: 36)
            .background(Capsule().fill(.black))
            .overlay(Capsule().stroke(backupBrandEnd.opacity(0.9), lineWidth: 1.5))
        }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.12))
}

/// Mock of the expanded Dynamic Island — same region composition as
/// `BackupLiveActivity` (glyph leading, percent trailing, file/ETA center,
/// real progress bar bottom).
#Preview("Island expanded", traits: .fixedLayout(width: 380, height: 200)) {
    let state = BackupActivityAttributes.ContentState(
        progress: 0.62, processed: 62, total: 100,
        uploaded: 48, onServer: 10, waiting: 3, failed: 1,
        phase: .uploading, fileName: "IMG_2314.HEIC",
        estimatedDone: Date.now.addingTimeInterval(95)
    )
    return VStack(spacing: 10) {
        HStack(alignment: .center) {
            BackupGlyph(state: state)
            Spacer(minLength: 10)
            BackupIslandCenter(state: state)
            Spacer(minLength: 10)
            BackupIslandTrailing(state: state)
        }
        BackupIslandBottom(state: state)
    }
    .padding(16)
    .frame(width: 340)
    .background(RoundedRectangle(cornerRadius: 42, style: .continuous).fill(.black))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.12))
    .environment(\.colorScheme, .dark)
}
