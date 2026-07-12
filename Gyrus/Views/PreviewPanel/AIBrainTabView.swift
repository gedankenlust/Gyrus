import SwiftUI

struct AIBrainTabView: View {
    let bookmark: Bookmark

    private let chat = BrainChatStore.shared
    @State private var currentPrompt: String = ""
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var hasDesignSnapshot = false

    // Conversation state lives in the shared store, keyed by bookmark — so it
    // survives switching bookmarks and runs in the background.
    private var messages: [ChatMessage] { chat.messages(for: bookmark.id) }
    private var isSending: Bool { chat.isSending(bookmark.id) }

    private var config: AIBrainConfig {
        AppSettings.shared.aiBrainConfig
    }

    /// The actual prompt sent to the LLM must be in the app's language too —
    /// the reply otherwise tends to mirror the prompt's language regardless
    /// of the German "respond in German" system instruction on some models.
    private var isGerman: Bool { AppSettings.shared.effectiveLanguageCode == "de" }

    private static let quickStarts: [(title: LocalizedStringKey, en: String, de: String)] = [
        ("Summarize content",
         "Summarize the main content of this page.",
         "Fasse den Hauptinhalt dieser Seite zusammen."),
        ("Analyze UI/UX Structure",
         "Analyze the UI/UX structure and user intent. Use captured design evidence when available, distinguish evidence from recommendations, and do not guess missing details.",
         "Analysiere UI/UX-Struktur und Nutzerintention. Nutze vorhandene Design-Messdaten, trenne Belege von Empfehlungen und erfinde keine fehlenden Details."),
        ("Compare Viewports",
         "Compare the captured desktop, tablet, and mobile viewports. Identify meaningful responsive differences, inconsistencies, and concrete improvements. State clearly when a viewport has not been captured.",
         "Vergleiche die erfassten Desktop-, Tablet- und Mobile-Viewports. Nenne relevante responsive Unterschiede, Inkonsistenzen und konkrete Verbesserungen. Sage klar, wenn ein Viewport nicht erfasst wurde."),
        ("Extract Design Details",
         "Extract a concise design system from the captured rendered page: colors, typography, spacing, radii, shadows, layout patterns, and reusable components. Separate measured evidence from interpretation and say what is missing.",
         "Extrahiere aus der erfassten gerenderten Seite ein kompaktes Designsystem: Farben, Typografie, Abstände, Radien, Schatten, Layoutmuster und wiederverwendbare Komponenten. Trenne gemessene Belege von Interpretation und nenne fehlende Daten."),
        ("Generate MD Briefing",
         "Generate a comprehensive Markdown briefing for this bookmark.",
         "Erstelle ein umfassendes Markdown-Briefing für dieses Lesezeichen."),
    ]

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
        .task(id: bookmark.id) {
            await chat.load(bookmarkId: bookmark.id)
            hasDesignSnapshot = (try? await APIClient.shared.visualSnapshot(bookmarkId: bookmark.id)) != nil
        }
    }
    
    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if isSending {
                    ProgressView().scaleEffect(0.5)
                }
                // Summarize button — quick one-tap note generation
                Button {
                    Task {
                        do {
                            let resp = try await APIClient.shared.summarize(bookmarkId: bookmark.id, config: config)
                            if !resp.summary.isEmpty {
                                AppStore.shared.uiStateStore.showInfo("Summary added to Notes.")
                            }
                        } catch {
                            AppStore.shared.uiStateStore.showError(error.localizedDescription)
                        }
                    }
                } label: {
                    Image(systemName: "text.quote")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Generate a summary and save it to Notes")
                .disabled(isSending)
                if chat.hasConversation(bookmark.id) {
                    Button {
                        chat.clear(bookmark.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear this conversation")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            HStack(spacing: 6) {
                BrainContextBadge(title: "Page text", icon: "doc.text")
                BrainContextBadge(title: "Chat history", icon: "bubble.left.and.bubble.right")
                if hasDesignSnapshot {
                    BrainContextBadge(title: "3 viewports", icon: "rectangle.3.group")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
        }
    }
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    // Skip the empty placeholder reply that fills in while streaming.
                    ForEach(messages.filter { !(!$0.isUser && $0.text.isEmpty) }) { msg in
                        ChatBubble(message: msg) {
                            Task { try? await AppStore.shared.bookmarksStore.addNote(to: bookmark, content: msg.text, source: msg.isUser ? "user" : "ai") }
                        }
                        .id(msg.id)
                    }
                    if isSending && (messages.last?.text.isEmpty ?? true) {
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
                ForEach(Self.quickStarts, id: \.en) { qs in
                    QuickStartButton(title: qs.title) { sendPrompt(isGerman ? qs.de : qs.en) }
                }
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
                
                if isSending {
                    Button {
                        chat.stop(bookmark.id)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                } else {
                    Button {
                        sendPrompt(currentPrompt)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(currentPrompt.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(currentPrompt.isEmpty)
                }
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

private struct BrainContextBadge: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
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
                bubbleText
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
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
                
                if !message.isUser && !message.isError {
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

    /// Render assistant replies as Markdown (bold, lists, code, links) while
    /// preserving newlines; user text stays plain. Falls back to plain text if
    /// Markdown parsing fails.
    @ViewBuilder
    private var bubbleText: some View {
        if message.isUser {
            Text(message.text)
        } else if message.isError {
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
        } else if let attributed = try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(message.text)
        }
    }

    private var bubbleBackground: Color {
        if message.isUser { return Color.accentColor }
        if message.isError { return Color.red.opacity(0.15) }
        return Color.secondary.opacity(0.2)
    }
}

struct QuickStartButton: View {
    let title: LocalizedStringKey
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
