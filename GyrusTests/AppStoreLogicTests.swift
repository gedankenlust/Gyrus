import XCTest
@testable import Gyrus

@MainActor
final class AppStoreLogicTests: XCTestCase {

    var appStore: AppStore!
    var bookmarkStore: BookmarkStore!
    var collectionStore: CollectionStore!
    var tagStore: TagStore!

    override func setUp() {
        super.setUp()
        appStore = AppStore()
        bookmarkStore = appStore.bookmarksStore
        collectionStore = appStore.collectionsStore
        tagStore = appStore.tagsStore
    }

    // MARK: - tagPresence

    func testTagPresenceNone() {
        let bms = [bm("b1", tags: []), bm("b2", tags: [])]
        XCTAssertEqual(tagStore.tagPresence(tagId: "t1", in: bms, forIds: ["b1", "b2"]), .none)
    }

    func testTagPresenceAll() {
        let bms = [bm("b1", tags: ["t1"]), bm("b2", tags: ["t1"])]
        XCTAssertEqual(tagStore.tagPresence(tagId: "t1", in: bms, forIds: ["b1", "b2"]), .all)
    }

    func testTagPresenceSome() {
        let bms = [bm("b1", tags: ["t1"]), bm("b2", tags: [])]
        XCTAssertEqual(tagStore.tagPresence(tagId: "t1", in: bms, forIds: ["b1", "b2"]), .some)
    }

    func testTagPresenceEmptySelectionReturnsNone() {
        let bms = [bm("b1", tags: ["t1"])]
        XCTAssertEqual(tagStore.tagPresence(tagId: "t1", in: bms, forIds: []), .none)
    }

    func testTagPresenceIgnoresNonSelectedBookmarks() {
        let bms = [bm("b1", tags: ["t1"]), bm("b2", tags: [])]
        // Only b1 is selected — it has the tag → .all
        XCTAssertEqual(tagStore.tagPresence(tagId: "t1", in: bms, forIds: ["b1"]), .all)
    }

    // MARK: - flatCollections

    func testFlatCollectionsEmpty() {
        collectionStore.collections = []
        XCTAssertTrue(collectionStore.flatCollections.isEmpty)
    }

    func testFlatCollectionsFlat() {
        collectionStore.collections = [col("c1"), col("c2")]
        XCTAssertEqual(collectionStore.flatCollections.map { $0.id }, ["c1", "c2"])
    }

    func testFlatCollectionsDepthFirstOrder() {
        collectionStore.collections = [
            col("parent", children: [
                col("child1", children: [col("grandchild")]),
                col("child2"),
            ])
        ]
        XCTAssertEqual(
            collectionStore.flatCollections.map { $0.id },
            ["parent", "child1", "grandchild", "child2"]
        )
    }

    func testFlatCollectionsMultipleRoots() {
        collectionStore.collections = [
            col("a", children: [col("a1")]),
            col("b", children: [col("b1")]),
        ]
        XCTAssertEqual(
            collectionStore.flatCollections.map { $0.id },
            ["a", "a1", "b", "b1"]
        )
    }

    // MARK: - requestOpenInBrowser / batch-open threshold

    func testBatchOpenAtThresholdDoesNotSetPending() {
        // threshold is 5: exactly 5 should NOT show confirmation
        bookmarkStore.bookmarks = (1...5).map { bm("b\($0)", tags: []) }
        appStore.requestOpenInBrowser(ids: Set(bookmarkStore.bookmarks.map { $0.id }))
        XCTAssertNil(appStore.uiStateStore.pendingBatchOpen)
    }

    func testBatchOpenAboveThresholdSetsPending() {
        bookmarkStore.bookmarks = (1...6).map { bm("b\($0)", tags: []) }
        let ids = Set(bookmarkStore.bookmarks.map { $0.id })
        appStore.requestOpenInBrowser(ids: ids)
        XCTAssertEqual(appStore.uiStateStore.pendingBatchOpen, ids)
    }

    func testCancelPendingOpenClearsState() {
        bookmarkStore.bookmarks = (1...6).map { bm("b\($0)", tags: []) }
        appStore.requestOpenInBrowser(ids: Set(bookmarkStore.bookmarks.map { $0.id }))
        appStore.cancelPendingOpen()
        XCTAssertNil(appStore.uiStateStore.pendingBatchOpen)
    }

    func testConfirmPendingOpenClearsState() {
        bookmarkStore.bookmarks = (1...6).map { bm("b\($0)", tags: []) }
        appStore.requestOpenInBrowser(ids: Set(bookmarkStore.bookmarks.map { $0.id }))
        appStore.confirmPendingOpen()
        XCTAssertNil(appStore.uiStateStore.pendingBatchOpen)
    }

    // MARK: - Fixtures

    private func bm(_ id: String, tags tagIds: [String]) -> Bookmark {
        Bookmark(
            id: id, title: "T", url: "test://fake",
            description: nil, notes: nil, bookmarkNotes: [], faviconPath: nil,
            ogImageUrl: nil, ogImagePath: nil,
            source: "manual", isDead: false, collectionId: nil,
            tags: tagIds.map { Tag(id: $0, name: $0, color: nil, createdAt: Date()) },
            createdAt: Date(), updatedAt: Date()
        )
    }

    private func col(_ id: String, children: [Collection] = []) -> Collection {
        Collection(id: id, name: id, children: children)
    }
}
