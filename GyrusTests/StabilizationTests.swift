import XCTest
@testable import Gyrus

private final class ReviewURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class StabilizationTests: XCTestCase {
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> APIClient {
        ReviewURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        return APIClient(base: URL(string: "http://gyrus-test.invalid")!, session: URLSession(configuration: config))
    }

    private func bookmark(_ id: String = "bookmark-1") -> Bookmark {
        Bookmark(id: id, title: "Example", url: "https://example.com", description: nil,
                 notes: nil, bookmarkNotes: [], faviconPath: nil, ogImageUrl: nil,
                 ogImagePath: nil, source: "manual", isDead: false, collectionId: nil,
                 tags: [], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNoteFailurePreservesDraftAndRetryClearsOnlySavedText() async throws {
        var fail = true
        let note = BookmarkNote(id: "note-1", content: "Keep this draft", source: "user", createdAt: Date(), updatedAt: Date())
        let data = try encoded(note)
        let api = client { _ in
            fail ? (500, Data(#"{"detail":"Save unavailable"}"#.utf8)) : (200, data)
        }
        let store = BookmarkStore(api: api)
        let bm = bookmark()
        store.bookmarks = [bm]
        store.selectedBookmark = bm
        store.noteDrafts[bm.id] = note.content
        store.noteDrafts["another"] = "Independent draft"
        await store.saveNoteDraft(for: bm)
        XCTAssertEqual(store.noteDrafts[bm.id], note.content)
        XCTAssertNotNil(store.noteErrors[bm.id])
        XCTAssertTrue(store.savingNoteIds.isEmpty)
        fail = false
        await store.saveNoteDraft(for: bm)
        XCTAssertNil(store.noteDrafts[bm.id])
        XCTAssertNil(store.noteErrors[bm.id])
        XCTAssertEqual(store.selectedBookmark?.bookmarkNotes.map(\.content), [note.content])
        XCTAssertEqual(store.noteDrafts["another"], "Independent draft")
    }

    func testSemanticFallbackContinuesKeywordPagination() async throws {
        let first = try encoded((0..<100).map { bookmark("b-\($0)") })
        let second = try encoded([bookmark("b-100")])
        var semanticCalls = 0
        var offsets: [String] = []
        let api = client { request in
            if request.url!.path == "/api/search/semantic" {
                semanticCalls += 1
                return (200, Data("[]".utf8))
            }
            XCTAssertEqual(request.url!.path, "/api/search")
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
            offsets.append(offset)
            return (200, offset == "0" ? first : second)
        }
        let store = BookmarkStore(api: api)
        store.semanticSearchEnabled = true
        try await store.loadBookmarks(query: "needle", refreshCount: false)
        XCTAssertTrue(store.usingKeywordFallback)
        XCTAssertTrue(store.hasMore)
        try await store.loadMoreBookmarks()
        XCTAssertEqual(store.bookmarks.count, 101)
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(semanticCalls, 1)
        XCTAssertEqual(offsets, ["0", "100"])
    }

    func testSemanticSelectAllUsesSemanticResults() async throws {
        let results = try encoded([bookmark("semantic-only")])
        let api = client { request in
            XCTAssertEqual(request.url!.path, "/api/search/semantic")
            return (200, results)
        }
        let store = BookmarkStore(api: api)
        store.semanticSearchEnabled = true
        try await store.loadBookmarks(query: "needle", refreshCount: false)
        try await store.selectAllInCurrentView(query: "needle")
        XCTAssertEqual(store.selectedIds, ["semantic-only"])
    }

    func testDroppedURLGetsValidTitleAndFolder() async throws {
        let response = try encoded(bookmark())
        let api = client { [self] request in
            let json = try body(request)
            XCTAssertEqual(json["title"] as? String, "example.com")
            XCTAssertEqual(json["collection_id"] as? String, "folder-1")
            return (200, response)
        }
        _ = try await BookmarkStore(api: api).addBookmarkFromURL("https://example.com/path", collectionId: "folder-1")
    }

    func testTagAssignmentIncludesUnloadedSelectionWithoutReplacingOtherTags() async throws {
        let results = try encoded([Bookmark]())
        let api = client { [self] request in
            XCTAssertEqual(request.url!.path, "/api/tags/assign")
            let json = try body(request)
            XCTAssertEqual(Set(json["bookmark_ids"] as! [String]), ["loaded", "unloaded"])
            XCTAssertEqual(json["add_tag_ids"] as? [String], ["new-tag"])
            XCTAssertEqual(json["remove_tag_ids"] as? [String], [])
            return (200, results)
        }
        let store = TagStore(api: api)
        _ = try await store.toggleTag(tagId: "new-tag", onBookmarkIds: ["loaded", "unloaded"], in: [bookmark("loaded")])
    }

    func testAllTagPresenceRequiresEntireSelection() {
        let tag = Tag(id: "tag", name: "Tag", createdAt: Date())
        var loaded = bookmark("loaded")
        loaded.tags = [tag]
        XCTAssertEqual(TagStore().tagPresence(tagId: tag.id, in: [loaded], forIds: ["loaded", "unloaded"]), .some)
    }

    func testExportScopeAndPageLimitAreSentToBothEndpoints() async throws {
        let api = client { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "collection_id" }?.value, "folder with spaces")
            if request.url!.path.hasSuffix("bookmarks") {
                XCTAssertEqual(query.first { $0.name == "limit" }?.value, "200")
            }
            return (200, Data("[]".utf8))
        }
        _ = try await api.exportHTML(collectionId: "folder with spaces")
        _ = try await api.exportBookmarks(collectionId: "folder with spaces")
    }

    func testAIMasterSwitchIsSentSeparatelyAndDisablesMirror() async throws {
        let api = client { [self] request in
            let json = try body(request)
            XCTAssertEqual(json["ai_enabled"] as? Bool, false)
            XCTAssertEqual(json["is_enabled"] as? Bool, false)
            return (200, Data(#"{"status":"ok","root_dir":"/tmp/brain","is_enabled":false}"#.utf8))
        }
        var config = AIBrainConfig()
        config.aiEnabled = false
        config.brainMirrorEnabled = true
        try await api.updateAIBrainConfig(config)
    }

    func testBusyResponseIsNotMistakenForDuplicateBookmark() throws {
        let response = HTTPURLResponse(url: URL(string: "http://gyrus-test.invalid")!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try APIClient().checkStatus(response, data: Data(#"{"detail":"Background work is still running."}"#.utf8))) { error in
            guard case APIError.serverMessage(let message) = error else { return XCTFail("Expected actionable server message") }
            XCTAssertEqual(message, "Background work is still running.")
        }
    }

    func testReadinessRequiresMatchingSessionAndService() async throws {
        var service = "unrelated"
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/api/ready")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gyrus-Token"), BackendLauncher.apiToken)
            return (200, Data("{\"status\":\"ok\",\"service\":\"\(service)\"}".utf8))
        }
        let unrelated = try await api.health()
        XCTAssertFalse(unrelated)
        service = "gyrus"
        let ready = try await api.health()
        XCTAssertTrue(ready)
    }

    func testBackupPreviewReadsCountsWithoutCallingRestore() async throws {
        let api = client { request in
            XCTAssertEqual(request.url?.path, "/api/data/restore/preview")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Data(#"{"version":2,"exported_at":"2026-09-06T12:00:00Z","collections":3,"tags":4,"bookmarks":21,"notes":7,"messages":9}"#.utf8))
        }
        let result = try await api.previewBackup(Data("{}".utf8))
        XCTAssertEqual(result.bookmarks, 21)
        XCTAssertEqual(result.notes, 7)
        XCTAssertNotNil(result.exportedAt)
    }

    func testConfigWritesAreSerializedAndIntermediateChangesCoalesced() async throws {
        var sent: [AIBrainConfig] = []
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "First write started")
        let sync = AIConfigSync { config in
            sent.append(config)
            if sent.count == 1 {
                started.fulfill()
                await withCheckedContinuation { resume = $0 }
            }
        }
        var first = AIBrainConfig()
        first.ollamaModel = "first"
        var middle = first
        middle.ollamaModel = "middle"
        var last = first
        last.ollamaModel = "last"
        sync.submit(first)
        await fulfillment(of: [started], timeout: 2)
        sync.submit(middle)
        sync.submit(last)
        XCTAssertEqual(sent.map(\.ollamaModel), ["first"])
        resume?.resume()
        let completed = await sync.synchronize(last)
        XCTAssertTrue(completed)
        XCTAssertEqual(sent.map(\.ollamaModel), ["first", "last"])
        XCTAssertEqual(sync.confirmed, last)
        XCTAssertFalse(sync.isSyncing)
    }

    func testConfigFailureIsVisibleAndSameValueCanBeRetried() async {
        var fail = true
        let sync = AIConfigSync { _ in
            if fail { throw APIError.serverError(503) }
        }
        let config = AIBrainConfig()
        let failed = await sync.synchronize(config)
        XCTAssertFalse(failed)
        XCTAssertNotNil(sync.error)
        XCTAssertNil(sync.confirmed)
        fail = false
        let retried = await sync.synchronize(config)
        XCTAssertTrue(retried)
        XCTAssertNil(sync.error)
    }

    func testDraftsSurviveStoreRecreationAndResetClearsDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = NoteDraftStorage(url: directory.appendingPathComponent("drafts.json"))
        let first = BookmarkStore(draftStorage: storage)
        first.noteDrafts["a"] = "Unsaved work"
        let restored = BookmarkStore(draftStorage: storage)
        XCTAssertEqual(restored.noteDrafts["a"], "Unsaved work")
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        restored.resetLocalState()
        XCTAssertEqual(try storage.read(), [:])
    }

    func testDraftWriteFailureIsVisibleAndKeepsTextInMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("blocks-directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookmarkStore(draftStorage: NoteDraftStorage(url: directory.appendingPathComponent("drafts.json")))
        store.noteDrafts["a"] = "Keep this"
        XCTAssertEqual(store.noteDrafts["a"], "Keep this")
        XCTAssertNotNil(store.draftStorageError)
    }

    func testChatClearFailureKeepsConversationAndOffersRetry() async throws {
        var fail = true
        let deleted = expectation(description: "Delete attempted")
        let api = client { request in
            if request.httpMethod == "DELETE" {
                deleted.fulfill()
                return fail ? (503, Data(#"{"detail":"Try later"}"#.utf8)) : (204, Data())
            }
            return (200, Data(#"[{"id":"message","bookmark_id":"a","role":"user","content":"Remember me","status":"complete","created_at":"2026-09-06T12:00:00Z","updated_at":"2026-09-06T12:00:00Z"}]"#.utf8))
        }
        let chat = BrainChatStore(api: api)
        await chat.load(bookmarkId: "a")
        XCTAssertEqual(chat.messages(for: "a").count, 1)
        chat.clear("a")
        await fulfillment(of: [deleted], timeout: 2)
        // Wait for the URLSession completion to propagate onto the main actor.
        for _ in 0..<100 where chat.clearing.contains("a") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.clearing.contains("a"))
        XCTAssertEqual(chat.messages(for: "a").first?.text, "Remember me")
        XCTAssertNotNil(chat.errors["a"])
        fail = false
        chat.resetLocalState()
        XCTAssertTrue(chat.messages(for: "a").isEmpty)
        XCTAssertTrue(chat.errors.isEmpty)
    }
}
