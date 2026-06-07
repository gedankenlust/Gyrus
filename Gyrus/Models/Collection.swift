import Foundation

struct Collection: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var parentId: String?
    var icon: String?
    var color: String?
    let createdAt: Date
    var bookmarkCount: Int
    var children: [Collection]

    enum CodingKeys: String, CodingKey {
        case id, name, icon, color, children
        case parentId = "parent_id"
        case createdAt = "created_at"
        case bookmarkCount = "bookmark_count"
    }

    init(id: String, name: String, parentId: String? = nil, icon: String? = nil,
         color: String? = nil, createdAt: Date = Date(), bookmarkCount: Int = 0,
         children: [Collection] = []) {
        self.id = id; self.name = name; self.parentId = parentId; self.icon = icon
        self.color = color; self.createdAt = createdAt; self.bookmarkCount = bookmarkCount
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        parentId    = try c.decodeIfPresent(String.self, forKey: .parentId)
        icon        = try c.decodeIfPresent(String.self, forKey: .icon)
        color       = try c.decodeIfPresent(String.self, forKey: .color)
        createdAt   = try c.decode(Date.self, forKey: .createdAt)
        bookmarkCount = (try? c.decode(Int.self, forKey: .bookmarkCount)) ?? 0
        children    = (try? c.decode([Collection].self, forKey: .children)) ?? []
    }
}

struct CollectionCreate: Encodable {
    let name: String
    let parentId: String?
    let icon: String?

    enum CodingKeys: String, CodingKey {
        case name, icon
        case parentId = "parent_id"
    }
}

struct CollectionUpdate: Encodable {
    var name: String? = nil
    var parentId: String? = nil
    var icon: String? = nil
    var color: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, icon, color
        case parentId = "parent_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let v = name     { try c.encode(v, forKey: .name) }
        if let v = parentId { try c.encode(v, forKey: .parentId) }
        if let v = icon     { try c.encode(v, forKey: .icon) }
        if let v = color    { try c.encode(v, forKey: .color) }
    }
}
