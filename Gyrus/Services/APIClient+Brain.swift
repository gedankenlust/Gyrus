import Foundation

// MARK: - AI Brain: config, model discovery, chat, summarize

extension APIClient {
    struct BrainMessageDTO: Decodable {
        let id: String
        let bookmarkId: String
        let role: String
        let content: String
        let model: String?
        let status: String
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, role, content, model, status
            case bookmarkId = "bookmark_id"
            case createdAt = "created_at"
        }
    }

    func brainMessages(bookmarkId: String) async throws -> [BrainMessageDTO] {
        try await get(base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/messages"))
    }

    func clearBrainMessages(bookmarkId: String) async throws {
        try await delete(base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/messages"))
    }

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
            is_enabled: config.brainMirrorEnabled,
            llm_provider: config.llmProvider.rawValue,
            ollama_url: config.ollamaURL,
            ollama_model: config.ollamaModel,
            embedding_model: config.embeddingModel
        )
        struct Response: Decodable {
            let status: String
            let root_dir: String
            let is_enabled: Bool
        }
        let _: Response = try await post(base.appending(path: "/api/brain/config"), body: body)
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

    struct SummarizeResponse: Decodable {
        let summary: String
    }

    /// Generate an LLM summary for a bookmark; the backend saves it to Notes.
    func summarize(bookmarkId: String, config: AIBrainConfig) async throws -> SummarizeResponse {
        struct Body: Encodable { let provider_config: ProviderPayload; let language: String }
        return try await post(base.appending(path: "/api/brain/summarize/\(bookmarkId)"),
                              body: Body(provider_config: ProviderPayload(config),
                                        language: AppSettings.shared.effectiveLanguageCode),
                              timeout: APIClient.llmTimeout)
    }

    func aiChat(bookmarkId: String, prompt: String, history: [(role: String, content: String)] = [], config: AIBrainConfig) async throws -> String {
        struct HistoryMessage: Encodable {
            let role: String
            let content: String
        }
        struct ChatRequest: Encodable {
            let bookmark_id: String
            let prompt: String
            let provider_config: ProviderPayload
            let history: [HistoryMessage]
            let language: String
        }
        struct ChatResponse: Decodable {
            let response: String
        }

        let providerConfig = ProviderPayload(config)

        let body = ChatRequest(
            bookmark_id: bookmarkId,
            prompt: prompt,
            provider_config: providerConfig,
            history: history.map { HistoryMessage(role: $0.role, content: $0.content) },
            language: AppSettings.shared.effectiveLanguageCode
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
        // The FastAPI streaming wrapper currently closes its chunked response
        // early on macOS URLSession ("cannot parse response"). Use the stable
        // non-streaming endpoint behind the same UI until streaming is rebuilt.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.aiChat(
                        bookmarkId: bookmarkId,
                        prompt: prompt,
                        history: history,
                        config: config
                    )
                    if !Task.isCancelled {
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
