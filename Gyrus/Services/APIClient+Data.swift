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
        var components = URLComponents(url: base.appending(path: "/api/export/html"), resolvingAgainstBaseURL: false)!
        if let collectionId { components.queryItems = [.init(name: "collection_id", value: collectionId)] }
        let url = components.url!
        var request = URLRequest(url: url)
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    func exportBookmarks(collectionId: String?, limit: Int = 200, offset: Int = 0) async throws -> [Bookmark] {
        var components = URLComponents(url: base.appending(path: "/api/export/bookmarks"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit)), .init(name: "offset", value: String(offset))]
        if let collectionId { items.append(.init(name: "collection_id", value: collectionId)) }
        components.queryItems = items
        return try await get(components.url!)
    }

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        var request = URLRequest(url: base.appending(path: "/api/import/html"))
        request.httpMethod = "POST"
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
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
        request.httpBody = body
        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try decoder.decode(ImportResult.self, from: respData)
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
        let url = base.appending(path: "/api/data/backup")
        var request = URLRequest(url: url)
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return data
    }

    /// Replace all current data with the contents of a JSON backup file.
    func previewBackup(_ json: Data) async throws -> BackupPreview {
        var request = URLRequest(url: base.appending(path: "/api/data/restore/preview"))
        request.httpMethod = "POST"
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
        return try decoder.decode(BackupPreview.self, from: data)
    }

    func restoreBackup(_ json: Data) async throws {
        var request = URLRequest(url: base.appending(path: "/api/data/restore"))
        request.httpMethod = "POST"
        request.setValue(BackendLauncher.apiToken, forHTTPHeaderField: "X-Gyrus-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data: data)
    }
}
