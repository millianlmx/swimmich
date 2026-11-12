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
                LabeledContent("Cached offline", value: "\(vm.offlineCount)")
                LabeledContent("Offline size", value: vm.formattedUsage(vm.offlineBytes))
                LabeledContent("Last server check", value: vm.formattedLastReconciliation())
            } header: {
                Text("Local")
            }

            Section {
                if vm.storage.isLoading {
                    ProgressView()
                        .accessibilityIdentifier("mediaStatsServerLoading")
                }
                AccountStorageRows(
                    storage: vm.storage,
                    idPrefix: "mediaStatsServer",
                    showsQuotaBar: false
                ) { Task { await vm.load() } }
            } header: {
                Text("Server")
            }
        }
        .labeledContentStyle(.pvAdaptive)
        .navigationTitle("Media Stats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }
}
