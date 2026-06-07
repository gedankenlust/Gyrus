import SwiftUI

struct AIBrainTabView: View {
    let bookmark: Bookmark

    private let chat = BrainChatStore.shared
    @State private var currentPrompt: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil

    // Conversation state lives in the shared store, keyed by bookmark — so it
    // survives switching bookmarks and runs in the background.
    private var messages: [ChatMessage] { chat.messages(for: bookmark.id) }
    private var isSending: Bool { chat.isSending(bookmark.id) }

    private var config: AIBrainConfig {
        AppSettings.shared.aiBrainConfig
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            if messages.isEmpty && !isSending {
                quickStarts
            } else {
                messageList
            }
            
            inputArea
        }
    }
    
    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Brain")
                    .font(.headline)
                Spacer()
                if isSending {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
        }
    }
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(messages) { msg in
                        ChatBubble(message: msg) {
                            Task { try? await AppStore.shared.bookmarksStore.addNote(to: bookmark, content: msg.text, source: msg.isUser ? "user" : "ai") }
                        }
                        .id(msg.id)
                    }
                    if isSending {
                        HStack {
                            ProgressView().scaleEffect(0.6)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .id("loading")
                    }
                }
                .padding(.vertical, 16)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: messages) { scrollToBottom() }
            .onChange(of: isSending) { scrollToBottom() }
        }
    }
    
    private var quickStarts: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            
            Text("Ask anything about this bookmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            
            VStack(spacing: 8) {
                QuickStartButton(title: "Summarize content") { sendPrompt("Summarize the main content of this page.") }
                QuickStartButton(title: "Analyze UI/UX Structure") { sendPrompt("Analyze the UI and UX structure of this page based on its title and description.") }
                QuickStartButton(title: "Show Core Web Vitals") { sendPrompt("What are common Core Web Vitals to look for on a site like this?") }
                QuickStartButton(title: "Extract Design Details") { sendPrompt("Extract potential design details, colors, and typography patterns mentioned or implied.") }
                QuickStartButton(title: "Generate MD Briefing") { sendPrompt("Generate a comprehensive Markdown briefing for this bookmark.") }
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }
    
    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                TextField("Ask the Brain...", text: $currentPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1...5)
                    .onSubmit {
                        if !currentPrompt.isEmpty && !isSending {
                            sendPrompt(currentPrompt)
                        }
                    }
                
                Button {
                    sendPrompt(currentPrompt)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(currentPrompt.isEmpty || isSending ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(currentPrompt.isEmpty || isSending)
            }
            .padding(12)
            .background(.bar)
        }
    }
    
    private func sendPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        currentPrompt = ""
        chat.send(bookmark: bookmark, prompt: trimmed, config: config)
    }
    
    private func scrollToBottom() {
        withAnimation {
            if isSending {
                scrollProxy?.scrollTo("loading", anchor: .bottom)
            } else if let last = messages.last {
                scrollProxy?.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let onSaveToNotes: () -> Void
    @State private var isHovering = false
    @State private var didSave = false
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser { Spacer() }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isUser ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundStyle(message.isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
                    .contextMenu {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        
                        Button(action: onSaveToNotes) {
                            Label("Add to Notes", systemImage: "note.text.badge.plus")
                        }
                    }
                
                if !message.isUser {
                    Button {
                        onSaveToNotes()
                        withAnimation { didSave = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: didSave ? "checkmark" : "note.text.badge.plus")
                            Text(didSave ? "Saved to Notes" : "Save to Notes")
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(didSave ? Color.green : Color.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(didSave || isHovering ? 1 : 0)
                    .disabled(didSave)
                }
            }
            
            if !message.isUser { Spacer() }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct QuickStartButton: View {
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
