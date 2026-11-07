import Foundation

// MARK: - Notes and their persisted drafts

extension BookmarkStore {
    /// Drafts are written on every change so an unsaved note survives a quit
    /// or crash; a failed write is shown instead of silently losing the text.
    func persistDrafts() {
        do {
            try draftStorage?.write(noteDrafts)
            draftStorageError = nil
        } catch {
            draftStorageError = String(localized: "Note drafts could not be saved on this Mac. Keep Gyrus open until they are saved.")
        }
    }

    func saveNoteDraft(for bookmark: Bookmark) async {
        let id = bookmark.id
        let generation = libraryGeneration
        guard !savingNoteIds.contains(id), let content = noteDrafts[id],
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingNoteIds.insert(id)
        noteErrors[id] = nil
        defer { if generation == libraryGeneration { savingNoteIds.remove(id) } }
        do {
            try await addNote(to: bookmark, content: content, source: "user")
            guard generation == libraryGeneration else { return }
            if noteDrafts[id] == content { noteDrafts[id] = nil }
        } catch {
            guard generation == libraryGeneration else { return }
            noteErrors[id] = String(localized: "Note could not be saved. Your draft is preserved.") + " " + error.localizedDescription
        }
    }

    func addNote(to bookmark: Bookmark, content: String, source: String = "user") async throws {
        let generation = libraryGeneration
        let note = try await api.addNote(bookmarkId: bookmark.id, content: content, source: source)
        guard generation == libraryGeneration else { return }
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].bookmarkNotes.insert(note, at: 0)
        }
        if selectedBookmark?.id == bookmark.id {
            selectedBookmark?.bookmarkNotes.insert(note, at: 0)
        }
    }

    func deleteNote(_ noteId: String, from bookmark: Bookmark) async throws {
        try await api.deleteNote(bookmarkId: bookmark.id, noteId: noteId)
        if let idx = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[idx].bookmarkNotes.removeAll { $0.id == noteId }
        }
        if selectedBookmark?.id == bookmark.id {
            selectedBookmark?.bookmarkNotes.removeAll { $0.id == noteId }
        }
    }
}
