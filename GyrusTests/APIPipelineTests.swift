import XCTest
@testable import Gyrus

/// Answers every request from a handler and records what was sent, so tests
/// see the request exactly as it left the pipeline (headers, timeout, body).
private final class PipelineURLProtocol: URLProtocol {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(Error)
    }

    static var reply: (URLRequest) -> Reply = { _ in .response(status: 200, body: Data("{}".utf8)) }
    static var recorded: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        switch Self.reply(request) {
        case .response(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class APIPipelineTests: XCTestCase {
    private var api: APIClient!

    override func setUp() {
        super.setUp()
        PipelineURLProtocol.recorded = []
        PipelineURLProtocol.reply = { _ in .response(status: 200, body: Data("{}".utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PipelineURLProtocol.self]
        api = APIClient(base: URL(string: "http://gyrus-pipeline.invalid")!,
                        session: URLSession(configuration: configuration))
    }

    private func reply(_ status: Int, _ body: String) {
        PipelineURLProtocol.reply = { _ in .response(status: status, body: Data(body.utf8)) }
    }

    private var lastRequest: URLRequest {
        get throws { try XCTUnwrap(PipelineURLProtocol.recorded.last) }
    }

    private func sentBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func assertToken(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Gyrus-Token"), BackendLauncher.apiToken,
                       file: file, line: line)
    }

    // MARK: Token, headers, timeouts

    func testGetCarriesTokenAndNoBody() async throws {
        reply(200, "5")
        let count = try await api.bookmarkCount()
        XCTAssertEqual(count, 5)
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/bookmarks/count")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
    }

    func testPostSendsJSONWithToken() async throws {
        reply(200, #"{"updated":2}"#)
        let updated = try await api.setBookmarksRead(ids: ["a"], isRead: true)
        XCTAssertEqual(updated, 2)
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sentBody(request)) as? [String: Any])
        XCTAssertEqual(json["ids"] as? [String], ["a"])
        XCTAssertEqual(json["is_read"] as? Bool, true)
    }

    func testPutAndDeleteCarryToken() async throws {
        reply(200, "{}")
        try await api.deleteTag(id: "t1")
        var request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/tags/t1")

        reply(200, #"{"status":"ok"}"#)
        let _: [String: String] = try await api.put(api.base.appending(path: "/api/x"), body: EmptyBody())
        request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRawRequestCarriesTokenAndTransferTimeout() async throws {
        reply(200, "raw")
        var raw = URLRequest(url: api.base.appending(path: "/api/data/backup"))
        raw.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let data = try await api.sendRaw(raw)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "raw")
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertEqual(request.timeoutInterval, APIClient.libraryTransferTimeout)
    }

    func testMultipartImportUsesTransferTimeoutAndBoundary() async throws {
        reply(200, #"{"status":"ok","imported":1,"skipped":0,"collections_created":0}"#)
        let result = try await api.importHTML(data: Data("<html/>".utf8), filename: "b.html", rootFolderName: "Import")
        XCTAssertEqual(result.imported, 1)
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, APIClient.libraryTransferTimeout)
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: sentBody(request), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="root_folder_name""#))
        XCTAssertTrue(body.contains("<html/>"))
    }

    func testHealthCarriesTokenAndShortTimeout() async throws {
        reply(200, #"{"status":"ok","service":"gyrus"}"#)
        let healthy = try await api.health()
        XCTAssertTrue(healthy)
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.url?.path, "/api/ready")
        XCTAssertEqual(request.timeoutInterval, 2)
    }

    func testHealthTreatsErrorStatusAsNotReady() async throws {
        reply(503, #"{"detail":"starting"}"#)
        let healthy = try await api.health()
        XCTAssertFalse(healthy)
    }

    func testLLMTimeoutIsApplied() async throws {
        reply(200, #"{"summary":"Short."}"#)
        _ = try await api.summarize(bookmarkId: "b1", config: AIBrainConfig())
        XCTAssertEqual(try lastRequest.timeoutInterval, APIClient.llmTimeout)
    }

    func testReindexIsABodylessPostThroughTheClientSession() async throws {
        reply(200, #"{"status":"started","message":null}"#)
        let response = try await api.reindexEmbeddings()
        XCTAssertEqual(response.status, "started")
        let request = try lastRequest
        assertToken(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(sentBody(request).isEmpty)
    }

    // MARK: Query items

    func testQueryItemsAreAppendedAndEncoded() async throws {
        reply(200, "[]")
        _ = try await api.bookmarks(collectionId: "folder with spaces", deadOnly: true, limit: 50, offset: 100)
        let url = try XCTUnwrap(lastRequest.url)
        XCTAssertEqual(url.path, "/api/bookmarks")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["collection_id"], "folder with spaces")
        XCTAssertEqual(query["dead_only"], "true")
        XCTAssertEqual(query["limit"], "50")
        XCTAssertEqual(query["offset"], "100")
        XCTAssertNil(query["unread_only"])
    }

    func testPlusInQueryIsPercentEncoded() throws {
        // A literal "+" is read as a space by the server's form decoding.
        let request = APIRequest(.get, path: "/api/search", query: [URLQueryItem(name: "q", value: "c++ guide")])
        let url = try request.resolvedURL(base: URL(string: "http://127.0.0.1:8080")!)
        XCTAssertEqual(url.query(percentEncoded: true), "q=c%2B%2B%20guide")
    }

    func testEmptyQueryAddsNoQuestionMark() async throws {
        reply(200, "[]")
        _ = try await api.bookmarkIds()
        let url = try XCTUnwrap(lastRequest.url)
        XCTAssertNil(url.query)
        XCTAssertFalse(url.absoluteString.hasSuffix("?"))
    }

    // MARK: Status mapping

    func testConflictWithoutDetailIsDuplicate() async {
        reply(409, "")
        do {
            _ = try await api.createTag(TagCreate(name: "x", color: nil))
            XCTFail("Expected duplicate")
        } catch APIError.duplicate {
            XCTAssertEqual(APIError.duplicate.localizedDescription, String(localized: "This bookmark already exists."))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testConflictSayingAlreadyExistsIsDuplicate() async {
        reply(409, #"{"detail":"Bookmark with this URL already exists"}"#)
        do {
            try await api.deleteBookmark(id: "b")
            XCTFail("Expected duplicate")
        } catch APIError.duplicate {
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testValidationErrorListBecomesReadableMessage() async {
        reply(422, """
        {"detail":[
          {"type":"missing","loc":["body","url"],"msg":"Field required","input":{}},
          {"type":"string_type","loc":["body","ids",0],"msg":"Input should be a valid string","input":1}
        ]}
        """)
        do {
            try await api.deleteBookmarks(ids: ["b"])
            XCTFail("Expected server message")
        } catch APIError.serverMessage(let message) {
            XCTAssertEqual(message, "url: Field required\nids.0: Input should be a valid string")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testStringDetailIsPassedThroughUnchanged() async {
        // VisualSnapshotTabView and the Reader match on the exact backend text.
        reply(404, #"{"detail":"Visual snapshot not found"}"#)
        do {
            _ = try await api.visualSnapshot(bookmarkId: "b")
            XCTFail("Expected server message")
        } catch APIError.serverMessage(let message) {
            XCTAssertEqual(message, "Visual snapshot not found")
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testServerErrorWithoutDetailIsStatusError() async {
        reply(500, "Internal Server Error")
        do {
            _ = try await api.tags()
            XCTFail("Expected status error")
        } catch APIError.serverError(let code) {
            XCTAssertEqual(code, 500)
            let text = APIError.serverError(code).localizedDescription
            XCTAssertNotEqual(text, "Server error 500")
            XCTAssertTrue(text.contains("500"))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testUnreadableDetailFallsBackToStatusError() {
        XCTAssertNil(APIError.serverDetail(from: Data(#"{"detail":{"nested":true}}"#.utf8)))
        XCTAssertNil(APIError.serverDetail(from: Data(#"{"detail":[1,2]}"#.utf8)))
        XCTAssertNil(APIError.serverDetail(from: Data("not json".utf8)))
        XCTAssertEqual(APIError.serverDetail(from: Data(#"{"detail":{"msg":"Too many"}}"#.utf8)), "Too many")
    }

    // MARK: Transport and decoding

    func testTransportFailureBecomesReadableNetworkError() async {
        PipelineURLProtocol.reply = { _ in .failure(URLError(.cannotConnectToHost)) }
        do {
            _ = try await api.collections()
            XCTFail("Expected network error")
        } catch APIError.networkError(let inner) {
            XCTAssertEqual((inner as? URLError)?.code, .cannotConnectToHost)
            XCTAssertEqual(APIError.networkError(inner).localizedDescription,
                           String(localized: "The Gyrus backend could not be reached. Check the app status and try again."))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testTimeoutHasItsOwnMessage() {
        let text = APIError.networkError(URLError(.timedOut)).localizedDescription
        XCTAssertEqual(text, String(localized: "The backend took too long to respond. Please try again."))
        XCTAssertFalse(text.hasPrefix("Network error"))
    }

    func testCancelledRequestIsCancellationNotNetworkError() async {
        PipelineURLProtocol.reply = { _ in .failure(URLError(.cancelled)) }
        do {
            _ = try await api.tags()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testDecodingFailureIsReadableAndKeepsTheCauseForDebugging() async {
        reply(200, #"{"unexpected":true}"#)
        do {
            _ = try await api.collections()
            XCTFail("Expected decoding error")
        } catch let error as APIError {
            guard case .decodingError(let detail) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(detail.contains("/api/collections"))
            XCTAssertEqual(error.localizedDescription,
                           String(localized: "The backend sent a response Gyrus could not read. Please try again."))
            XCTAssertEqual(error.failureReason, detail)
            XCTAssertFalse(error.localizedDescription.contains("unexpected"))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    // MARK: Request description

    func testRequestDescriptionBuildsWithoutToken() throws {
        let request = try APIRequest(.post, path: "/api/a b", query: [.init(name: "q", value: "x y")],
                                     body: .raw(Data("1".utf8), contentType: "text/csv"), timeout: 7)
            .urlRequest(base: URL(string: "http://h.invalid")!)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/a b")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "x y")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/csv")
        XCTAssertEqual(request.timeoutInterval, 7)
        // Only `APIClient.exchange` adds the token.
        XCTAssertNil(request.value(forHTTPHeaderField: APIClient.tokenHeader))
    }

    func testQueryIsAppendedToAnExistingQuery() throws {
        let url = try APIRequest(url: URL(string: "http://h.invalid/p?a=1")!, query: [.init(name: "b", value: "2")])
            .resolvedURL(base: URL(string: "http://ignored.invalid")!)
        XCTAssertEqual(url.absoluteString, "http://h.invalid/p?a=1&b=2")
    }
}
