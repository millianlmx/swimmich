import SwiftUI

/// The locked folder (gap G12) — pushed from the Albums tab's Library section
/// (L-12).
///
/// Three doors, one screen: whichever state the session is in, the user stands
/// in front of the same view, so no back-and-forth can route around the PIN.
///
/// No `NavigationStack` of its own (the Albums tab owns the stack, exactly like
/// the other pushed screens; a second one would draw a second navigation bar),
/// and no re-lock on `onDisappear`: pushing the photo viewer makes this view
/// disappear, which would ask for the PIN after every photo. The explicit
/// "Lock now" button covers the intent; backgrounding the app re-locks an open
/// folder from `AuthenticatedRoot` (`relockIfUnlocked`), whichever tab is up.
struct LockedFolderView: View {
    let vm: LockedFolderViewModel

    @PVReduceMotion private var reduceMotion

    var body: some View {
        Group {
            if !vm.hasCheckedAccess {
                // First access check only: later checks keep the current door.
                ProgressView()
                    .pvLoadingIndicator("lockedFolderLoading")
            } else {
                switch vm.gate {
                case .needsSetup:
                    LockedFolderSetupView(vm: vm)
                case .locked:
                    LockedFolderPINView(vm: vm)
                case .unlocked:
                    LockedFolderGridView(vm: vm)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPrimary)
        .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.gate)
        .task { await vm.refreshGate() }
    }
}

// MARK: - Door 1: create the PIN

/// First run of the folder — the server has no PIN for this account yet.
private struct LockedFolderSetupView: View {
    @Bindable var vm: LockedFolderViewModel
    @FocusState private var focused: Bool
    @PVReduceMotion private var reduceMotion

    private var canSubmit: Bool {
        !vm.isBusy && vm.pinEntry.count == 6 && vm.pinEntry == vm.confirmationEntry
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                Text("Create a PIN")
                    .font(.pvTitle)
                    .foregroundStyle(Color.textPrimaryPV)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("lockedFolderSetupTitle")

                PVInputGroup {
                    SecureField("6 digits", text: $vm.pinEntry)
                        .keyboardType(.numberPad)
                        .font(.pvNumeric)
                        .focused($focused)
                        .accessibilityIdentifier("lockedFolderPINField")
                        .pvFieldSurface()

                    Divider()

                    SecureField("Confirm PIN", text: $vm.confirmationEntry)
                        .keyboardType(.numberPad)
                        .font(.pvNumeric)
                        .accessibilityIdentifier("lockedFolderConfirmPINField")
                        .pvFieldSurface()
                }

                if vm.biometricsAvailable {
                    Toggle("Unlock with Face ID", isOn: $vm.rememberPIN)
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textPrimaryPV)
                        .accessibilityIdentifier("lockedFolderRememberToggle")
                }

                if let message = vm.errorMessage {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("lockedFolderErrorText")
                        .transition(.opacity)
                }

                Button("Create a PIN") {
                    Task { await vm.setupPIN() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .accessibilityIdentifier("lockedFolderCreatePINButton")
            }
            .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.errorMessage)
            .padding(PVSpacing.s16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { focused = true }
    }
}

// MARK: - Door 2: enter the PIN

/// The session is not elevated and a PIN already exists.
private struct LockedFolderPINView: View {
    @Bindable var vm: LockedFolderViewModel
    @FocusState private var focused: Bool
    @PVReduceMotion private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s24) {
                Image(systemName: "lock")
                    .font(.pvTitleXL)
                    .foregroundStyle(Color.textSecondaryPV)

                Text("Locked Folder")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textPrimaryPV)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("lockedFolderPINTitle")

                PVInputGroup {
                    SecureField("6 digits", text: $vm.pinEntry)
                        .keyboardType(.numberPad)
                        .font(.pvNumeric)
                        .focused($focused)
                        .accessibilityIdentifier("lockedFolderPINField")
                        .pvFieldSurface()
                }

                if let message = vm.errorMessage {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("lockedFolderErrorText")
                        .transition(.opacity)
                }

                Button("Unlock") {
                    Task { await vm.submitPIN() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isBusy || vm.pinEntry.count != 6 || vm.attemptsExhausted)
                .accessibilityIdentifier("lockedFolderUnlockButton")

                // Face ID is a shortcut for a *remembered* PIN, never a door of its
                // own — hence the stored-PIN requirement, and its disappearance at
                // the attempt cap alongside the manual field.
                if vm.canUnlockWithBiometrics && !vm.attemptsExhausted {
                    Button("Unlock with Face ID") {
                        Task { await vm.unlockWithBiometrics() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy)
                    .accessibilityIdentifier("lockedFolderBiometricButton")
                }
            }
            .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.errorMessage)
            .padding(PVSpacing.s24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { focused = true }
    }
}

