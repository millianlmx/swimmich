import SwiftUI

/// Album activity sheet — comments + per-asset likes (P3 activity-feed).
/// Rows: avatar, author, content (comment text / like heart), asset thumbnail
/// when anchored, relative time, like toggle + delete for the current user.
struct ActivityFeedSheet: View {
    let vm: ActivityFeedViewModel

    @Environment(AuthViewModel.self) private var auth
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            // One `List` carries every state and `.refreshable`, so a state
            // change never cancels the pull in flight.
            List {
                switch vm.renderState {
                case .loading:
                    ProgressView("Loading activity…")
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("activityFeedLoading")
                        .listRowBackground(Color.clear)
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load activity",
                        message: message,
                        identifierPrefix: "activityFeed",
                        retry: { Task { await vm.load() } }
                    )
                    .listRowBackground(Color.clear)
                case .empty:
                    ContentUnavailableView(
                        "No Activity Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Comments and reactions on this album's photos will appear here.")
                    )
                    .accessibilityIdentifier("activityFeedEmptyState")
                    .listRowBackground(Color.clear)
                case .data(let status):
                    reloadStatus(status)
                    Section {
                        ForEach(vm.activities, id: \.id) { activity in
                            ActivityRow(
                                activity: activity,
                                canDelete: activity.user.id == auth.userId,
                                hasMyLike: vm.hasMyLike(activity),
                                canToggleLike: vm.canToggleLike(activity),
                                onToggleLike: { Task { await vm.toggleLike(activity: activity) } },
                                onDelete: { Task { await vm.deleteActivity(id: activity.id) } }
                            )
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.refresh() }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let error = vm.errorMessage, !vm.activities.isEmpty {
                        Text(error)
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichError)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composer
            }
        }
        .task { await vm.load() }
    }

    /// "Try Again" with the feed on screen: the indicator stands in for the
    /// banner while the read runs; a failed refresh keeps the rows under it.
    @ViewBuilder
    private func reloadStatus(_ status: DataStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .reloading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .pvLoadingIndicator("activityFeedLoading")
                .listRowBackground(Color.clear)
        case .failed(let message):
            InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                .accessibilityIdentifier("activityFeedRefreshError")
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: PVSpacing.s12) {
            TextField(
                "Add a comment…",
                text: $draft,
                prompt: Text("Add a comment…").foregroundStyle(PVFloating.secondaryContent),
                axis: .vertical
            )
                .lineLimit(1...4)
                .font(.pvBody)
                .focused($composerFocused)
                .padding(.horizontal, PVSpacing.s16)
                .padding(.vertical, PVSpacing.s8)
                .tint(PVFloating.accent)

            Button {
                let text = draft
                draft = ""
                Task {
                    if await vm.addComment(text) {
                        composerFocused = false
                    } else {
                        draft = text
                    }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSending
                            ? PVFloating.secondaryContent
                            : PVFloating.accent
                    )
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSending)
            .accessibilityLabel("Send comment")
            .accessibilityIdentifier("activityFeedSendButton")
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
        .pvFloating(.bar)
        .padding(.horizontal, PVSpacing.s12)
        .padding(.bottom, PVSpacing.s8)
    }
}

/// One activity row: avatar + author + content + relative time, with a
/// per-row like toggle and delete (own activities).
private struct ActivityRow: View {
    let activity: ActivityResponseDto
    let canDelete: Bool
    let hasMyLike: Bool
    let canToggleLike: Bool
    let onToggleLike: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: PVSpacing.s12) {
            UserAvatarCircle(user: activity.user, size: 36, baseURL: auth.baseURL, token: auth.accessToken)

            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(activity.user.name)
                    .font(.pvBody.weight(.medium))
                    .foregroundStyle(Color.textPrimaryPV)
                if case .comment = activity.type {
                    Text(activity.comment ?? "")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textPrimaryPV)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Liked this photo", systemImage: "heart.fill")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Text(relativeTime)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }

            Spacer()

            if let assetId = activity.assetId {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.thumbnail(
                        assetId: assetId,
                        thumbhash: "",
                        baseURL: authBaseURL
                    ),
                    token: authToken
                )
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
            }

            if canToggleLike {
                Button(action: onToggleLike) {
                    Image(systemName: hasMyLike ? "heart.fill" : "heart")
                        .font(.pvBody)
                        .foregroundStyle(hasMyLike ? Color.immichPrimary : Color.textSecondaryPV)
                }
                .accessibilityLabel(hasMyLike ? "Unlike" : "Like")
                .accessibilityIdentifier("activityLikeToggle-\(activity.id)")
                .buttonStyle(.plain)
            }

            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                }
                .accessibilityLabel("Delete activity")
                .accessibilityIdentifier("activityDelete-\(activity.id)")
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, PVSpacing.s4)
    }

    /// `.short` relative phrase ("2 h ago"). `AppDateFormat` owns the cached
    /// `RelativeDateTimeFormatter` — this used to allocate one per row.
    private var relativeTime: String {
        AppDateFormat.relativeString(
            for: LongDateFormatter.parse(isoTimestamp: activity.createdAt) ?? Date()
        )
    }

    @Environment(AuthViewModel.self) private var auth
    private var authBaseURL: URL {
        auth.baseURL ?? URL(string: "https://example.com")!
    }
    private var authToken: String? { auth.accessToken }
}