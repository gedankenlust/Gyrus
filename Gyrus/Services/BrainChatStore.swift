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
    private let api: APIClient
    init(api: APIClient = .shared) { self.api = api }
    private var requestIDs: [String: UUID] = [:]
    private var loadIDs: [String: UUID] = [:]
    private var clearTasks: [String: Task<Void, Never>] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var clearing: Set<String> = []

    private(set) var conversations: [String: [ChatMessage]] = [:]
    private(set) var sending: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var loading: Set<String> = []
    private var generation = 0

    func messages(for bookmarkId: String) -> [ChatMessage] { conversations[bookmarkId] ?? [] }
    func isSending(_ bookmarkId: String) -> Bool { sending.contains(bookmarkId) }
    func hasConversation(_ bookmarkId: String) -> Bool { !(conversations[bookmarkId] ?? []).isEmpty }

    func load(bookmarkId: String) async {
        guard !loading.contains(bookmarkId), !clearing.contains(bookmarkId) else { return }
        let requestGeneration = generation
        let loadID = UUID()
        loadIDs[bookmarkId] = loadID
        loading.insert(bookmarkId)
        defer {
            if loadIDs[bookmarkId] == loadID { loading.remove(bookmarkId); loadIDs[bookmarkId] = nil }
        }

        do {
            let persisted = try await api.brainMessages(bookmarkId: bookmarkId)
            guard requestGeneration == generation, loadIDs[bookmarkId] == loadID, !sending.contains(bookmarkId), !clearing.contains(bookmarkId) else { return }
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
            if requestGeneration == generation { errors[bookmarkId] = error.localizedDescription }
        }
    }

    func send(bookmark: Bookmark, prompt: String, config: AIBrainConfig) {
        let id = bookmark.id
        guard !sending.contains(id), !clearing.contains(id) else { return }
        let requestID = UUID()
        requestIDs[id] = requestID
        errors[id] = nil
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
                let stream = api.aiChatStream(
                    bookmarkId: id, prompt: prompt, history: history, config: config)
                for try await delta in stream {
                    guard self.requestIDs[id] == requestID else { return }
                    self.appendDelta(to: id, at: replyIndex, delta: delta)
                }
                guard self.requestIDs[id] == requestID else { return }
                // If the model returned nothing at all, show a gentle note.
                if self.conversations[id]?[safe: replyIndex]?.text.isEmpty == true {
                    self.setMessage(id, replyIndex, text: "(No response)", isError: true)
                }
            } catch is CancellationError {
                guard self.requestIDs[id] == requestID else { return }
                self.markStopped(id, replyIndex)
            } catch {
                guard self.requestIDs[id] == requestID else { return }
                self.setMessage(id, replyIndex,
                                text: error.localizedDescription, isError: true)
            }
            guard self.requestIDs[id] == requestID else { return }
            self.requestIDs[id] = nil
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
        guard !clearing.contains(bookmarkId) else { return }
        let oldTask = tasks[bookmarkId]
        oldTask?.cancel()
        requestIDs[bookmarkId] = nil
        loadIDs[bookmarkId] = nil
        loading.remove(bookmarkId)
        sending.remove(bookmarkId)
        clearing.insert(bookmarkId)
        errors[bookmarkId] = nil
        let requestGeneration = generation
        clearTasks[bookmarkId] = Task {
            await oldTask?.value
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            self.tasks[bookmarkId] = nil
            do {
                try await self.api.clearBrainMessages(bookmarkId: bookmarkId)
                guard !Task.isCancelled, requestGeneration == self.generation else { return }
                self.conversations[bookmarkId] = []
            } catch {
                guard requestGeneration == self.generation else { return }
                self.errors[bookmarkId] = String(localized: "Conversation could not be cleared. Please try again.") + " " + error.localizedDescription
            }
            self.clearing.remove(bookmarkId)
            self.clearTasks[bookmarkId] = nil
        }
    }

    func resetLocalState() {
        generation += 1
        for task in tasks.values { task.cancel() }
        for task in clearTasks.values { task.cancel() }
        clearTasks.removeAll()
        clearing.removeAll()
        errors.removeAll()
        requestIDs.removeAll()
        loadIDs.removeAll()
        tasks.removeAll()
        conversations.removeAll()
        sending.removeAll()
        loading.removeAll()
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
