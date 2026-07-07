import Foundation

// MARK: - Background jobs: link check, metadata refresh, batch auto-tag

extension APIClient {
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
}
