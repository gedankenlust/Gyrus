import Foundation

struct Tag: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var color: String?
    let createdAt: Date
    var bookmarkCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
        case bookmarkCount = "bookmark_count"
    }

    init(id: String, name: String, color: String? = nil, createdAt: Date, bookmarkCount: Int = 0) {
        self.id = id; self.name = name; self.color = color
        self.createdAt = createdAt; self.bookmarkCount = bookmarkCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        bookmarkCount = try c.decodeIfPresent(Int.self, forKey: .bookmarkCount) ?? 0
    }
}

struct TagCreate: Encodable {
    let name: String
    let color: String?
}

struct TagUpdate: Encodable {
    var name: String? = nil
    var color: String? = nil

    enum CodingKeys: String, CodingKey { case name, color }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = name  { try c.encode(v, forKey: .name) }
        if let v = color { try c.encode(v, forKey: .color) }
    }
}
