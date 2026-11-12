import SwiftUI

/// Connected devices (gap G19) — the account's sessions, one screen.
///
/// A **control** screen, not a reading one: it answers "who is signed in, and
/// how do I get one of them out?". Three rules drive the surface:
///
/// 1. The current session is never a row like the others. It opens the list,
///    carries the "This device" badge, and offers **no** revocation affordance
///    — no trash, no swipe, no menu. You do not sign yourself out by accident.
/// 2. Two destructions, two confirmations, two texts. The bulk one says
///    explicitly that this device stays signed in.
/// 3. The screen exposes devices, so it carries nothing extra: no session id,
///    no `isPendingSyncReset`, and nothing that can reach the clipboard.
///
/// Pushed from `ProfileView`'s `NavigationStack`, so it deliberately declares
/// none of its own — a second one would stack a second navigation bar (the
/// trap `LanguageSettingsView` paid for). Same contract as `RecentAssetsView`.
struct DeviceSessionsView: View {
    @Bindable var vm: DeviceSessionsViewModel

    @PVReduceMotion private var reduceMotion

    @State private var showRevokeAllConfirm = false
    @State private var showUnlock = false
    @State private var pin = ""

    var body: some View {
        List {
            switch vm.renderState {
            case .loading:
                loadingPlaceholders
            case .error(let message):
                Section {
                    PVErrorStateView(
                        title: "Couldn't load devices",
                        message: message,
                        identifierPrefix: "deviceSessions",
                        retry: { Task { await vm.load() } }
                    )
                    .listRowBackground(Color.clear)
                }
            case .empty:
                Section {
                    emptyState
                }
            case .data(let status):
                switch status {
                case .idle:
                    EmptyView()
                case .reloading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .pvLoadingIndicator("deviceSessionsLoading")
                    }
                case .failed(let message):
                    errorSection(message)
                }
                // "This device" is written first, and it carries nothing
                // destructive: the only revocation in this view lives in the
                // `otherSessions` branch below, so it cannot reach the session
                // in use. The current one is not even offered the gesture.
                if let session = vm.currentSession {
                    Section {
                        DeviceSessionRow(session: session, vm: vm)
                            .accessibilityIdentifier("deviceSessionRow_\(session.id)")
                    } header: {
                        Text("This device")
                    }
                }

                Section {
                    ForEach(vm.otherSessions) { session in
                        DeviceSessionRow(session: session, vm: vm)
                            .accessibilityIdentifier("deviceSessionRow_\(session.id)")
                            // `allowsFullSwipe: false`: a full swipe would sign
                            // a device out on a flick, past the confirmation.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    vm.requestRevoke(session)
                                } label: {
                                    Label("Log Out", systemImage: "trash")
                                }
                                .accessibilityIdentifier("deviceSessionRevokeButton_\(session.id)")
                            }
                    }
                } header: {
                    Text("Other devices")
                } footer: {
                    Text("Swipe a device to sign it out. Your current device stays signed in.")
                }
            }

            // An action's failure (revoke, lock, unlock) keeps its own message
            // and never replaces the list.
            if let message = vm.errorMessage {
                Section {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("deviceSessionsActionError")
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.bgPrimary)
        .accessibilityIdentifier("deviceSessionsList")
        .navigationTitle("Connected Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.refresh() }
        .toolbar { toolbar }
        // A PIN is a single six-digit field, so it is an alert and not a sheet.
        .alert("Unlock", isPresented: $showUnlock) {
            TextField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("deviceSessionsUnlockField")
            Button("Unlock") {
                Task { await vm.unlock(pinCode: pin) }
            }
            .accessibilityIdentifier("deviceSessionsUnlockConfirm")
            Button("Cancel", role: .cancel) { pin = "" }
        } message: {
            Text("Enter the 6-digit PIN of your account to reach locked photos.")
        }
        .confirmationDialog(
            pendingRevokePrompt,
            isPresented: Binding(
                get: { vm.pendingRevocation != nil },
                set: { if !$0 { vm.pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let session = vm.pendingRevocation {
                    Task { await vm.revoke(session) }
                }
            } label: {
                Text("Log Out")
            }
            // Same label as the swipe action that raised this dialog: the
            // identifier is the only unambiguous handle from a UI test.
            .accessibilityIdentifier("deviceSessionRevokeConfirm")
            Button("Cancel", role: .cancel) { vm.pendingRevocation = nil }
        } message: {
            Text("This device will have to sign in again.")
        }
        .confirmationDialog(
            vm.revokeAllPrompt,
            isPresented: $showRevokeAllConfirm,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await vm.revokeAllOthers() }
            } label: {
                Text(vm.revokeAllButtonTitle)
            }
            .accessibilityIdentifier("deviceSessionsRevokeAllConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            // The one sentence the single-device confirmation must NOT share:
            // signing the others out leaves this device exactly where it is.
            Text("Your current device stays signed in.")
        }
    }

    // MARK: - States

    /// The failure of a read stays in context: the rows already loaded remain
    /// listed and revocable, and the retry is the reload itself.
    private func errorSection(_ message: String) -> some View {
        Section {
            InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                .accessibilityIdentifier("deviceSessionsErrorBadge")
                .listRowBackground(Color.clear)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No connected devices", systemImage: "laptopcomputer.and.iphone")
        } description: {
            Text("Sign in from another device to see it here.")
        }
        .accessibilityIdentifier("deviceSessionsEmptyView")
        .listRowBackground(Color.clear)
    }

    /// Template rows, `.redacted` rather than shimmered: the repository's
    /// skeleton is `PVSkeletonGrid`, a *grid* animation, and this screen is a
    /// list. One element for the whole block, so one identifier carries it.
    private var loadingPlaceholders: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    DeviceSessionPlaceholderRow()
                        .redacted(reason: .placeholder)
                }
            }
            .pvLoadingIndicator("deviceSessionsLoading")
        }
    }

    // MARK: - Toolbar

    /// A lock (a state) and a menu (an action that erases N sessions): they do
    /// not share a row. The menu also keeps the destructive bulk action one
    /// deliberate tap away.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                pin = ""
                if vm.isElevated {
                    Task { await vm.lockCurrentSession() }
                } else {
                    showUnlock = true
                }
            } label: {
                Image(systemName: vm.isElevated ? "lock.open" : "lock")
                    .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
            }
            .accessibilityLabel(Text(vm.isElevated ? "Lock session" : "Unlock"))
            // A failed probe leaves the elevation unconfirmed: the control keeps
            // the last value the server did report and says so, rather than
            // passing it off as current.
            .accessibilityValue(vm.isElevationStale ? Text("Unknown") : Text(verbatim: ""))
            .accessibilityIdentifier("deviceSessionsLockButton")
            .animation(
                PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion),
                value: vm.isElevated
            )

            Menu {
                Button("Log out other devices", role: .destructive) {
                    showRevokeAllConfirm = true
                }
                .disabled(vm.otherSessions.isEmpty)
                .accessibilityIdentifier("deviceSessionsRevokeAllButton")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            // The menu's label is a bare SF Symbol, so without an identifier the
            // only way to open it would be its position in the toolbar.
            .accessibilityIdentifier("deviceSessionsMenuButton")
            .accessibilityLabel("Options")
        }
    }

    /// The confirmation's title is the device's name: a swipe on one row must
    /// never be ambiguous about which device it signs out.
    private var pendingRevokePrompt: String {
        guard let session = vm.pendingRevocation else { return "" }
        return vm.revokePrompt(for: session)
    }
}

