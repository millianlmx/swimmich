import SwiftUI

/// Memories tab — one full-bleed hero card per memory (Liquid Glass chips over
/// the hero photo), each titled by its type ("On this day" date, a birthday's
/// person, an unknown type's date). Tapping a card opens the full-screen
/// `MemoryPlaybackView`, which chains the memories one after the other up to an
/// end screen. Empty state when the server has no
/// memories (e.g. a fresh library).
///
/// The card carries the memory CRUD the `/api/memories` routes expose: the
/// bookmark toggles `isSaved`, the context menu adds photos / deletes, and the
/// toolbar "+" creates a memory from a photo selection. A memory is a date, a
/// type and a set of assets — there is no name to type, so the create sheet is
/// a date plus the picker.
struct MemoriesView: View {
    @Bindable var vm: MemoriesViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile
    @Environment(\.openSyncStatus) private var openSyncStatus

    /// The full-screen playback, created by the list's view model so it reads the
    /// live list: a memory whose assets were just edited (or emptied) is never
    /// shown stale, and a delete moves on to the next memory.
    @State private var playback: MemoryPlaybackViewModel?
    @State private var addingPhotosToID: String?
    @State private var pendingDelete: MemoryResponseDto?

    var body: some View {
        NavigationStack {
            Group {
                if vm.renderState == .loading {
                    // Outside the ScrollView: only a first read (or a "Try
                    // Again" with nothing to show) reaches here, never a pull,
                    // so the ScrollView and its refresh task stay in place.
                    ProgressView("Loading memories…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .pvLoadingIndicator("memoriesLoading")
                } else {
                    ScrollView {
                        scrollContent
                    }
                    .refreshable { await vm.refresh() }
                }
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        vm.showCreate = true
                    } label: {
                        Label("New Memory", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("memoriesCreateButton")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SyncStatusButton { openSyncStatus() }
                    ProfileAvatarButton { openProfile() }
                }
            }
            .task { await vm.load() }
            .sheet(isPresented: $vm.showCreate) {
                CreateMemorySheet(vm: vm)
            }
            .sheet(isPresented: Binding(
                get: { addingPhotosToID != nil },
                set: { if !$0 { addingPhotosToID = nil } }
            )) {
                if let memoryId = addingPhotosToID {
                    AddPhotosToMemorySheet(
                        memoryId: memoryId,
                        existingAssetIds: Set(vm.memory(id: memoryId)?.assets.map(\.id) ?? []),
                        vm: vm
                    )
                }
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Memory", role: .destructive) {
                    guard let memory = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await vm.deleteMemory(id: memory.id) }
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("The photos stay in your library — only this memory is removed.")
            }
            .fullScreenCover(item: $playback) { playback in
                MemoryPlaybackView(playback: playback, vm: vm, baseURL: baseURL, token: auth.accessToken)
            }
        }
    }

    /// One `ScrollView` through the error, empty and cards states: a state
    /// change must not cancel the task of a pull-to-refresh in flight.
    @ViewBuilder
    private var scrollContent: some View {
        switch vm.renderState {
        case .loading:
            EmptyView()
        case .error(let message):
            PVErrorStateView(
                title: "Couldn't load memories",
                message: message,
                identifierPrefix: "memories",
                retry: { Task { await vm.load() } }
            )
            .containerRelativeFrame(.vertical)
        case .empty:
            ContentUnavailableView(
                "No Memories Yet",
                systemImage: "sparkles.rectangle.stack",
                description: Text("Photos from this day in past years will appear here.")
            )
            .containerRelativeFrame(.vertical)
            .accessibilityIdentifier("memoriesEmptyState")
        case .data(let status):
            VStack(spacing: PVSpacing.s16) {
                switch status {
                case .reloading:
                    // "Try Again" from the banner: the cards stay, this stands in for it.
                    ProgressView()
                        .pvLoadingIndicator("memoriesLoading")
                case .failed(let message):
                    // Refresh failures keep the stale list (try-then-mutate)
                    // — surface the error instead of hiding it.
                    refreshErrorBanner(message)
                case .idle:
                    if let message = vm.errorMessage {
                        refreshErrorBanner(message)
                    }
                }
                memoryCards
            }
            .padding(PVSpacing.s16)
        }
    }

