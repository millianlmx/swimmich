import SwiftUI

/// Where the scrubber handle rests: the month it designates (0 = newest of the
/// served range) and how far into that month, in `[0, 1)`.
struct TimelineScrubPosition: Equatable {
    var monthIndex: Int
    var fraction: Double
}

/// A jump whose month failed to load, kept so "Try Again" reloads that month
/// alone.
struct PendingJump: Equatable {
    let timeBucket: String
    let fraction: Double
}

/// A scroll the timeline owes after its window changed. `serial` makes two
/// requests for the same id distinct, so `onChange` fires for both.
struct TimelineScrollRequest: Equatable {
    let id: String
    let serial: Int
}

/// Pure arithmetic of the date scrubber (testable without SwiftUI). The track
/// is divided in `n` equal shares, one per month of the served range, from the
/// newest month at the top (`0`) to the oldest at the bottom (`n - 1`).
enum TimelineScrubberMath {
    /// The month under track fraction `p` and the fraction inside that month.
    /// `p` is clamped to `[0, 1]`; `nil` when there is no month.
    static func target(atTrackFraction p: Double, monthCount n: Int) -> (monthIndex: Int, fraction: Double)? {
        guard n > 0 else { return nil }
        let clamped = p.isFinite ? min(max(p, 0), 1) : 0
        let scaled = clamped * Double(n)
        let month = min(n - 1, Int(scaled.rounded(.down)))
        let fraction = min(max(scaled - Double(month), 0), 1.0.nextDown)
        return (month, fraction)
    }

    /// Inverse of `target`: where on the track a month position sits.
    static func trackFraction(monthIndex m: Int, fraction f: Double, monthCount n: Int) -> Double {
        n == 0 ? 0 : (Double(m) + f) / Double(n)
    }

    /// Rank (0-based, grid order) of the photo `f` of the way into a month of
    /// `c` photos.
    static func anchorRank(fraction f: Double, count c: Int) -> Int {
        guard c > 1 else { return 0 }
        return max(0, min(c - 1, Int((f * Double(c)).rounded(.down))))
    }

    /// The accessibility slider runs from the oldest month (`0`) to the newest
    /// (`n - 1`): a VoiceOver increment (swipe up) goes to a newer month.
    static func sliderValue(monthIndex m: Int, monthCount n: Int) -> Double {
        Double(max(n - 1 - m, 0))
    }

    /// Inverse of `sliderValue`, clamped to the months of the list.
    static func monthIndex(sliderValue v: Double, monthCount n: Int) -> Int {
        guard n > 0, v.isFinite else { return 0 }
        return max(0, min(n - 1, n - 1 - Int(v.rounded())))
    }
}

/// State of one scrubbing gesture, kept apart from the view so that what the
/// label shows while the finger is down can be tested without SwiftUI.
/// `labelMonthIndex` is the only source of the label's visibility and month.
struct TimelineScrubberGesture: Equatable {
    private(set) var trackFraction: Double = 0
    private(set) var isScrubbing = false
    /// The month the bubble names; `nil` = bubble hidden.
    private(set) var labelMonthIndex: Int?
    private(set) var lingerToken = 0

    mutating func changed(trackFraction p: Double, monthCount n: Int) {
        trackFraction = p.isFinite ? min(max(p, 0), 1) : 0
        isScrubbing = true
        labelMonthIndex = TimelineScrubberMath.target(atTrackFraction: trackFraction, monthCount: n)?.monthIndex
        lingerToken &+= 1
    }

    /// Ends the gesture; the bubble keeps the released month until
    /// `lingerExpired`. Returns the release target.
    mutating func ended(monthCount n: Int) -> (monthIndex: Int, fraction: Double)? {
        isScrubbing = false
        lingerToken &+= 1
        return TimelineScrubberMath.target(atTrackFraction: trackFraction, monthCount: n)
    }

    /// Hides the bubble, unless a newer gesture started since `token` was read.
    mutating func lingerExpired(token: Int) {
        if token == lingerToken && !isScrubbing { labelMonthIndex = nil }
    }
}

