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
        struct Body: Encodable {
            let bookmark_ids: [String]
            let provider_config: ProviderPayload
            let language: String
        }
        let body = Body(bookmark_ids: ids, provider_config: ProviderPayload(config),
                        language: AppSettings.shared.effectiveLanguageCode)
        return try await post(base.appending(path: "/api/bookmarks/auto-tag-batch"), body: body)
    }

    func fastAutoTag(ids: [String], limitPerBookmark: Int = 3) async throws -> FastAutoTagResult {
        struct Body: Encodable {
            let bookmark_ids: [String]
            let limit_per_bookmark: Int
        }
        return try await post(
            base.appending(path: "/api/bookmarks/auto-tag-fast"),
            body: Body(bookmark_ids: ids, limit_per_bookmark: limitPerBookmark)
        )
    }

    func batchAutoTagStatus() async throws -> BatchAutoTagStatus {
        try await get(base.appending(path: "/api/bookmarks/auto-tag-batch/status"))
    }

    @discardableResult
    func cancelBatchAutoTag() async throws -> BatchAutoTagStatus {
        try await post(base.appending(path: "/api/bookmarks/auto-tag-batch/cancel"), body: EmptyBody())
    }

    func applyTaxonomyDraft(id: String, tags: [TaxonomyTagEdit]) async throws -> ApplyTaxonomyResult {
        struct Body: Encodable {
            let draftId: String
            let tags: [TaxonomyTagEdit]

            enum CodingKeys: String, CodingKey {
                case draftId = "draft_id"
                case tags
            }
        }
        return try await post(
            base.appending(path: "/api/bookmarks/auto-tag-batch/apply"),
            body: Body(draftId: id, tags: tags)
        )
    }

    func discardTaxonomyDraft(id: String) async throws {
        try await delete(base.appending(path: "/api/bookmarks/auto-tag-batch/draft/\(id)"))
    }
}
