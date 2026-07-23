import SwiftUI
import AppKit

struct BookmarkTableView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(UIStateStore.self) private var uiStateStore
    
    @State private var sortOrder = [KeyPathComparator(\Bookmark.createdAt, order: .reverse)]

    var body: some View {
        @Bindable var bookmarkStore = bookmarkStore

        VStack(spacing: 0) {
            Table(of: Bookmark.self, selection: $bookmarkStore.selectedIds, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { bm in
                    let urlFirst = AppSettings.shared.cardLayout == "urlFirst"
                    let showRead = AppSettings.shared.enableReadStatus
                    HStack(spacing: 8) {
                        // Unread indicator (reserves space so rows stay aligned).
                        if showRead {
                            Circle()
                                .fill(bm.isRead ? Color.clear : Color.accentColor)
                                .frame(width: 7, height: 7)
                                .help(bm.isRead ? "Read" : "Unread")
                        }
                        FaviconView(faviconPath: bm.faviconPath, bookmarkURL: bm.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(urlFirst ? bm.url : bm.displayTitle)
                                .font(.callout.weight(showRead && !bm.isRead ? .semibold : .regular)).lineLimit(1)
                                .truncationMode(urlFirst ? .middle : .tail)
                            Text(urlFirst ? bm.displayTitle : bm.url)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .onAppear {
                        // Prefetch the next page ~24 rows before the end, so it's
                        // ready before the user scrolls to the bottom.
                        if bookmarkStore.hasMore && !bookmarkStore.isLoadingMore {
                            let arr = bookmarkStore.bookmarks
                            let triggerIndex = max(0, arr.count - 24)
                            if triggerIndex < arr.count && arr[triggerIndex].id == bm.id {
                                Task { try? await bookmarkStore.loadMoreBookmarks() }
                            }
                        }
                        // Lazily fetch a missing favicon when the row appears.
                        if bm.faviconPath == nil {
                            Task { try? await bookmarkStore.fetchMeta(bm) }
                        }
                    }
                }
                TableColumn("Tags") { bm in
                    HStack(spacing: 4) {
                        ForEach(bm.tags.prefix(3)) { TagChip(tag: $0) }
                    }
                }
                // Flexible width (not a fixed value) so the Tags/Date boundary
                // is user-resizable, like the Title column.
                .width(min: 80, ideal: 120, max: 400)
                TableColumn("Captured") { bm in
                    HStack {
                        Spacer(minLength: 0)
                        analysisStatusIcon(for: bm)
                        Spacer(minLength: 0)
                    }
                }
                .width(min: 64, ideal: 72, max: 96)
                TableColumn("Date Added", value: \.createdAt) { bm in
                    Text(bm.createdAt, style: .date)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90, max: 220)
            } rows: {
                ForEach(bookmarkStore.bookmarks) { bm in
                    TableRow(bm)
                        .draggable(dragPayload(for: bm))
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    BookmarkContextMenu(ids: ids, bookmarks: bookmarkStore.bookmarks)
                }
            } primaryAction: { ids in
                appStore.requestOpenInBrowser(ids: ids)
            }
            .onChange(of: bookmarkStore.selectedIds) {
                handleSelectionChange(bookmarkStore.selectedIds)
            }
            .onChange(of: sortOrder) {
                handleSortChange(sortOrder)
            }

            if bookmarkStore.isLoadingMore {
                loadingMoreIndicator
            }
        }
        .onAppear {
            syncSortOrder()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func analysisStatusIcon(for bookmark: Bookmark) -> some View {
        if let analysis = bookmark.analysis {
            switch analysis.overall {
            case "running":
                ProgressView()
                    .controlSize(.small)
                    .help(analysisHelp(analysis))
            case "pending":
                Image(systemName: "clock.fill")
                    .foregroundStyle(.secondary)
                    .help(analysisHelp(analysis))
            case "ready":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(analysisHelp(analysis))
            case "partial":
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(analysisHelp(analysis))
            case "failed":
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(analysisHelp(analysis))
            default:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
                    .help(analysisHelp(analysis))
            }
        } else if bookmark.designSnapshotCapturedAt == nil {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .help("Not captured")
        } else if bookmark.designSnapshotComplete {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Captured")
        } else {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
                .help("Reinspection required")
        }
    }

    private func analysisHelp(_ analysis: BookmarkAnalysis) -> String {
        let settings = AppSettings.shared
        let detail = [
            "\(settings.localized("Metadata")): \(localizedStage(analysis.metadata))",
            "\(settings.localized("Reader")): \(localizedStage(analysis.reader))",
            "\(settings.localized("Search")): \(localizedStage(analysis.index))",
            "\(settings.localized("Design")): \(localizedStage(analysis.design))",
        ].joined(separator: " · ")
        if let error = analysis.lastError, !error.isEmpty {
            return "\(detail)\n\(error)"
        }
        return detail
    }

    private func localizedStage(_ value: String) -> String {
        switch value {
        case "ready": return AppSettings.shared.localized("Ready")
        case "pending": return AppSettings.shared.localized("Pending")
        case "running": return AppSettings.shared.localized("Running")
        case "failed": return AppSettings.shared.localized("Failed")
        case "partial": return AppSettings.shared.localized("Partial")
        case "unavailable": return AppSettings.shared.localized("Unavailable")
        case "stale": return AppSettings.shared.localized("Outdated")
        default: return AppSettings.shared.localized("Not analyzed")
        }
    }

    private func syncSortOrder() {
        let order: SortOrder = bookmarkStore.sortOrder == "asc" ? .forward : .reverse
        
        // We use KeyPathComparator which needs a specific KeyPath. 
        // In our table we support Title and Date Added.
        if bookmarkStore.sortBy == "title" {
            sortOrder = [KeyPathComparator(\Bookmark.title, order: order)]
        } else {
            // Default to created_at
            sortOrder = [KeyPathComparator(\Bookmark.createdAt, order: order)]
        }
    }

    private var loadingMoreIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text("Loading more…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private func handleSelectionChange(_ ids: Set<String>) {
        if let id = ids.first,
           let bm = bookmarkStore.bookmarks.first(where: { $0.id == id }) {
            bookmarkStore.selectedBookmark = bm
        } else if ids.isEmpty {
            bookmarkStore.selectedBookmark = nil
        }
    }

    private func handleSortChange(_ newOrder: [KeyPathComparator<Bookmark>]) {
        guard let comparator = newOrder.first else { return }
        let order = comparator.order == .forward ? "asc" : "desc"
        let titleKP: PartialKeyPath<Bookmark> = \Bookmark.title
        let dateKP: PartialKeyPath<Bookmark>  = \Bookmark.createdAt
        
        let field: String?
        if comparator.keyPath == titleKP {
            field = "title"
        } else if comparator.keyPath == dateKP {
            field = "created_at"
        } else {
            field = nil
        }
        
        if let field {
            Task { await appStore.setSort(by: field, order: order) }
        }
    }

    private func dragPayload(for bm: Bookmark) -> String {
        if bookmarkStore.selectedIds.contains(bm.id), bookmarkStore.selectedIds.count > 1 {
            return bookmarkStore.selectedIds.joined(separator: "\n")
        }
        return bm.id
    }
}
