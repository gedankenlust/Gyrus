import XCTest
@testable import Gyrus

final class ModelEncodingTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - BookmarkUpdate

    func testBookmarkUpdateEncodesOnlySetFields() throws {
        var update = BookmarkUpdate()
        update.title = "New Title"
        let json = try decode(update)
        XCTAssertEqual(json["title"] as? String, "New Title")
        XCTAssertNil(json["url"])
        XCTAssertNil(json["notes"])
        XCTAssertNil(json["is_dead"])
    }

    func testBookmarkUpdateSnakeCaseKeys() throws {
        var update = BookmarkUpdate()
        update.collectionId = "col-1"
        update.isDead = true
        let json = try decode(update)
        XCTAssertEqual(json["collection_id"] as? String, "col-1")
        XCTAssertEqual(json["is_dead"] as? Bool, true)
    }

    func testBookmarkUpdateTagIds() throws {
        var update = BookmarkUpdate()
        update.tagIds = ["t1", "t2"]
        let json = try decode(update)
        XCTAssertEqual(json["tag_ids"] as? [String], ["t1", "t2"])
    }

    func testBookmarkUpdateEmptyEncodesNothing() throws {
        let json = try decode(BookmarkUpdate())
        XCTAssertTrue(json.isEmpty)
    }

    // MARK: - CollectionUpdate

    func testCollectionUpdateEncodesOnlySetFields() throws {
        var update = CollectionUpdate()
        update.name = "Renamed"
        let json = try decode(update)
        XCTAssertEqual(json["name"] as? String, "Renamed")
        XCTAssertNil(json["parent_id"])
        XCTAssertNil(json["icon"])
    }

    func testCollectionUpdateParentId() throws {
        var update = CollectionUpdate()
        update.parentId = "p-42"
        let json = try decode(update)
        XCTAssertEqual(json["parent_id"] as? String, "p-42")
        XCTAssertNil(json["name"])
    }

    // MARK: - Collection decoding

    func testCollectionDefaultsBookmarkCountToZero() throws {
        let data = #"{"id":"1","name":"X","created_at":"2024-01-01T00:00:00Z"}"#.data(using: .utf8)!
        let col = try isoDecoder.decode(Collection.self, from: data)
        XCTAssertEqual(col.bookmarkCount, 0)
    }

    func testCollectionDefaultsChildrenToEmpty() throws {
        let data = #"{"id":"1","name":"X","created_at":"2024-01-01T00:00:00Z","bookmark_count":3}"#.data(using: .utf8)!
        let col = try isoDecoder.decode(Collection.self, from: data)
        XCTAssertTrue(col.children.isEmpty)
    }

    func testCollectionDecodesNestedChildren() throws {
        let data = """
        {
          "id":"parent","name":"P","created_at":"2024-01-01T00:00:00Z",
          "children":[
            {"id":"child","name":"C","created_at":"2024-01-01T00:00:00Z"}
          ]
        }
        """.data(using: .utf8)!
        let col = try isoDecoder.decode(Collection.self, from: data)
        XCTAssertEqual(col.children.count, 1)
        XCTAssertEqual(col.children[0].id, "child")
    }

    // MARK: - Helpers

    private func decode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
