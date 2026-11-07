import XCTest
@testable import Gyrus

/// Counts, delete with undo, trash and purge (TrashController).
@MainActor
final class TrashControllerTests: XCTestCase {
    override func tearDown() {
        ControllerURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Counts

    func testCountsSubtractPendingDeletions() {
        let store = BookmarkStore(api: stubbedClient { _ in (500, Data()) }, draftStorage: nil)
        store.pendingDeletionIds = ["a", "b"]
        store.applyCounts(BookmarkCounts(total: 10, dead: 1, unread: 2, trash: 3))
        XCTAssertEqual(store.totalBookmarkCount, 8)
        XCTAssertEqual(store.deadBookmarkCount, 1)
        XCTAssertEqual(store.unreadBookmarkCount, 2)
        XCTAssertEqual(store.trashCount, 3)

        // A count the server has not caught up with yet never goes negative.
        store.pendingDeletionIds = Set((0..<20).map { "p-\($0)" })
        store.applyCounts(BookmarkCounts(total: 10, dead: 0, unread: 0, trash: 0))
        XCTAssertEqual(store.totalBookmarkCount, 0)
    }

    func testRefreshedServerCountsSubtractPendingDeletions() async {
        let (trash, bookmarks, _, _, _) = makeTrash { request in
            XCTAssertEqual(request.url?.path, "/api/bookmarks/counts")
            return (200, Data(#"{"total":5,"dead":1,"unread":0,"trash":2}"#.utf8))
        }
        bookmarks.pendingDeletionIds = ["waiting-out-undo"]
        await trash.refreshCounts()
        XCTAssertEqual(bookmarks.totalBookmarkCount, 4)
        XCTAssertEqual(bookmarks.trashCount, 2)
    }

    // MARK: - Delete, purge, undo

    func testDeleteInTrashRoutesToPurgeConfirmation() {
        // Even with delete confirmation turned off, a permanent delete asks.
        let (trash, bookmarks, collections, ui, _) = makeTrash(confirmsDelete: false) { _ in (500, Data()) }
        collections.showTrash = true
        bookmarks.bookmarks = [fixtureBookmark("a"), fixtureBookmark("b")]
        bookmarks.selectedIds = ["a"]

        trash.requestDeleteSelected()

        XCTAssertEqual(trash.pendingPurge, .ids(["a"]))
        XCTAssertNil(trash.pendingBatchDelete)
        XCTAssertTrue(bookmarks.pendingDeletionIds.isEmpty)
        XCTAssertEqual(bookmarks.bookmarks.map(\.id), ["a", "b"])
        XCTAssertNil(ui.undoAction)
    }

    func testDeleteOutsideTrashAsksForMoveToTrashConfirmation() {
        let (trash, bookmarks, _, _, _) = makeTrash(confirmsDelete: true) { _ in (500, Data()) }
        bookmarks.selectedIds = ["a", "b"]
        trash.requestDeleteSelected()
        XCTAssertEqual(trash.pendingBatchDelete, ["a", "b"])
        XCTAssertNil(trash.pendingPurge)
    }

    func testUndoRestoresRowsAtTheirOriginalIndexes() async throws {
        let log = RequestLog()
        let (trash, bookmarks, _, ui, library) = makeTrash(undoWindow: 0.2) { request in
            log.record(request.url!.path)
            return (204, Data())
        }
        bookmarks.bookmarks = ["a", "b", "c", "d", "e"].map { fixtureBookmark($0) }
        bookmarks.totalBookmarkCount = 5
        bookmarks.selectedIds = ["b", "d"]
        bookmarks.selectedBookmark = bookmarks.bookmarks[1]

        await trash.deleteSelected()

        XCTAssertEqual(bookmarks.bookmarks.map(\.id), ["a", "c", "e"])
        XCTAssertEqual(bookmarks.pendingDeletionIds, ["b", "d"])
        XCTAssertEqual(bookmarks.totalBookmarkCount, 3)
        XCTAssertTrue(bookmarks.selectedIds.isEmpty)
        XCTAssertNil(bookmarks.selectedBookmark)
        XCTAssertEqual(ui.undoMessage, String(localized: "Deleted \(2) bookmarks"))

        let reloaded = expectation(description: "Undo reloads the view")
        library.onLoadBookmarks = { reloaded.fulfill() }
        try XCTUnwrap(ui.undoAction)()

        XCTAssertEqual(bookmarks.bookmarks.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(bookmarks.selectedIds, ["b", "d"])
        XCTAssertEqual(bookmarks.selectedBookmark?.id, "b")
        XCTAssertTrue(bookmarks.pendingDeletionIds.isEmpty)
        XCTAssertNil(ui.undoMessage)
        XCTAssertNil(ui.undoAction)
        await fulfillment(of: [reloaded], timeout: 2)

        // The deferred server delete was cancelled, not just delayed.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(log.requests(to: "/api/bookmarks/delete-batch").isEmpty)
        XCTAssertEqual(library.loadAllCount, 0)
    }

    func testCommittedDeleteIsSentInChunksThenReloadsLibrary() async throws {
        let log = RequestLog()
        let (trash, bookmarks, _, _, library) = makeTrash(undoWindow: 0.01) { request in
            let ids = try XCTUnwrap(try requestJSON(request)["ids"] as? [String])
            log.record(request.url!.path, ids: ids)
            return (204, Data())
        }
        let ids = Set((0..<1201).map { "b-\($0)" })
        bookmarks.selectedIds = ids

        let committed = expectation(description: "Library reloaded after the server delete")
        library.onLoadAll = { committed.fulfill() }
        await trash.deleteSelected()
        await fulfillment(of: [committed], timeout: 5)

        let chunks = log.requests(to: "/api/bookmarks/delete-batch")
        XCTAssertEqual(chunks.map(\.count).sorted(), [201, 500, 500])
        XCTAssertEqual(Set(chunks.flatMap { $0 }), ids)
        XCTAssertTrue(bookmarks.pendingDeletionIds.isEmpty)
    }

    func testSingleDeleteOfUnlistedBookmarkKeepsItsPreview() async {
        let (trash, bookmarks, _, _, _) = makeTrash { _ in (204, Data()) }
        let hit = fixtureBookmark("quick-search-hit")
        bookmarks.bookmarks = [fixtureBookmark("a")]
        bookmarks.selectedBookmark = hit
        await trash.deleteBookmark(hit)
        XCTAssertEqual(bookmarks.selectedBookmark?.id, hit.id)
        XCTAssertEqual(bookmarks.pendingDeletionIds, [hit.id])
        XCTAssertEqual(bookmarks.bookmarks.map(\.id), ["a"])
        // Never let the deferred delete outlive the test into another one.
        await trash.cancelPendingDeletes()
    }

    // MARK: - Fixtures

    private func makeTrash(
        confirmsDelete: Bool = false,
        undoWindow: TimeInterval = UIStateStore.undoWindow,
        _ handler: @escaping StubHandler
    ) -> (TrashController, BookmarkStore, CollectionStore, UIStateStore, LibraryRecorder) {
        let api = stubbedClient(handler)
        let bookmarks = BookmarkStore(api: api, draftStorage: nil)
        let collections = CollectionStore(api: api)
        let ui = UIStateStore()
        let library = LibraryRecorder()
        let trash = TrashController(api: api, bookmarks: bookmarks, collections: collections, ui: ui,
                                    confirmsDelete: { confirmsDelete }, undoWindow: undoWindow)
        trash.library = library
        return (trash, bookmarks, collections, ui, library)
    }
}
