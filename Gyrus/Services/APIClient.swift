import Foundation

// The backend API surface is split by domain to keep each file reviewable:
//   APIClient.swift              core: session plumbing, HTTP verbs, errors
//   APIClient+Bookmarks.swift    bookmark CRUD, trash, reader, notes
//   APIClient+Collections.swift  folder CRUD, move, reorder
//   APIClient+Tags.swift         tag CRUD, restore
//   APIClient+Search.swift       keyword + semantic search, reindex
//   APIClient+Jobs.swift         background jobs (link check, metadata, batch tag)
//   APIClient+Brain.swift        AI config, models, chat, summarize
//   APIClient+Data.swift         import/export, backup, resets, file URLs
// Response models shared across stores live in Models/APIResponses.swift.

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

enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int)
    case decodingError(Error)
    case networkError(Error)
    case duplicate
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .serverError(let code): return "Server error \(code)"
        case .duplicate: return "Bookmark already exists"
        case .decodingError(let e): return "Decode error: \(e)"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .serverMessage(let m): return m
        }
    }
}

struct EmptyBody: Encodable {}

final class APIClient {
    static let shared = APIClient()

    /// Generous timeout for local-LLM calls — a cold Ollama model can take a
    /// minute or two to load before it answers, well past URLSession's 60s default.
    static let llmTimeout: TimeInterval = 300

    // Internal (not private) so the domain extensions in sibling files can use them.
    let base = Config.backendURL

    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
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

    // MARK: - Health

    func health() async throws -> Bool {
        var request = URLRequest(url: base.appending(path: "/health"))
        request.timeoutInterval = 2.0 // Short timeout for health check
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - HTTP verbs

    func get<T: Decodable>(_ url: URL) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    func post<Body: Encodable, T: Decodable>(_ url: URL, body: Body, timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let timeout { request.timeoutInterval = timeout }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    func postIgnoreResponse<Body: Encodable>(_ url: URL, body: Body) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    func put<Body: Encodable, T: Decodable>(_ url: URL, body: Body) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
            return try decode(data)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    func delete(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try checkStatus(response)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.networkError(error)
        }
    }

    func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 409 { throw APIError.duplicate }
        if !(200...299).contains(http.statusCode) {
            throw APIError.serverError(http.statusCode)
        }
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
