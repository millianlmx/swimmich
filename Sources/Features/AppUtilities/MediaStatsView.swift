import SwiftUI

/// Media Stats (gap G24) — the numbers, side by side: what this device holds and
/// what the server holds.
///
/// The two sections are the two halves of the question. `Local` reads only the
/// device (the ledger and the cache) and is therefore always available, even
/// with no connection; `Server` is the account's own storage (two reads, each
/// with its own "Unavailable" and Try Again).
///
/// Pushed from `ProfileView`'s Advanced section, which owns the hub's navigation
/// container — no `NavigationStack` here.
struct MediaStatsView: View {
    @Bindable var vm: MediaStatsViewModel

    var body: some View {
        List {
            Section {
                LabeledContent("Tracked assets", value: "\(vm.trackedCount)")
                if let message = vm.offlineListingErrorMessage {
                    LabeledContent("Cached offline", value: String(localized: "Unavailable"))
                        .accessibilityIdentifier("mediaStatsCachedOffline")
                    LabeledContent("Offline size", value: String(localized: "Unavailable"))
                        .accessibilityIdentifier("mediaStatsOfflineSize")
                    InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                        .accessibilityIdentifier("mediaStatsLocalError")
                } else {
                    LabeledContent("Cached offline", value: "\(vm.offlineCount)")
                        .accessibilityIdentifier("mediaStatsCachedOffline")
                    LabeledContent("Offline size", value: vm.formattedUsage(vm.offlineBytes))
                        .accessibilityIdentifier("mediaStatsOfflineSize")
                }
                LabeledContent("Last server check", value: vm.formattedLastReconciliation())
            } header: {
                Text("Local")
            }

            Section {
                if vm.storage.isLoading {
                    ProgressView()
                        .pvLoadingIndicator("mediaStatsServerLoading")
                }
                AccountStorageRows(
                    storage: vm.storage,
                    idPrefix: "mediaStatsServer",
                    showsQuotaBar: false,
                    showsEmptyCounts: true
                ) { Task { await vm.load() } }
            } header: {
                Text("Server")
            }
        }
        .navigationTitle("Media Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}
