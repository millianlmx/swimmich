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
            Group {
                if vm.isLoading && vm.activities.isEmpty {
                    ProgressView("Loading activity…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.activities.isEmpty {
                    ContentUnavailableView(
                        "No Activity Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Comments and reactions on this album's photos will appear here.")
                    )
                } else {
                    List {
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
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
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

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: PVSpacing.s12) {
            TextField("Add a comment…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.pvBody)
                .focused($composerFocused)
                .padding(.horizontal, PVSpacing.s16)
                .padding(.vertical, PVSpacing.s8)
                .background(Color.bgSecondary.opacity(0.7), in: Capsule())

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
                            ? Color.textSecondaryPV
                            : Color.immichPrimary
                    )
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isSending)
            .accessibilityLabel("Send comment")
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
        .background(.regularMaterial)
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