import Foundation

// MARK: - Data management: import/export, backup, resets, file URLs

extension APIClient {
    // MARK: Export / import

    func exportHTML() async throws -> Data {
        let url = base.appending(path: "/api/export/html")
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response)
        return data
    }

    func importHTML(data: Data, filename: String, rootFolderName: String? = nil) async throws -> ImportResult {
        var request = URLRequest(url: base.appending(path: "/api/import/html"))
        request.httpMethod = "POST"
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
        let (respData, response) = try await URLSession.shared.data(for: request)
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
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkStatus(response)
        return data
    }

    /// Replace all current data with the contents of a JSON backup file.
    func restoreBackup(_ json: Data) async throws {
        var request = URLRequest(url: base.appending(path: "/api/data/restore"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        let (_, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
    }
}
