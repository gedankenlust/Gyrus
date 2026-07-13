import Foundation

// Response models for backend endpoints, shared across stores.
// (Moved out of APIClient.swift when it was split by domain.)

struct LinkCheckStatus: Decodable, JobStatusReporting {
    let running: Bool
    let checked: Int
    let total: Int
    let deadFound: Int

    enum CodingKeys: String, CodingKey {
        case running, checked, total
        case deadFound = "dead_found"
    }
}

struct MetadataRefreshStatus: Decodable, JobStatusReporting {
    let running: Bool
    let processed: Int
    let total: Int
    let updated: Int
}

struct TaxonomyDraftTag: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let bookmarkCount: Int
    let bookmarkIds: [String]
    let bookmarkTitles: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case bookmarkCount = "bookmark_count"
        case bookmarkIds = "bookmark_ids"
        case bookmarkTitles = "bookmark_titles"
    }
}

struct TaxonomyUntaggedBookmark: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
}

struct TaxonomyDraft: Decodable, Identifiable, Hashable {
    let id: String
    let language: String
    let total: Int
    let assigned: Int
    let withoutTags: Int
    let tags: [TaxonomyDraftTag]
    let untagged: [TaxonomyUntaggedBookmark]

    enum CodingKeys: String, CodingKey {
        case id, language, total, assigned, tags, untagged
        case withoutTags = "without_tags"
    }
}

struct TaxonomyTagEdit: Encodable, Identifiable, Hashable {
    let id: String
    var name: String
    var enabled: Bool
}

struct ApplyTaxonomyResult: Decodable {
    let status: String
    let tags: Int
    let assignments: Int
    let assigned: Int
    let withoutTags: Int
    let total: Int

    enum CodingKeys: String, CodingKey {
        case status, tags, assignments, assigned, total
        case withoutTags = "without_tags"
    }
}

struct TagReviewPayload: Identifiable {
    var id: String { draft.id }
    let draft: TaxonomyDraft
}

struct BatchAutoTagStatus: Decodable, JobStatusReporting {
    let running: Bool
    let processed: Int
    let total: Int
    let assigned: Int
    let withoutTags: Int
    let failed: Int
    let error: String?
    let phase: String
    let generatedTokens: Int
    let model: String?
    let draft: TaxonomyDraft?

    enum CodingKeys: String, CodingKey {
        case running, processed, total, assigned, failed, error, phase, model, draft
        case withoutTags = "without_tags"
        case generatedTokens = "generated_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        processed = try c.decode(Int.self, forKey: .processed)
        total = try c.decode(Int.self, forKey: .total)
        assigned = try c.decodeIfPresent(Int.self, forKey: .assigned) ?? 0
        withoutTags = try c.decodeIfPresent(Int.self, forKey: .withoutTags) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "preparing"
        generatedTokens = try c.decodeIfPresent(Int.self, forKey: .generatedTokens) ?? 0
        model = try c.decodeIfPresent(String.self, forKey: .model)
        draft = try c.decodeIfPresent(TaxonomyDraft.self, forKey: .draft)
    }
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
