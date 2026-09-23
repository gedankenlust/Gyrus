import SwiftUI

struct FolderOrganizeSection: View {
    private var uiState: UIStateStore { AppStore.shared.uiStateStore }

    private var status: FolderOrganizeStatus? { uiState.folderOrganizeStatus }
    private var running: Bool { status?.running == true }

    var body: some View {
        Section(header: Text("Folders")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The local model invents a new folder structure and moves bookmarks into it. It pauses between batches so the Mac stays cooler. A backup is written first. Old folders stay, even when they end up empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(running ? "Sorting…" : "Sort into new folders") {
                        Task { await start() }
                    }
                    .disabled(running || AIConfigSync.shared.isSyncing)
                    if running {
                        Button("Stop") { Task { await stop() } }
                    }
                    Spacer()
                    if let status, status.total > 0, running {
                        Text("\(status.processed) / \(status.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if status?.phase == "cooldown" {
                    Text("Resting \(status?.cooldownRemaining ?? 0)s so the Mac can cool down.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = status?.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(status?.phase == "error" ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func start() async {
        await AppStore.shared.startFolderOrganize()
    }

    private func stop() async {
        await AppStore.shared.cancelFolderOrganize()
    }
}

struct FolderOrganizeStatus: Decodable, JobStatusReporting {
    let running: Bool
    let phase: String
    let processed: Int
    let total: Int
    let message: String?
    let cooldownRemaining: Int
    let draft: FolderOrganizeDraft?

    enum CodingKeys: String, CodingKey {
        case running, phase, processed, total, message, draft
        case cooldownRemaining = "cooldown_remaining"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        processed = try container.decodeIfPresent(Int.self, forKey: .processed) ?? 0
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        message = try container.decodeIfPresent(String.self, forKey: .message)
        cooldownRemaining = try container.decodeIfPresent(Int.self, forKey: .cooldownRemaining) ?? 0
        draft = try container.decodeIfPresent(FolderOrganizeDraft.self, forKey: .draft)
    }
}

struct FolderOrganizeDraft: Decodable, Identifiable, Sendable {
    let id: String
    let folders: [FolderOrganizeFolder]
    let moving: Int
    let unchanged: Int
    let skipped: Int
}

struct FolderOrganizeFolder: Decodable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let name: String
    let path: String
    let parentKey: String?
    let count: Int
    let samples: [String]

    enum CodingKeys: String, CodingKey {
        case key, name, path, count, samples
        case parentKey = "parent_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? name
        parentKey = try container.decodeIfPresent(String.self, forKey: .parentKey)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        samples = try container.decodeIfPresent([String].self, forKey: .samples) ?? []
    }
}
