import SwiftUI

struct BookmarkCardView: View {
    let bookmark: Bookmark
    @Environment(BookmarkStore.self) private var bookmarkStore
    @State private var isHovering = false

    private var isSelected: Bool {
        bookmarkStore.selectedIds.contains(bookmark.id)
    }

    var body: some View {
        // Reading this here makes cards re-render when the layout setting changes.
        let urlFirst = AppSettings.shared.cardLayout == "urlFirst"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                FaviconView(faviconPath: bookmark.faviconPath, bookmarkURL: bookmark.url)
                Text(urlFirst ? bookmark.url : bookmark.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(urlFirst ? .middle : .tail)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            }

            Text(urlFirst ? bookmark.displayTitle : bookmark.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !bookmark.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(bookmark.tags) { tag in
                            TagChip(tag: tag)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: 116)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 1.5 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(isHovering ? 0.14 : 0), radius: 7, y: 3)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .task(id: bookmark.id) {
            // Lazily fetch a missing favicon when the card scrolls into view.
            if bookmark.faviconPath == nil {
                try? await bookmarkStore.fetchMeta(bookmark)
            }
        }
    }
}

/// Loads favicon images once and keeps them in memory. Using an explicit
/// loader (instead of AsyncImage) avoids AsyncImage's flaky phase/caching
/// behavior in reused grid cells, where icons would get stuck on the globe
/// fallback even though the file existed.
@MainActor
@Observable
final class FaviconCache {
    static let shared = FaviconCache()
    private var cache: [String: NSImage] = [:]
    /// Bumped on clear() so every FaviconView reloads, even when a favicon's
    /// filename is unchanged (same domain → same hash) after a forced refresh.
    private(set) var generation = 0

    func cached(_ filename: String) -> NSImage? { cache[filename] }

    func load(_ filename: String) async -> NSImage? {
        if let img = cache[filename] { return img }
        let url = APIClient.shared.faviconURL(filename: filename)
        // Retry once: right after launch the backend may still be warming up,
        // and a first miss would otherwise leave the card stuck on the globe.
        for attempt in 0..<2 {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = NSImage(data: data) {
                cache[filename] = img
                return img
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 600_000_000) }
        }
        return nil
    }

    func clear() {
        cache.removeAll()
        generation += 1
    }

    /// Re-run every FaviconView's load without dropping the cache. Already-loaded
    /// icons return instantly from memory; ones that fell back to the globe
    /// (e.g. while the backend was unreachable after sleep) get another chance.
    func refresh() {
        generation += 1
    }
}

struct FaviconView: View {
    let faviconPath: String?
    var bookmarkURL: String? = nil
    var size: CGFloat = 16

    @State private var image: NSImage?

    private var filename: String? {
        guard let path = faviconPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        // Reading `generation` here makes the view reload when the cache is
        // cleared (e.g. after a forced metadata refresh).
        let token = FaviconCache.shared.generation
        return Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(faviconPath ?? "none")#\(token)") {
            image = nil
            guard let filename else { return }
            if let cached = FaviconCache.shared.cached(filename) {
                image = cached
            } else {
                image = await FaviconCache.shared.load(filename)
            }
        }
    }
}

struct TagChip: View {
    let tag: Tag

    var body: some View {
        Text(tag.name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chipColor.opacity(0.15), in: Capsule())
            .foregroundStyle(chipColor)
    }

    private var chipColor: Color {
        Color(hex: tag.color ?? "") ?? .accentColor
    }
}

struct TagToggleChip: View {
    let tag: Tag
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark").font(.caption2.bold())
                }
                Text(tag.name).font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(selected ? chipColor.opacity(0.25) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(chipColor.opacity(selected ? 0.6 : 0.3), lineWidth: 1)
            )
            .foregroundStyle(chipColor)
        }
        .buttonStyle(.plain)
    }

    private var chipColor: Color {
        Color(hex: tag.color ?? "") ?? .accentColor
    }
}
