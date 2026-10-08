import Foundation

/// One folder of the server's real directory tree — the iOS counterpart of the
/// upstream `RecursiveFolder` (path of the parent + name + children).
///
/// `path` is the **absolute** directory path as the server spells it
/// (`/mnt/media/Photos/2024`, no trailing slash); the synthetic root node
/// carries `""`, which is also the key under which `unique-paths` reports
/// assets sitting at the filesystem root. Identity is the path: two folders
/// with the same name under different parents are two different screens.
struct FolderNode: Hashable, Identifiable {
    let path: String
    let name: String
    let children: [FolderNode]

    var id: String { path }
    var hasChildren: Bool { !children.isEmpty }
}

/// The two axes the screen offers. Folder names are sorted A→Z (Files.app);
/// assets are sorted by date, newest first by default (every other grid in the
/// app). The server sorts `/view/folder` by file name, so the date order is
/// client-side — and in-memory, since the route does not paginate.
enum FolderSortOrder: String {
    case ascending
    case descending
}

/// Folder view state (gap G11): builds the directory tree **once** from
/// `GET /api/view/folder/unique-paths` and caches the assets of each visited
/// folder, so walking back up a level costs nothing.
///
/// `@Observable @MainActor` mirrors SearchViewModel / TagsViewModel.
@Observable
@MainActor
final class FolderViewModel {
    private let client: any ImmichClient

    /// Synthetic root (`path == ""`) holding the top-level folders. `nil` until
    /// the tree has loaded — that is also what `loadTree()` keys on, so
    /// descending a level never replays `unique-paths`.
    private(set) var root: FolderNode?
    /// `unique-paths` reports the empty string for assets laid directly at the
    /// filesystem root; those get no node, only this flag (the screen calls the
    /// server for `""` only when it is set).
    private(set) var hasRootLevelAssets = false
    /// Assets per folder path — the per-path cache. Entries stay sorted by
    /// `assetOrder` (written sorted, re-sorted in place by `toggleAssetOrder`).
    private(set) var assetsByPath: [String: [AssetReactItem]] = [:]
    private(set) var loadingPaths: Set<String> = []
    private(set) var errorByPath: [String: String] = [:]
    private(set) var isBuildingTree = false
    private(set) var treeError: String?
    private(set) var folderOrder: FolderSortOrder = .ascending
    private(set) var assetOrder: FolderSortOrder = .descending

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Tree

    /// Pure: no network, no state — the tree is a function of the path list, so
    /// it is testable on its own. Every path is split into its segments and each
    /// intermediate segment becomes a node (`childPath` = parent + "/" + name),
    /// which is what makes two paths sharing a parent share that parent node.
    nonisolated static func buildTree(from paths: [String]) -> (root: FolderNode, hasRootLevelAssets: Bool) {
        var hasRootLevelAssets = false
        // Parent path → names of its direct children.
        var childrenByParent: [String: Set<String>] = [:]

        for path in paths {
            // `split` drops the empty segments, so a path with or without its
            // leading slash yields the same segments.
            let segments = path.split(separator: "/").map(String.init)
            guard !segments.isEmpty else {
                // `""`: assets at the filesystem root. `"/"` never comes back
                // from the server (it is normalized away), so it is ignored.
                if path.isEmpty { hasRootLevelAssets = true }
                continue
            }
            var parent = ""
            for name in segments {
                childrenByParent[parent, default: []].insert(name)
                parent = parent.isEmpty ? "/\(name)" : "\(parent)/\(name)"
            }
        }

        func node(path: String, name: String) -> FolderNode {
            let names = (childrenByParent[path] ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let children = names.map { name in
                node(path: path.isEmpty ? "/\(name)" : "\(path)/\(name)", name: name)
            }
            return FolderNode(path: path, name: name, children: children)
        }

        return (node(path: "", name: ""), hasRootLevelAssets)
    }

    /// Loads the directory tree — and only ever once (`root != nil` bails out):
    /// the tree only moves after a server-side import, while the screen
    /// refreshes folder by folder.
    func loadTree() async {
        guard root == nil else { return }
        isBuildingTree = true
        do {
            let paths = try await client.getUniqueFolderPaths()
            let tree = FolderViewModel.buildTree(from: paths)
            root = tree.root
            hasRootLevelAssets = tree.hasRootLevelAssets
            treeError = nil
        } catch {
            treeError = error.userFacingMessage
        }
        isBuildingTree = false
    }

    /// Rebuilds the tree from scratch after a failure (`root` is still `nil`).
    func retryTree() async {
        root = nil
        hasRootLevelAssets = false
        await loadTree()
    }

    // MARK: - Assets

    /// Assets laid **directly** in `path`, cached until forced. The path goes to
    /// the server as-is, leading slash included: the server strips trailing
    /// slashes only, and its pattern is wrapped in `%`.
    func loadAssets(for path: String, force: Bool = false) async {
        guard assetsByPath[path] == nil || force else { return }
        loadingPaths.insert(path)
        do {
            let dtos = try await client.getFolderAssets(path: path)
            assetsByPath[path] = ordered(dtos.map { AssetReactItem(from: $0) })
            errorByPath[path] = nil
        } catch {
            errorByPath[path] = error.userFacingMessage
        }
        loadingPaths.remove(path)
    }

    /// Forces a refetch of one folder — pull-to-refresh and the asset-level
    /// `Retry` both land here, and neither touches the tree.
    func refresh(path: String) async {
        await loadAssets(for: path, force: true)
    }

    /// Flips the asset order and reorders what is already cached: the route does
    /// not paginate, so an extra round-trip could not bring anything new.
    func toggleAssetOrder() {
        assetOrder = assetOrder == .descending ? .ascending : .descending
        assetsByPath = assetsByPath.mapValues { ordered($0) }
    }

    /// Sorts by capture date — the server sorts by file name, so this is the
    /// only place the date order exists. `id` breaks ties so the order is total
    /// (and therefore stable across the in-place re-sort).
    private func ordered(_ items: [AssetReactItem]) -> [AssetReactItem] {
        items.sorted { lhs, rhs in
            let left = LongDateFormatter.parse(isoTimestamp: lhs.fileCreatedAt) ?? .distantPast
            let right = LongDateFormatter.parse(isoTimestamp: rhs.fileCreatedAt) ?? .distantPast
            if left == right { return lhs.id < rhs.id }
            return assetOrder == .ascending ? left < right : left > right
        }
    }

    // MARK: - Reads for the view

    /// The folders of one level: `nil` is the top level, a node is one folder.
    func children(of node: FolderNode?) -> [FolderNode] {
        let nodes = node?.children ?? root?.children ?? []
        return nodes.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return folderOrder == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    func sortedAssets(for path: String) -> [AssetReactItem] {
        assetsByPath[path] ?? []
    }

    func isLoadingAssets(_ path: String) -> Bool {
        loadingPaths.contains(path)
    }

    func errorMessage(_ path: String) -> String? {
        errorByPath[path]
    }
}
