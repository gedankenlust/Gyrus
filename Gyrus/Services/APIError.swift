import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int)
    /// The payload is the technical cause (endpoint, decoder error, response
    /// excerpt). It stays available as `failureReason` for debugging but is
    /// never what the user reads.
    case decodingError(String)
    case networkError(Error)
    case duplicate
    /// A message the backend wrote for people. Shown as is: callers match on
    /// the exact backend text (for example "Visual snapshot not found") and
    /// the Reader maps known English messages to catalog strings.
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Gyrus could not build the request to its backend.")
        case .serverError(let code):
            return Self.statusDescription(code)
        case .duplicate:
            return String(localized: "This bookmark already exists.")
        case .decodingError:
            return String(localized: "The backend sent a response Gyrus could not read. Please try again.")
        case .networkError(let error):
            return Self.transportDescription(error)
        case .serverMessage(let message):
            return message
        }
    }

    var failureReason: String? {
        switch self {
        case .decodingError(let detail): return detail
        case .networkError(let error): return (error as NSError).localizedDescription
        default: return nil
        }
    }

    /// A status code is all the user gets when the backend sent no `detail`,
    /// so say what kind of failure it was instead of "Server error 500".
    private static func statusDescription(_ code: Int) -> String {
        switch code {
        case 401, 403:
            // The token is per launch; a mismatch means another backend
            // answered or this one was started by a different copy of the app.
            return String(localized: "The backend did not accept this copy of Gyrus. Quit Gyrus and open it again.")
        case 404:
            return String(localized: "The requested item no longer exists.")
        case 413:
            return String(localized: "The data is too large for the backend to accept.")
        case 500...599:
            return String(localized: "The backend ran into a problem (error \(code)). Please try again.")
        default:
            return String(localized: "The backend could not complete the request (error \(code)).")
        }
    }

    /// The backend is always on this Mac, so a transport failure almost always
    /// means it is not running or still busy; the raw NSURLError text ("Could
    /// not connect to the server.") does not tell the user which.
    private static func transportDescription(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return String(localized: "The connection to the Gyrus backend failed. Please try again.")
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return String(localized: "The Gyrus backend could not be reached. Check the app status and try again.")
        case .timedOut:
            return String(localized: "The backend took too long to respond. Please try again.")
        default:
            return String(localized: "The connection to the Gyrus backend failed. Please try again.")
        }
    }

    /// The `detail` of a FastAPI error body in readable form: the string as
    /// sent, or for validation errors (a list of `{loc, msg}` objects) one
    /// "field: message" line per problem. Anything else yields nil so the
    /// caller falls back to the status code instead of showing a dictionary dump.
    static func serverDetail(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] else { return nil }
        if let text = detail as? String { return text }
        if let entry = detail as? [String: Any] { return validationLine(entry) }
        if let entries = detail as? [Any] {
            let lines = entries.compactMap { ($0 as? [String: Any]).flatMap(validationLine) }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        return nil
    }

    private static func validationLine(_ entry: [String: Any]) -> String? {
        guard let message = (entry["msg"] ?? entry["message"]) as? String,
              !message.isEmpty else { return nil }
        // FastAPI prefixes the location with where the value came from
        // ("body", "query", ...); the field name alone is what the user knows.
        var location = (entry["loc"] as? [Any] ?? []).map { "\($0)" }
        if let first = location.first, ["body", "query", "path", "header", "cookie"].contains(first) {
            location.removeFirst()
        }
        return location.isEmpty ? message : "\(location.joined(separator: ".")): \(message)"
    }
}
