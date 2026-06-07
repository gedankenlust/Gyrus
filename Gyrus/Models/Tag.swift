import Foundation

struct Tag: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var color: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, color
        case createdAt = "created_at"
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
