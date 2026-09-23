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

    func startFolderOrganize(config: AIBrainConfig) async throws -> FolderOrganizeStatus {
        struct Body: Encodable {
            let provider_config: ProviderPayload
            let language: String
        }
        return try await post(
            base.appending(path: "/api/bookmarks/organize-folders"),
            body: Body(provider_config: ProviderPayload(config), language: AppSettings.shared.effectiveLanguageCode)
        )
    }

    func folderOrganizeStatus() async throws -> FolderOrganizeStatus {
        try await get(base.appending(path: "/api/bookmarks/organize-folders/status"))
    }

    func cancelFolderOrganize() async throws -> FolderOrganizeStatus {
        try await post(base.appending(path: "/api/bookmarks/organize-folders/cancel"), body: EmptyBody())
    }

    func applyFolderDraft(id: String, folderKeys: [String]) async throws -> FolderOrganizeApplyResult {
        struct Body: Encodable {
            let draftId: String
            let folderKeys: [String]
            enum CodingKeys: String, CodingKey {
                case draftId = "draft_id"
                case folderKeys = "folder_keys"
            }
        }
        return try await post(
            base.appending(path: "/api/bookmarks/organize-folders/apply"),
            body: Body(draftId: id, folderKeys: folderKeys)
        )
    }

    func discardFolderDraft(id: String) async throws {
        try await delete(base.appending(path: "/api/bookmarks/organize-folders/draft/\(id)"))
    }
}

struct FolderOrganizeApplyResult: Decodable {
    let moved: Int
}
