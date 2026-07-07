import SwiftUI
import Observation
import AppKit

struct AISettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var textModels: [String] = []
    @State private var embeddingModels: [String] = []
    @State private var isLoadingModels = false
    @State private var errorMessage: String? = nil
    @State private var lastLoadSuccessful: Bool? = nil
    @State private var isReindexing = false
    @State private var reindexMessage: String? = nil
    @State private var semanticIndexed: Int = 0
    
    var body: some View {
        Form {
            Section(header: Text("Artificial Intelligence")) {
                Toggle("Enable AI", isOn: $settings.aiBrainConfig.aiEnabled)
                Text("Local AI via Ollama — auto-tagging, semantic search, summaries and chat. Off by default; Gyrus is a full bookmark manager without it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.aiBrainConfig.aiEnabled {
            Section(header: Text("Local Model (Ollama)")) {
                TextField("Ollama URL", text: $settings.aiBrainConfig.ollamaURL)

                // Text model — drives chat, summaries and auto-tags.
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.5), radius: 2)
                        .help(statusTooltip)

                    Picker("Text Model", selection: $settings.aiBrainConfig.ollamaModel) {
                        if textModels.isEmpty {
                            Text("No models found").tag("")
                        } else {
                            ForEach(textModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    Button {
                        refreshModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Refresh the model list from Ollama")
                }
                Text("Used for AI chat, summaries and auto-tagging.")
                    .font(.caption).foregroundStyle(.secondary)

                // Embedding model — drives semantic (meaning-based) search.
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.5), radius: 2)
                        .help(statusTooltip)

                    Picker("Embedding Model", selection: $settings.aiBrainConfig.embeddingModel) {
                        if embeddingModels.isEmpty {
                            Text("No embedding models found").tag("")
                        } else {
                            ForEach(embeddingModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                }
                Text("Used for semantic (meaning-based) search. Only dedicated embedding models are listed (e.g. nomic-embed-text, bge-m3). Changing it needs a reindex below.")
                    .font(.caption).foregroundStyle(.secondary)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Semantic Search")) {
                // Semantic search silently returns nothing while the index is
                // empty — make that state loud instead of a quiet "0 indexed".
                if semanticIndexed == 0 {
                    Label("Semantic search is empty — your bookmarks aren't indexed yet. Click Reindex to build the index.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Embedding index")
                        Text(semanticIndexed == 1 ? "1 bookmark indexed"
                                                  : "\(semanticIndexed) bookmarks indexed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isReindexing = true
                        reindexMessage = nil
                        Task {
                            do {
                                _ = try await APIClient.shared.reindexEmbeddings()
                                reindexMessage = "Reindexing started in the background."
                                isReindexing = false
                                // Refresh the indexed count while the background
                                // job fills the index, so progress is visible.
                                for _ in 0..<20 {
                                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                                    if let status = try? await APIClient.shared.semanticSearchStatus() {
                                        semanticIndexed = status.indexed
                                    }
                                }
                            } catch {
                                reindexMessage = "Failed: \(error.localizedDescription)"
                                isReindexing = false
                            }
                        }
                    } label: {
                        if isReindexing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Reindex")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isReindexing)
                    .help("Build the semantic search index from existing bookmark content. Requires nomic-embed-text in Ollama.")
                }
                if let msg = reindexMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(header: Text("AI Brain (Markdown mirror)")) {
                Toggle("Mirror bookmarks to Markdown files", isOn: $settings.aiBrainConfig.brainMirrorEnabled)
                Text("Saves one Markdown file per bookmark — folders, tags, notes and AI chats — in a folder you choose. Open it in Obsidian, Logseq or any editor: your library in an open format you own. An auto-generated _Index.md maps everything.")
                    .font(.caption).foregroundStyle(.secondary)

                if settings.aiBrainConfig.brainMirrorEnabled {
                    HStack {
                        Text("Storage")
                        Spacer()
                        Text(settings.aiBrainConfig.rootDirectoryPath ?? "Not selected")
                            .foregroundColor(.secondary).font(.caption)
                            .lineLimit(1).truncationMode(.middle)
                            .help(settings.aiBrainConfig.rootDirectoryPath ?? "No path selected")
                        Button("Choose…") { selectDirectory() }
                    }
                    HStack {
                        Button { revealBrainInFinder() } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        Button { openBrainIndex() } label: {
                            Label("Open Index", systemImage: "doc.text")
                        }
                    }
                    .controlSize(.small)
                }
            }
            } // end: if AI enabled
        }
        .formStyle(.grouped)
        .onAppear {
            refreshModels()
            Task {
                if let status = try? await APIClient.shared.semanticSearchStatus() {
                    semanticIndexed = status.indexed
                }
            }
        }
    }
    
    private var statusColor: Color {
        if isLoadingModels { return .gray }
        if let success = lastLoadSuccessful {
            return success ? .green : .red
        }
        return .gray.opacity(0.5)
    }

    private var statusTooltip: String {
        if isLoadingModels { return "Connecting..." }
        if let success = lastLoadSuccessful {
            return success ? "Connected to Ollama" : (errorMessage ?? "Connection failed")
        }
        return "Not connected"
    }

    private func refreshModels() {
        guard !settings.aiBrainConfig.ollamaURL.isEmpty else { return }
        
        isLoadingModels = true
        errorMessage = nil
        Task {
            do {
                let (text, embedding) = try await APIClient.shared
                    .fetchModelsByCapability(ollamaURL: settings.aiBrainConfig.ollamaURL)
                await MainActor.run {
                    self.textModels = text
                    self.embeddingModels = embedding
                    // Keep each pick if still installed; otherwise fall back to
                    // the first model of the matching kind — the lists are already
                    // capability-filtered, so the embedding pick can't become a
                    // chat model by accident.
                    if !text.contains(settings.aiBrainConfig.ollamaModel), let first = text.first {
                        settings.aiBrainConfig.ollamaModel = first
                    }
                    if !embedding.contains(settings.aiBrainConfig.embeddingModel), let first = embedding.first {
                        settings.aiBrainConfig.embeddingModel = first
                    }
                    self.isLoadingModels = false
                    self.lastLoadSuccessful = true
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Could not connect to Ollama"
                    self.isLoadingModels = false
                    self.lastLoadSuccessful = false
                }
            }
        }
    }
    
    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            settings.aiBrainConfig.rootDirectoryPath = AppSettings.brainRoot(forChosenDirectory: url)
        }
    }

    private func revealBrainInFinder() {
        guard let path = settings.aiBrainConfig.rootDirectoryPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openBrainIndex() {
        guard let path = settings.aiBrainConfig.rootDirectoryPath else { return }
        let index = URL(fileURLWithPath: path).appendingPathComponent("_Index.md")
        if FileManager.default.fileExists(atPath: index.path) {
            NSWorkspace.shared.open(index)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