// MARK: - Row

/// One device. `OS • type (vX.Y.Z)`, when it was last seen (relative and
/// absolute), the "This device" badge on the session in use, and the "Expired"
/// badge when the server stamped an expiry in the past. No session id, nothing
/// selectable, nothing copyable.
private struct DeviceSessionRow: View {
    let session: SessionResponseDto
    let vm: DeviceSessionsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: PVSpacing.s12) {
            Image(systemName: vm.deviceSymbol(for: session))
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                HStack(spacing: PVSpacing.s8) {
                    Text(verbatim: vm.deviceDescription(for: session))
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textPrimaryPV)

                    if session.current {
                        PVStatusBadge(
                            text: String(localized: "This device"),
                            color: .immichSuccess,
                            symbol: "checkmark"
                        )
                    } else if vm.isExpired(session) {
                        PVStatusBadge(
                            text: String(localized: "Expired"),
                            color: .immichWarning,
                            symbol: "clock.badge.exclamationmark"
                        )
                    }
                }

                Text(verbatim: vm.lastSeenText(for: session))
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)

                Text(verbatim: vm.lastSeenAbsoluteText(for: session))
                    .font(.pvCaption)
                    .foregroundStyle(Color.textTertiaryPV)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: vm.accessibilityLabel(for: session)))
    }
}

/// The loading shape of a device row — never shown unredacted.
private struct DeviceSessionPlaceholderRow: View {
    var body: some View {
        HStack(spacing: PVSpacing.s12) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.pvHeadline)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text("Connected Devices")
                    .font(.pvSubhead)
                Text("Last seen")
                    .font(.pvCaption)
            }
        }
    }
}
