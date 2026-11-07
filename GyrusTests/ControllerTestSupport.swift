import XCTest
@testable import Gyrus

// Shared fixtures for the controller suites (TrashControllerTests,
// LibraryControllerTests).

/// Answers every request of a test's APIClient. Separate from the stub in
/// StabilizationTests so the two suites never share a handler.
final class ControllerURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

/// Records what a controller asked its owner to reload.
@MainActor
final class LibraryRecorder: LibraryReloading {
    var loadAllCount = 0
    var loadBookmarksCount = 0
    var onLoadAll: (() -> Void)?
    var onLoadBookmarks: (() -> Void)?

    func loadAll() async {
        loadAllCount += 1
        onLoadAll?()
    }

    func loadBookmarks(showsLoadingIndicator: Bool) async {
        loadBookmarksCount += 1
        onLoadBookmarks?()
    }
}

/// Thread-safe log of the requests the stub saw (URLProtocol runs off the main thread).
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, ids: [String])] = []

    func record(_ path: String, ids: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        entries.append((path, ids))
    }

    func requests(to path: String) -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.path == path }.map(\.ids)
    }
}

/// Health answers handed out in order across URL loading threads; the last
/// one repeats.
final class HealthAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]

    init(_ answers: [Bool]) { self.answers = answers }

    func next() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? false)
    }
}

/// An APIClient whose requests all go to `handler`.
func stubbedClient(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> APIClient {
    ControllerURLProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ControllerURLProtocol.self]
    return APIClient(base: URL(string: "http://gyrus-test.invalid")!, session: URLSession(configuration: config))
}

func fixtureBookmark(_ id: String) -> Bookmark {
    Bookmark(id: id, title: id, url: "https://example.com/\(id)", description: nil,
             notes: nil, bookmarkNotes: [], faviconPath: nil, ogImageUrl: nil,
             ogImagePath: nil, source: "manual", isDead: false, collectionId: nil,
             tags: [], createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
}

func decodeFixture<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// The JSON body of a stubbed request. URLSession hands it over as a stream.
func requestJSON(_ request: URLRequest) throws -> [String: Any] {
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
