import Foundation
import Observation

enum TagPresence: Equatable { case all, some, none }

@MainActor
@Observable
final class TagStore {
    var tags: [Tag] = []
    var selectedTagName: String? = nil

    private let api: APIClient
    private var generation = 0

    func resetLocalState() { generation += 1; tags = []; selectedTagName = nil }

    init(api: APIClient = .shared) { self.api = api }

    func fetchTags() async throws {
        let started = generation
        let result = try await api.tags()
        guard started == generation else { return }
        tags = result
    }

    func createTag(name: String, color: String? = nil) async throws -> Tag {
        let tag = try await api.createTag(.init(name: name, color: color))
        try await fetchTags()
        return tag
    }

    @discardableResult
    func createTagAndAssign(name: String, color: String?, toBookmarkIds ids: Set<String>, in bookmarks: [Bookmark]) async throws -> [Bookmark] {
        let tag = try await createTag(name: name, color: color)
        return try await api.assignTags(bookmarkIds: Array(ids), addTagIds: [tag.id], removeTagIds: [])
    }

    func renameTag(_ id: String, newName: String) async throws {
        var u = TagUpdate(); u.name = newName
        _ = try await api.updateTag(id: id, body: u)
        try await fetchTags()
    }

    func recolorTag(_ id: String, color: String) async throws {
        var u = TagUpdate(); u.color = color
        _ = try await api.updateTag(id: id, body: u)
        try await fetchTags()
    }

    func deleteTag(_ id: String) async throws {
        try await api.deleteTag(id: id)
        if let name = tags.first(where: { $0.id == id })?.name, selectedTagName == name {
            selectedTagName = nil
        }
        try await fetchTags()
    }

    /// Reassign every tag a distinct color — fixes a library where many tags
    /// ended up with the same or a very similar color.
    func rebalanceTagColors() async throws {
        tags = try await api.rebalanceTagColors()
    }

    func tagPresence(tagId: String, in bookmarks: [Bookmark], forIds bookmarkIds: Set<String>) -> TagPresence {
        let selected = bookmarks.filter { bookmarkIds.contains($0.id) }
        guard !selected.isEmpty else { return .none }
        let withTag = selected.filter { bm in bm.tags.contains(where: { $0.id == tagId }) }.count
        if withTag == 0 { return .none }
        if withTag == bookmarkIds.count { return .all }
        return .some
    }

    /// Returns the updated bookmarks so the caller can refresh local state
    /// immediately (otherwise the new tags only appear after a reload).
    @discardableResult
    func toggleTag(tagId: String, onBookmarkIds ids: Set<String>, in bookmarks: [Bookmark]) async throws -> [Bookmark] {
        let presence = tagPresence(tagId: tagId, in: bookmarks, forIds: ids)
        let shouldAdd = presence != .all
        return try await api.assignTags(
            bookmarkIds: Array(ids),
            addTagIds: shouldAdd ? [tagId] : [],
            removeTagIds: shouldAdd ? [] : [tagId]
        )
    }
}
