import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp = Date()
}

/// Holds one conversation per bookmark, shared across the app. Because the
/// history lives here (not in the chat view's @State), switching bookmarks no
/// longer ends the session — a request keeps running in the background, the
/// conversation is restored when you return, and several bookmarks can be
/// queried in parallel.
@MainActor
@Observable
final class BrainChatStore {
    static let shared = BrainChatStore()
    private init() {}

    private(set) var conversations: [String: [ChatMessage]] = [:]
    private(set) var sending: Set<String> = []

    func messages(for bookmarkId: String) -> [ChatMessage] { conversations[bookmarkId] ?? [] }
    func isSending(_ bookmarkId: String) -> Bool { sending.contains(bookmarkId) }

    func send(bookmark: Bookmark, prompt: String, config: AIBrainConfig) {
        let id = bookmark.id
        // Capture the prior turns before appending the new prompt, then send
        // the last few so follow-up questions keep their context.
        let history = (conversations[id] ?? []).suffix(10).map {
            (role: $0.isUser ? "user" : "assistant", content: $0.text)
        }
        conversations[id, default: []].append(ChatMessage(text: prompt, isUser: true))
        sending.insert(id)
        Task {
            do {
                let response = try await APIClient.shared.aiChat(
                    bookmarkId: id, prompt: prompt, history: history, config: config)
                conversations[id, default: []].append(ChatMessage(text: response, isUser: false))
            } catch {
                conversations[id, default: []].append(ChatMessage(text: "Error: \(error.localizedDescription)", isUser: false))
            }
            sending.remove(id)
        }
    }
}