/// Fast-scroll handle on the trailing edge of the Photos timeline: dragging it
/// names the targeted month in a bubble; releasing loads that month.
///
/// The view reads `vm.scrubPosition` itself, so the grid's body never does
/// (a row change would re-evaluate the whole grid). During the gesture only
/// this view's `@State` changes: no request, no write to the model.
struct TimelineScrubber: View {
    let vm: TimelineViewModel
    /// Release on `(monthIndex, fractionInMonth)`.
    let onRelease: (_ monthIndex: Int, _ fraction: Double) -> Void
    /// VoiceOver adjustment to `monthIndex`.
    let onAdjust: (_ monthIndex: Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gesture = TimelineScrubberGesture()
    @State private var labelText = ""
    @State private var lingerTask: Task<Void, Never>?

    static let labelLinger: Duration = .seconds(1.5)
    private static let spaceName = "timelineScrubberTrack"
    private static let handleHeight: CGFloat = 44

    /// The scrubber exists only over a loaded, non-selecting timeline.
    static func isShown(for vm: TimelineViewModel) -> Bool {
        !vm.items.isEmpty && !vm.buckets.isEmpty && !vm.selectionMode
    }

    var body: some View {
        if Self.isShown(for: vm) {
            let count = vm.buckets.count
            GeometryReader { geo in
                track(height: geo.size.height, monthCount: count)
            }
            .coordinateSpace(name: Self.spaceName)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("timelineScrubberTrack")
            .padding(.top, PVSpacing.s8 + 44 + PVSpacing.s16)
            .padding(.bottom, PVSpacing.s24 + 44 + PVSpacing.s16)
            .padding(.trailing, PVSpacing.s4)
        }
    }

    /// The month position the handle rests on outside a gesture; one that no
    /// longer names a month of the list (a reload shrank it) reads as none.
    private var restingPosition: TimelineScrubPosition? {
        guard let position = vm.scrubPosition, vm.buckets.indices.contains(position.monthIndex) else { return nil }
        return position
    }

    private func monthLabel(_ index: Int) -> String {
        guard vm.buckets.indices.contains(index) else { return "" }
        return TimelineSectionBuilder.monthLabel(forTimeBucket: vm.buckets[index].timeBucket)
    }

    @ViewBuilder
    private func track(height: CGFloat, monthCount n: Int) -> some View {
        // While the finger is down, and while the bubble lingers after the
        // release, the handle stays where the finger left it; the jump that
        // follows moves the resting position under it.
        let followsGesture = gesture.isScrubbing || gesture.labelMonthIndex != nil
        let rest = restingPosition
        let fraction = followsGesture
            ? gesture.trackFraction
            : TimelineScrubberMath.trackFraction(
                monthIndex: rest?.monthIndex ?? 0, fraction: rest?.fraction ?? 0, monthCount: n
            )
        HStack(spacing: PVSpacing.s8) {
            if let month = gesture.labelMonthIndex, vm.buckets.indices.contains(month) {
                Text(verbatim: labelText)
                    .font(.pvHeadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, PVSpacing.s12)
                    .padding(.vertical, PVSpacing.s8)
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("timelineScrubberLabel")
                    .transition(.opacity)
            }
            handle(height: height, monthCount: n, rest: rest)
        }
        .frame(maxWidth: .infinity, minHeight: Self.handleHeight, maxHeight: Self.handleHeight, alignment: .trailing)
        .offset(y: CGFloat(fraction) * height - Self.handleHeight / 2)
        .onChange(of: gesture.labelMonthIndex, initial: true) { _, month in
            if let month { labelText = monthLabel(month) }
        }
    }

    private func handle(height: CGFloat, monthCount n: Int, rest: TimelineScrubPosition?) -> some View {
        let month = rest?.monthIndex ?? 0
        return Image(systemName: "chevron.up.chevron.down")
            .font(.pvCaption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: Self.handleHeight)
            .glassEffect(.regular, in: Capsule())
            .frame(width: 44, height: Self.handleHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: PVSpacing.s4, coordinateSpace: .named(Self.spaceName))
                    .onChanged { value in
                        guard height > 0 else { return }
                        lingerTask?.cancel()
                        let fraction: Double = Double(value.location.y / height)
                        gesture.changed(trackFraction: fraction, monthCount: n)
                    }
                    .onEnded { _ in
                        if let target = gesture.ended(monthCount: n) {
                            onRelease(target.monthIndex, target.fraction)
                        }
                        scheduleLabelFade()
                    }
            )
            .accessibilityRepresentation {
                Slider(value: adjustBinding(month: month, monthCount: n), in: 0...Double(max(n - 1, 1)), step: 1) {
                    Text("Date scrubber")
                }
                .accessibilityLabel(Text("Date scrubber"))
                .accessibilityValue(Text(verbatim: monthLabel(month)))
                .accessibilityIdentifier("timelineScrubber")
            }
    }

    /// The VoiceOver slider: reads the resting month, and a change of its value
    /// asks for a jump to that month.
    private func adjustBinding(month: Int, monthCount n: Int) -> Binding<Double> {
        Binding<Double>(
            get: { TimelineScrubberMath.sliderValue(monthIndex: month, monthCount: n) },
            set: { value in
                let next = TimelineScrubberMath.monthIndex(sliderValue: value, monthCount: n)
                if next != month { onAdjust(next) }
            }
        )
    }

    /// Hides the bubble 1.5 s after the release, unless a new gesture began.
    private func scheduleLabelFade() {
        lingerTask?.cancel()
        let token = gesture.lingerToken
        lingerTask = Task { @MainActor in
            try? await Task.sleep(for: Self.labelLinger)
            guard !Task.isCancelled else { return }
            withAnimation(PVMotion.adaptive(.easeOut(duration: PVDuration.moderate), reduceMotion: reduceMotion)) {
                gesture.lingerExpired(token: token)
            }
        }
    }
}
