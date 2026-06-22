import Foundation

private let _iso8601Formatters: [DateFormatter] = {
    ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
     "yyyy-MM-dd'T'HH:mm:ss.SSS",
     "yyyy-MM-dd'T'HH:mm:ss"].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }
}()

enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int)
    case decodingError(Error)
    case networkError(Error)
    case duplicate
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .serverError(let code): return "Server error \(code)"
        case .duplicate: return "Bookmark already exists"
        case .decodingError(let e): return "Decode error: \(e)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .serverMessage(let m): return m
        }
    }
}

final class APIClient {
    static let shared = APIClient()
    private let base = Config.backendURL

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            for fmt in _iso8601Formatters {
                if let date = fmt.date(from: string) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Cannot parse date: \(string)")
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Health

    func health() async throws -> Bool {
        var request = URLRequest(url: base.appending(path: "/health"))
        request.timeoutInterval = 2.0 // Short timeout for health check
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Bookmarks

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

    // MARK: - Trash

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

    func startLinkCheck() async throws -> LinkCheckStatus {
        try await post(base.appending(path: "/api/bookmarks/check-links"), body: EmptyBody())
    }

    func linkCheckStatus() async throws -> LinkCheckStatus {
        try await get(base.appending(path: "/api/bookmarks/check-links/status"))
    }

    func startMetadataRefresh() async throws -> MetadataRefreshStatus {
        try await post(base.appending(path: "/api/bookmarks/refresh-metadata"), body: EmptyBody())
    }

    func metadataRefreshStatus() async throws -> MetadataRefreshStatus {
        try await get(base.appending(path: "/api/bookmarks/refresh-metadata/status"))
    }

    @discardableResult
    func cancelMetadataRefresh() async throws -> MetadataRefreshStatus {
        try await post(base.appending(path: "/api/bookmarks/refresh-metadata/cancel"), body: EmptyBody())
    }

    func startBatchAutoTag(ids: [String], config: AIBrainConfig) async throws -> BatchAutoTagStatus {
        struct ProviderConfig: Encodable {
            let provider: String
            let model: String
            let ollama_url: String
            let api_key: String
        }
        struct Body: Encodable {
            let bookmark_ids: [String]
            let provider_config: ProviderConfig
        }
        let body = Body(
            bookmark_ids: ids,
            provider_config: ProviderConfig(
                provider: config.llmProvider.rawValue,
                model: config.ollamaModel,
                ollama_url: config.ollamaURL,
                api_key: ""
            )
        )
        return try await post(base.appending(path: "/api/bookmarks/auto-tag-batch"), body: body)
    }

    func batchAutoTagStatus() async throws -> BatchAutoTagStatus {
        try await get(base.appending(path: "/api/bookmarks/auto-tag-batch/status"))
    }

    @discardableResult
    func cancelBatchAutoTag() async throws -> BatchAutoTagStatus {
        try await post(base.appending(path: "/api/bookmarks/auto-tag-batch/cancel"), body: EmptyBody())
    }

    func fetchMeta(id: String) async throws -> Bookmark {
        try await post(base.appending(path: "/api/bookmarks/\(id)/fetch-meta"), body: EmptyBody())
    }

    func fetchReaderContent(id: String) async throws -> String {
        struct ReaderResponse: Decodable { let content: String }
        let res: ReaderResponse = try await get(base.appending(path: "/api/bookmarks/\(id)/reader"))
        return res.content
    }

    /// Optional, opt-in: ask the local LLM to tidy the reader text into clean
    /// prose. Returns the cleaned text; the cached original is left untouched.
    func cleanupReaderContent(id: String, config: AIBrainConfig) async throws -> String {
        struct ProviderConfig: Encodable {
            let provider: String
            let model: String
            let ollama_url: String
        }
        struct Body: Encodable { let provider_config: ProviderConfig }
        struct ReaderResponse: Decodable { let content: String }
        let pc = ProviderConfig(
            provider: config.llmProvider.rawValue,
            model: config.ollamaModel,
            ollama_url: config.ollamaURL
        )
        let res: ReaderResponse = try await post(
            base.appending(path: "/api/bookmarks/\(id)/reader/cleanup"),
            body: Body(provider_config: pc), timeout: APIClient.llmTimeout)
        return res.content
    }

    func autoTag(bookmarkId: String, config: AIBrainConfig) async throws -> Bookmark {
        struct ProviderConfig: Encodable {
            let provider: String
            let model: String
            let ollama_url: String
            let api_key: String
        }
        struct Body: Encodable {
            let provider_config: ProviderConfig
        }
        
        let providerConfig = ProviderConfig(
            provider: config.llmProvider.rawValue,
            model: config.ollamaModel,
            ollama_url: config.ollamaURL,
            api_key: ""
        )

        return try await post(base.appending(path: "/api/bookmarks/\(bookmarkId)/auto-tag"), body: Body(provider_config: providerConfig), timeout: APIClient.llmTimeout)
    }

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

    // MARK: - Collections

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

    // MARK: - Tags

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

    // MARK: - Search

    func search(query: String, limit: Int = 100, offset: Int = 0) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        return try await get(components.url!)
    }

    /// Semantic / meaning-based search. Returns an empty list when Ollama is
    /// unreachable — the caller should fall back to keyword search silently.
    func searchSemantic(query: String, limit: Int = 20) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/search/semantic"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "limit", value: "\(limit)"),
        ]
        return try await get(components.url!)
    }

    struct SemanticSearchStatus: Decodable {
        let available: Bool
        let indexed: Int
        let message: String
    }

    func semanticSearchStatus() async throws -> SemanticSearchStatus {
        try await get(base.appending(path: "/api/search/status"))
    }

    struct ReindexResponse: Decodable {
        let status: String
        let message: String?
    }

    /// Kick off a background rebuild of the semantic search index.
    func reindexEmbeddings() async throws -> ReindexResponse {
        var req = URLRequest(url: base.appending(path: "/api/search/reindex"))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response)
        return try decoder.decode(ReindexResponse.self, from: data)
    }

    struct SummarizeResponse: Decodable {
        let summary: String
    }

    /// Generate an LLM summary for a bookmark; the backend saves it to Notes.
    func summarize(bookmarkId: String) async throws -> SummarizeResponse {
        var req = URLRequest(url: base.appending(path: "/api/brain/summarize/\(bookmarkId)"))
        req.httpMethod = "POST"
        req.timeoutInterval = APIClient.llmTimeout
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response)
        return try decoder.decode(SummarizeResponse.self, from: data)
    }

    // MARK: - Export

    func exportHTML() async throws -> Data {
        let url = base.appending(path: "/api/export/html")
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response)
        return data
    }

    // MARK: - Import

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        var request = URLRequest(url: base.appending(path: "/api/import/html"))
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/html\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        if let name = rootFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"root_folder_name\"\r\n\r\n".data(using: .utf8)!)
            body.append(name.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try decoder.decode(ImportResult.self, from: respData)
    }

    // MARK: - File URLs

    func faviconURL(filename: String) -> URL {
        base.appending(path: "/api/files/favicons/\(filename)")
    }

    func ogImageURL(filename: String) -> URL {
        base.appending(path: "/api/files/og-images/\(filename)")
    }

    // MARK: - AI Brain

    func updateAIBrainConfig(_ config: AIBrainConfig) async throws {
        struct Body: Encodable {
            let root_dir: String?
            let is_enabled: Bool
            let llm_provider: String
            let ollama_url: String
            let ollama_model: String
            let embedding_model: String
        }
        let body = Body(
            root_dir: config.rootDirectoryPath,
            is_enabled: config.isEnabled,
            llm_provider: config.llmProvider.rawValue,
            ollama_url: config.ollamaURL,
            ollama_model: config.ollamaModel,
            embedding_model: config.embeddingModel
        )
        let _: [String: String] = try await post(base.appending(path: "/api/brain/config"), body: body)
    }

    /// Installed Ollama models split by capability, so the UI can offer chat
    /// models for the LLM and embedding models for semantic search separately.
    func fetchModelsByCapability(ollamaURL: String) async throws -> (text: [String], embedding: [String]) {
        struct Response: Decodable {
            let text_models: [String]
            let embedding_models: [String]
            let error: String?
        }
        var comps = URLComponents(url: base.appending(path: "/api/brain/available-models"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "url", value: ollamaURL)]
        let r: Response = try await get(comps.url!)
        return (r.text_models, r.embedding_models)
    }

    func updateBrainConfig(rootDir: String, isEnabled: Bool) async throws {
        struct Body: Encodable {
            let root_dir: String
            let is_enabled: Bool
        }
        let _: [String: String] = try await post(base.appending(path: "/api/brain/config"), body: Body(root_dir: rootDir, is_enabled: isEnabled))
    }

    func fetchOllamaModels(url: String) async throws -> [String] {
        struct OllamaModel: Decodable { let name: String }
        struct OllamaResponse: Decodable { let models: [OllamaModel] }
        
        guard let baseURL = URL(string: url) else { throw APIError.invalidURL }
        let tagsURL = baseURL.appending(path: "/api/tags")
        
        let (data, response) = try await URLSession.shared.data(from: tagsURL)
        try checkStatus(response)
        
        let decoded: OllamaResponse = try JSONDecoder().decode(OllamaResponse.self, from: data)
        return decoded.models.map { $0.name }
    }

    func aiChat(bookmarkId: String, prompt: String, history: [(role: String, content: String)] = [], config: AIBrainConfig) async throws -> String {
        struct ProviderConfig: Encodable {
            let provider: String
            let model: String
            let ollama_url: String
            let api_key: String
        }
        struct HistoryMessage: Encodable {
            let role: String
            let content: String
        }
        struct ChatRequest: Encodable {
            let bookmark_id: String
            let prompt: String
            let provider_config: ProviderConfig
            let history: [HistoryMessage]
        }
        struct ChatResponse: Decodable {
            let response: String
        }

        let providerConfig = ProviderConfig(
            provider: config.llmProvider.rawValue,
            model: config.ollamaModel,
            ollama_url: config.ollamaURL,
            api_key: ""
        )

        let body = ChatRequest(
            bookmark_id: bookmarkId,
            prompt: prompt,
            provider_config: providerConfig,
            history: history.map { HistoryMessage(role: $0.role, content: $0.content) }
        )
        let res: ChatResponse = try await post(base.appending(path: "/api/brain/chat"), body: body, timeout: APIClient.llmTimeout)
        return res.response
    }

    /// Stream the AI reply token-by-token. The returned stream yields text
    /// deltas; cancelling the consuming task aborts the request (Stop button).
    /// A backend error arrives as a `[GYRUS-ERROR] …` sentinel and is surfaced
    /// as a thrown `APIError.serverMessage`.
    func aiChatStream(bookmarkId: String, prompt: String,
                      history: [(role: String, content: String)] = [],
                      config: AIBrainConfig) -> AsyncThrowingStream<String, Error> {
        struct ProviderConfig: Encodable { let provider: String; let model: String; let ollama_url: String }
        struct HistoryMessage: Encodable { let role: String; let content: String }
        struct ChatRequest: Encodable {
            let bookmark_id: String
            let prompt: String
            let provider_config: ProviderConfig
            let history: [HistoryMessage]
        }

        let providerConfig = ProviderConfig(
            provider: config.llmProvider.rawValue,
            model: config.ollamaModel,
            ollama_url: config.ollamaURL
        )
        let body = ChatRequest(
            bookmark_id: bookmarkId, prompt: prompt,
            provider_config: providerConfig,
            history: history.map { HistoryMessage(role: $0.role, content: $0.content) }
        )

        let url = base.appending(path: "/api/brain/chat/stream")
        let encoder = self.encoder
        let sentinel = "[GYRUS-ERROR]"

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try encoder.encode(body)
                    // A cold Ollama model can take a while before the first token.
                    request.timeoutInterval = APIClient.llmTimeout

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw APIError.serverError(http.statusCode)
                    }

                    // Decode cumulatively so multibyte UTF-8 never splits, and
                    // emit only the newly added suffix as a delta.
                    var data = Data()
                    var emitted = ""
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        data.append(byte)
                        guard let full = String(data: data, encoding: .utf8) else { continue }
                        if let r = full.range(of: sentinel) {
                            let msg = full[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                            throw APIError.serverMessage(msg.isEmpty ? "AI request failed" : msg)
                        }
                        if full.count > emitted.count {
                            let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                            emitted = full
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Data Management

    func clearCache() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-cache"), body: EmptyBody())
    }

    func clearBrain() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-brain"), body: EmptyBody())
    }

    func clearBookmarks() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-bookmarks"), body: EmptyBody())
    }

    func factoryReset() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/factory-reset"), body: EmptyBody())
    }

    func downloadBackup() async throws -> Data {
        let url = base.appending(path: "/api/data/backup")
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response)
        return data
    }

    /// Replace all current data with the contents of a JSON backup file.
    func restoreBackup(_ json: Data) async throws {
        var request = URLRequest(url: base.appending(path: "/api/data/restore"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    /// Generous timeout for local-LLM calls — a cold Ollama model can take a
    /// minute or two to load before it answers, well past URLSession's 60s default.
    static let llmTimeout: TimeInterval = 300

    private func post<Body: Encodable, T: Decodable>(_ url: URL, body: Body, timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let timeout { request.timeoutInterval = timeout }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func postIgnoreResponse<Body: Encodable>(_ url: URL, body: Body) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func put<Body: Encodable, T: Decodable>(_ url: URL, body: Body) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func delete(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 409 { throw APIError.duplicate }
        if !(200...299).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

private struct EmptyBody: Encodable {}

struct LinkCheckStatus: Decodable {
    let running: Bool
    let checked: Int
    let total: Int
    let deadFound: Int

    enum CodingKeys: String, CodingKey {
        case running, checked, total
        case deadFound = "dead_found"
    }
}

struct MetadataRefreshStatus: Decodable {
    let running: Bool
    let processed: Int
    let total: Int
    let updated: Int
}

struct BatchAutoTagStatus: Decodable {
    let running: Bool
    let processed: Int
    let total: Int
    let tagged: Int
}

struct ImportResult: Decodable {
    let status: String
    let imported: Int
    let skipped: Int
    let collectionsCreated: Int

    enum CodingKeys: String, CodingKey {
        case status, imported, skipped
        case collectionsCreated = "collections_created"
    }
}