    private var memoryCards: some View {
        LazyVStack(spacing: PVSpacing.s24) {
            ForEach(vm.memories, id: \.id) { memory in
                MemoryCard(
                    memory: memory,
                    baseURL: baseURL,
                    token: auth.accessToken,
                    onOpen: {
                        playback = vm.makePlayback(
                            startingAt: memory.id,
                            autoPlays: !MemoryPlaybackProbe.autoplayOff
                        )
                    },
                    onToggleSaved: {
                        Task {
                            if memory.isSaved {
                                await vm.unsaveMemory(id: memory.id)
                            } else {
                                await vm.saveMemory(id: memory.id)
                            }
                        }
                    },
                    onAddPhotos: { addingPhotosToID = memory.id },
                    onDelete: { pendingDelete = memory }
                )
            }
        }
    }

    /// `auth.baseURL` is guaranteed non-nil while authenticated (codebase-wide
    /// convention — see TimelineView/TrashView/SearchView). Fallback never
    /// renders a card in practice.
    private var baseURL: URL {
        auth.baseURL ?? URL(string: "https://example.com")!
    }

    private func refreshErrorBanner(_ message: String) -> some View {
        PVAdaptiveStack(hAlignment: .center, vAlignment: .leading, spacing: PVSpacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: PVSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichWarning)
                Text(message)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("memoriesRefreshErrorMessage")
            }
            Spacer(minLength: 0)
            Button("Try Again") { Task { await vm.load() } }
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(Color.immichPrimary)
        }
        .padding(PVSpacing.s12)
        .background(Color.bgTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memoriesRefreshErrorBanner")
    }
}

/// One full-bleed "On this day" card: the memory's hero photo as the card
/// background with the day + year set in big poster typography over a bottom
/// scrim ("1 juillet" / "2022"), plus "N years ago" and Liquid Glass chips
/// (photo/video counts, location, asset count). Tapping the card opens the
/// full-screen `MemoryPlaybackView`; the bookmark toggles `isSaved` and the long
/// press opens the memory's mutations.
struct MemoryCard: View {
    let memory: MemoryResponseDto
    let baseURL: URL
    let token: String?
    let onOpen: () -> Void
    let onToggleSaved: () -> Void
    let onAddPhotos: () -> Void
    let onDelete: () -> Void

    private var hero: AssetResponseDto? { memory.assets.first }

    private var heroURL: URL? {
        guard let hero else { return nil }
        return ImmichAssetURL.thumbnail(
            assetId: hero.id,
            thumbhash: hero.thumbhash ?? "",
            baseURL: baseURL,
            size: .preview
        )
    }

