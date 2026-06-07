import Foundation

struct BookmarkNote: Identifiable, Codable, Hashable {
    let id: String
    var content: String
    var source: String // "user" or "ai"
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, content, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct Bookmark: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var url: String
    var description: String?
    var notes: String? // Legacy field
    var bookmarkNotes: [BookmarkNote]
    var faviconPath: String?
    var ogImageUrl: String?
    var ogImagePath: String?
    var source: String
    var isDead: Bool
    var collectionId: String?
    var tags: [Tag]
    let createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != url else { return URL(string: url)?.host ?? url }
        return t
    }

    enum CodingKeys: String, CodingKey {
        case id, title, url, description, notes, source, tags
        case bookmarkNotes = "bookmark_notes"
        case faviconPath = "favicon_path"
        case ogImageUrl = "og_image_url"
        case ogImagePath = "og_image_path"
        case isDead = "is_dead"
        case collectionId = "collection_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct BookmarkCreate: Encodable {
    let title: String
    let url: String
    let description: String?
    let notes: String?
    let collectionId: String?
    let tagIds: [String]
    let source: String

    enum CodingKeys: String, CodingKey {
        case title, url, description, notes, source
        case collectionId = "collection_id"
        case tagIds = "tag_ids"
    }
}

struct BookmarkUpdate: Encodable {
    var title: String? = nil
    var url: String? = nil
    var description: String? = nil
    var notes: String? = nil
    var collectionId: String? = nil
    var tagIds: [String]? = nil
    var isDead: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case title, url, description, notes
        case collectionId = "collection_id"
        case tagIds = "tag_ids"
        case isDead = "is_dead"
    }

    // Only encode fields that were explicitly set — prevents overwriting unrelated fields with null
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = title       { try c.encode(v, forKey: .title) }
        if let v = url         { try c.encode(v, forKey: .url) }
        if let v = description { try c.encode(v, forKey: .description) }
        if let v = notes       { try c.encode(v, forKey: .notes) }
        if let v = collectionId { try c.encode(v, forKey: .collectionId) }
        if let v = tagIds      { try c.encode(v, forKey: .tagIds) }
        if let v = isDead      { try c.encode(v, forKey: .isDead) }
    }
}
