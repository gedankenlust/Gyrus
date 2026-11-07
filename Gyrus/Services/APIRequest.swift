import Foundation

/// One backend call, described without touching URLSession. Every helper on
/// `APIClient` builds one of these and hands it to `send`, so the token, the
/// timeout and the error mapping are decided in a single place instead of in
/// each verb.
struct APIRequest {
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    enum Body {
        case none
        /// Already-encoded JSON; sent with `Content-Type: application/json`.
        case json(Data)
        /// Uploads such as multipart imports or backup files. A nil content
        /// type sends no header, which is what a bodyless POST did before.
        case raw(Data, contentType: String?)
    }

    /// Which URLSession carries the request. Metadata refreshes wait on slow
    /// websites and must not occupy the connections pagination and favicons use.
    enum Transport {
        case standard
        case metadata
        case custom(URLSession)
    }

    enum Endpoint {
        /// Resolved against the client's base URL.
        case path(String)
        /// An absolute URL, for the helpers that have always taken one.
        case url(URL)
    }

    var method: Method
    var endpoint: Endpoint
    /// Appended to any query the endpoint already has. Empty means no `?`.
    var query: [URLQueryItem]
    var body: Body
    /// Nil keeps URLRequest's default; set for LLM calls and library transfers.
    var timeout: TimeInterval?
    var transport: Transport

    init(_ method: Method = .get, path: String, query: [URLQueryItem] = [],
         body: Body = .none, timeout: TimeInterval? = nil, transport: Transport = .standard) {
        self.init(method, endpoint: .path(path), query: query, body: body, timeout: timeout, transport: transport)
    }

    init(_ method: Method = .get, url: URL, query: [URLQueryItem] = [],
         body: Body = .none, timeout: TimeInterval? = nil, transport: Transport = .standard) {
        self.init(method, endpoint: .url(url), query: query, body: body, timeout: timeout, transport: transport)
    }

    private init(_ method: Method, endpoint: Endpoint, query: [URLQueryItem],
                 body: Body, timeout: TimeInterval?, transport: Transport) {
        self.method = method
        self.endpoint = endpoint
        self.query = query
        self.body = body
        self.timeout = timeout
        self.transport = transport
    }

    /// The final URL: endpoint plus query items. Fails only for an endpoint
    /// URLComponents cannot represent, which used to be a force unwrap.
    func resolvedURL(base: URL) throws -> URL {
        let url: URL
        switch endpoint {
        case .path(let path): url = base.appending(path: path)
        case .url(let absolute): url = absolute
        }
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = (components.queryItems ?? []) + query
        // URLComponents leaves "+" as is, and form decoding on the server
        // reads it as a space, so a search for "c++" arrived as "c  ".
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let resolved = components.url else { throw APIError.invalidURL }
        return resolved
    }

    /// Everything except the token, which `APIClient.exchange` adds so that no
    /// request can reach the backend without it and no other code sets it.
    func urlRequest(base: URL) throws -> URLRequest {
        var request = URLRequest(url: try resolvedURL(base: base))
        request.httpMethod = method.rawValue
        switch body {
        case .none:
            break
        case .json(let data):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case .raw(let data, let contentType):
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.httpBody = data
        }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }
}
