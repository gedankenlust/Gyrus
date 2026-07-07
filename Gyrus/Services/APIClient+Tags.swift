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
}
