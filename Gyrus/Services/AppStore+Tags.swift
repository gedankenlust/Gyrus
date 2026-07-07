import Foundation

// MARK: - Tag operations: delete (with undo), merge, assign, review-discard

extension AppStore {
    /// Delete one or more tags with a 5s Undo. Tag deletion is permanent on the
    /// server (it drops the bookmark associations), so — unlike the deferred
    /// bookmark delete — we snapshot each tag's bookmarks first and Undo
    /// recreates the tag and re-attaches them via the /tags/restore endpoint.
    func deleteTags(_ tags: [Tag]) async {
        guard !tags.isEmpty else { return }
        uiStateStore.cancelUndoTimer()
        uiStateStore.undoGeneration += 1

        // Snapshot associations BEFORE deleting (covers bookmarks not currently
        // loaded, which a frontend-only undo would silently miss).
        var snapshots: [(name: String, color: String?, ids: [String])] = []
        for t in tags {
            let ids = (try? await api.bookmarkIds(tag: t.name)) ?? []
            snapshots.append((t.name, t.color, ids))
        }

        let ids = tags.map(\.id)
        let names = Set(tags.map(\.name))
        var deleteFailure: Error?
        for id in ids {
            do { try await api.deleteTag(id: id) }
            catch { deleteFailure = error; continue }
            bookmarksStore.removeTagLocally(id)
        }
        if let sel = tagsStore.selectedTagName, names.contains(sel) {
            tagsStore.selectedTagName = nil
        }
        try? await tagsStore.fetchTags()
        await loadBookmarks()
        if let deleteFailure {
            // Don't offer Undo for a partial delete — restoring on top of a
            // half-applied state would be confusing. Show what went wrong.
            surfaceError(deleteFailure)
            return
        }

        uiStateStore.undoMessage = tags.count == 1
            ? AppSettings.shared.localized("Deleted tag “\(tags[0].name)”")
            : AppSettings.shared.localized("Deleted \(tags.count) tags")
        uiStateStore.undoAction = { [weak self] in
            guard let self else { return }
            self.uiStateStore.cancelUndoTimer()
            self.uiStateStore.undoMessage = nil
            self.uiStateStore.undoAction = nil
            Task {
                do {
                    for s in snapshots {
                        _ = try await self.api.restoreTag(name: s.name, color: s.color, bookmarkIds: s.ids)
                    }
                } catch {
                    // A silently failed undo is worse than no undo — the user
                    // believes the tags are back when they aren't.
                    self.surfaceError(error)
                }
                try? await self.tagsStore.fetchTags()
                await self.loadBookmarks()
            }
        }
        uiStateStore.startUndoTimer(window: Self.undoWindow)
    }

    /// Merge tags: bookmarks with any source tag get `target` instead; the
    /// sources are deleted. Not undoable (recreating the exact pre-merge state
    /// would require stripping the target from bookmarks that gained it), so
    /// callers confirm first.
    func mergeTags(_ sources: [Tag], into target: Tag) async {
        let sourceIds = sources.map(\.id).filter { $0 != target.id }
        guard !sourceIds.isEmpty else { return }
        do {
            try await api.mergeTags(sourceIds: sourceIds, targetId: target.id)
            for id in sourceIds { bookmarksStore.removeTagLocally(id) }
            if let sel = tagsStore.selectedTagName,
               sources.contains(where: { $0.name == sel }) {
                tagsStore.selectedTagName = nil
            }
            try? await tagsStore.fetchTags()
            await loadBookmarks()
            let merged = sources.filter { $0.id != target.id }.map(\.name).joined(separator: "”, “")
            uiStateStore.showInfo(AppSettings.shared.localized("Merged “\(merged)” into “\(target.name)”."))
        } catch {
            surfaceError(error)
        }
    }

    /// Assign a tag to a set of bookmarks (drag & drop onto a tag row).
    /// Additive only — never removes, unlike toggleTag.
    func assignTag(_ tag: Tag, toBookmarkIds ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        do {
            var tagged = 0
            for id in ids {
                guard let bm = bookmarksStore.bookmarks.first(where: { $0.id == id }) else { continue }
                var tagIds = bm.tags.map(\.id)
                guard !tagIds.contains(tag.id) else { continue }
                tagIds.append(tag.id)
                var u = BookmarkUpdate(); u.tagIds = tagIds
                let updated = try await api.updateBookmark(id: id, body: u)
                if let idx = bookmarksStore.bookmarks.firstIndex(where: { $0.id == id }) {
                    bookmarksStore.bookmarks[idx] = updated
                }
                if bookmarksStore.selectedBookmark?.id == id {
                    bookmarksStore.selectedBookmark = updated
                }
                tagged += 1
            }
            try? await tagsStore.fetchTags() // refresh sidebar counts
            if tagged > 0 {
                uiStateStore.showInfo(tagged == 1
                    ? AppSettings.shared.localized("Tagged 1 bookmark with “\(tag.name)”.")
                    : AppSettings.shared.localized("Tagged \(tagged) bookmarks with “\(tag.name)”."))
            }
        } catch {
            surfaceError(error)
        }
    }

    /// Discard tags the user rejected in the post-batch review sheet.
    func discardReviewedTags(_ tags: [CreatedTagInfo]) async {
        guard !tags.isEmpty else { return }
        var failure: Error?
        for t in tags {
            do { try await api.deleteTag(id: t.id) }
            catch { failure = error; continue }
            bookmarksStore.removeTagLocally(t.id)
        }
        try? await tagsStore.fetchTags()
        await loadBookmarks()
        if let failure {
            surfaceError(failure)
        } else {
            uiStateStore.showInfo(tags.count == 1
                ? AppSettings.shared.localized("Discarded 1 tag.")
                : AppSettings.shared.localized("Discarded \(tags.count) tags."))
        }
    }
}
