import Foundation

// MARK: - Collections (folders): CRUD, move, reorder

extension APIClient {
    func collections() async throws -> [Collection] {
        try await get(base.appending(path: "/api/collections"))
    }

    func createCollection(_ body: CollectionCreate) async throws -> Collection {
        try await post(base.appending(path: "/api/collections"), body: body)
    }

    func updateCollection(id: String, body: CollectionUpdate) async throws -> Collection {
        try await put(base.appending(path: "/api/collections/\(id)"), body: body)
    }

    func deleteCollection(id: String) async throws {
        try await delete(base.appending(path: "/api/collections/\(id)"))
    }

    func moveCollection(id: String, parentId: String?) async throws {
        struct Body: Encodable {
            let parentId: String?
            enum CodingKeys: String, CodingKey { case parentId = "parent_id" }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                // Always send parent_id, including an explicit null — otherwise
                // moving a folder to the top level (nil) would omit the key and
                // the backend (exclude_unset) would never un-nest it.
                try c.encode(parentId, forKey: .parentId)
            }
        }
        let _: Collection = try await put(base.appending(path: "/api/collections/\(id)"), body: Body(parentId: parentId))
    }

    func reorderCollections(parentId: String?, orderedIds: [String]) async throws {
        struct Body: Encodable {
            let parentId: String?
            let orderedIds: [String]
            enum CodingKeys: String, CodingKey {
                case parentId = "parent_id"
                case orderedIds = "ordered_ids"
            }
        }
        let _: [String: String] = try await post(
            base.appending(path: "/api/collections/reorder"),
            body: Body(parentId: parentId, orderedIds: orderedIds)
        )
    }
}
