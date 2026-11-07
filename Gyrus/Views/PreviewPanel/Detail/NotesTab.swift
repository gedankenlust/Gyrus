import SwiftUI

/// Notes for the open bookmark, newest data from the store, with a composer
/// pinned to the bottom. Drafts and errors live in `BookmarkStore` keyed by
/// bookmark, so switching bookmarks never loses an unsent note.
struct NotesTab: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore

    private var draft: Binding<String> {
        Binding(
            get: { bookmarkStore.noteDrafts[bookmark.id] ?? "" },
            set: { bookmarkStore.noteDrafts[bookmark.id] = $0 }
        )
    }

    private var isSaving: Bool { bookmarkStore.savingNoteIds.contains(bookmark.id) }

    private var canSave: Bool {
        !isSaving && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if bookmark.bookmarkNotes.isEmpty {
                ContentUnavailableView("No notes yet", systemImage: "note.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(bookmark.bookmarkNotes) { note in
                            NoteCard(note: note) { delete(note) }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()

            if let error = bookmarkStore.noteErrors[bookmark.id] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            composer
        }
        .background(Color(.windowBackgroundColor))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Add a note…", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .lineLimit(1...5)

            Button {
                Task { await bookmarkStore.saveNoteDraft(for: bookmark) }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save note")
            .help("Save note")
            .disabled(!canSave)
        }
        .padding(12)
        .background(.bar)
    }

    private func delete(_ note: BookmarkNote) {
        Task {
            do {
                try await bookmarkStore.deleteNote(note.id, from: bookmark)
                bookmarkStore.noteErrors[bookmark.id] = nil
            } catch {
                bookmarkStore.noteErrors[bookmark.id] = error.localizedDescription
            }
        }
    }
}

// MARK: - Note card

/// One note. Delete shows on hover, but also when its button has keyboard
/// focus, in the context menu and as a VoiceOver action — a hover-only
/// control is unreachable without a pointer. Deleting always asks first.
struct NoteCard: View {
    let note: BookmarkNote
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isConfirmingDelete = false
    @FocusState private var isDeleteFocused: Bool

    private var isAI: Bool { note.source == "ai" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sourceBadge
                Spacer(minLength: 4)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .focused($isDeleteFocused)
                .opacity(isHovering || isDeleteFocused ? 1 : 0)
                .help("Delete Note")
                .accessibilityLabel("Delete Note")
            }

            Text(note.content)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Note…", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Delete Note")) { isConfirmingDelete = true }
        .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete) {
            Button("Delete Note", role: .destructive, action: onDelete)
        } message: {
            Text("This can't be undone.")
        }
    }

    private var sourceBadge: some View {
        // "You" rather than "Self": the badge speaks to the reader.
        let title: LocalizedStringKey = isAI ? "Brain" : "You"
        let tint: Color = isAI ? .purple : .blue
        return Label(title, systemImage: isAI ? "brain" : "person.fill")
            .font(.caption2.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
