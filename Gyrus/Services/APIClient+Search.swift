import Foundation

// MARK: - Search: keyword, semantic, index management

extension APIClient {
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
}
