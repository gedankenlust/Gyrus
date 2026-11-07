import Foundation

struct BackupPreview: Decodable {
    let version: Int
    let exportedAt: Date?
    let collections: Int
    let tags: Int
    let bookmarks: Int
    let notes: Int
    let messages: Int
    enum CodingKeys: String, CodingKey {
        case version, collections, tags, bookmarks, notes, messages
        case exportedAt = "exported_at"
    }
}

// MARK: - Data management: import/export, backup, resets, file URLs

extension APIClient {
    /// Whole-library transfers. A large restore or import keeps working on the
    /// server long after the default 60 s, which used to report a failure for
    /// a job that then finished anyway.
    static let libraryTransferTimeout: TimeInterval = 15 * 60

    /// Raw-body requests through the same token, status and error mapping as
    /// the JSON helpers, so a 422 or a lost connection reads like any other
    /// failure instead of a bare "Server error" or a decoding dump.
    func sendRaw(_ request: URLRequest, timeout: TimeInterval = APIClient.libraryTransferTimeout) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await exchange(request, on: session)
        try checkStatus(response, data: data)
        return data
    }

    /// A whole-library upload or download with the long transfer timeout.
    private func transfer(_ method: APIRequest.Method, _ path: String,
                          query: [URLQueryItem] = [], body: APIRequest.Body = .none) -> APIRequest {
        APIRequest(method, path: path, query: query, body: body, timeout: APIClient.libraryTransferTimeout)
    }

    struct AutomaticBackupStatus: Decodable {
        let lastBackupAt: Date?
        let error: String?
        enum CodingKeys: String, CodingKey { case lastBackupAt = "last_backup_at", error }
    }

    func automaticBackupStatus() async throws -> AutomaticBackupStatus {
        try await get(base.appending(path: "/api/data/backup-status"))
    }

    // MARK: Export / import

    func exportHTML(collectionId: String? = nil) async throws -> Data {
        let query = collectionId.map { [URLQueryItem(name: "collection_id", value: $0)] } ?? []
        return try await send(transfer(.get, "/api/export/html", query: query))
    }

    func exportBookmarks(collectionId: String?, limit: Int = 200, offset: Int = 0) async throws -> [Bookmark] {
        var query = [URLQueryItem(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]
        if let collectionId { query.append(.init(name: "collection_id", value: collectionId)) }
        return try await get(base.appending(path: "/api/export/bookmarks"), query: query)
    }

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/html\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        if let name = rootFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"root_folder_name\"\r\n\r\n".data(using: .utf8)!)
            body.append(name.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return try await send(transfer(.post, "/api/import/html",
                                       body: .raw(body, contentType: "multipart/form-data; boundary=\(boundary)")))
    }

    // MARK: File URLs

    func faviconURL(filename: String) -> URL {
        base.appending(path: "/api/files/favicons/\(filename)")
    }

    func ogImageURL(filename: String) -> URL {
        base.appending(path: "/api/files/og-images/\(filename)")
    }

    // MARK: Resets & backup

    func clearCache() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-cache"), body: EmptyBody())
    }

    func clearBrain() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-brain"), body: EmptyBody())
    }

    func clearBookmarks() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/clear-bookmarks"), body: EmptyBody())
    }

    func factoryReset() async throws {
        let _: [String: String] = try await post(base.appending(path: "/api/data/factory-reset"), body: EmptyBody())
    }

    func downloadBackup() async throws -> Data {
        try await send(transfer(.get, "/api/data/backup"))
    }

    /// Counts in a JSON backup file, read without restoring anything.
    func previewBackup(_ json: Data) async throws -> BackupPreview {
        try await send(transfer(.post, "/api/data/restore/preview", body: .json(json)))
    }

    /// Replace all current data with the contents of a JSON backup file.
    func restoreBackup(_ json: Data) async throws {
        _ = try await send(transfer(.post, "/api/data/restore", body: .json(json)))
    }
}
