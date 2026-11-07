import Foundation

// The backend API surface is split by domain to keep each file reviewable:
//   APIClient.swift              core: sessions, the request pipeline, HTTP verbs
//   APIRequest.swift             the request description every call is built from
//   APIError.swift               errors, user-facing texts, FastAPI detail parsing
//   APIClient+Bookmarks.swift    bookmark CRUD, trash, reader, notes
//   APIClient+Collections.swift  folder CRUD, move, reorder
//   APIClient+Tags.swift         tag CRUD, restore
//   APIClient+Search.swift       keyword + semantic search, reindex
//   APIClient+Jobs.swift         background jobs (link check, metadata, batch tag)
//   APIClient+Brain.swift        AI config, models, chat, summarize
//   APIClient+Data.swift         import/export, backup, resets, file URLs
// Response models shared across stores live in Models/APIResponses.swift.

// ISO8601DateFormatter is documented as thread-safe but not marked Sendable.
// These two are configured once here and afterwards only read from, so sharing
// them across the decoder's concurrent calls is safe.
nonisolated(unsafe) private let _iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

nonisolated(unsafe) private let _iso8601InternetDateTime: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let _iso8601Formatters: [DateFormatter] = {
    ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
     "yyyy-MM-dd'T'HH:mm:ss.SSS",
     "yyyy-MM-dd'T'HH:mm:ss"].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }
}()

struct EmptyBody: Encodable {}

/// Ollama provider settings in the shape the backend expects inside request
/// bodies (`provider_config`). One shared type instead of five ad-hoc copies.
struct ProviderPayload: Encodable {
    let provider: String
    let model: String
    let embedding_model: String
    let ollama_url: String
    let api_key: String
    let gentle_tagging: Bool

    init(_ config: AIBrainConfig) {
        provider = config.llmProvider.rawValue
        model = config.ollamaModel
        embedding_model = config.embeddingModel
        ollama_url = config.ollamaURL
        api_key = ""
        gentle_tagging = config.gentleTagging
    }
}

/// Sendable because every stored property is an immutable `let` of a Sendable
/// type, so stores on the main actor can hand it to their network calls.
final class APIClient: Sendable {
    static let shared = APIClient()

    /// Generous timeout for local-LLM calls — a cold Ollama model can take a
    /// minute or two to load before it answers, well past URLSession's 60s default.
    static let llmTimeout: TimeInterval = 300

    // Internal (not private) so the domain extensions in sibling files can use them.
    let base: URL
    let session: URLSession
    let metadataSession: URLSession

    private static let backgroundMetadataSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 35
        return URLSession(configuration: configuration)
    }()

    init(base: URL = Config.backendURL, session: URLSession = .shared) {
        self.base = base
        self.session = session
        // Slow website refreshes must not occupy the pagination/icon session.
        self.metadataSession = session === URLSession.shared ? Self.backgroundMetadataSession : session
    }

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = _iso8601WithFractionalSeconds.date(from: string) {
                return date
            }
            if let date = _iso8601InternetDateTime.date(from: string) {
                return date
            }
            for fmt in _iso8601Formatters {
                if let date = fmt.date(from: string) { return date }
            }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Cannot parse date: \(string)")
        }
        return d
    }()

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Request pipeline

    /// Every request carries this header; the backend refuses anything else.
    static let tokenHeader = "X-Gyrus-Token"

    private func urlSession(for transport: APIRequest.Transport) -> URLSession {
        switch transport {
        case .standard: return session
        case .metadata: return metadataSession
        case .custom(let custom): return custom
        }
    }

    /// The one place a request is put on the wire: adds the token and turns
    /// transport failures into `APIError.networkError` (or a cancellation).
    /// Status codes are left to the caller, because the health check reads a
    /// non-2xx answer as "not ready" rather than as an error.
    func exchange(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: Self.tokenHeader)
        do {
            return try await session.data(for: request)
        } catch {
            throw transportError(error)
        }
    }

    /// Build, send and status-check a request; returns the raw body.
    func send(_ request: APIRequest) async throws -> Data {
        let (data, response) = try await exchange(request.urlRequest(base: base),
                                                  on: urlSession(for: request.transport))
        try checkStatus(response, data: data)
        return data
    }

    /// `send` plus decoding with the shared date-tolerant decoder.
    func send<T: Decodable>(_ request: APIRequest, decoding type: T.Type = T.self) async throws -> T {
        let url = try request.resolvedURL(base: base)
        let data = try await send(request)
        return try decode(data, from: url)
    }

    /// JSON request bodies are encoded before anything is sent, so an encoding
    /// failure surfaces as itself and never as a network error.
    func jsonBody<Body: Encodable>(_ body: Body) throws -> APIRequest.Body {
        .json(try encoder.encode(body))
    }

    // MARK: - Health

    func health() async throws -> Bool {
        let request = try APIRequest(path: "/api/ready", timeout: 2.0) // Short timeout for health check
            .urlRequest(base: base)
        let (data, response) = try await exchange(request, on: session)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return payload["status"] as? String == "ok" && payload["service"] as? String == "gyrus"
    }

    // MARK: - HTTP verbs

    /// URLSession reports task cancellation as an NSURLError. Preserve the
    /// cancellation semantic so callers can silently discard superseded work
    /// instead of presenting it as a network failure.
    func transportError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        return APIError.networkError(error)
    }

    func get<T: Decodable>(_ url: URL, query: [URLQueryItem] = []) async throws -> T {
        try await send(APIRequest(.get, url: url, query: query))
    }

    func post<Body: Encodable, T: Decodable>(_ url: URL, body: Body, timeout: TimeInterval? = nil, using requestSession: URLSession? = nil) async throws -> T {
        let transport: APIRequest.Transport = requestSession.map {
            $0 === metadataSession ? .metadata : .custom($0)
        } ?? .standard
        return try await send(APIRequest(.post, url: url, body: jsonBody(body), timeout: timeout, transport: transport))
    }

    func postIgnoreResponse<Body: Encodable>(_ url: URL, body: Body) async throws {
        _ = try await send(APIRequest(.post, url: url, body: jsonBody(body)))
    }

    func put<Body: Encodable, T: Decodable>(_ url: URL, body: Body) async throws -> T {
        try await send(APIRequest(.put, url: url, body: jsonBody(body)))
    }

    func delete(_ url: URL) async throws {
        _ = try await send(APIRequest(.delete, url: url))
    }

    func checkStatus(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse else { return }
        let detail = APIError.serverDetail(from: data)
        if http.statusCode == 409 {
            if detail == nil || detail?.lowercased().contains("already exists") == true {
                throw APIError.duplicate
            }
        }
        if !(200...299).contains(http.statusCode) {
            if let detail { throw APIError.serverMessage(detail) }
            throw APIError.serverError(http.statusCode)
        }
    }

    func decode<T: Decodable>(_ data: Data, from url: URL? = nil) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let endpoint = url?.path ?? "response"
            let raw = String(data: data.prefix(600), encoding: .utf8) ?? "<\(data.count) bytes>"
            throw APIError.decodingError("Could not parse \(endpoint): \(error). Response: \(raw)")
        }
    }
}
