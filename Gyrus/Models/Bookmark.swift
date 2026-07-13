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
    var isRead: Bool
    var designSnapshotCapturedAt: Date?
    var designSnapshotComplete: Bool
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
        case isRead = "is_read"
        case designSnapshotCapturedAt = "design_snapshot_captured_at"
        case designSnapshotComplete = "design_snapshot_complete"
        case collectionId = "collection_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        bookmarkNotes = try c.decodeIfPresent([BookmarkNote].self, forKey: .bookmarkNotes) ?? []
        faviconPath = try c.decodeIfPresent(String.self, forKey: .faviconPath)
        ogImageUrl = try c.decodeIfPresent(String.self, forKey: .ogImageUrl)
        ogImagePath = try c.decodeIfPresent(String.self, forKey: .ogImagePath)
        source = try c.decode(String.self, forKey: .source)
        isDead = try c.decodeIfPresent(Bool.self, forKey: .isDead) ?? false
        // Tolerate responses without is_read (defaults to unread) for safety.
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        designSnapshotCapturedAt = try c.decodeIfPresent(Date.self, forKey: .designSnapshotCapturedAt)
        designSnapshotComplete = try c.decodeIfPresent(Bool.self, forKey: .designSnapshotComplete) ?? false
        collectionId = try c.decodeIfPresent(String.self, forKey: .collectionId)
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    // Memberwise initializer (kept available after adding init(from:)).
    init(id: String, title: String, url: String, description: String?, notes: String?,
         bookmarkNotes: [BookmarkNote], faviconPath: String?, ogImageUrl: String?,
         ogImagePath: String?, source: String, isDead: Bool, isRead: Bool = false,
         collectionId: String?, tags: [Tag], createdAt: Date, updatedAt: Date,
         designSnapshotCapturedAt: Date? = nil, designSnapshotComplete: Bool = false) {
        self.id = id; self.title = title; self.url = url
        self.description = description; self.notes = notes; self.bookmarkNotes = bookmarkNotes
        self.faviconPath = faviconPath; self.ogImageUrl = ogImageUrl; self.ogImagePath = ogImagePath
        self.source = source; self.isDead = isDead; self.isRead = isRead
        self.designSnapshotCapturedAt = designSnapshotCapturedAt
        self.designSnapshotComplete = designSnapshotComplete
        self.collectionId = collectionId; self.tags = tags
        self.createdAt = createdAt; self.updatedAt = updatedAt
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
    var isRead: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case title, url, description, notes
        case collectionId = "collection_id"
        case tagIds = "tag_ids"
        case isDead = "is_dead"
        case isRead = "is_read"
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
        if let v = isRead      { try c.encode(v, forKey: .isRead) }
    }
}
