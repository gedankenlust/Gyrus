import Foundation

// MARK: - AI Brain: config, model discovery, chat, summarize

extension APIClient {
    struct VisualSnapshotDTO: Decodable {
        let bookmarkId: String
        let schemaVersion: Int?
        let runId: String?
        let url: String
        let title: String
        let capturedAt: String
        let status: String?
        let viewports: [VisualViewportDTO]

        enum CodingKeys: String, CodingKey {
            case url, title, status, viewports
            case bookmarkId = "bookmark_id"
            case schemaVersion = "schema_version"
            case runId = "run_id"
            case capturedAt = "captured_at"
        }
    }

    struct VisualSnapshotJobStatus: Decodable, JobStatusReporting {
        let running: Bool
        let bookmarkId: String?
        let stage: String?
        let completed: Int?
        let total: Int?
        let error: String?
        let snapshot: VisualSnapshotDTO?

        enum CodingKeys: String, CodingKey {
            case running, stage, completed, total, error, snapshot
            case bookmarkId = "bookmark_id"
        }
    }

    struct VisualViewportDTO: Decodable {
        let pageTitle: String?
        let metaDescription: String?
        let name: String
        let width: Int
        let height: Int
        let screenshot: String
        let screenshotURL: String
        let dominantColors: [String]
        let observedColors: [String]
        let observedFonts: [String]
        let structure: VisualStructureDTO
        let elementSamples: [VisualElementSampleDTO]?
        let seo: VisualSEODTO?
        let assets: VisualAssetsDTO?
        let accessibility: VisualAccessibilityDTO?
        let cssVariables: [VisualCSSVariableDTO]?
        let network: VisualNetworkDTO?
        let consoleMessages: [VisualConsoleMessageDTO]?
        let responsiveIssues: [VisualResponsiveIssueDTO]?

        enum CodingKeys: String, CodingKey {
            case name, width, height, screenshot, structure, seo, assets, accessibility, network
            case pageTitle = "page_title"
            case metaDescription = "meta_description"
            case screenshotURL = "screenshot_url"
            case dominantColors = "dominant_colors"
            case observedColors = "observed_colors"
            case observedFonts = "observed_fonts"
            case elementSamples = "element_samples"
            case cssVariables = "css_variables"
            case consoleMessages = "console_messages"
            case responsiveIssues = "responsive_issues"
        }
    }

