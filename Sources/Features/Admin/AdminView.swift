import SwiftUI

/// Admin panel (gap #12): users, jobs and libraries. Pushed from the Me section
/// (ProfileView) and only reachable when the current account is an admin. No own
/// NavigationStack (TrashView pattern).
///
/// The API-key section that used to live here is gone: `GET /api/api-keys`
/// returns the keys of the token's bearer with no admin permission, so the list
/// belongs to every account and now lives in `UserApiKeysView` (gap G20).
struct AdminView: View {
    @Bindable var vm: AdminViewModel

    @State private var showCreateUser = false
    @State private var newUserName = ""
    @State private var newUserEmail = ""
    @State private var newUserPassword = ""
    @State private var newUserIsAdmin = false

    @State private var pendingDeleteUser: UserAdminResponseDto?
    @State private var pendingDeleteLibrary: LibraryResponseDto?

    var body: some View {
        // One `List` carries every state and `.refreshable`, so a state change
        // never cancels the pull in flight. The instance totals come first and
        // read on their own.
        List {
            instanceStatsSection
            switch vm.renderState {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("adminLoading")
                        .listRowBackground(Color.clear)
                }
            case .error(let message):
                Section {
                    PVErrorStateView(
                        title: "Couldn't load administration",
                        message: message,
                        identifierPrefix: "admin",
                        retry: { Task { await vm.load(force: true) } }
                    )
                    .listRowBackground(Color.clear)
                }
            case .empty:
                listSections
            case .data(let status):
                reloadStatus(status)
                listSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .task { await vm.loadInstanceStats() }
        .refreshable { await vm.refresh() }
        .alert("New User", isPresented: $showCreateUser) {
            TextField("Name", text: $newUserName)
            TextField("Email", text: $newUserEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            SecureField("Password", text: $newUserPassword)
            Toggle("Admin", isOn: $newUserIsAdmin)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { await vm.createUser(name: newUserName, email: newUserEmail, password: newUserPassword, isAdmin: newUserIsAdmin) }
            }
        }
        .confirmationDialog(
            "Delete user?",
            isPresented: Binding(get: { pendingDeleteUser != nil }, set: { if !$0 { pendingDeleteUser = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete (force)", role: .destructive) {
                if let u = pendingDeleteUser { Task { await vm.deleteUser(u, force: true) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete library and all its assets?",
            isPresented: Binding(get: { pendingDeleteLibrary != nil }, set: { if !$0 { pendingDeleteLibrary = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let l = pendingDeleteLibrary { Task { await vm.deleteLibrary(l) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Instance statistics

    /// Instance-wide totals (`GET /api/server/statistics`, administrators only).
    /// Read on its own: a failure here shows its badge and leaves users, jobs and
    /// libraries untouched.
    @ViewBuilder
    private var instanceStatsSection: some View {
        Section {
            if vm.isLoadingInstanceStats && vm.instanceStats == nil {
                ProgressView()
                    .accessibilityIdentifier("adminInstanceStatsLoading")
            }
            if let stats = vm.instanceStats {
                LabeledContent("Photos", value: stats.photos.formatted())
                    .accessibilityIdentifier("adminInstancePhotos")
                LabeledContent("Videos", value: stats.videos.formatted())
                    .accessibilityIdentifier("adminInstanceVideos")
                LabeledContent("Usage", value: StorageStatsViewModel.format(Int64(stats.usage)))
                    .accessibilityIdentifier("adminInstanceUsage")
            }
            if let error = vm.instanceStatsError {
                InlineErrorBadge(message: error) { Task { await vm.loadInstanceStats() } }
                    .accessibilityIdentifier("adminInstanceStatsError")
            }
        } header: {
            Text("Instance Statistics")
        }
    }

    // MARK: - Users

    @ViewBuilder
    private var usersSection: some View {
        Section {
            ForEach(vm.users) { user in
                HStack(spacing: PVSpacing.s12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name)
                            .font(.pvBody)
                            .foregroundStyle(Color.textPrimaryPV)
                        Text(user.email)
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                    Spacer()
                    if user.isAdmin == true {
                        Text("Admin")
                            .font(.pvCaption.weight(.semibold))
                            .foregroundStyle(Color.immichPrimary)
                    }
                }
                .contextMenu {
                    if user.deletedAt != nil {
                        Button {
                            Task { await vm.restoreUser(user) }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button(role: .destructive) {
                        pendingDeleteUser = user
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button {
                newUserName = ""
                newUserEmail = ""
                newUserPassword = ""
                newUserIsAdmin = false
                showCreateUser = true
            } label: {
                Label("Add user", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Users (\(vm.users.count))")
        }
    }

    // MARK: - Jobs

    @ViewBuilder
    private var jobsSection: some View {
        Section {
            ForEach(vm.sortedJobNames, id: \.self) { name in
                if let job = vm.jobs[name] {
                    HStack(spacing: PVSpacing.s12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.displayName(name))
                                .font(.pvBody)
                                .foregroundStyle(Color.textPrimaryPV)
                            Text(Self.jobSummary(job.jobCounts))
                                .font(.pvCaption)
                                .foregroundStyle(Color.textSecondaryPV)
                        }
                        Spacer()
                        if job.queueStatus.isPaused {
                            Text("Paused")
                                .font(.pvCaption.weight(.semibold))
                                .foregroundStyle(Color.immichWarning)
                        } else if job.queueStatus.isActive {
                            Text("Active")
                                .font(.pvCaption.weight(.semibold))
                                .foregroundStyle(Color.immichSuccess)
                        }
                    }
                    .contextMenu {
                        Button { Task { await vm.runJob(name: name, command: "start") } } label: { Label("Run", systemImage: "play.fill") }
                        Button { Task { await vm.runJob(name: name, command: "pause") } } label: { Label("Pause", systemImage: "pause.fill") }
                        Button { Task { await vm.runJob(name: name, command: "resume") } } label: { Label("Resume", systemImage: "arrow.clockwise") }
                        Button { Task { await vm.runJob(name: name, command: "empty") } } label: { Label("Empty", systemImage: "trash") }
                        Button { Task { await vm.runJob(name: name, command: "clear-failed") } } label: { Label("Clear failed", systemImage: "xmark.circle") }
                    }
                }
            }
            if vm.jobs.isEmpty {
                ContentUnavailableView(
                    "No jobs",
                    systemImage: "gearshape.2",
                    description: Text("Jobs reported by the server appear here.")
                )
                .accessibilityIdentifier("adminJobsEmptyState")
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Jobs")
        }
    }

    // MARK: - Libraries

    @ViewBuilder
    private var librariesSection: some View {
        Section {
            ForEach(vm.libraries) { library in
                HStack(spacing: PVSpacing.s12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.name)
                            .font(.pvBody)
                            .foregroundStyle(Color.textPrimaryPV)
                        Text("\(library.assetCount ?? 0) assets")
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }
                .contextMenu {
                    Button {
                        Task { await vm.scanLibrary(library) }
                    } label: {
                        Label("Scan", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        pendingDeleteLibrary = library
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            if vm.libraries.isEmpty {
                ContentUnavailableView(
                    "No external libraries",
                    systemImage: "books.vertical",
                    description: Text("External libraries added on the server appear here.")
                )
                .accessibilityIdentifier("adminLibrariesEmptyState")
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Libraries (\(vm.libraries.count))")
        }
    }

    // MARK: - Read states

    /// The three sections, shown once a read succeeded (an empty one then says
    /// so; it never stands in for a failed read).
    @ViewBuilder
    private var listSections: some View {
        usersSection
        jobsSection
        librariesSection
    }

    /// "Try Again" with data on screen: the indicator stands in for the banner
    /// while the read runs; a failed refresh keeps the sections under it.
    @ViewBuilder
    private func reloadStatus(_ status: DataStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .reloading:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .pvLoadingIndicator("adminLoading")
                    .listRowBackground(Color.clear)
            }
        case .failed(let message):
            Section {
                InlineErrorBadge(message: message, retry: { Task { await vm.load(force: true) } })
                    .accessibilityIdentifier("adminRefreshError")
                    .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Helpers

    /// "2 active · 0 waiting · 41 completed · 1 failed": each count is its own
    /// catalog plural, so every language agrees each word with its number. Pure,
    /// so each shipped language is testable.
    static func jobSummary(_ c: QueueStatisticsDto, bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(
            localized: "\(c.active) active · \(c.waiting) waiting · \(c.completed) completed · \(c.failed) failed",
            bundle: bundle,
            locale: locale
        )
    }

    private static func displayName(_ raw: String) -> String {
        raw.splitBeforeUppercase
    }
}

private extension String {
    /// "thumbnailGeneration" → "Thumbnail Generation"
    var splitBeforeUppercase: String {
        var out = ""
        for (i, ch) in self.enumerated() {
            if i > 0, ch.isUppercase {
                out.append(" ")
            }
            out.append(ch)
        }
        return out.capitalized
    }
}