    var body: some View {
        // The bookmark is a sibling *above* the card's button, not a child of
        // it: nested buttons swallow each other's taps (see the stack badge
        // trap), and an overlay hit-tests first.
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                card
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("memoryCard_\(memory.id)")
            .contextMenu {
                Button(action: onToggleSaved) {
                    Label(
                        memory.isSaved ? "Unsave Memory" : "Save Memory",
                        systemImage: memory.isSaved ? "bookmark.slash" : "bookmark"
                    )
                }
                Button(action: onAddPhotos) {
                    Label("Add Photos", systemImage: "plus.rectangle.on.rectangle")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Memory", systemImage: "trash")
                }
            }

            bookmarkButton
                .padding(PVSpacing.s12)
        }
    }

    /// The save toggle — armed/unarmed in one tap, with its state readable by
    /// VoiceOver (and by the UI test, which asserts on the label).
    private var bookmarkButton: some View {
        Button(action: onToggleSaved) {
            Image(systemName: memory.isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .pvFloating(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryBookmark_\(memory.id)")
        .accessibilityLabel(memory.isSaved ? "Unsave memory" : "Save memory")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s12) {
            header
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PVSpacing.s16)
        // The card grows with its text; the image and the scrim are drawn
        // behind the final frame, so they always fill the whole card.
        .frame(minHeight: 320, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.25),
                    .init(color: .black.opacity(0.9), location: 0.85),
                    .init(color: .black.opacity(0.98), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .background {
            if let heroURL {
                GeometryReader { proxy in
                    AuthenticatedAsyncImage(url: heroURL, token: token, contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else {
                Rectangle().fill(Color.bgTertiary.opacity(0.3))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.xl, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s0) {
            if let title = MemoryTitlePresentation.cardTitle(for: memory) {
                Text(title)
                    .font(.pvH3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .accessibilityIdentifier("memoryCardTitle_\(memory.id)")
            }
            if let subtitle = MemoryTitlePresentation.cardSubtitle(for: memory) {
                Text(subtitle)
                    .font(.pvSubhead)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .padding(.top, PVSpacing.s4)
            }
        }
    }

    private var footer: some View {
        PVAdaptiveStack(vAlignment: .leading, spacing: PVSpacing.s8) {
            if let media = MemoryCardPresentation.mediaCountLabel(for: memory) {
                Label(media, systemImage: "photo.on.rectangle")
                    .lineLimit(1)
            }
            if let location = MemoryCardPresentation.locationLabel(for: memory) {
                Label(location, systemImage: "mappin.and.ellipse")
                    .lineLimit(1)
                    .accessibilityIdentifier("memoryCardLocation_\(memory.id)")
            }
            if memory.assets.count > 1 {
                Label(String(memory.assets.count), systemImage: "square.stack")
            }
        }
        .font(.pvCaption.weight(.medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, PVSpacing.s12)
        .padding(.vertical, PVSpacing.s8)
        .pvFloating(.pill)
    }
}

/// Pure presentation helpers for the memory card (date/location/count labels).
/// No SwiftUI state — unit-testable.
enum MemoryCardPresentation {

    /// Parses a UTC `memoryAt` timestamp; tolerates both fractional
    /// ("…00.000Z") and plain ("…00Z") seconds. Nil when malformed.
    static func parseMemoryAt(_ iso: String) -> Date? {
        fractionalParser.date(from: iso) ?? plainParser.date(from: iso)
    }

    /// "July 1" from a UTC timestamp (memory day kept in UTC — memoryAt is a
    /// UTC "this day" anchor, a local tz shift would flip the day). The
    /// `MMMMd` template keeps day/month order locale-correct ("July 1" en,
    /// "1 juillet" fr). `AppDateFormat` renders it, so the label follows the
    /// app's current language instead of the one the app launched with.
    static func monthDayLabel(from date: Date, locale: Locale = .current) -> String {
        AppDateFormat.string(from: date, style: .monthDay, locale: locale, calendar: utcCalendar)
    }

    /// "July 1" — the card's title line. Nil when memoryAt can't be parsed.
    static func dayLabel(for memory: MemoryResponseDto, locale: Locale = .current) -> String? {
        guard let date = parseMemoryAt(memory.memoryAt) else { return nil }
        return monthDayLabel(from: date, locale: locale)
    }

    /// Years elapsed since the memory's year (calendar year arithmetic); nil
    /// when the year is current or in the future (no such memories server-side,
    /// but cheap to guard).
    static func yearsAgoCount(year: Int, now: Date = .now) -> Int? {
        let diff = Calendar.current.component(.year, from: now) - year
        return diff > 0 ? diff : nil
    }

    /// "Last year" / "N years ago" for a count from `yearsAgoCount`.
    static func yearsAgoText(count: Int, locale: Locale = .current) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return String(localized: "Last year", locale: locale) }
        return String(localized: "\(count) years ago", locale: locale)
    }

    /// Photo/video split of a memory's assets.
    static func mediaCount(for memory: MemoryResponseDto) -> (photos: Int, videos: Int) {
        let photos = memory.assets.filter { $0.type == "IMAGE" }.count
        return (photos, memory.assets.count - photos)
    }

    /// "12 photos" / "1 video" / "8 photos · 2 videos". Nil for an empty
    /// memory (server never sends one, but guards the formatting).
    static func mediaCountLabel(for memory: MemoryResponseDto, locale: Locale = .current) -> String? {
        let (photos, videos) = mediaCount(for: memory)
        switch (photos, videos) {
        case (0, 0): return nil
        case (_, 0): return photoLabel(photos, locale: locale)
        case (0, _): return videoLabel(videos, locale: locale)
        default: return "\(photoLabel(photos, locale: locale)) · \(videoLabel(videos, locale: locale))"
        }
    }

    /// "Paris, France" from the first asset carrying EXIF location (city →
    /// country fallback, whitespace-trimmed).
    static func locationLabel(for memory: MemoryResponseDto) -> String? {
        for asset in memory.assets {
            guard let exif = asset.exifInfo else { continue }
            let city = trimmed(exif.city)
            let country = trimmed(exif.country)
            switch (city, country) {
            case (let city?, let country?): return "\(city), \(country)"
            case (let city?, nil): return city
            case (nil, let country?): return country
            case (nil, nil): continue
            }
        }
        return nil
    }

    private static func photoLabel(_ n: Int, locale: Locale) -> String {
        n == 1 ? String(localized: "1 photo", locale: locale) : String(localized: "\(n) photos", locale: locale)
    }

    private static func videoLabel(_ n: Int, locale: Locale) -> String {
        n == 1 ? String(localized: "1 video", locale: locale) : String(localized: "\(n) videos", locale: locale)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let fractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser
    }()

    private static let plainParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser
    }()

    /// Gregorian calendar pinned to UTC: memory days are UTC anchors, so they
    /// must never be re-read through the device's time zone.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
