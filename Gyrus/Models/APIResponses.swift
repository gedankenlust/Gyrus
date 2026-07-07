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

/// A tag the LLM created during a batch auto-tag run — offered for review
/// (keep or discard) when the run finishes.
struct CreatedTagInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String?
}

/// Sheet payload for the post-batch tag review (Identifiable for .sheet(item:)).
struct TagReviewPayload: Identifiable {
    let id = UUID()
    let tags: [CreatedTagInfo]
}

struct BatchAutoTagStatus: Decodable, JobStatusReporting {
    let running: Bool
    let processed: Int
    let total: Int
    let tagged: Int
    let failed: Int
    let error: String?
    let createdTags: [CreatedTagInfo]

    enum CodingKeys: String, CodingKey {
        case running, processed, total, tagged, failed, error
        case createdTags = "created_tags"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        processed = try c.decode(Int.self, forKey: .processed)
        total = try c.decode(Int.self, forKey: .total)
        tagged = try c.decode(Int.self, forKey: .tagged)
        // Defaulted so older backend responses (without these keys) still decode.
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        createdTags = try c.decodeIfPresent([CreatedTagInfo].self, forKey: .createdTags) ?? []
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
