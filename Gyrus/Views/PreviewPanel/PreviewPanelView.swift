import SwiftUI
import AppKit

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let textView = nsView.documentView as! NSTextView
        if textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownTextEditor
        init(_ parent: MarkdownTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

enum PreviewTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case reader = "Reader"
    case brain = "AI Brain"
    case notes = "Notes"
    case web = "Web"
    var id: String { rawValue }
}

// MARK: - Root

struct PreviewPanelView: View {
    @Environment(BookmarkStore.self) private var bookmarkStore

    var body: some View {
        if let bookmark = bookmarkStore.selectedBookmark {
            BookmarkDetailView(bookmark: bookmark)
        } else {
            EmptyPreviewView()
        }
    }
}

// MARK: - Empty state

struct EmptyPreviewView: View {
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "bookmark.square")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)

            VStack(spacing: 6) {
                Text("No bookmark selected")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
                Text("Select a bookmark to see details")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                HintRow(icon: "hand.tap",              text: "Click a bookmark → info & preview")
                HintRow(icon: "magnifyingglass",       text: "⌘K → quick search")
                HintRow(icon: "plus",                  text: "⌘N → add a bookmark manually")
                HintRow(icon: "square.and.arrow.down", text: "Import → Brave, Chrome, Firefox, Safari")
                HintRow(icon: "note.text",             text: "Save notes per bookmark")
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

struct HintRow: View {
    let icon: String
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tertiary).frame(width: 20)
            Text(text).font(.callout).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Detail

struct BookmarkDetailView: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    
    @State private var controller   = WebController()
    @State private var selectedTab: PreviewTab = PreviewTab(rawValue: AppSettings.shared.defaultPreviewTab) ?? .info
    @State private var isEditing    = false
    @State private var newNoteText  = ""
    @State private var readerContent: String = "Loading..."
    @State private var isCleaningReader = false

    // Edit-mode drafts
    @State private var editTitle    = ""
    @State private var editURL      = ""
    @State private var editDesc     = ""
    @State private var editCollectionId: String? = nil
    @State private var editTagIds: Set<String> = []
    @State private var isAutoTagging = false

    private var aiConfig: AIBrainConfig { AppSettings.shared.aiBrainConfig }

    private var availableTabs: [PreviewTab] {
        PreviewTab.allCases.filter { tab in
            if tab == .brain { return aiConfig.isEnabled }
            return true
        }
    }

    /// The user's preferred starting tab, falling back to Info if that tab
    /// isn't available (e.g. AI Brain while the brain is disabled).
    private var preferredTab: PreviewTab {
        let pref = PreviewTab(rawValue: AppSettings.shared.defaultPreviewTab) ?? .info
        return availableTabs.contains(pref) ? pref : .info
    }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                editMode
            } else {
                tabPicker
                Divider()
                
                switch selectedTab {
                case .info: infoMode
                case .reader: readerMode
                case .brain: AIBrainTabView(bookmark: bookmark)
                case .notes: notesMode
                case .web: webMode
                }
            }
        }
        .onAppear {
            selectedTab = preferredTab
            Task { try? await bookmarkStore.fetchMeta(bookmark) }
        }
        .onChange(of: bookmark.id) {
            selectedTab = preferredTab
            isEditing   = false
            Task { try? await bookmarkStore.fetchMeta(bookmark) }
        }
    }

    private var tabPicker: some View {
        Picker("View Mode", selection: $selectedTab) {
            ForEach(availableTabs) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(10)
        .background(.bar)
    }

    // MARK: - Info Mode

    private var infoMode: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ogHeader

                VStack(alignment: .leading, spacing: 20) {
                    titleBlock
                    urlPill

                    if let desc = bookmark.description, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !bookmark.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(bookmark.tags) { TagChip(tag: $0) }
                        }
                    }

                    detailsSection
                }
                .padding(16)
            }
        }
    }

    // MARK: - Reader Mode

    private var readerMode: some View {
        VStack(spacing: 0) {
            // Optional, opt-in AI tidy-up. The local model reformats the text;
            // it never silently replaces the extracted original on disk.
            HStack {
                Text("Reader").font(.headline)
                Spacer()
                Button {
                    cleanupReaderWithAI()
                } label: {
                    if isCleaningReader {
                        ProgressView().scaleEffect(0.5)
                    } else {
                        Label("Tidy with AI", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isCleaningReader || readerContent == "Loading..." || readerContent == "Failed to load content.")
                .help("Reformat this text into clean prose using your local AI model")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(bookmark.title)
                        .font(.title.bold())

                    // Using AttributedString for basic markdown parsing without dependencies
                    if let attrString = try? AttributedString(markdown: readerContent, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attrString)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    } else {
                        Text(readerContent)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            Task {
                readerContent = "Loading..."
                do {
                    readerContent = try await APIClient.shared.fetchReaderContent(id: bookmark.id)
                } catch {
                    readerContent = "Failed to load content."
                }
            }
        }
    }

    private func cleanupReaderWithAI() {
        isCleaningReader = true
        Task {
            defer { isCleaningReader = false }
            do {
                readerContent = try await APIClient.shared.cleanupReaderContent(
                    id: bookmark.id, config: AppSettings.shared.aiBrainConfig)
            } catch {
                // Keep the original text; surface the reason via the shared toast.
                AppStore.shared.uiStateStore.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Notes Mode

    private var notesMode: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 12) {
                    if bookmark.bookmarkNotes.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "note.text")
                                .font(.system(size: 40))
                                .foregroundStyle(.quaternary)
                            Text("No notes yet")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(height: 200)
                    } else {
                        ForEach(bookmark.bookmarkNotes) { note in
                            NoteCard(note: note) {
                                Task { try? await bookmarkStore.deleteNote(note.id, from: bookmark) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
            HStack(spacing: 10) {
                TextField("Add a note...", text: $newNoteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1...5)
                
                Button {
                    let content = newNoteText
                    newNoteText = ""
                    Task { try? await bookmarkStore.addNote(to: bookmark, content: content, source: "user") }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
    }

    struct NoteCard: View {
        let note: BookmarkNote
        let onDelete: () -> Void
        @State private var isHovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(note.source == "ai" ? "Brain" : "Self",
                          systemImage: note.source == "ai" ? "brain" : "person.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(note.source == "ai" ? Color.purple : Color.blue)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(note.source == "ai" ? Color.purple.opacity(0.1) : Color.blue.opacity(0.1), in: Capsule())
                    
                    Spacer()
                    
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    
                    if isHovering {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                
                Text(note.content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .onHover { isHovering = $0 }
        }
    }

    // MARK: - Info Mode building blocks

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url, size: 20)
                .padding(.top, 2)
            Text(bookmark.title.isEmpty ? (URL(string: bookmark.url)?.host ?? bookmark.url) : bookmark.title)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                editTitle = bookmark.title
                editURL   = bookmark.url
                editDesc  = bookmark.description ?? ""
                editCollectionId = bookmark.collectionId
                editTagIds = Set(bookmark.tags.map { $0.id })
                isEditing = true
            } label: {
                Image(systemName: "pencil").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Edit")
        }
    }

    private var urlPill: some View {
        HStack(spacing: 7) {
            Image(systemName: bookmark.url.hasPrefix("https") ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(bookmark.url.hasPrefix("https") ? Color.green : Color.orange)
            Text(bookmark.url)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url, forType: .string)
            } label: { Image(systemName: "doc.on.doc").font(.caption) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy URL")
            Button { bookmarkStore.safeBrowserOpen(bookmark.url) } label: {
                Image(systemName: "arrow.up.right.square").font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in Browser")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var domainString: String {
        URL(string: bookmark.url)?.host ?? "Unknown"
    }

    private var collectionPath: String {
        guard let id = bookmark.collectionId else { return String(localized: "No Folder") }
        let flat = collectionStore.flatCollections
        
        var pathNames: [String] = []
        var currentId: String? = id
        
        while let current = currentId, let collection = flat.first(where: { $0.id == current }) {
            pathNames.insert(collection.name, at: 0)
            currentId = collection.parentId
        }
        
        return pathNames.isEmpty ? String(localized: "Unknown") : pathNames.joined(separator: " > ")
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Details")
            VStack(spacing: 0) {
                detailRow(icon: "globe", label: "Domain", value: domainString)
                Divider().padding(.leading, 40)

                detailRow(icon: "folder", label: "Folder", value: collectionPath)
                Divider().padding(.leading, 40)

                detailRow(icon: "calendar", label: "Added",
                          value: bookmark.createdAt.formatted(date: .abbreviated, time: .omitted))
                Divider().padding(.leading, 40)

                detailRow(icon: "clock", label: "Updated",
                          value: bookmark.updatedAt.formatted(date: .abbreviated, time: .omitted))
                Divider().padding(.leading, 40)

                detailRow(icon: "arrow.down.circle", label: "Source", value: bookmark.source)

                if bookmark.isDead {
                    Divider().padding(.leading, 40)
                    detailRow(icon: "exclamationmark.triangle.fill", label: "Status",
                              value: String(localized: "Dead Link"), tint: .red)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func detailRow(icon: String, label: LocalizedStringKey, value: String,
                           tint: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(tint == .red ? Color.red : Color.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Edit Mode

    private var editMode: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Edit").font(.title3.bold())
                    Spacer()
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(.bordered)
                    Button("Save") { Task { await saveEdit() } }
                        .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Title").font(.callout.weight(.medium))
                    TextField("Title", text: $editTitle, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("URL").font(.callout.weight(.medium))
                    TextField("https://...", text: $editURL, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Description").font(.callout.weight(.medium))
                    TextField("Optional description", text: $editDesc, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                        .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Folder").font(.callout.weight(.medium))
                    Picker("Folder", selection: $editCollectionId) {
                        Text("No Folder").tag(Optional<String>.none)
                        ForEach(collectionStore.flatCollections) { col in
                            Text(col.name).tag(Optional(col.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tags").font(.callout.weight(.medium))
                        Spacer()
                        if isAutoTagging {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(action: { Task { await runAutoTag() } }) {
                                Image(systemName: "wand.and.stars")
                                    .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                            .help("Auto-tag with AI")
                        }
                        Text("\(editTagIds.count) selected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if tagStore.tags.isEmpty {
                        Text("No tags yet. Create tags in the sidebar.")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(tagStore.tags) { tag in
                                TagToggleChip(
                                    tag: tag,
                                    selected: editTagIds.contains(tag.id)
                                ) {
                                    if editTagIds.contains(tag.id) { editTagIds.remove(tag.id) }
                                    else { editTagIds.insert(tag.id) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveEdit() async {
        var update = BookmarkUpdate()
        update.title = editTitle.isEmpty ? nil : editTitle
        update.url = editURL.isEmpty ? nil : editURL
        update.description = editDesc.isEmpty ? nil : editDesc
        update.collectionId = editCollectionId
        update.tagIds = Array(editTagIds)
        try? await bookmarkStore.updateBookmark(bookmark, update: update)
        isEditing = false
    }

    private func runAutoTag() async {
        isAutoTagging = true
        defer { isAutoTagging = false }
        do {
            let updated = try await APIClient.shared.autoTag(bookmarkId: bookmark.id, config: AppSettings.shared.aiBrainConfig)
            // Reload available tags from store in case new ones were created
            try? await tagStore.fetchTags()
            editTagIds = Set(updated.tags.map { $0.id })
        } catch {
            print("Auto-tag failed: \(error)")
        }
    }

    // MARK: - OG Header

    private var ogHeaderURL: URL? {
        if let path = bookmark.ogImagePath {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return APIClient.shared.ogImageURL(filename: filename)
        }
        if let remote = bookmark.ogImageUrl {
            return URL(string: remote)
        }
        return nil
    }

    @ViewBuilder
    private var ogHeader: some View {
        if let url = ogHeaderURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                        .frame(maxWidth: .infinity).frame(height: 180).clipped()
                case .failure, .empty: domainPlaceholder
                @unknown default: domainPlaceholder
                }
            }
        } else {
            domainPlaceholder
        }
    }

    private var domainPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url, size: 36)
                if let host = URL(string: bookmark.url)?.host {
                    Text(host).font(.caption).foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 100)
    }

    // MARK: - Web Mode

    private var webMode: some View {
        VStack(spacing: 0) {
            webToolbar
            Divider()
            if let url = URL(string: bookmark.url) {
                WebPreviewView(url: url, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var webToolbar: some View {
        HStack(spacing: 8) {
            Button { controller.goBack() } label: { Image(systemName: "chevron.left").frame(width: 14) }
                .buttonStyle(.plain).opacity(controller.canGoBack ? 1 : 0.3).disabled(!controller.canGoBack)
            Button { controller.goForward() } label: { Image(systemName: "chevron.right").frame(width: 14) }
                .buttonStyle(.plain).opacity(controller.canGoForward ? 1 : 0.3).disabled(!controller.canGoForward)
            Button { controller.isLoading ? controller.stop() : controller.reload() } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise").frame(width: 14)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

            HStack(spacing: 5) {
                if controller.isLoading { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
                Text(bookmark.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Button { bookmarkStore.safeBrowserOpen(bookmark.url) } label: { Image(systemName: "safari") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open in Browser")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
    }
}
