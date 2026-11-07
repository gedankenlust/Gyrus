import SwiftUI

/// "Edit Bookmark" sheet. Drafts are copied once when the sheet opens, so a
/// background refresh of the bookmark cannot overwrite what the user typed.
struct BookmarkEditSheet: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var url: String
    @State private var desc: String
    @State private var collectionId: String?
    @State private var tagIds: Set<String>
    @State private var error: String?
    @State private var isSaving = false
    @State private var isAutoTagging = false

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _title = State(initialValue: bookmark.title)
        _url = State(initialValue: bookmark.url)
        _desc = State(initialValue: bookmark.description ?? "")
        _collectionId = State(initialValue: bookmark.collectionId)
        _tagIds = State(initialValue: Set(bookmark.tags.map(\.id)))
    }

    private var aiEnabled: Bool { AppSettings.shared.aiBrainConfig.aiEnabled }

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Bookmark")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)

            Form {
                if let error {
                    Section {
                        // Stay in the sheet on failure: closing it would throw
                        // the user's changes away without saying why
                        // (invalid URL, duplicate, backend busy).
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("URL", text: $url, prompt: Text("https://…"), axis: .vertical)
                    TextField("Description", text: $desc,
                              prompt: Text("Optional description"), axis: .vertical)
                        .lineLimit(3...6)
                    Picker("Folder", selection: $collectionId) {
                        Text("No Folder").tag(Optional<String>.none)
                        ForEach(collectionStore.flatCollections) { col in
                            Text(col.name).tag(Optional(col.id))
                        }
                    }
                }

                Section {
                    if tagStore.tags.isEmpty {
                        Text("No tags yet. Create tags in the sidebar.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(tagStore.tags) { tag in
                                TagToggleChip(tag: tag, selected: tagIds.contains(tag.id)) {
                                    if tagIds.contains(tag.id) { tagIds.remove(tag.id) }
                                    else { tagIds.insert(tag.id) }
                                }
                            }
                        }
                    }
                } header: {
                    tagsHeader
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding(16)
        }
        .frame(width: 480)
        .frame(minHeight: 460, idealHeight: 540)
    }

    private var tagsHeader: some View {
        HStack {
            Text("Tags")
            Spacer()
            if aiEnabled {
                if isAutoTagging {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await runAutoTag() }
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.borderless)
                    .help("Auto-tag with AI")
                    .accessibilityLabel("Auto-tag with AI")
                }
            }
            Text("\(tagIds.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() async {
        var update = BookmarkUpdate()
        update.title = title.isEmpty ? nil : title
        update.url = url.isEmpty ? nil : url
        update.description = desc.isEmpty ? nil : desc
        update.collectionId = collectionId
        update.tagIds = Array(tagIds)
        isSaving = true
        defer { isSaving = false }
        do {
            try await bookmarkStore.updateBookmark(bookmark, update: update)
            error = nil
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runAutoTag() async {
        isAutoTagging = true
        defer { isAutoTagging = false }
        do {
            let updated = try await APIClient.shared.autoTag(bookmarkId: bookmark.id, config: AppSettings.shared.aiBrainConfig)
            // Reload available tags from store in case new ones were created
            try? await tagStore.fetchTags()
            tagIds = Set(updated.tags.map { $0.id })
        } catch {
            // Same rule as everywhere: a failed user action must be visible,
            // not a console print (e.g. Ollama not running).
            AppStore.shared.surfaceError(error)
        }
    }
}
