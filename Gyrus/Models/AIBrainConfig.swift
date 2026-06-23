import Foundation

public struct AIBrainConfig: Codable, Equatable {
    /// Gyrus is local-only. The provider type is kept (rather than dropped) so
    /// the backend request shape stays stable, but the only value is Ollama.
    public enum LLMProvider: String, Codable {
        case ollama = "ollama"

        public init(from decoder: Decoder) throws {
            // Map any legacy/stored value (e.g. the removed "cloud") to ollama
            // so old configs keep decoding instead of resetting to defaults.
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = LLMProvider(rawValue: raw) ?? .ollama
        }
    }

    /// Master switch. Gates **all** AI features — auto-tags, semantic search,
    /// summaries and the AI Brain chat. Off by default, so Gyrus is a complete
    /// bookmark manager with zero AI surface until you opt in.
    public var aiEnabled: Bool = false
    /// Sub-option (only meaningful when `aiEnabled`): mirror every bookmark to a
    /// Markdown file on disk for use in Obsidian, Logseq, etc.
    public var brainMirrorEnabled: Bool = false
    public var rootDirectoryPath: String?
    public var llmProvider: LLMProvider = .ollama
    public var ollamaURL: String = "http://localhost:11434"
    public var ollamaModel: String = "llama3"
    public var embeddingModel: String = "nomic-embed-text"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case aiEnabled, brainMirrorEnabled, rootDirectoryPath
        case llmProvider, ollamaURL, ollamaModel, embeddingModel
    }
    private enum LegacyKeys: String, CodingKey { case isEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aiEnabled = (try? c.decode(Bool.self, forKey: .aiEnabled)) ?? false
        // Older configs stored the Markdown-mirror flag as `isEnabled`; migrate it.
        if let mirror = try? c.decode(Bool.self, forKey: .brainMirrorEnabled) {
            brainMirrorEnabled = mirror
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let mirror = try? legacy.decode(Bool.self, forKey: .isEnabled) {
            brainMirrorEnabled = mirror
        } else {
            brainMirrorEnabled = false
        }
        rootDirectoryPath = try? c.decode(String.self, forKey: .rootDirectoryPath)
        llmProvider = (try? c.decode(LLMProvider.self, forKey: .llmProvider)) ?? .ollama
        ollamaURL = (try? c.decode(String.self, forKey: .ollamaURL)) ?? "http://localhost:11434"
        ollamaModel = (try? c.decode(String.self, forKey: .ollamaModel)) ?? "llama3"
        embeddingModel = (try? c.decode(String.self, forKey: .embeddingModel)) ?? "nomic-embed-text"
    }
}
