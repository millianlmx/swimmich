import SwiftUI

/// Stack list — the hub surface for `/api/stacks` (gap #1). Pushed from
/// the Albums tab's Library section (L-12), so it declares **no** `NavigationStack`
/// of its own (TagsView / PeopleView pattern; the tab already owns one).
struct StackView: View {
    @Bindable var vm: StacksViewModel
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        Group {
            if vm.isLoading && vm.stacks.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.stacks.isEmpty {
                ContentUnavailableView {
                    Label("No stacks yet", systemImage: "square.stack.3d.down.right")
                } description: {
                    Text(vm.errorMessage ?? "Group similar photos — bursts, edits, brackets — to keep your timeline clean.")
                } actions: {
                    if vm.errorMessage != nil {
                        Button("Retry") { Task { await vm.loadStacks(force: true) } }
                            .buttonStyle(PVPrimaryButtonStyle())
                    }
                }
            } else {
                List {
                    if let errorMessage = vm.errorMessage {
                        Text(errorMessage)
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichError)
                    }

                    ForEach(vm.stacks, id: \.id) { stack in
                        NavigationLink {
                            StackDetailView(stackId: stack.id, vm: vm)
                        } label: {
                            StackRowView(stack: stack)
                        }
                        .accessibilityIdentifier("stackRow_\(stack.id)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await vm.deleteStack(id: stack.id) }
                            } label: {
                                Label("Unstack", systemImage: "square.stack.3d.up.slash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Stacks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create stack")
                .accessibilityIdentifier("newStackButton")
            }
        }
        .task { await vm.loadStacks() }
        .refreshable { await vm.loadStacks(force: true) }
        .sheet(isPresented: $vm.showCreate) {
            CreateStackSheet(vm: vm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stacksScreen")
    }
}

/// One row: the stack's cover, how many photos it holds, and when it was last
/// touched. The cover comes first in `stack.assets` (the server orders the
/// primary ahead of the rest) but is matched by id so a mismatched payload
/// still renders the stack's own photo.
private struct StackRowView: View {
    let stack: StackResponseDto
    @Environment(AuthViewModel.self) private var auth

    private var cover: AssetResponseDto? {
        stack.assets.first { $0.id == stack.primaryAssetId } ?? stack.assets.first
    }

    var body: some View {
        HStack(spacing: PVSpacing.s12) {
            Color.clear
                .frame(width: 56, height: 56)
                .overlay {
                    if let cover {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: cover.id, thumbhash: cover.thumbhash ?? "", baseURL: baseURL),
                            token: auth.accessToken
                        )
                    } else {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.pvBody)
                            .foregroundStyle(Color.textTertiaryPV)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(stack.assets.count == 1 ? "1 photo" : "\(stack.assets.count) photos")
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                if let cover {
                    Text(String(localized: "Cover: \(cover.originalFileName)"))
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, PVSpacing.s4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(stack.assets.count) photos in a stack"))
    }

    private var baseURL: URL {
        auth.baseURL ?? URL(string: "https://example.com")!
    }
}
