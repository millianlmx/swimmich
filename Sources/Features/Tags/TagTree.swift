import Foundation

extension TagResponseDto {
    /// The full path (`Voyages/Japon`) the server computes; the short name when absent.
    var path: String { value ?? name }
}

/// One line of the tag hierarchy, in display order.
struct TagRow: Identifiable, Equatable {
    let tag: TagResponseDto
    /// 0 at the root, +1 per level below it.
    let depth: Int
    /// Id of the tag this row is displayed under, `nil` at the root. Not
    /// `tag.parentId`: an orphan has a non-nil `tag.parentId` yet sits at the root.
    let parentId: String?

    var id: String { tag.id }

    /// Makes the parent/child relation observable: `tagRow_<parent|root>_<id>`.
    var accessibilityIdentifier: String { "tagRow_\(parentId ?? "root")_\(tag.id)" }
}

/// Builds the hierarchy from the flat list `GET /api/tags` returns.
///
/// Every distinct tag appears exactly once, whatever the server sent: an
/// orphan (unknown `parentId`), a self-parent or a `parentId` cycle never
/// hides a tag, it is shown at the root.
enum TagTree {
    static func rows(from tags: [TagResponseDto]) -> [TagRow] {
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0.id).inserted }
        let ids = Set(unique.map(\.id))
        let sorted = unique.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }

        func isRoot(_ tag: TagResponseDto) -> Bool {
            guard let parentId = tag.parentId else { return true }
            return parentId == tag.id || !ids.contains(parentId)
        }

        var children: [String: [TagResponseDto]] = [:]
        for tag in sorted where !isRoot(tag) {
            if let parentId = tag.parentId { children[parentId, default: []].append(tag) }
        }

        var visited = Set<String>()
        var rows: [TagRow] = []
        func visit(_ tag: TagResponseDto, depth: Int, parentId: String?) {
            guard visited.insert(tag.id).inserted else { return }
            rows.append(TagRow(tag: tag, depth: depth, parentId: parentId))
            for child in children[tag.id] ?? [] {
                visit(child, depth: depth + 1, parentId: tag.id)
            }
        }

        for tag in sorted where isRoot(tag) { visit(tag, depth: 0, parentId: nil) }
        // Whatever the walk did not reach sits in a parentId cycle: root them.
        for tag in sorted where !visited.contains(tag.id) { visit(tag, depth: 0, parentId: nil) }
        return rows
    }
}
