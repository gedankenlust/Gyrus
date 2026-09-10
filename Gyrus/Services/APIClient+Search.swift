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
    func searchSemantic(query: String, limit: Int = 20, offset: Int = 0) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/search/semantic"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "q", value: query),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        return try await get(components.url!)
    }

    struct SemanticSearchStatus: Decodable {
        let available: Bool
        let indexed: Int
        let message: String
        let reindexRunning: Bool?
        let reindexCompleted: Int?
        let reindexTotal: Int?
        let reindexError: String?
        let reindexErrorCode: String?

        var reindexErrorDescription: String? {
            guard let error = reindexError else { return nil }
            switch reindexErrorCode {
            case "embedding_input_too_long": return String(localized: "The embedding model rejected a text as too long. Check the model and update Ollama.")
            case "embedding_model_unavailable": return String(localized: "The embedding model or API is unavailable. Check the selected model and update Ollama.")
            case "embedding_connection": return String(localized: "Ollama is unreachable. Start Ollama and try indexing again.")
            case "embedding_timeout": return String(localized: "Ollama took too long. Wait for other AI tasks to finish and try again.")
            case "embedding_invalid_response": return String(localized: "Ollama returned an invalid search vector. Check the embedding model and try again.")
            case "embedding_server_error": return String(localized: "Ollama could not calculate a search vector. Check Ollama and try again.")
            default: return error
            }
        }
        enum CodingKeys: String, CodingKey {
            case available, indexed, message
            case reindexRunning = "reindex_running", reindexCompleted = "reindex_completed"
            case reindexTotal = "reindex_total", reindexError = "reindex_error"
            case reindexErrorCode = "reindex_error_code"
        }
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
        req.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        let (data, response) = try await URLSession.shared.data(for: req)
        try checkStatus(response)
        return try decoder.decode(ReindexResponse.self, from: data)
    }
}
