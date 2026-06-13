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

    public var isEnabled: Bool = false
    public var rootDirectoryPath: String?
    public var llmProvider: LLMProvider = .ollama
    public var ollamaURL: String = "http://localhost:11434"
    public var ollamaModel: String = "llama3"
}