    struct VisualResponsiveIssueDTO: Decodable, Identifiable {
        let id: String
        let kind: String
        let severity: String
        let title: String
        let detail: String
        let selectorHint: String
        let text: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let metric: String
        let evidenceURL: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, severity, title, detail, text, x, y, width, height, metric
            case selectorHint = "selector_hint"
            case evidenceURL = "evidence_url"
        }
    }

    struct VisualStructureDTO: Decodable {
        let h1: [String]
        let h2: [String]
        let links: Int
        let buttons: Int
        let images: Int
        let svgs: Int
        let forms: Int
    }

    struct VisualSEODTO: Decodable {
        let title: String?
        let metaDescription: String?
        let canonical: String?
        let language: String?
        let robots: String?
        let openGraph: [VisualMetaDTO]?
        let twitter: [VisualMetaDTO]?
        let jsonLd: [String]?
        let headings: [VisualHeadingDTO]?
        let internalLinks: Int?
        let externalLinks: Int?

        enum CodingKeys: String, CodingKey {
            case title, canonical, language, robots, twitter, headings
            case metaDescription = "meta_description"
            case openGraph = "open_graph"
            case jsonLd = "json_ld"
            case internalLinks = "internal_links"
            case externalLinks = "external_links"
        }
    }

    struct VisualMetaDTO: Decodable, Identifiable {
        var id: String { "\(name ?? "")-\(content ?? "")" }
        let name: String?
        let content: String?
    }

    struct VisualHeadingDTO: Decodable, Identifiable {
        var id: String { "\(level)-\(text)" }
        let level: Int
        let text: String
    }

    struct VisualAssetsDTO: Decodable {
        let images: [VisualAssetDTO]?
        let icons: [VisualAssetDTO]?
        let stylesheets: [VisualAssetDTO]?
        let scripts: [VisualAssetDTO]?
    }

    struct VisualAssetDTO: Decodable, Identifiable {
        var id: String { "\(kind ?? "")-\(url ?? "")-\(selectorHint ?? "")" }
        let kind: String?
        let url: String?
        let alt: String?
        let width: Int?
        let height: Int?
        let loading: String?
        let selectorHint: String?
        let rel: String?
        let sizes: String?
        let type: String?
        let media: String?
        let isAsync: Bool?
        let isDeferred: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, url, alt, width, height, loading, rel, sizes, type, media
            case selectorHint = "selector_hint"
            case isAsync = "async"
            case isDeferred = "defer"
        }
    }

    struct VisualAccessibilityDTO: Decodable {
        let missingAltImages: [VisualAssetDTO]?
        let emptyButtons: [VisualAccessibilityItemDTO]?
        let unlabeledInputs: [VisualAccessibilityItemDTO]?
        let headingSkips: [VisualHeadingSkipDTO]?

        enum CodingKeys: String, CodingKey {
            case missingAltImages = "missing_alt_images"
            case emptyButtons = "empty_buttons"
            case unlabeledInputs = "unlabeled_inputs"
            case headingSkips = "heading_skips"
        }
    }

    struct VisualAccessibilityItemDTO: Decodable, Identifiable {
        var id: String { "\(selectorHint ?? "")-\(text ?? "")-\(name ?? "")-\(placeholder ?? "")" }
        let selectorHint: String?
        let text: String?
        let ariaLabel: String?
        let type: String?
        let name: String?
        let placeholder: String?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case text, type, name, placeholder, label
            case selectorHint = "selector_hint"
            case ariaLabel = "aria_label"
        }
    }

    struct VisualHeadingSkipDTO: Decodable, Identifiable {
        var id: String { "\(from?.id ?? "")-\(to?.id ?? "")" }
        let from: VisualHeadingDTO?
        let to: VisualHeadingDTO?
    }

    struct VisualCSSVariableDTO: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let value: String
    }

    struct VisualNetworkDTO: Decodable {
        let requestCount: Int?
        let resourceCounts: [VisualResourceCountDTO]?
        let failedRequests: [VisualNetworkRequestDTO]?
        let largeRequests: [VisualNetworkRequestDTO]?

        enum CodingKeys: String, CodingKey {
            case requestCount = "request_count"
            case resourceCounts = "resource_counts"
            case failedRequests = "failed_requests"
            case largeRequests = "large_requests"
        }
    }

    struct VisualResourceCountDTO: Decodable, Identifiable {
        var id: String { type }
        let type: String
        let count: Int
    }

    struct VisualNetworkRequestDTO: Decodable, Identifiable {
        var id: String { "\(method ?? "")-\(url ?? "")-\(status ?? 0)" }
        let url: String?
        let method: String?
        let resourceType: String?
        let status: Int?
        let contentType: String?
        let failure: String?
        let contentLength: Int?

        enum CodingKeys: String, CodingKey {
            case url, method, status, failure
            case resourceType = "resource_type"
            case contentType = "content_type"
            case contentLength = "content_length"
        }
    }

    struct VisualConsoleMessageDTO: Decodable, Identifiable {
        var id: String { "\(type ?? "")-\(text ?? "")-\(location?.url ?? "")-\(location?.lineNumber ?? 0)" }
        let type: String?
        let text: String?
        let location: VisualConsoleLocationDTO?
    }

    struct VisualConsoleLocationDTO: Decodable {
        let url: String?
        let lineNumber: Int?
        let columnNumber: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case lineNumber = "lineNumber"
            case columnNumber = "columnNumber"
        }
    }

    struct VisualElementSampleDTO: Decodable, Identifiable {
        var id: String {
            "\(selectorHint)-\(x)-\(y)-\(width)-\(height)-\(text)"
        }

        let tag: String
        let selectorHint: String
        let text: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let display: String
        let position: String
        let fontFamily: String
        let fontSize: String
        let fontWeight: String
        let lineHeight: String
        let color: String
        let backgroundColor: String
        let borderRadius: String
        let boxShadow: String
        let letterSpacing: String
        let textTransform: String
        let margin: String
        let padding: String

        enum CodingKeys: String, CodingKey {
            case tag, text, x, y, width, height, display, position, color, margin, padding
            case selectorHint = "selector_hint"
            case fontFamily = "font_family"
            case fontSize = "font_size"
            case fontWeight = "font_weight"
            case lineHeight = "line_height"
            case backgroundColor = "background_color"
            case borderRadius = "border_radius"
            case boxShadow = "box_shadow"
            case letterSpacing = "letter_spacing"
            case textTransform = "text_transform"
        }
    }

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

    func visualSnapshot(bookmarkId: String) async throws -> VisualSnapshotDTO {
        try await get(base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/visual-snapshot"))
    }

    func createVisualSnapshot(bookmarkId: String) async throws -> VisualSnapshotDTO {
        try await post(base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/visual-snapshot"),
                       body: EmptyBody(), timeout: APIClient.llmTimeout)
    }

    func startVisualSnapshotJob(bookmarkId: String) async throws -> VisualSnapshotJobStatus {
        try await post(
            base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/visual-snapshot/job"),
            body: EmptyBody()
        )
    }

    func visualSnapshotJobStatus(bookmarkId: String) async throws -> VisualSnapshotJobStatus {
        try await get(base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/visual-snapshot/job"))
    }

    @discardableResult
    func cancelVisualSnapshotJob(bookmarkId: String) async throws -> VisualSnapshotJobStatus {
        try await post(
            base.appending(path: "/api/brain/bookmarks/\(bookmarkId)/visual-snapshot/job/cancel"),
            body: EmptyBody()
        )
    }

    func visualSnapshotFileURL(path: String) -> URL {
        if path.hasPrefix("/") {
            return base.appending(path: path)
        }
        return base.appending(path: "/\(path)")
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
