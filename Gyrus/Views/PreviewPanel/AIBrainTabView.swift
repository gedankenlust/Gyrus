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

    /// The actual prompt sent to the LLM must be in the app's language too —
    /// the reply otherwise tends to mirror the prompt's language regardless
    /// of the German "respond in German" system instruction on some models.
    private var isGerman: Bool { AppSettings.shared.effectiveLanguageCode == "de" }

    private static let quickStarts: [(title: LocalizedStringKey, en: String, de: String)] = [
        ("Summarize content",
         "Summarize the main content of this page.",
         "Fasse den Hauptinhalt dieser Seite zusammen."),
        ("Analyze UI/UX Structure",
         "Analyze the content structure and likely user intent of this page. Use only evidence from the saved title, URL, description, and extracted text. Do not infer visual layout, colors, or typography unless they are explicitly mentioned.",
         "Analysiere die Inhaltsstruktur und wahrscheinliche Nutzerintention dieser Seite. Nutze nur Hinweise aus gespeichertem Titel, URL, Beschreibung und extrahiertem Text. Leite kein visuelles Layout, keine Farben und keine Typografie ab, sofern sie nicht ausdrücklich erwähnt werden."),
        ("Show Core Web Vitals",
         "Create a practical Core Web Vitals and UX checklist for this page type. Make clear that these are checks to run, not measured results.",
         "Erstelle eine praktische Core-Web-Vitals- und UX-Checkliste für diesen Seitentyp. Mache klar, dass es Prüfpunkte sind und keine gemessenen Ergebnisse."),
        ("Extract Design Details",
         "List only design, brand, color, typography, or layout clues that are explicitly present in the saved metadata or extracted page text. If none are present, say that the Brain cannot inspect the rendered page and should not guess.",
         "Liste nur Design-, Marken-, Farb-, Typografie- oder Layout-Hinweise auf, die ausdrücklich in den gespeicherten Metadaten oder im extrahierten Seitentext vorkommen. Wenn keine vorhanden sind, sage, dass der Brain die gerenderte Seite nicht sehen kann und nicht raten sollte."),
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
