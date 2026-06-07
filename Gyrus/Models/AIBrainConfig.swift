import Foundation

public struct AIBrainConfig: Codable, Equatable {
    public enum LLMProvider: String, Codable, CaseIterable {
        case ollama = "ollama"
        case cloud = "cloud"
        
        public var displayName: String {
            switch self {
            case .ollama: return "Ollama"
            case .cloud: return "Cloud"
            }
        }
    }
    
    public var isEnabled: Bool = false
    public var rootDirectoryPath: String?
    public var llmProvider: LLMProvider = .ollama
    public var ollamaURL: String = "http://localhost:11434"
    public var ollamaModel: String = "llama3"
}
