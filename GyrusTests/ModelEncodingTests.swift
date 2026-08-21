import XCTest
@testable import Gyrus

final class ModelEncodingTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - BookmarkCreate

    func testBookmarkCreateEncodesAllFields() throws {
        let create = BookmarkCreate(
            title: "Test Title",
            url: "https://example.com",
            description: "Test description",
            notes: "Test notes",
            collectionId: "col-123",
            tagIds: ["tag-1", "tag-2"],
            source: "manual"
        )
        let json = try decode(create)

        XCTAssertEqual(json["title"] as? String, "Test Title")
        XCTAssertEqual(json["url"] as? String, "https://example.com")
        XCTAssertEqual(json["description"] as? String, "Test description")
        XCTAssertEqual(json["notes"] as? String, "Test notes")
        XCTAssertEqual(json["collection_id"] as? String, "col-123")
        XCTAssertEqual(json["tag_ids"] as? [String], ["tag-1", "tag-2"])
        XCTAssertEqual(json["source"] as? String, "manual")
    }

    func testBookmarkCreateEncodesNilOptionals() throws {
        let create = BookmarkCreate(
            title: "Minimal Title",
            url: "https://example.com/minimal",
            description: nil,
            notes: nil,
            collectionId: nil,
            tagIds: [],
            source: "extension"
        )
        let json = try decode(create)

        XCTAssertEqual(json["title"] as? String, "Minimal Title")
        XCTAssertEqual(json["url"] as? String, "https://example.com/minimal")
        XCTAssertNil(json["description"])
        XCTAssertNil(json["notes"])
        XCTAssertNil(json["collection_id"])
        XCTAssertEqual(json["tag_ids"] as? [String], [])
        XCTAssertEqual(json["source"] as? String, "extension")
    }

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

    func testBookmarkDecodesPersistentAnalysisStatus() throws {
        let data = """
        {
          "id":"b1","title":"Example","url":"https://example.com",
          "description":null,"notes":null,"bookmark_notes":[],
          "favicon_path":null,"og_image_url":null,"og_image_path":null,
          "source":"manual","is_dead":false,"is_read":false,
          "collection_id":null,"tags":[],
          "created_at":"2026-07-22T10:00:00Z",
          "updated_at":"2026-07-22T10:00:00Z",
          "analysis":{
            "overall":"partial","metadata":"ready","reader":"failed",
            "index":"not_requested","design":"not_requested",
            "last_error":"Reader failed","attempts":2,
            "updated_at":"2026-07-22T10:01:00Z"
          }
        }
        """.data(using: .utf8)!

        let bookmark = try isoDecoder.decode(Bookmark.self, from: data)
        XCTAssertEqual(bookmark.analysis?.overall, "partial")
        XCTAssertEqual(bookmark.analysis?.lastError, "Reader failed")
        XCTAssertEqual(bookmark.analysis?.attempts, 2)
    }

    func testBookmarkSummaryDecodesWithoutNoteDetails() throws {
        let data = """
        {
          "id":"b1","title":"Example","url":"https://example.com",
          "description":"Summary",
          "favicon_path":null,"og_image_url":null,"og_image_path":null,
          "source":"manual","is_dead":false,"is_read":false,
          "collection_id":null,"tags":[],
          "created_at":"2026-07-22T10:00:00Z",
          "updated_at":"2026-07-22T10:00:00Z"
        }
        """.data(using: .utf8)!

        let bookmark = try isoDecoder.decode(Bookmark.self, from: data)
        XCTAssertNil(bookmark.notes)
        XCTAssertTrue(bookmark.bookmarkNotes.isEmpty)
    }

    func testPendingSemanticIndexKeepsAnalysisPollingActive() {
        let analysis = BookmarkAnalysis(
            overall: "ready",
            metadata: "ready",
            reader: "ready",
            index: "pending",
            design: "not_requested",
            lastError: nil,
            attempts: 1,
            updatedAt: nil
        )

        XCTAssertTrue(analysis.isActive)
        XCTAssertFalse(analysis.needsAttention)
    }

    // MARK: - TagCreate

    func testTagCreateEncodesAllFields() throws {
        let create = TagCreate(name: "swift", color: "#FF5733")
        let json = try decode(create)

        XCTAssertEqual(json["name"] as? String, "swift")
        XCTAssertEqual(json["color"] as? String, "#FF5733")
    }

    func testTagCreateEncodesNilColor() throws {
        let create = TagCreate(name: "design", color: nil)
        let json = try decode(create)

        XCTAssertEqual(json["name"] as? String, "design")
        XCTAssertNil(json["color"])
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

    // MARK: - Taxonomy draft decoding

    func testBatchTagStatusDecodesReviewDraft() throws {
        let data = """
        {
          "running": false,
          "processed": 3,
          "total": 3,
          "assigned": 2,
          "without_tags": 1,
          "failed": 0,
          "phase": "review",
          "generated_tokens": 712,
          "model": "qwen3:8b",
          "draft": {
            "id": "draft-1",
            "language": "de",
            "total": 3,
            "assigned": 2,
            "without_tags": 1,
            "tags": [{
              "id": "T001",
              "name": "design",
              "bookmark_count": 2,
              "bookmark_ids": ["b1", "b2"],
              "bookmark_titles": ["One", "Two"]
            }],
            "untagged": [{"id": "b3", "title": "Three"}]
          }
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(BatchAutoTagStatus.self, from: data)

        XCTAssertEqual(status.phase, "review")
        XCTAssertEqual(status.generatedTokens, 712)
        XCTAssertEqual(status.model, "qwen3:8b")
        XCTAssertEqual(status.draft?.tags.first?.bookmarkCount, 2)
        XCTAssertEqual(status.draft?.untagged.first?.title, "Three")
        XCTAssertEqual(status.draft?.omittedTags, 0)
    }

    func testTaxonomyDraftDecodesOmittedTagCount() throws {
        let data = """
        {
          "id": "draft-2",
          "language": "de",
          "total": 22,
          "assigned": 22,
          "without_tags": 0,
          "omitted_tags": 2,
          "tags": [],
          "untagged": []
        }
        """.data(using: .utf8)!

        let draft = try JSONDecoder().decode(TaxonomyDraft.self, from: data)

        XCTAssertEqual(draft.omittedTags, 2)
    }

    // MARK: - Design inspection decoding

    func testVisualSnapshotJobDecodesResponsiveIssue() throws {
        let data = """
        {
          "running": false,
          "bookmark_id": "bookmark-1",
          "stage": "finished",
          "completed": 3,
          "total": 3,
          "error": null,
          "snapshot": {
            "bookmark_id": "bookmark-1",
            "schema_version": 2,
            "run_id": "run-1",
            "url": "https://example.com",
            "title": "Example",
            "captured_at": "2026-07-13T12:00:00Z",
            "status": "completed",
            "viewports": [{
              "name": "mobile",
              "width": 390,
              "height": 844,
              "screenshot": "mobile.png",
              "screenshot_url": "/mobile.png",
              "dominant_colors": [],
              "observed_colors": [],
              "observed_fonts": [],
              "structure": {"h1": [], "h2": [], "links": 0, "buttons": 0, "images": 0, "svgs": 0, "forms": 0},
              "responsive_issues": [{
                "id": "overflow:html",
                "kind": "horizontal_overflow",
                "severity": "high",
                "title": "Page overflows horizontally",
                "detail": "Wider than viewport",
                "selector_hint": "html",
                "text": "",
                "x": 0,
                "y": 0,
                "width": 450,
                "height": 1,
                "metric": "450px / 390px",
                "evidence_url": "/evidence/mobile-1.jpg"
              }]
            }]
          }
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(APIClient.VisualSnapshotJobStatus.self, from: data)

        XCTAssertFalse(status.running)
        XCTAssertEqual(status.snapshot?.runId, "run-1")
        XCTAssertEqual(status.snapshot?.viewports.first?.responsiveIssues?.first?.kind, "horizontal_overflow")
    }

    // MARK: - Helpers

    private func decode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
