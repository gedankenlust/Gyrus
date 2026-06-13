import SwiftUI
import Observation

struct AISettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var errorMessage: String? = nil
    @State private var lastLoadSuccessful: Bool? = nil
    @State private var isReindexing = false
    @State private var reindexMessage: String? = nil
    @State private var semanticIndexed: Int = 0
    
    var body: some View {
        Form {
            Section(header: Text("General")) {
                Toggle("Enable AI Brain", isOn: $settings.aiBrainConfig.isEnabled)
                
                HStack {
                    Text("Brain Storage")
                    Spacer()
                    Text(settings.aiBrainConfig.rootDirectoryPath ?? "Not selected")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.aiBrainConfig.rootDirectoryPath ?? "No path selected")
                    Button("Select...") {
                        selectDirectory()
                    }
                }
            }
            
            Section(header: Text("Local Model (Ollama)")) {
                TextField("Ollama URL", text: $settings.aiBrainConfig.ollamaURL)

                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.5), radius: 2)
                        .help(statusTooltip)

                    Picker("Model Name", selection: $settings.aiBrainConfig.ollamaModel) {
                        if availableModels.isEmpty {
                            Text("No models found").tag("")
                        } else {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }

                    Button {
                        refreshModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(isLoadingModels ? 360 : 0))
                            .animation(isLoadingModels ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoadingModels)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section(header: Text("Semantic Search")) {
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
                            } catch {
                                reindexMessage = "Failed: \(error.localizedDescription)"
                            }
                            isReindexing = false
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
                let models = try await APIClient.shared.fetchOllamaModels(url: settings.aiBrainConfig.ollamaURL)
                await MainActor.run {
                    self.availableModels = models
                    if !models.contains(settings.aiBrainConfig.ollamaModel), let first = models.first {
                        settings.aiBrainConfig.ollamaModel = first
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
}