// MARK: - Door 3: the folder itself

/// The elevated session's grid: the timeline's cells, scoped to the folder.
private struct LockedFolderGridView: View {
    let vm: LockedFolderViewModel

    @Environment(AuthViewModel.self) private var auth
    @PVReduceMotion private var reduceMotion
    @State private var viewerItem: PhotoViewerItem?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    var body: some View {
        // One scroll container carries every state and `.refreshable`, so a
        // state change never cancels the pull in flight.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PVSpacing.s2) {
                statusBanner

                switch vm.gridState {
                case .loading:
                    PVSkeletonGrid(rows: 3, columnCount: columns.count)
                        .padding(.horizontal, PVSpacing.s4)
                        .pvLoadingIndicator("lockedFolderLoading")
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load photos",
                        message: message,
                        identifierPrefix: "lockedFolder",
                        retry: { Task { await vm.refreshGate() } }
                    )
                    .containerRelativeFrame(.vertical)
                case .empty:
                    emptyState
                        .containerRelativeFrame(.vertical)
                case .data(let status):
                    reloadStatus(status)
                    LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                        ForEach(vm.items) { item in
                            cellView(for: item)
                                .id(item.id)
                                .task {
                                    // Last cell in view pulls the next bucket,
                                    // exactly like the timeline.
                                    if item.id == vm.items.last?.id {
                                        await vm.loadMore()
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, PVSpacing.s4)
                }

                if vm.isLoadingMore {
                    PVSkeletonGrid(rows: 1, columnCount: columns.count)
                        .padding(.horizontal, PVSpacing.s4)
                }
            }
        }
        .refreshable { await vm.refresh() }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .toolbarBackground(.visible, for: .navigationBar)
        .immichAppBarTitleHeader("Locked Folder")
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            client: vm.client
        )
    }

    /// Status strip — the one visual difference from the timeline: the folder
    /// is open, and that state is visible and closable from here.
    private var statusBanner: some View {
        PVAdaptiveStack(vAlignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                PVStatusBadge(text: String(localized: "Unlocked"), color: .immichSuccess, symbol: "lock.open.fill")
                    .accessibilityIdentifier("lockedFolderStatusBadge")

                Spacer()

                Text(vm.itemCountText)
                    .font(.pvNumeric)
                    .foregroundStyle(Color.textSecondaryPV)
                    .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                    .accessibilityIdentifier("lockedFolderCountValue")
            }

            Button("Lock now") {
                Task { await vm.relock() }
            }
            .font(.pvSubhead)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            .accessibilityIdentifier("lockNowButton")
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
        .background(Color.bgSecondary)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing in your locked folder", systemImage: "lock")
        } description: {
            Text("Photos you move here are hidden from the timeline until you unlock it.")
        }
        .accessibilityIdentifier("lockedFolderEmptyState")
    }

    /// "Try Again" with photos on screen: the indicator stands in for the
    /// banner while the read runs; a failed refresh keeps the photos under it.
    @ViewBuilder
    private func reloadStatus(_ status: DataStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .reloading:
            ProgressView()
                .padding(.vertical, PVSpacing.s8)
                .frame(maxWidth: .infinity)
                .pvLoadingIndicator("lockedFolderLoading")
        case .failed(let message):
            InlineErrorBadge(message: message, retry: { Task { await vm.refreshGate() } })
                .padding(PVSpacing.s16)
                .accessibilityIdentifier("lockedFolderRefreshError")
        }
    }

    @ViewBuilder
    private func cellView(for item: AssetReactItem) -> some View {
        // No identifier on the cell wrapper: an identifier on a container
        // replaces its descendants', which would erase `assetTile_<id>` and the
        // badges inside `AssetThumbnailCell` (measured trap in this repo).
        let cell = AssetThumbnailCell(
            asset: item,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            selectionMode: vm.selectionMode,
            isSelected: vm.selectedIds.contains(item.id),
            onTap: {
                if vm.selectionMode {
                    vm.toggleSelection(id: item.id)
                } else {
                    openViewer(for: item)
                }
            }
        )

        if vm.selectionMode {
            cell
        } else {
            cell.onLongPressGesture(minimumDuration: 0.4) {
                vm.enterSelectionMode()
                vm.toggleSelection(id: item.id)
            }
        }
    }

    private func openViewer(for item: AssetReactItem) {
        guard let index = vm.items.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: vm.items, index: index)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ImmichAppBar(title: "Locked Folder")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await vm.restoreSelectionToTimeline() }
            } label: {
                Label("Move back to timeline", systemImage: "arrow.uturn.backward")
            }
            .disabled(vm.selectedIds.isEmpty || vm.isBusy)
            .accessibilityIdentifier("restoreFromLockedFolderButton")
        }
    }
}
