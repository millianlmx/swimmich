import SwiftUI

/// Profile identity + relocation hub for the features that lost their top-level
/// tab in the PRD §4 restructure (Trash, Backup) + logout. Since P1
/// storage-stats, also shows the server's storage usage + quota.
struct ProfileView: View {
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppLockViewModel.self) private var appLock
    @AppStorage(AppLockViewModel.enabledKey) private var appLockEnabled = false
    @Environment(\.openURL) private var openURL
    @State var trash: TrashViewModel
    @State var storage: StorageStatsViewModel
    @State var upload: UploadViewModel
    @State var uploadDetail: UploadDetailViewModel
    @State var duplicates: DuplicatesViewModel
    @State var people: PeopleViewModel
    @State var tags: TagsViewModel
    @State var stacks: StacksViewModel
    @State var partners: PartnersViewModel
    @State var admin: AdminViewModel
    @State var offline: OfflineDownloadViewModel
    @State var recentTaken: RecentAssetsViewModel
    @State var recentAdded: RecentAssetsViewModel
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
    @State var localLibrary: LocalLibraryViewModel
    @State var freeUpSpace: FreeUpSpaceViewModel
    @State var folders: FolderViewModel
    /// Profile picture screen (gap G16). Built by the composition root and owned
    /// by `RootView`, so the row below and the pushed screen show one photo.
    @State var profilePicture: ProfilePictureViewModel
    /// Locked folder (gap G12). A plain `let`, not a `@State`: the ViewModel's
    /// lifetime is the Me sheet's (`AuthenticatedRoot` owns it), so re-entering
    /// the row does not reset a folder the user is working in.
    let lockedFolder: LockedFolderViewModel
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
    /// Drives the logout confirmation dialog (SP-4).
    @State private var showLogoutConfirm = false

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

                        LabeledContent("Name", value: user)
                        LabeledContent("Email", value: email)
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

                // Consultation, not configuration: two read-only grids over the
                // library sit above Management, which carries settings. Pushed
                // without a stack — this view already owns one.
                Section {
                    NavigationLink {
                        RecentAssetsView(vm: recentTaken)
                    } label: {
                        Label("Recently Taken", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("recentTakenRow")

                    NavigationLink {
                        RecentAssetsView(vm: recentAdded)
                    } label: {
                        Label("Recently Added", systemImage: "arrow.up.circle")
                    }
                    .accessibilityIdentifier("recentAddedRow")
                } header: {
                    Text("Recently")
                }

                Section {
                    NavigationLink {
                        TrashView(vm: trash)
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                .accessibilityIdentifier("trashRow")

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

                    NavigationLink {
                        DuplicatesView(vm: duplicates)
                    } label: {
                        Label("Duplicates", systemImage: "rectangle.on.rectangle.angled")
                    }
                .accessibilityIdentifier("duplicatesRow")

                    NavigationLink {
                        PeopleView(vm: people)
                    } label: {
                        Label("People", systemImage: "person.2")
                    }
                .accessibilityIdentifier("peopleRow")

                    NavigationLink {
                        TagsView(vm: tags)
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                .accessibilityIdentifier("tagsRow")

                    NavigationLink {
                        StackView(vm: stacks)
                    } label: {
                        Label("Stacks", systemImage: "square.stack.3d.down.right")
                    }
                .accessibilityIdentifier("stacksRow")

                    NavigationLink {
                        PartnersView(vm: partners)
                    } label: {
                        Label("Partners", systemImage: "person.badge.plus")
                    }
                .accessibilityIdentifier("partnersRow")

                    NavigationLink {
                        OfflineAssetsView(vm: offline)
                    } label: {
                        Label("Offline Storage", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("offlineStorageRow")

                    // Next to Offline Storage on purpose: the two lines read the
                    // same library from its two sides — what the device keeps in
                    // cache, and the tree the server sees on its disk.
                    NavigationLink {
                        FolderView(vm: folders, node: nil)
                    } label: {
                        Label("Folders", systemImage: "folder")
                    }
                    .accessibilityIdentifier("foldersRow")

                    // Next to Offline Storage on purpose: both lines read the
                    // device, not the server.
                    NavigationLink {
                        LocalLibraryView(vm: localLibrary)
                    } label: {
                        Label("On this device", systemImage: "iphone")
                    }
                    .accessibilityIdentifier("localLibraryRow")
                    // Last in Management on purpose: it acts on what the DEVICE
                    // holds, like the Offline Storage row right above, and keeps
                    // the Backup / Sync cluster (what goes up) intact.
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

                // Instruments, not settings: these three screens only report
                // what the app believes. One header keeps them apart from the
                // preferences above, and the fourth diagnostic — the asset
                // troubleshoot — lives on the photo it describes, never here:
                // its page is parameterized by an asset.
                Section {
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
                } header: {
                    Text("Advanced")
                }

                // App lock lives here rather than on the Backup screen: it
                // guards the whole app, not the backup run.
                Section {
                    // The locked folder is a place, the toggle below is a
                    // setting: a row, not a switch — and it comes first because
                    // it is the narrower protection (one folder vs the app).
                    NavigationLink {
                        LockedFolderView(vm: lockedFolder)
                    } label: {
                        Label("Locked Folder", systemImage: "lock")
                    }
                    .accessibilityIdentifier("lockedFolderRow")

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

                    Toggle("Require Face ID", isOn: $appLockEnabled)
                        .onChange(of: appLockEnabled) { _, newValue in
                            appLock.setEnabled(newValue)
                        }
                        .accessibilityIdentifier("appLockToggle")

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
        } header: {
            Text("Server")
        }
    }

    /// Server storage usage (P1 storage-stats): photo/video counts, total
    /// bytes used and, when the server defines a quota, a determinate bar.
    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent("Photos", value: storage.photos.formatted())
            LabeledContent("Videos", value: storage.videos.formatted())
            LabeledContent("Usage", value: StorageStatsViewModel.format(storage.usage))
            if let quota = storage.quotaSizeInBytes, quota > 0 {
                ProgressView(
                    value: min(Double(storage.usage) / Double(quota), 1.0)
                )
                LabeledContent("Quota", value: StorageStatsViewModel.format(quota))
            }
            if storage.isLoading {
                HStack(spacing: PVSpacing.s8) {
                    ProgressView()
                    Text("Loading…")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
            } else if let error = storage.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.pvCaption)
                    .foregroundStyle(Color.immichError)
            }
        } header: {
            Text("Storage")
        }
    }
}
