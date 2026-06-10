import Foundation
import Observation

@MainActor
@Observable
final class CollectionStore {
    var collections: [Collection] = []
    var selectedCollectionId: String? = nil
    var showDeadOnly: Bool = false
    var showUnreadOnly: Bool = false
    var showTrash: Bool = false

    private let api = APIClient.shared

    func fetchCollections() async throws {
        collections = try await api.collections()
    }

    func moveCollection(_ id: String, toParent parentId: String?) async throws {
        try await api.moveCollection(id: id, parentId: parentId)
        try await fetchCollections()
    }

    /// Reorder/move `movedId` to sit just before or after `targetId`, at the
    /// target's level. Covers same-level reorder AND un-nesting (when the target
    /// is at a shallower level). Optimistic local update, then persist.
    func moveFolder(_ movedId: String, relativeTo targetId: String, after: Bool) {
        guard movedId != targetId,
              let target = flatCollections.first(where: { $0.id == targetId }) else { return }
        let destParent = target.parentId

        // Reject cycles: can't move a folder next to one of its own descendants.
        var cursor: String? = destParent
        while let c = cursor {
            if c == movedId { return }
            cursor = flatCollections.first(where: { $0.id == c })?.parentId
        }

        guard var moved = Self.removeNode(movedId, from: &collections) else { return }
        moved.parentId = destParent
        Self.insert(moved, target: targetId, after: after, parentId: destParent, in: &collections)

        let orderedIds = Self.childIds(of: destParent, in: collections)
        Task {
            do {
                try await api.moveCollection(id: movedId, parentId: destParent)
                try await api.reorderCollections(parentId: destParent, orderedIds: orderedIds)
            } catch {
                try? await fetchCollections()
            }
        }
    }

    /// Move `movedId` under `newParent` (nil = root) at a specific child index.
    /// Used by the AppKit outline view, which gives a precise parent + index for
    /// both reordering (index >= 0) and nesting (index < 0 → append).
    func moveFolder(_ movedId: String, toParent newParent: String?, atIndex index: Int) {
        guard movedId != newParent else { return }
        // Reject cycles.
        var cursor: String? = newParent
        while let c = cursor {
            if c == movedId { return }
            cursor = flatCollections.first(where: { $0.id == c })?.parentId
        }
        guard var moved = Self.removeNode(movedId, from: &collections) else { return }
        moved.parentId = newParent
        Self.insertNode(moved, intoParent: newParent, at: index, in: &collections)

        let orderedIds = Self.childIds(of: newParent, in: collections)
        Task {
            do {
                try await api.moveCollection(id: movedId, parentId: newParent)
                try await api.reorderCollections(parentId: newParent, orderedIds: orderedIds)
            } catch {
                try? await fetchCollections()
            }
        }
    }

    // MARK: - Tree helpers (value-type, in-place)

    nonisolated static func insertNode(_ node: Collection, intoParent parentId: String?,
                                   at index: Int, in nodes: inout [Collection]) {
        if parentId == nil {
            let i = (index < 0 || index > nodes.count) ? nodes.count : index
            nodes.insert(node, at: i)
            return
        }
        for j in nodes.indices {
            if nodes[j].id == parentId {
                let i = (index < 0 || index > nodes[j].children.count) ? nodes[j].children.count : index
                nodes[j].children.insert(node, at: i)
                return
            }
            insertNode(node, intoParent: parentId, at: index, in: &nodes[j].children)
        }
    }

    @discardableResult
    nonisolated static func removeNode(_ id: String, from nodes: inout [Collection]) -> Collection? {
        if let idx = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: idx)
        }
        for i in nodes.indices {
            if let found = removeNode(id, from: &nodes[i].children) { return found }
        }
        return nil
    }

    nonisolated static func insert(_ node: Collection, target targetId: String, after: Bool,
                               parentId: String?, in nodes: inout [Collection]) {
        func place(into arr: inout [Collection]) {
            let base = arr.firstIndex(where: { $0.id == targetId }) ?? arr.count
            let idx = after ? min(base + 1, arr.count) : base
            arr.insert(node, at: idx)
        }
        if parentId == nil {
            place(into: &nodes)
            return
        }
        for i in nodes.indices {
            if nodes[i].id == parentId {
                place(into: &nodes[i].children)
                return
            }
            insert(node, target: targetId, after: after, parentId: parentId, in: &nodes[i].children)
        }
    }

    nonisolated static func childIds(of parentId: String?, in nodes: [Collection]) -> [String] {
        if parentId == nil { return nodes.map(\.id) }
        for node in nodes {
            if node.id == parentId { return node.children.map(\.id) }
            let found = childIds(of: parentId, in: node.children)
            if !found.isEmpty { return found }
        }
        return []
    }

    func renameCollection(_ id: String, newName: String) async throws {
        var u = CollectionUpdate()
        u.name = newName
        _ = try await api.updateCollection(id: id, body: u)
        try await fetchCollections()
    }

    func recolorCollection(_ id: String, color: String?) async throws {
        var u = CollectionUpdate()
        u.color = color
        _ = try await api.updateCollection(id: id, body: u)
        try await fetchCollections()
    }

    func deleteCollection(_ id: String) async throws -> [String] {
        let all = flatCollections
        func descendants(of parentId: String) -> [String] {
            var ids: [String] = []
            for col in all where col.parentId == parentId {
                ids.append(contentsOf: descendants(of: col.id))
                ids.append(col.id)
            }
            return ids
        }
        let toDelete = descendants(of: id) + [id]
        for deleteId in toDelete {
            try await api.deleteCollection(id: deleteId)
            if selectedCollectionId == deleteId { selectedCollectionId = nil }
        }
        try await fetchCollections()
        return toDelete
    }

    func createCollection(name: String, parentId: String? = nil) async throws {
        _ = try await api.createCollection(.init(name: name, parentId: parentId, icon: nil))
        try await fetchCollections()
    }

    var flatCollections: [Collection] {
        var result: [Collection] = []
        func flatten(_ cols: [Collection]) {
            for col in cols { result.append(col); flatten(col.children) }
        }
        flatten(collections)
        return result
    }
}
