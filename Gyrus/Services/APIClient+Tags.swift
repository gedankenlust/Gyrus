import Foundation

// MARK: - Tags: CRUD, restore (undo)

extension APIClient {
    func tags() async throws -> [Tag] {
        try await get(base.appending(path: "/api/tags"))
    }

    func createTag(_ body: TagCreate) async throws -> Tag {
        try await post(base.appending(path: "/api/tags"), body: body)
    }

    func updateTag(id: String, body: TagUpdate) async throws -> Tag {
        try await put(base.appending(path: "/api/tags/\(id)"), body: body)
    }

    func deleteTag(id: String) async throws {
        try await delete(base.appending(path: "/api/tags/\(id)"))
    }

    func restoreTag(name: String, color: String?, bookmarkIds: [String]) async throws -> Tag {
        try await post(base.appending(path: "/api/tags/restore"),
                       body: TagRestore(name: name, color: color, bookmarkIds: bookmarkIds))
    }

    func assignTags(bookmarkIds: [String], addTagIds: [String], removeTagIds: [String]) async throws -> [Bookmark] {
        struct Body: Encodable {
            let bookmarkIds: [String]
            let addTagIds: [String]
            let removeTagIds: [String]

            enum CodingKeys: String, CodingKey {
                case bookmarkIds = "bookmark_ids"
                case addTagIds = "add_tag_ids"
                case removeTagIds = "remove_tag_ids"
            }
        }
        return try await post(
            base.appending(path: "/api/tags/assign"),
            body: Body(
                bookmarkIds: bookmarkIds,
                addTagIds: addTagIds,
                removeTagIds: removeTagIds
            )
        )
    }

    /// Merge tags: bookmarks with any source tag get the target tag instead;
    /// the source tags are deleted.
    @discardableResult
    func mergeTags(sourceIds: [String], targetId: String) async throws -> Tag {
        struct Body: Encodable {
            let sourceIds: [String]
            let targetId: String
            enum CodingKeys: String, CodingKey {
                case sourceIds = "source_ids"
                case targetId = "target_id"
            }
        }
        return try await post(base.appending(path: "/api/tags/merge"),
                              body: Body(sourceIds: sourceIds, targetId: targetId))
    }

    /// Reassign every tag a distinct color in one pass — repairs a library
    /// where many tags ended up with the same or a very similar color.
    @discardableResult
    func rebalanceTagColors() async throws -> [Tag] {
        try await post(base.appending(path: "/api/tags/rebalance-colors"), body: EmptyBody())
    }
}
