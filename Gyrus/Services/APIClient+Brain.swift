import Foundation

// MARK: - AI Brain: config, model discovery, chat, summarize

extension APIClient {
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
        struct HistoryMessage: Encodable { let role: String; let content: String }
        struct ChatRequest: Encodable {
            let bookmark_id: String
            let prompt: String
            let provider_config: ProviderPayload
            let history: [HistoryMessage]
            let language: String
        }

        let providerConfig = ProviderPayload(config)
        let body = ChatRequest(
            bookmark_id: bookmarkId, prompt: prompt,
            provider_config: providerConfig,
            history: history.map { HistoryMessage(role: $0.role, content: $0.content) },
            language: AppSettings.shared.effectiveLanguageCode
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
}
