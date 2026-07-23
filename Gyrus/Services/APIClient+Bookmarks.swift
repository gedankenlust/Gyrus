import Foundation

// MARK: - Bookmarks: CRUD, counts, trash, reader, notes

extension APIClient {
    func bookmarks(
        collectionId: String? = nil,
        tag: String? = nil,
        deadOnly: Bool = false,
        unreadOnly: Bool = false,
        limit: Int = 100,
        offset: Int = 0,
        sortBy: String = "created_at",
        order: String = "desc"
    ) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/bookmarks"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "limit",   value: "\(limit)"),
            .init(name: "offset",  value: "\(offset)"),
            .init(name: "sort_by", value: sortBy),
            .init(name: "order",   value: order),
        ]
        if let cid = collectionId { items.append(.init(name: "collection_id", value: cid)) }
        if let t = tag { items.append(.init(name: "tag", value: t)) }
        if deadOnly { items.append(.init(name: "dead_only", value: "true")) }
        if unreadOnly { items.append(.init(name: "unread_only", value: "true")) }
        components.queryItems = items
        return try await get(components.url!)
    }

    func bookmarkIds(
        collectionId: String? = nil,
        tag: String? = nil,
        deadOnly: Bool = false,
        unreadOnly: Bool = false,
        query: String? = nil
    ) async throws -> [String] {
        var components = URLComponents(url: base.appending(path: "/api/bookmarks/ids"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let cid = collectionId { items.append(.init(name: "collection_id", value: cid)) }
        if let t = tag { items.append(.init(name: "tag", value: t)) }
        if deadOnly { items.append(.init(name: "dead_only", value: "true")) }
        if unreadOnly { items.append(.init(name: "unread_only", value: "true")) }
        if let q = query { items.append(.init(name: "q", value: q)) }
        components.queryItems = items.isEmpty ? nil : items
        return try await get(components.url!)
    }

    func createBookmark(_ body: BookmarkCreate) async throws -> Bookmark {
        try await post(base.appending(path: "/api/bookmarks"), body: body)
    }

    func updateBookmark(id: String, body: BookmarkUpdate) async throws -> Bookmark {
        try await put(base.appending(path: "/api/bookmarks/\(id)"), body: body)
    }

    func deleteBookmark(id: String) async throws {
        try await delete(base.appending(path: "/api/bookmarks/\(id)"))
    }

    func deleteBookmarks(ids: Set<String>) async throws {
        struct Body: Encodable { let ids: [String] }
        try await postIgnoreResponse(base.appending(path: "/api/bookmarks/delete-batch"), body: Body(ids: Array(ids)))
    }

    func bookmarkCount() async throws -> Int {
        try await get(base.appending(path: "/api/bookmarks/count"))
    }

    func deadBookmarkCount() async throws -> Int {
        try await get(base.appending(path: "/api/bookmarks/count-dead"))
    }

    func unreadBookmarkCount() async throws -> Int {
        try await get(base.appending(path: "/api/bookmarks/count-unread"))
    }

    // MARK: Trash

    func trashedBookmarks(limit: Int = 200, offset: Int = 0) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/bookmarks/trash"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        return try await get(components.url!)
    }

    func trashCount() async throws -> Int {
        try await get(base.appending(path: "/api/bookmarks/trash/count"))
    }

    @discardableResult
    func restoreFromTrash(ids: [String]) async throws -> Int {
        struct Body: Encodable { let ids: [String] }
        struct Resp: Decodable { let restored: Int }
        let r: Resp = try await post(base.appending(path: "/api/bookmarks/trash/restore"), body: Body(ids: ids))
        return r.restored
    }

    /// Permanently delete trashed bookmarks. Pass nil to empty the whole Trash.
    @discardableResult
    func purgeTrash(ids: [String]? = nil) async throws -> Int {
        struct Body: Encodable { let ids: [String]? }
        struct Resp: Decodable { let purged: Int }
        let r: Resp = try await post(base.appending(path: "/api/bookmarks/trash/purge"), body: Body(ids: ids))
        return r.purged
    }

    // MARK: Metadata & reader

    func fetchMeta(id: String) async throws -> Bookmark {
        try await post(base.appending(path: "/api/bookmarks/\(id)/fetch-meta"), body: EmptyBody())
    }

    func retryBookmarkAnalysis(id: String) async throws -> Bookmark {
        try await post(base.appending(path: "/api/bookmarks/\(id)/analysis/retry"), body: EmptyBody())
    }

    func fetchReaderContent(id: String) async throws -> String {
        struct ReaderResponse: Decodable { let content: String }
        let res: ReaderResponse = try await get(base.appending(path: "/api/bookmarks/\(id)/reader"))
        return res.content
    }

    /// Optional, opt-in: ask the local LLM to tidy the reader text into clean
    /// prose. Returns the cleaned text; the cached original is left untouched.
    func cleanupReaderContent(id: String, config: AIBrainConfig) async throws -> String {
        struct Body: Encodable { let provider_config: ProviderPayload }
        struct ReaderResponse: Decodable { let content: String }
        let pc = ProviderPayload(config)
        let res: ReaderResponse = try await post(
            base.appending(path: "/api/bookmarks/\(id)/reader/cleanup"),
            body: Body(provider_config: pc), timeout: APIClient.llmTimeout)
        return res.content
    }

    func translateReaderContent(
        id: String,
        content: String,
        targetLanguage: String,
        config: AIBrainConfig
    ) async throws -> String {
        struct Body: Encodable {
            let provider_config: ProviderPayload
            let target_language: String
            let content: String
        }
        struct ReaderResponse: Decodable { let content: String }
        let body = Body(
            provider_config: ProviderPayload(config),
            target_language: targetLanguage,
            content: content
        )
        let res: ReaderResponse = try await post(
            base.appending(path: "/api/bookmarks/\(id)/reader/translate"),
            body: body,
            timeout: APIClient.llmTimeout
        )
        return res.content
    }

    func autoTag(bookmarkId: String, config: AIBrainConfig) async throws -> Bookmark {
        struct Body: Encodable { let provider_config: ProviderPayload; let language: String }
        return try await post(base.appending(path: "/api/bookmarks/\(bookmarkId)/auto-tag"),
                              body: Body(provider_config: ProviderPayload(config),
                                        language: AppSettings.shared.effectiveLanguageCode),
                              timeout: APIClient.llmTimeout)
    }

    // MARK: Notes

    func addNote(bookmarkId: String, content: String, source: String = "user") async throws -> BookmarkNote {
        struct Body: Encodable {
            let content: String
            let source: String
        }
        return try await post(base.appending(path: "/api/bookmarks/\(bookmarkId)/notes"), body: Body(content: content, source: source))
    }

    func deleteNote(bookmarkId: String, noteId: String) async throws {
        try await delete(base.appending(path: "/api/bookmarks/\(bookmarkId)/notes/\(noteId)"))
    }
}
