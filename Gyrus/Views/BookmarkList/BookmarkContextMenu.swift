import SwiftUI
import AppKit

struct BookmarkContextMenu: View {
    let ids: Set<String>
    let bookmarks: [Bookmark]
    
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore
    @Environment(TagStore.self) private var tagStore
    @Environment(UIStateStore.self) private var uiStateStore

    private var count: Int { ids.count }
    private var single: Bool { count == 1 }
    private var firstBookmark: Bookmark? {
        ids.first.flatMap { id in bookmarks.first { $0.id == id } }
    }

    var body: some View {
        Group {
            // Select all in the current view (same as ⌘A) — discoverable here
            // for mouse users who don't know the shortcut.
            Button {
                Task { await appStore.selectAllInCurrentView() }
            } label: {
                Label("Select All", systemImage: "checklist")
            }
            .disabled(bookmarkStore.bookmarks.isEmpty)

            // Auto-tag the whole selection with AI (background job). Needs only
            // Ollama (like the single-bookmark wand), so it's always offered.
            Button {
                Task { await appStore.startBatchAutoTag(ids: Array(ids)) }
            } label: {
                Label(single ? "Generate Tags with AI" : "Generate Tags with AI (\(count))",
                      systemImage: "wand.and.stars")
            }
            .disabled(uiStateStore.batchAutoTagStatus?.running == true)

            Divider()

            // Open
            Button {
                appStore.requestOpenInBrowser(ids: ids)
            } label: {
                Label(single ? "Open in Browser" : "Open \(count) in Browser",
                      systemImage: "safari")
            }

            // Copy URL
            Button {
                let urls = bookmarks
                    .filter { ids.contains($0.id) }
                    .map { $0.url }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls, forType: .string)
            } label: {
                Label(single ? "Copy URL" : "Copy URLs", systemImage: "doc.on.doc")
            }

            if single, let bm = firstBookmark {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bm.title, forType: .string)
                } label: {
                    Label("Copy Title", systemImage: "textformat")
                }
            }

            Divider()

            // Move to Collection submenu
            Menu {
                Button("No Folder (Root)") {
                    Task { await appStore.moveBookmarks(ids: ids, to: nil) }
                }
                Divider()
                ForEach(collectionStore.flatCollections) { col in
                    Button(col.name) {
                        Task { await appStore.moveBookmarks(ids: ids, to: col.id) }
                    }
                }
            } label: {
                Label(single ? "Move to Folder" : "Move \(count) to Folder",
                      systemImage: "folder")
            }

            // Tags submenu
            Menu {
                ForEach(tagStore.tags) { tag in
                    Button {
                        Task {
                            if let updated = try? await tagStore.toggleTag(tagId: tag.id, onBookmarkIds: ids, in: bookmarks) {
                                bookmarkStore.applyUpdated(updated)
                            }
                        }
                    } label: {
                        let presence = tagStore.tagPresence(tagId: tag.id, in: bookmarks, forIds: ids)
                        let color = Color(hex: tag.color ?? "") ?? .accentColor
                        Label {
                            Text(tag.name)
                        } icon: {
                            Image(nsImage: tagDotImage(color: color, presence: presence))
                        }
                    }
                }
                if !tagStore.tags.isEmpty { Divider() }
                Button {
                    uiStateStore.newTagForIds = ids
                } label: {
                    Label("New Tag…", systemImage: "plus")
                }
            } label: {
                Label(single ? "Tags" : "Tags for \(count)", systemImage: "tag")
            }

            if collectionStore.showTrash {
                Divider()
                // Trash view: restore or permanently delete.
                Button {
                    Task { await appStore.restoreFromTrash(ids: ids) }
                } label: {
                    Label(single ? "Restore" : "Restore \(count)", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    Task { await appStore.purgeFromTrash(ids: ids) }
                } label: {
                    Label(single ? "Delete Permanently" : "Delete \(count) Permanently",
                          systemImage: "trash.slash")
                }
            } else {
                // Mark read / unread (only when the feature is enabled)
                if AppSettings.shared.enableReadStatus {
                    let anyUnread = bookmarks.filter { ids.contains($0.id) }.contains { !$0.isRead }
                    Button {
                        Task { await appStore.setRead(ids: ids, isRead: anyUnread) }
                    } label: {
                        Label(anyUnread
                              ? (single ? "Mark as Read" : "Mark \(count) as Read")
                              : (single ? "Mark as Unread" : "Mark \(count) as Unread"),
                              systemImage: anyUnread ? "envelope.open" : "envelope.badge")
                    }
                }

                Divider()

                // Delete (moves to Trash)
                Button(role: .destructive) {
                    if single, let bm = firstBookmark {
                        Task { await appStore.deleteBookmark(bm) }
                    } else {
                        bookmarkStore.selectedIds = ids
                        appStore.requestDeleteSelected()
                    }
                } label: {
                    Label(single ? "Delete" : "Delete \(count) Bookmarks",
                          systemImage: "trash")
                }
            }
        }
    }

    private func tagDotImage(color: Color, presence: TagPresence) -> NSImage {
        let d: CGFloat = 13
        let img = NSImage(size: CGSize(width: d, height: d), flipped: false) { r in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: r).fill()
            if presence != .none {
                let p = NSBezierPath()
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.lineWidth = 1.6
                NSColor.white.setStroke()
                if presence == .all {
                    p.move(to: NSPoint(x: 2.5, y: 6.0))
                    p.line(to: NSPoint(x: 5.2, y: 3.2))
                    p.line(to: NSPoint(x: 10.5, y: 9.2))
                } else {
                    p.move(to: NSPoint(x: 2.8, y: 6.5))
                    p.line(to: NSPoint(x: 10.2, y: 6.5))
                }
                p.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
