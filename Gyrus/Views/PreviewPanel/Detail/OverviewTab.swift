import SwiftUI
import AppKit

/// Page → Overview: the bookmark's metadata. This is the one place the full
/// URL is shown; the header and the other tabs only show the title.
struct OverviewTab: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore
    @Environment(CollectionStore.self) private var collectionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OverviewHeroImage(bookmark: bookmark)

                VStack(alignment: .leading, spacing: 20) {
                    Text(bookmark.displayTitle)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)

                    urlRow

                    if let desc = bookmark.description, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if !bookmark.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(bookmark.tags) { TagChip(tag: $0) }
                        }
                    }

                    RelatedBookmarksSection(bookmarkId: bookmark.id)

                    detailsSection
                }
                .padding(16)
            }
        }
    }

    // MARK: URL

    private var isSecure: Bool { bookmark.url.lowercased().hasPrefix("https") }

    private var urlRow: some View {
        let securityLabel: LocalizedStringKey = isSecure ? "Secure connection" : "Not secure"
        return HStack(spacing: 8) {
            Image(systemName: isSecure ? "lock.fill" : "lock.open")
                .font(.caption)
                .foregroundStyle(isSecure ? Color.green : Color.orange)
                .help(securityLabel)
                .accessibilityLabel(securityLabel)
            Text(bookmark.url)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(bookmark.url)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy URL")
            .accessibilityLabel("Copy URL")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Details

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
            DetailSectionHeader("Details")
            VStack(spacing: 0) {
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
                    deadLinkRows
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var deadLinkRows: some View {
        let selCount = bookmarkStore.selectedIds.contains(bookmark.id)
            ? bookmarkStore.selectedIds.count : 1
        let markTitle: LocalizedStringKey = selCount > 1
            ? "Mark \(selCount) as working"
            : "Mark as working"
        Divider().padding(.leading, 40)
        detailRow(icon: "exclamationmark.triangle.fill", label: "Status",
                  value: String(localized: "Dead Link"), tint: .red)
        Button {
            Task { await markAlive() }
        } label: {
            Label(markTitle, systemImage: "checkmark.circle")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 40)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .help("Clear the dead-link flag — use this for false positives")
    }

    private func detailRow(icon: String, label: LocalizedStringKey, value: String,
                           tint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // Folder paths can be long in a narrow inspector: wrap to a
            // second line instead of squeezing the label.
            Text(value)
                .font(.callout)
                .foregroundStyle(tint == .red ? Color.red : Color.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// Clear the dead-link flag (false positives — e.g. a site that blocks our
    /// check, or a temporary outage). Applies to the whole selection when this
    /// bookmark is part of it, so multiple can be cleared at once. Reloads so
    /// they leave the Dead Links view.
    private func markAlive() async {
        let ids = bookmarkStore.selectedIds.contains(bookmark.id) && bookmarkStore.selectedIds.count > 1
            ? Array(bookmarkStore.selectedIds)
            : [bookmark.id]
        var update = BookmarkUpdate()
        update.isDead = false
        var firstError: Error?
        for id in ids {
            do {
                _ = try await APIClient.shared.updateBookmark(id: id, body: update)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { AppStore.shared.surfaceError(firstError) }
        await AppStore.shared.loadAll()
        // The cleared bookmarks just left the Dead Links view — drop the now-stale
        // selection so the detail panel doesn't keep showing the old "dead" state.
        bookmarkStore.selectedIds.removeAll()
        bookmarkStore.selectedBookmark = nil
    }
}

// MARK: - Hero image

/// The page's Open Graph image, or a quiet favicon banner when it has none.
/// The banner deliberately omits the host: the URL row right below shows it.
private struct OverviewHeroImage: View {
    let bookmark: Bookmark

    private var imageURL: URL? {
        if let path = bookmark.ogImagePath {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return APIClient.shared.ogImageURL(filename: filename)
        }
        if let remote = bookmark.ogImageUrl {
            return URL(string: remote)
        }
        return nil
    }

    var body: some View {
        Group {
            if let url = imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 180).clipped()
                    case .failure, .empty: placeholder
                    @unknown default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url, size: 36)
        }
        .frame(maxWidth: .infinity).frame(height: 100)
    }
}
