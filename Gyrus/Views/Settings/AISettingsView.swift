import SwiftUI
import Observation

struct AISettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var cloudAPIKey: String = ""
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var errorMessage: String? = nil
    @State private var lastLoadSuccessful: Bool? = nil
    
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
            
            Section(header: Text("LLM Provider")) {
                Picker("Provider", selection: $settings.aiBrainConfig.llmProvider) {
                    ForEach(AIBrainConfig.LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                if settings.aiBrainConfig.llmProvider == AIBrainConfig.LLMProvider.ollama {
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
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("API Key", text: $cloudAPIKey)
                        Text("Cloud integration (OpenAI/Anthropic) coming soon.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let keyData = KeychainHelper.shared.read(), let key = String(data: keyData, encoding: .utf8) {
                cloudAPIKey = key
            }
            if settings.aiBrainConfig.llmProvider == AIBrainConfig.LLMProvider.ollama {
                refreshModels()
            }
        }
        .onChange(of: cloudAPIKey) { _, newValue in
            if let data = newValue.data(using: .utf8) {
                KeychainHelper.shared.save(data)
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
        guard settings.aiBrainConfig.llmProvider == AIBrainConfig.LLMProvider.ollama, !settings.aiBrainConfig.ollamaURL.isEmpty else { return }
        
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
