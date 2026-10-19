import SwiftUI
import UIKit

/// Notification permission screen (issue #16) — pushed from `ProfileView`'s
/// Management section, so it declares **no** `NavigationStack` of its own
/// (StackView / OfflineAssetsView pattern; the hub sheet already owns one).
///
/// One question only: does iOS let Immich notify, and if not, where to fix it.
/// There is no toggle per notification type because the app produces a single
/// kind (the local "backup complete" alert) and the server pushes none.
struct NotificationSettingsView: View {
    @Bindable var vm: NotificationsViewModel

    @Environment(\.openURL) private var openURL

    /// Deep link into this app's page in Settings — the only place a refused
    /// permission can be turned back on.
    private var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    var body: some View {
        Form {
            Section {
                if vm.loaded {
                    LabeledContent {
                        Text(vm.isEnabled ? LocalizedStringKey("On") : LocalizedStringKey("Off"))
                            .foregroundStyle(vm.isEnabled ? Color.immichPrimary : Color.textSecondaryPV)
                    } label: {
                        Label("Notifications", systemImage: vm.isEnabled ? "bell.badge.fill" : "bell.slash")
                    }
                    .accessibilityIdentifier("notificationsStatusRow")

                    if vm.canAsk {
                        Button {
                            Task { await vm.requestPermission() }
                        } label: {
                            Label("Enable Notifications", systemImage: "bell.badge")
                        }
                        .disabled(vm.isRequesting)
                        .accessibilityIdentifier("notificationsEnableButton")
                    } else if let settingsURL {
                        Button {
                            openURL(settingsURL)
                        } label: {
                            Label("Open System Settings", systemImage: "gear")
                        }
                        .accessibilityIdentifier("notificationsOpenSettingsButton")
                    }
                } else {
                    HStack(spacing: PVSpacing.s8) {
                        ProgressView()
                        Text("Loading…")
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if let footer { Text(footer) }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    /// Nil until the system's answer is known: an empty `LocalizedStringKey`
    /// would be extracted as a catalog key of `""` — a string with nothing to
    /// translate.
    private var footer: LocalizedStringKey? {
        guard vm.loaded else { return nil }
        if vm.isEnabled {
            return "Swimmich tells you when a backup finishes."
        }
        if vm.canAsk {
            return "Swimmich tells you when a backup finishes, so a background backup isn't silent."
        }
        return "Notifications are off. iOS only asks once, so turn them back on in System Settings."
    }
}
