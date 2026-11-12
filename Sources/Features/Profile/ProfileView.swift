import SwiftUI

/// Account, settings and tools hub (PRD §4 restructure): the account row,
/// saved servers, storage usage + quota, preferences, backup, administration,
/// diagnostics, security and logout. Content collections live in the Albums
/// tab's Library section (L-12), never here.
struct ProfileView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppLockViewModel.self) private var appLock
    @Environment(\.openURL) private var openURL
    @State var storage: StorageStatsViewModel
    @State var upload: UploadViewModel
    @State var uploadDetail: UploadDetailViewModel
    @State var admin: AdminViewModel
    @State var notifications: NotificationsViewModel
    @State var language: LanguageSettingsViewModel
    /// Connected devices (gap G19). Built by the composition root and owned by
    /// `RootView`, so the pushed screen and its row share one instance.
    @State var deviceSessions: DeviceSessionsViewModel
    /// Preferences screen (gap G22). A pass-through to the process-wide store,
    /// owned by `AuthenticatedRoot` like the other hub view models.
    @State var appSettings: PreferencesViewModel
    /// Read-only mode (gap G17). The composition root's store, not a copy: the
    /// switch below, the avatar's badge and the client guard are three readers
    /// of the same boolean.
    @State var readOnly: ReadOnlyModeStore
    @State var freeUpSpace: FreeUpSpaceViewModel
    /// Profile picture screen (gap G16). Built by the composition root and owned
    /// by `RootView`, so the row below and the pushed screen show one photo.
    @State var profilePicture: ProfilePictureViewModel
    /// Change-password screen (gap G18). Built by the composition root: the
    /// screen is pushed, so the row and the form must show one instance.
    @State var changePassword: ChangePasswordViewModel
    /// User API keys (gap G20). A `@State`, like the hub's other ViewModels: the
    /// sheet's lifetime is its owner's.
    @State var apiKeys: UserApiKeysViewModel
    /// "What's New" (gap G23). Carried through from `AuthenticatedRoot` so the
    /// About row reopens the same cards, on the same seen-release, as the
    /// automatic sheet.
    @State var whatsNew: WhatsNewViewModel

    /// The Advanced section's three instruments (gap G24). Owned by `RootView`
    /// like the rest of the hub's state, so a row and the screen it pushes
    /// project one instance.
    @State var appLog: AppLogViewModel
    @State var mediaStats: MediaStatsViewModel
    @State var downloadInfo: DownloadInfoViewModel
    /// The client certificate of the active server (L-10), pushed from Advanced.
    @State var clientCertificate: ClientCertificateViewModel
    /// Drives the logout confirmation dialog (SP-4).
    @State private var showLogoutConfirm = false
    /// An activation prompt is on screen: the toggle shows "on" and ignores taps.
    @State private var isActivatingAppLock = false
    /// The last activation was refused because the device cannot authenticate.
    /// Lives with the sheet: never persisted.
    @State private var appLockUnavailable = false

    private func setAppLock(_ on: Bool) {
        guard !isActivatingAppLock else { return }
        guard on else {
            appLock.disable()
            return
        }
        appLockUnavailable = false
        isActivatingAppLock = true
        Task {
            let result = await appLock.requestEnable()
            isActivatingAppLock = false
            appLockUnavailable = (result == .unavailable)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let user = auth.userName, let email = auth.userEmail {
                    Section {
                        NavigationLink {
                            ProfilePictureView(vm: profilePicture)
                        } label: {
                            profilePictureRow
                        }
                        .accessibilityIdentifier("profilePictureRow")

                        LabeledContent("Name") {
                            Text(user).accessibilityIdentifier("profileNameValue")
                        }
                        LabeledContent("Email") {
                            Text(email).accessibilityIdentifier("profileEmailValue")
                        }
                    } header: {
                        Text("Account")
                    }
                }

                serversSection

                webSection

                storageSection

                // App preferences and Language sit together rather than in
                // Management: both are device-level choices, not another
                // library screen. Preferences leads because it is the wider
                // one — and its icon (`slider.horizontal.3`) stays distinct
                // from Language's `globe`.
                Section {
                    NavigationLink {
                        PreferencesView(vm: appSettings)
                    } label: {
                        Label("Preferences", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("preferencesRow")

                    NavigationLink {
                        LanguageSettingsView(vm: language)
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                    .accessibilityIdentifier("languageRow")
                } header: {
                    Text("General")
                }

                Section {
                    NavigationLink {
                        BackupSettingsView(vm: upload, detail: uploadDetail)
                    } label: {
                        Label("Backup", systemImage: "icloud.and.arrow.up")
                    }
                .accessibilityIdentifier("backupRow")

                    // Next to Backup on purpose: the only notification this app
                    // posts is the end of a backup run.
                    NavigationLink {
                        NotificationSettingsView(vm: notifications)
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("notificationsRow")

                    // Last in Management on purpose: it acts on what the DEVICE
                    // holds and keeps the Backup / Sync cluster (what goes up)
                    // intact.
                    NavigationLink {
                        FreeUpSpaceView(vm: freeUpSpace)
                    } label: {
                        Label("Free Up Space", systemImage: "externaldrive.badge.minus")
                    }
                    .accessibilityIdentifier("freeUpSpaceRow")

                    // Last in Management, and deliberately OUTSIDE the admin-only
                    // section below: the list endpoint is scoped to the bearer of
                    // the token, so every account manages its own keys here
                    // (gap G20).
                    NavigationLink {
                        UserApiKeysView(vm: apiKeys)
                    } label: {
                        Label("API Keys", systemImage: "key.horizontal")
                    }
                    .accessibilityIdentifier("apiKeysRow")
                } header: {
                    Text("Management")
                }

                if auth.isAdmin {
                    Section {
                        NavigationLink {
                            AdminView(vm: admin)
                        } label: {
                            Label("Administration", systemImage: "gearshape.2")
                        }
                    .accessibilityIdentifier("adminRow")
                    } header: {
                        Text("Administration")
                    }
                }

                // About sits between Administration and Security on purpose: it
                // describes the app itself, not the account, and the two rows
                // above and below it are about what this device is allowed to do.
                Section {
                    NavigationLink {
                        AboutView(whatsNew: whatsNew)
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("aboutRow")
                } header: {
                    Text("About")
                }

                // Diagnostics and the network settings the official client keeps
                // under Advanced (custom headers). The three diagnostic screens
                // only report what the app believes; the fourth diagnostic — the
                // asset troubleshoot — lives on the photo it describes, never
                // here: its page is parameterized by an asset.
                Section {
                    if let serverKey = auth.baseURL.flatMap({ ServerKey(url: $0) }) {
                        NavigationLink {
                            CustomHeadersScreen(
                                serverKey: serverKey,
                                onSaved: { auth.customHeadersDidChange(for: $0) }
                            )
                        } label: {
                            Label("Custom HTTP Headers", systemImage: "list.bullet.rectangle")
                        }
                        .accessibilityIdentifier("customHeadersRow")
                    }

                    NavigationLink {
                        AppLogView(vm: appLog)
                    } label: {
                        Label("App Logs", systemImage: "doc.text.magnifyingglass")
                    }
                    .accessibilityIdentifier("appLogsRow")

                    NavigationLink {
                        MediaStatsView(vm: mediaStats)
                    } label: {
                        Label("Media Stats", systemImage: "chart.bar.xaxis")
                    }
                    .accessibilityIdentifier("mediaStatsRow")

                    NavigationLink {
                        DownloadInventoryView(vm: downloadInfo)
                    } label: {
                        Label("Download Info", systemImage: "arrow.down.doc")
                    }
                    .accessibilityIdentifier("downloadInfoRow")

                    NavigationLink {
                        ClientCertificateView(vm: clientCertificate)
                    } label: {
                        Label("Client Certificate", systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("clientCertificateRow")
                } header: {
                    Text("Advanced")
                }

                // App lock lives here rather than on the Backup screen: it
                // guards the whole app, not the backup run.
                Section {
                    // Above the toggle on purpose: this row answers a
                    // server-side request about the account itself, where the
                    // toggle below is a setting of this device.
                    NavigationLink {
                        ChangePasswordView(vm: changePassword, onPasswordChanged: { auth.notePasswordChanged() })
                    } label: {
                        Label("Change Password", systemImage: "key")
                    }
                    .accessibilityIdentifier("changePasswordRow")

                    // The server's own signal that an administrator reset this
                    // account's password: an invitation, not a wall — the row
                    // above stays the only way in, and nothing is gated on it.
                    if auth.shouldChangePassword {
                        Label("This server asks you to change your password.", systemImage: "exclamationmark.triangle.fill")
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichWarning)
                            .accessibilityIdentifier("shouldChangePasswordNotice")
                    }

                    // Bound to the model, not to `@AppStorage`: the key must only
                    // turn `true` once the authentication has succeeded. The
                    // toggle reads "on" while the prompt is up, then settles.
                    Toggle("Require Face ID", isOn: Binding(
                        get: { appLock.isEnabled || isActivatingAppLock },
                        set: { setAppLock($0) }
                    ))
                    .accessibilityIdentifier("appLockToggle")

                    // Only for a device that cannot authenticate at all; a
                    // failed or cancelled prompt stays silent.
                    if appLockUnavailable {
                        Label("To turn on “Require Face ID”, set a device passcode (and Face ID if you want) in iOS Settings.", systemImage: "exclamationmark.triangle.fill")
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichWarning)
                            .accessibilityIdentifier("appLockUnavailableNotice")
                    }

                    // After the app lock, before the logout button: sessions are
                    // a security object, not a library screen — and this row
                    // signs other devices out, which is what "Log Out" below
                    // deliberately cannot do.
                    NavigationLink {
                        DeviceSessionsView(vm: deviceSessions)
                    } label: {
                        Label("Connected Devices", systemImage: "laptopcomputer.and.iphone")
                    }
                    .accessibilityIdentifier("deviceSessionsRow")
                    // A device preference like the app lock right above (the
                    // upstream client keeps it in its own Advanced screen; this
                    // hub has no such section, and the lock is a lock).
                    Toggle("Read-only Mode", isOn: Binding(
                        get: { readOnly.isEnabled },
                        set: { readOnly.setEnabled($0) }
                    ))
                    .accessibilityIdentifier("readOnlyModeToggle")

                    if readOnly.isEnabled {
                        PVStatusBadge(text: "Read-only", color: .immichWarning, symbol: "lock.fill")
                    }
                } header: {
                    Text("Security")
                } footer: {
                    // A List footer renders ONE view: sibling `Text`s collapse to a
                    // TupleView and only the first is drawn and published, measured
                    // on 2026-09-15 by the read-only scenario. One VStack, every line.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Asks for Face ID (or your passcode) every time Immich comes back to the foreground, so someone holding your unlocked phone can't browse your photos.")
                        Text("Photos in the locked folder are hidden everywhere else and open with your Immich PIN — a separate code from this app lock.")
                        Text("Prevents deleting, editing and uploading. Browsing stays available.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(auth.isLoading)
                    .accessibilityIdentifier("logoutButton")
                }
            }
            .labeledContentStyle(.pvAdaptive)
            .accessibilityIdentifier("profileList")
            .navigationTitle("Me")
            // Logging out purges offline photos, caches and saved servers
            // (deconnexion-laisse-donnees): nothing is erased before this is
            // confirmed. An alert, not a confirmationDialog: on iOS 26 a
            // confirmationDialog is a popover anchored to its source and drops
            // the cancel button (measured on the iPhone 17 / iOS 26.4 simulator),
            // while the alert always shows both actions.
            .alert("Log out?", isPresented: $showLogoutConfirm) {
                Button("Log Out", role: .destructive) {
                    Task { await auth.logout() }
                }
                .accessibilityIdentifier("logoutConfirmButton")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Photos downloaded for offline use and the cache will be deleted from this device, along with saved servers and accounts.")
            }
            .navigationBarTitleDisplayMode(.inline)
            .task { await storage.load() }
            // The flag is a server fact, not a login-only event: re-read it
            // here so a password reset that happened mid-session still shows.
            .task { await auth.refreshShouldChangePassword() }
            // The Account row carries the avatar, so the identity has to be
            // known before the screen that publishes the photo is opened.
            .task { await profilePicture.load() }
            .refreshable { await storage.load() }
        }
    }

    /// Account row for the profile picture (gap G16). It carries the avatar on
    /// purpose: a plain label would promise a photo the hub never shows.
    @ViewBuilder
    private var profilePictureRow: some View {
        HStack(spacing: PVSpacing.s12) {
            if let user = profilePicture.avatarUser {
                UserAvatarCircle(user: user, size: 40, baseURL: auth.baseURL, token: auth.accessToken)
            } else {
                // Identity still in flight (or unreachable): keep the row's
                // height and let the avatar arrive rather than jump.
                Circle()
                    .fill(Color.bgTertiary)
                    .frame(width: 40, height: 40)
            }
            Text("Profile Picture")
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
        }
        .frame(minHeight: 44)
    }

    /// Saved accounts / servers (P5 multi-server): tap to switch, swipe to
    /// remove, or add a brand-new account.
    @ViewBuilder
    private var serversSection: some View {
        Section {
            ForEach(auth.savedAccounts) { account in
                Button {
                    Task { await auth.switchToAccount(account) }
                } label: {
                    HStack(spacing: PVSpacing.s8) {
                        Label(account.name ?? account.url, systemImage: "server.rack")
                            .foregroundStyle(.primary)
                        Spacer()
                        if account.id == auth.activeAccountID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.immichPrimary)
                        }
                    }
                }
                .accessibilityIdentifier("savedAccountRow_\(account.id)")
            }
            .onDelete { offsets in
                for index in offsets {
                    auth.removeSavedAccount(auth.savedAccounts[index])
                }
            }

            Button {
                auth.addNewServer()
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .accessibilityIdentifier("addAccountButton")
        } header: {
            Text("Servers")
        }
    }

    /// Open the Immich web UI of the active server in the browser (gap #9).
    @ViewBuilder
    private var webSection: some View {
        Section {
            Button {
                if let url = auth.baseURL { openURL(url) }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .disabled(auth.baseURL == nil)
            .accessibilityIdentifier("openInBrowserButton")
        } header: {
            Text("Server")
        }
    }

    /// Account storage (own counts, usage, quota): the shared rows, then the
    /// loading indicator.
    @ViewBuilder
    private var storageSection: some View {
        Section {
            AccountStorageRows(
                storage: storage,
                idPrefix: "profileStorage",
                showsQuotaBar: true
            ) { Task { await storage.load() } }
            if storage.isLoading {
                HStack(spacing: PVSpacing.s8) {
                    ProgressView()
                    Text("Loading…")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                .accessibilityIdentifier("profileStorageLoading")
            }
        } header: {
            Text("Storage")
        }
    }
}

/// The account-storage rows shared by the Me hub and Media Stats. Each half of
/// `StorageStatsViewModel` renders on its own: a value that was read, or
/// "Unavailable" plus a badge with Try Again — never a "0" for a half that was
/// not read, and never a bar or a "0" for an account without quota.
///
/// Order: Photos, Videos, counts badge, Usage, bar, Quota, usage badge.
struct AccountStorageRows: View {
    let storage: StorageStatsViewModel
    /// Prefix of every `accessibilityIdentifier` (`<prefix>Photos`, …).
    let idPrefix: String
    let showsQuotaBar: Bool
    let retry: () -> Void

    var body: some View {
        switch storage.counts {
        case .loaded(let counts):
            LabeledContent("Photos", value: counts.photos.formatted())
                .accessibilityIdentifier("\(idPrefix)Photos")
            LabeledContent("Videos", value: counts.videos.formatted())
                .accessibilityIdentifier("\(idPrefix)Videos")
        case .unavailable(let message):
            LabeledContent("Photos", value: String(localized: "Unavailable"))
                .accessibilityIdentifier("\(idPrefix)Photos")
            LabeledContent("Videos", value: String(localized: "Unavailable"))
                .accessibilityIdentifier("\(idPrefix)Videos")
            InlineErrorBadge(message: message, retry: retry)
                .accessibilityIdentifier("\(idPrefix)CountsError")
        case .notLoaded:
            EmptyView()
        }
        switch storage.usage {
        case .loaded(let usage):
            LabeledContent("Usage", value: StorageStatsViewModel.format(usage.usedBytes))
                .accessibilityIdentifier("\(idPrefix)Usage")
            if showsQuotaBar, let fraction = usage.fraction {
                ProgressView(value: fraction)
                    .accessibilityIdentifier("\(idPrefix)QuotaBar")
            }
            LabeledContent(
                "Quota",
                value: usage.quotaBytes.map(StorageStatsViewModel.format) ?? String(localized: "Unlimited")
            )
            .accessibilityIdentifier("\(idPrefix)Quota")
        case .unavailable(let message):
            LabeledContent("Usage", value: String(localized: "Unavailable"))
                .accessibilityIdentifier("\(idPrefix)Usage")
            LabeledContent("Quota", value: String(localized: "Unavailable"))
                .accessibilityIdentifier("\(idPrefix)Quota")
            InlineErrorBadge(message: message, retry: retry)
                .accessibilityIdentifier("\(idPrefix)UsageError")
        case .notLoaded:
            EmptyView()
        }
    }
}
