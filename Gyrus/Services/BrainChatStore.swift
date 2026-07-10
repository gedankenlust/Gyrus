import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var text: String          // var: updated in place while streaming
    let isUser: Bool
    var isError: Bool = false
    let timestamp: Date

    init(id: String = UUID().uuidString,
         text: String,
         isUser: Bool,
         isError: Bool = false,
         timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.isError = isError
        self.timestamp = timestamp
    }
}

/// Holds one conversation per bookmark, shared across the app. Because the
/// history lives here (not in the chat view's @State), switching bookmarks no
/// longer ends the session — a request keeps running in the background, the
/// conversation is restored when you return, and several bookmarks can be
/// queried in parallel. Replies stream in token-by-token and can be stopped.
@MainActor
@Observable
final class BrainChatStore {
    static let shared = BrainChatStore()
    private init() {}

    private(set) var conversations: [String: [ChatMessage]] = [:]
    private(set) var sending: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loading: Set<String> = []

    func messages(for bookmarkId: String) -> [ChatMessage] { conversations[bookmarkId] ?? [] }
    func isSending(_ bookmarkId: String) -> Bool { sending.contains(bookmarkId) }
    func hasConversation(_ bookmarkId: String) -> Bool { !(conversations[bookmarkId] ?? []).isEmpty }

    func load(bookmarkId: String) async {
        guard !loading.contains(bookmarkId) else { return }
        loading.insert(bookmarkId)
        defer { loading.remove(bookmarkId) }

        do {
            let persisted = try await APIClient.shared.brainMessages(bookmarkId: bookmarkId)
            guard !sending.contains(bookmarkId) else { return }
            conversations[bookmarkId] = persisted.map {
                let text = $0.status == "stopped" ? $0.content + " …(stopped)" : $0.content
                return ChatMessage(
                    id: $0.id,
                    text: text,
                    isUser: $0.role == "user",
                    isError: $0.status == "error",
                    timestamp: $0.createdAt
                )
            }
        } catch {
            // Non-fatal: the tab can still start a fresh local conversation.
        }
    }

    func send(bookmark: Bookmark, prompt: String, config: AIBrainConfig) {
        let id = bookmark.id
        // Prior turns (before appending the new prompt) so follow-ups keep context.
        let history = (conversations[id] ?? [])
            .filter { !$0.isError }
            .suffix(10)
            .map { (role: $0.isUser ? "user" : "assistant", content: $0.text) }

        conversations[id, default: []].append(ChatMessage(text: prompt, isUser: true))
        // Placeholder assistant message that fills in as tokens stream.
        conversations[id, default: []].append(ChatMessage(text: "", isUser: false))
        let replyIndex = (conversations[id]?.count ?? 1) - 1
        sending.insert(id)

        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = APIClient.shared.aiChatStream(
                    bookmarkId: id, prompt: prompt, history: history, config: config)
                for try await delta in stream {
                    self.appendDelta(to: id, at: replyIndex, delta: delta)
                }
                // If the model returned nothing at all, show a gentle note.
                if self.conversations[id]?[safe: replyIndex]?.text.isEmpty == true {
                    self.setMessage(id, replyIndex, text: "(No response)", isError: true)
                }
            } catch is CancellationError {
                self.markStopped(id, replyIndex)
            } catch {
                self.setMessage(id, replyIndex,
                                text: error.localizedDescription, isError: true)
            }
            self.sending.remove(id)
            self.tasks[id] = nil
        }
    }

    /// Stop the in-flight reply for a bookmark (keeps whatever streamed so far).
    func stop(_ bookmarkId: String) {
        tasks[bookmarkId]?.cancel()
    }

    /// Clear the whole conversation for a bookmark (cancels any in-flight reply).
    func clear(_ bookmarkId: String) {
        tasks[bookmarkId]?.cancel()
        tasks[bookmarkId] = nil
        sending.remove(bookmarkId)
        conversations[bookmarkId] = []
        Task {
            try? await APIClient.shared.clearBrainMessages(bookmarkId: bookmarkId)
        }
    }

    // MARK: - Mutation helpers (main-actor isolated)

    private func appendDelta(to id: String, at index: Int, delta: String) {
        guard var msgs = conversations[id], msgs.indices.contains(index) else { return }
        msgs[index].text += delta
        conversations[id] = msgs
    }

    private func setMessage(_ id: String, _ index: Int, text: String, isError: Bool) {
        guard var msgs = conversations[id], msgs.indices.contains(index) else { return }
        msgs[index].text = text
        msgs[index].isError = isError
        conversations[id] = msgs
    }

    private func markStopped(_ id: String, _ index: Int) {
        guard var msgs = conversations[id], msgs.indices.contains(index) else { return }
        if msgs[index].text.isEmpty {
            msgs[index].text = "(Stopped)"
            msgs[index].isError = true
        } else {
            msgs[index].text += " …(stopped)"
        }
        conversations[id] = msgs
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
