import SwiftUI

/// One memory page of the full-screen playback (`MemoryPlaybackView`) — the
/// nostalgia shot. A full-bleed swipeable hero pager (one centered photo per
/// page, slow Ken Burns on the active photo) with Liquid Glass chips floating
/// over it (title, date, location, people, tags, saved state).
///
/// Top bar: close (left, closes the whole playback), a centered type badge and
/// a "view in timeline" teleport (right) that dismisses and jumps the Photos tab
/// to this photo. Swipe horizontally to browse; one swipe past the last photo
/// goes on to the next memory. Tap a photo for the full Photos-style pager.
///
/// The page owns no playback state: which photo is shown comes from
/// `MemoryPlaybackViewModel` (only the *current* page follows it; any other page
/// rests on its first photo), and the viewer / sheets / delete confirmation live
/// on the playback container so a lazily recycled page cannot lose them.
///
/// It is also the memory's editing surface: the bottom action row saves or
/// unsaves it (`PUT /api/memories/{id}`), adds photos (`PUT
/// /api/memories/{id}/assets`), drops the photo currently on screen (`DELETE
/// …/assets`) and deletes the whole memory (`DELETE /api/memories/{id}`). Every
/// action stops the auto-play.
struct MemoryMomentView: View {
    let memory: MemoryResponseDto
    let playback: MemoryPlaybackViewModel
    /// Whether this page is the one the playback is on.
    let isCurrent: Bool
    /// The top and bottom bars fade in once, when the playback opens.
    let chromeVisible: Bool
    /// The device's safe-area insets: the page itself extends under them.
    let safeInsets: EdgeInsets
    /// The memory list's owner — mutations go through it so the list behind this
    /// screen shows the result.
    let vm: MemoriesViewModel
    let baseURL: URL
    let token: String?
    let onOpenViewer: (MemoryResponseDto, Int) -> Void
    let onAddPhotos: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openInTimeline) private var openInTimeline

    @State private var kenBurns = false
    /// Horizontal pager position: an asset id, or `passageID` on the page after
    /// the last photo.
    @State private var visibleItem: String?

    private static let passageID = "memory-passage"

    private var heroIndex: Int {
        isCurrent ? min(playback.assetIndex, max(memory.assets.count - 1, 0)) : 0
    }

    /// The asset shown as the hero (the first one on a page that is not current).
    private var heroAsset: AssetResponseDto? {
        memory.assets.indices.contains(heroIndex) ? memory.assets[heroIndex] : memory.assets.first
    }

    /// "Shot on iPhone 13" from the current hero asset's EXIF (make/model).
    private var heroCameraLabel: String? {
        guard let exif = heroAsset?.exifInfo else { return nil }
        let model = [exif.make, exif.model]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return model.isEmpty ? nil : model.joined(separator: " ")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            heroPager
            scrims
            VStack(spacing: PVSpacing.s0) {
                topBar
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : -12)
                Spacer()
                bottomPanel
                    .opacity(chromeVisible ? 1 : 0)
                    .offset(y: chromeVisible ? 0 : 24)
            }
            .padding(.top, safeInsets.top)
            .padding(.bottom, safeInsets.bottom)
        }
        .onAppear {
            visibleItem = heroAsset?.id
            if isCurrent { restartKenBurns() }
        }
        .onChange(of: heroAsset?.id) { _, newID in
            if isCurrent { restartKenBurns() }
            guard let newID, visibleItem != newID else { return }
            withAnimation(isCurrent ? PVMotion.adaptive(.easeInOut(duration: 0.4), reduceMotion: reduceMotion) : nil) {
                visibleItem = newID
            }
        }
        .onChange(of: isCurrent) { _, nowCurrent in
            // A page that becomes current rests on its photo 0 again (the
            // playback went to photo 0). For a one-photo memory `heroIndex` is
            // 0 before and after, so `heroAsset?.id` does not change and the
            // pager would stay on the passage it was left on. Not done when the
            // page stops being current: it is sliding out and must not jump.
            if nowCurrent {
                resetPagerPosition()
                restartKenBurns()
            } else {
                kenBurns = false
            }
        }
        .overlay(alignment: .topLeading) { pagerProbe }
    }

    /// Puts the horizontal pager back on the hero photo, without animation.
    private func resetPagerPosition() {
        guard let id = heroAsset?.id, visibleItem != id else { return }
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) { visibleItem = id }
    }

    /// UI-test probe (same switch as `memoryPlaybackProbe`): what the horizontal
    /// pager actually shows — an asset id, or `passage`.
    @ViewBuilder
    private var pagerProbe: some View {
        if MemoryPlaybackProbe.isEnabled {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("memoryPagerProbe_\(memory.id)")
                .accessibilityValue(Text(verbatim: visibleItem == Self.passageID ? "passage" : (visibleItem ?? "none")))
        }
    }

    // MARK: - Hero pager (swipe to browse)

    private var heroPager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(Array(memory.assets.enumerated()), id: \.element.id) { index, dto in
                    heroPage(dto, index: index)
                        .id(dto.id)
                        .containerRelativeFrame(.horizontal)
                        .clipped()
                }
                passagePage
                    .id(Self.passageID)
                    .containerRelativeFrame(.horizontal)
                    .clipped()
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visibleItem)
        .onScrollPhaseChange { oldPhase, newPhase in
            guard isCurrent else { return }
            if newPhase == .interacting {
                playback.stopAutoPlay()
            }
            if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating {
                commitVisibleItem()
            }
        }
        .ignoresSafeArea()
    }

    /// The user's horizontal swipe came to rest: report where.
    private func commitVisibleItem() {
        if visibleItem == Self.passageID {
            playback.userAdvancedPastLastPhoto()
        } else if let index = memory.assets.firstIndex(where: { $0.id == visibleItem }) {
            playback.userShowedPhoto(at: index)
        }
    }

    @ViewBuilder
    private func heroPage(_ dto: AssetResponseDto, index: Int) -> some View {
        let isHero = isCurrent && index == heroIndex
        Group {
            if dto.type == "VIDEO" && isHero {
                VideoPlayerView(
                    asset: AssetReactItem(from: dto),
                    baseURL: baseURL,
                    token: token,
                    controlsVisible: false,
                    videoGravity: .resizeAspectFill,
                    onPlaybackEnded: { playback.videoDidEnd() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(kenBurns ? 1.08 : 1.0)
                .clipped()
            } else {
                let url = ImmichAssetURL.thumbnail(
                    assetId: dto.id,
                    thumbhash: dto.thumbhash ?? "",
                    baseURL: baseURL,
                    size: .preview
                )
                AuthenticatedAsyncImage(url: url, token: token, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(kenBurns && isHero ? 1.08 : 1.0)
                    .clipped()
                    .id(url.absoluteString)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onOpenViewer(memory, index) })
        .accessibilityLabel(String(localized: "Open this memory's photos"))
    }

    /// The page after the last photo: a darkened preview of the next memory's
    /// first photo, or a check mark after the last memory. Swiping onto it moves
    /// on; it is not a photo, so VoiceOver and the page dots ignore it.
    private var passagePage: some View {
        ZStack {
            Color.black
            if let next = nextMemory, let first = next.assets.first {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.thumbnail(
                        assetId: first.id,
                        thumbhash: first.thumbhash ?? "",
                        baseURL: baseURL,
                        size: .preview
                    ),
                    token: token,
                    contentMode: .fill
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                Color.black.opacity(0.6)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityHidden(true)
    }

    private var nextMemory: MemoryResponseDto? {
        guard let index = vm.memories.firstIndex(where: { $0.id == memory.id }),
              index + 1 < vm.memories.count else { return nil }
        return vm.memories[index + 1]
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top, endPoint: .center
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Top bar

    private var topBar: some View {
        GlassEffectContainer {
            HStack(spacing: PVSpacing.s8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.pvHeadline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .glassEffect(.regular.tint(.black.opacity(0.6)), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Close memory"))
                .accessibilityIdentifier("memoryMomentClose")

                Spacer(minLength: PVSpacing.s8)

                let badge = MemoryTitlePresentation.badge(for: memory)
                Label(badge.label, systemImage: badge.symbol)
                    .font(.pvCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, PVSpacing.s12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.6)), in: Capsule())

                Spacer(minLength: PVSpacing.s8)

                Button {
                    if let asset = heroAsset {
                        openInTimeline(asset.id, String(asset.fileCreatedAt.prefix(10)))
                    }
                    dismiss()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.pvHeadline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .glassEffect(.regular.tint(.black.opacity(0.6)), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(heroAsset == nil)
                .accessibilityLabel(String(localized: "View in timeline"))
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, PVSpacing.s16)
        .padding(.top, PVSpacing.s8)
        .accessibilityHidden(!isCurrent)
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: PVSpacing.s12) {
            titleBlock
            pageDots
            chips
            actionRow
                .allowsHitTesting(isCurrent)
                .accessibilityHidden(!isCurrent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PVSpacing.s16)
        .padding(.bottom, PVSpacing.s16)
    }

    /// The memory's mutations, over the hero. Each is a glass circle sized for
    /// the 44 pt minimum tap target; icons carry the meaning, VoiceOver the words.
    /// Any of them stops the auto-play for good (no restart but "Start Over").
    private var actionRow: some View {
        GlassEffectContainer {
            HStack(spacing: PVSpacing.s16) {
                actionButton(
                    symbol: memory.isSaved ? "bookmark.fill" : "bookmark",
                    label: memory.isSaved ? "Unsave memory" : "Save memory",
                    identifier: "memoryMomentSave"
                ) {
                    playback.stopAutoPlay()
                    Task {
                        if memory.isSaved {
                            await vm.unsaveMemory(id: memory.id)
                        } else {
                            await vm.saveMemory(id: memory.id)
                        }
                    }
                }

                actionButton(
                    symbol: "plus.rectangle.on.rectangle",
                    label: "Add photos",
                    identifier: "memoryMomentAddPhotos"
                ) {
                    playback.stopAutoPlay()
                    onAddPhotos()
                }

                actionButton(
                    symbol: "minus.circle",
                    label: "Remove this photo from the memory",
                    identifier: "memoryMomentRemovePhoto"
                ) {
                    Task { await playback.removeCurrentPhoto() }
                }
                .disabled(heroAsset == nil)

                actionButton(
                    symbol: "trash",
                    label: "Delete memory",
                    identifier: "memoryMomentDelete"
                ) {
                    playback.stopAutoPlay()
                    onDelete()
                }
            }
        }
    }

    private func actionButton(
        symbol: String,
        label: LocalizedStringKey,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .glassEffect(.regular.tint(.black.opacity(0.6)), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
    }

    /// The type-aware title: the year for an on-this-day memory, the person (and
    /// their age at the photo on screen) for a birthday, the date otherwise.
    private var titleBlock: some View {
        VStack(spacing: PVSpacing.s4) {
            let title = MemoryTitlePresentation.momentTitle(for: memory, asset: heroAsset)
            if memory.type == .on_this_day {
                Text(title)
                    .font(.pvTitleXL)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("memoryTitle_\(memory.id)")
            } else {
                Text(title)
                    .font(.pvH3)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("memoryTitle_\(memory.id)")
            }
            if let subtitle = MemoryTitlePresentation.momentSubtitle(for: memory) {
                Text(subtitle)
                    .font(.pvSubhead)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var pageDots: some View {
        if memory.assets.count > 1 {
            HStack(spacing: PVSpacing.s4) {
                ForEach(memory.assets.indices, id: \.self) { index in
                    Circle()
                        .fill(index == heroIndex ? Color.white : Color.white.opacity(0.35))
                        .frame(width: index == heroIndex ? 8 : 6, height: index == heroIndex ? 8 : 6)
                }
            }
            .animation(PVMotion.standard, value: heroIndex)
            .accessibilityLabel(String(localized: "Page \(heroIndex + 1) of \(memory.assets.count)"))
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PVSpacing.s8) {
                if let location = MemoryCardPresentation.locationLabel(for: memory) {
                    MemoryChip(symbol: "mappin.and.ellipse", text: location)
                }
                if let camera = heroCameraLabel {
                    MemoryChip(symbol: "camera", text: camera)
                }
                peopleChip
                if let tags = MemoryMomentPresentation.tagsLabel(for: memory) {
                    MemoryChip(symbol: "tag", text: tags)
                }
                if memory.isSaved {
                    MemoryChip(symbol: "heart.fill", text: String(localized: "Saved"))
                }
            }
            .padding(.horizontal, PVSpacing.s16)
        }
    }

    @ViewBuilder
    private var peopleChip: some View {
        let people = MemoryMomentPresentation.people(for: memory)
        if !people.isEmpty {
            HStack(spacing: -6) {
                ForEach(Array(people.prefix(4)), id: \.id) { person in
                    AuthenticatedAsyncImage(
                        url: ImmichAssetURL.personThumbnail(personId: person.id, baseURL: baseURL),
                        token: token
                    )
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                }
                if people.count > 4 {
                    Text("+\(people.count - 4)")
                        .font(.pvCaption)
                        .foregroundStyle(.white)
                        .padding(.leading, PVSpacing.s8)
                }
            }
            .padding(.horizontal, PVSpacing.s8)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.black.opacity(0.6)), in: Capsule())
            .accessibilityLabel(MemoryMomentPresentation.peopleLabel(for: memory) ?? String(localized: "People"))
        }
    }

    // MARK: - Ken Burns

    /// Slow 10 s zoom-in per photo (Ken Burns), restarted on each photo change.
    private func restartKenBurns() {
        guard !reduceMotion else { return }
        kenBurns = false
        withAnimation(.linear(duration: 10)) {
            kenBurns = true
        }
    }
}

/// Small glass capsule chip (icon + label) used over hero imagery. White glyphs
/// over Liquid Glass — the scrim behind guarantees contrast on bright photos.
struct MemoryChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: PVSpacing.s4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.pvCaption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PVSpacing.s8)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(.black.opacity(0.6)), in: Capsule())
    }
}
