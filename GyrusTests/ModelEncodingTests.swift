import XCTest
import WebKit
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
        XCTAssertEqual(status.embedded, 0)
        XCTAssertEqual(status.classified, 0)
        XCTAssertEqual(status.cooldownRemaining, 0)
        XCTAssertEqual(status.model, "qwen3:8b")
        XCTAssertEqual(status.draft?.tags.first?.bookmarkCount, 2)
        XCTAssertEqual(status.draft?.untagged.first?.title, "Three")
        XCTAssertEqual(status.draft?.omittedTags, 0)
    }

    func testLargeLibraryJobProgressDecodesCountsAndErrors() throws {
        let data = Data(#"{"running":true,"processed":4094,"total":4094,"embedded":1024,"classified":144,"phase":"assigning"}"#.utf8)
        let status = try JSONDecoder().decode(BatchAutoTagStatus.self, from: data)
        XCTAssertEqual(status.embedded, 1024)
        XCTAssertEqual(status.classified, 144)
        let metadata = try JSONDecoder().decode(MetadataRefreshStatus.self, from:
            Data(#"{"running":false,"processed":4000,"total":4094,"updated":3900,"failed":100,"error":"Write failed"}"#.utf8))
        XCTAssertEqual(metadata.failed, 100)
        XCTAssertEqual(metadata.error, "Write failed")
    }

    func testGentleTaggingMigratesAndPersistsExplicitChoice() throws {
        let legacy = Data(#"{"ollamaModel":"saved-model","aiEnabled":true}"#.utf8)
        var config = try JSONDecoder().decode(AIBrainConfig.self, from: legacy)
        XCTAssertTrue(config.gentleTagging)
        XCTAssertEqual(config.ollamaModel, "saved-model")
        XCTAssertTrue(config.aiEnabled)
        XCTAssertEqual(try decode(ProviderPayload(config))["gentle_tagging"] as? Bool, true)
        config.gentleTagging = false
        let restored = try JSONDecoder().decode(AIBrainConfig.self, from: encoder.encode(config))
        XCTAssertFalse(restored.gentleTagging)
        XCTAssertEqual(try decode(ProviderPayload(restored))["gentle_tagging"] as? Bool, false)
    }

    func testGentleTaggingCountdownPreservesCompletedCounts() throws {
        let data = Data(#"{"running":true,"processed":4094,"total":4094,"embedded":4094,"classified":24,"phase":"cooldown","cooldown_remaining":12}"#.utf8)
        let status = try JSONDecoder().decode(BatchAutoTagStatus.self, from: data)
        XCTAssertEqual(status.phase, "cooldown")
        XCTAssertEqual(status.cooldownRemaining, 12)
        XCTAssertEqual(status.classified, 24)
        XCTAssertEqual(status.embedded, 4094)
    }

    func testSearchIndexErrorUsesSafeExplanationAndAcceptsLegacyStatus() throws {
        let data = Data(#"{"available":false,"indexed":324,"message":"Rebuild","reindex_error":"raw server response","reindex_error_code":"embedding_input_too_long"}"#.utf8)
        let status = try JSONDecoder().decode(APIClient.SemanticSearchStatus.self, from: data)
        XCTAssertEqual(status.reindexErrorCode, "embedding_input_too_long")
        XCTAssertEqual(status.reindexErrorDescription, String(localized: "The embedding model rejected a text as too long. Check the model and update Ollama."))
        let legacy = try JSONDecoder().decode(APIClient.SemanticSearchStatus.self, from:
            Data(#"{"available":true,"indexed":324,"message":"Ready"}"#.utf8))
        XCTAssertNil(legacy.reindexErrorCode)
        XCTAssertNil(legacy.reindexErrorDescription)
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
          "completed": 4,
          "total": 4,
          "error": null,
          "snapshot": {
            "bookmark_id": "bookmark-1",
            "schema_version": 6,
            "run_id": "run-1",
            "url": "https://example.com",
            "title": "Example",
            "captured_at": "2026-07-13T12:00:00Z",
            "status": "completed",
            "navigation": [{
              "label": "Main menu",
              "items": [{
                "label": "Services",
                "url": "https://example.com/services",
                "children": [{"label": "Design", "url": "https://example.com/services/design", "children": []}]
              }]
            }],
            "site_structure": {
              "origin": "https://example.com",
              "listed_page_count": 2,
              "sitemap_page_count": 2,
              "crawled_page_count": 1,
              "crawl_limit": 80,
              "crawl_limit_reached": false,
              "sitemap_limit": 10000,
              "sitemap_limit_reached": false,
              "sitemap_sources": ["https://example.com/sitemap.xml"],
              "pages": [{"url": "https://example.com/services", "path": "/services", "title": "Services", "source": "sitemap"}],
              "page_tree": [{
                "label": "Services",
                "path": "/services",
                "url": "https://example.com/services",
                "source": "sitemap",
                "children": []
              }],
              "errors": []
            },
            "viewports": [{
              "name": "mobile",
              "width": 390,
              "height": 844,
              "screenshot": "mobile.png",
              "screenshot_url": "/mobile.png",
              "dominant_colors": [],
              "observed_colors": [],
              "observed_fonts": [],
              "technologies": [{
                "name": "Astro",
                "version": "5.0",
                "category": "Framework",
                "confidence": "high",
                "evidence": ["Generator: Astro v5"]
              }],
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
        XCTAssertEqual(status.snapshot?.viewports.first?.technologies?.first?.name, "Astro")
        XCTAssertEqual(status.snapshot?.viewports.first?.technologies?.first?.version, "5.0")
        XCTAssertEqual(status.snapshot?.viewports.first?.responsiveIssues?.first?.kind, "horizontal_overflow")
        XCTAssertEqual(status.snapshot?.navigation?.first?.items.first?.children.first?.label, "Design")
        XCTAssertEqual(status.snapshot?.siteStructure?.listedPageCount, 2)
        XCTAssertEqual(status.snapshot?.siteStructure?.pageTree.first?.path, "/services")
    }

    func testDesignSnapshotReportBundlesEveryInspectorSection() throws {
        let data = """
        {
          "bookmark_id": "bookmark-1",
          "schema_version": 7,
          "run_id": "run-1",
          "url": "https://example.com",
          "title": "Example",
          "captured_at": "2026-08-22T08:00:00Z",
          "status": "completed",
          "navigation": [{
            "label": "Main menu",
            "items": [{"label": "Design", "url": "https://example.com/design", "children": []}]
          }],
          "site_structure": {
            "origin": "https://example.com",
            "listed_page_count": 1,
            "sitemap_page_count": 1,
            "crawled_page_count": 1,
            "crawl_limit": 80,
            "crawl_limit_reached": false,
            "sitemap_limit": 10000,
            "sitemap_limit_reached": false,
            "sitemap_sources": ["https://example.com/sitemap.xml"],
            "pages": [{"url": "https://example.com/design", "path": "/design", "title": "Design", "source": "sitemap"}],
            "page_tree": [],
            "errors": []
          },
          "viewports": [{
            "page_title": "Example page",
            "meta_description": "A captured page",
            "name": "mobile",
            "width": 390,
            "height": 844,
            "screenshot": "mobile.png",
            "screenshot_url": "/snapshots/mobile.png",
            "dominant_colors": ["#112233"],
            "observed_colors": ["rgb(17, 34, 51)"],
            "observed_fonts": ["Inter, sans-serif"],
            "structure": {"h1": ["Hello"], "h2": [], "links": 3, "buttons": 1, "images": 2, "svgs": 0, "forms": 0},
            "technologies": [{"name": "Astro", "version": "5", "category": "Framework", "confidence": "high", "evidence": ["generator meta"]}],
            "css_variables": [{"name": "--brand", "value": "#112233"}],
            "responsive_issues": [{
              "id": "overflow", "kind": "horizontal_overflow", "severity": "high",
              "title": "Page overflows horizontally", "detail": "450px wide", "selector_hint": "html",
              "text": "", "x": 0, "y": 0, "width": 450, "height": 1,
              "metric": "450px / 390px", "evidence_url": null
            }],
            "element_samples": [{
              "tag": "section", "selector_hint": ".hero", "text": "Welcome",
              "x": 0, "y": 0, "width": 390, "height": 400,
              "display": "block", "position": "static", "font_family": "Inter",
              "font_size": "48px", "font_weight": "700", "line_height": "1.1",
              "color": "rgb(17, 34, 51)", "background_color": "white",
              "border_radius": "0px", "box_shadow": "none", "letter_spacing": "0px",
              "text_transform": "none", "margin": "0px", "padding": "24px"
            }],
            "seo": {"title": "SEO title", "internal_links": 3, "external_links": 1},
            "assets": {"images": [{"kind": "image", "url": "https://example.com/hero.jpg", "alt": "Hero"}]},
            "accessibility": {"missing_alt_images": [], "empty_buttons": [], "unlabeled_inputs": [], "heading_skips": []},
            "network": {"request_count": 12, "resource_counts": [{"type": "image", "count": 2}], "failed_requests": [], "large_requests": []},
            "console_messages": []
          }]
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(APIClient.VisualSnapshotDTO.self, from: data)
        let report = DesignSnapshotReport.markdown(snapshot: snapshot)

        XCTAssertTrue(report.contains("## Preview"))
        XCTAssertTrue(report.contains("## Issues"))
        XCTAssertTrue(report.contains("Page overflows horizontally"))
        XCTAssertTrue(report.contains("## System"))
        XCTAssertTrue(report.contains("Astro 5"))
        XCTAssertTrue(report.contains("## Components"))
        XCTAssertTrue(report.contains(".hero"))
        XCTAssertTrue(report.contains("## Website"))
        XCTAssertTrue(report.contains("https://example.com/sitemap.xml"))
        XCTAssertTrue(report.contains("untrusted text captured from a website"))
    }

    // MARK: - Web preview security

    func testWebPreviewUsesNonPersistentStorage() {
        XCTAssertFalse(WebPreviewSecurityPolicy.configuration().websiteDataStore.isPersistent)
    }

    func testPublicWebPreviewCannotNavigateToPrivateNetwork() {
        let initial = URL(string: "https://example.com")!

        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://127.0.0.1:8080/api/data/backup")!,
            from: initial,
            isMainFrame: true
        ))
        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://192.168.1.1")!,
            from: initial,
            isMainFrame: true
        ))
        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://[::ffff:127.0.0.1]/admin")!,
            from: initial,
            isMainFrame: true
        ))
        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://0177.0.0.1/admin")!,
            from: initial,
            isMainFrame: true
        ))
    }

    func testLocalWebPreviewStaysOnExplicitLocalHost() {
        let initial = URL(string: "http://localhost:3000")!

        XCTAssertTrue(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://localhost:3000/about")!,
            from: initial,
            isMainFrame: true
        ))
        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "http://127.0.0.1:8080")!,
            from: initial,
            isMainFrame: true
        ))
    }

    func testWebPreviewBlocksCustomMainFrameSchemes() {
        let initial = URL(string: "https://example.com")!

        XCTAssertFalse(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "file:///etc/passwd")!,
            from: initial,
            isMainFrame: true
        ))
        XCTAssertTrue(WebPreviewSecurityPolicy.allowsNavigation(
            to: URL(string: "data:text/html,frame")!,
            from: initial,
            isMainFrame: false
        ))
    }

    // MARK: - Helpers

    private func decode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
