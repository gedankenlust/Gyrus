import SwiftUI

// MARK: - Root

/// The bookmark inspector. Deliberately thin: it only decides between the
/// empty state and `BookmarkDetailView` (Views/PreviewPanel/Detail/), so the
/// window can host it in a split column or an `.inspector` without knowing
/// anything about the detail's internals.
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
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.quaternary)
                .accessibilityHidden(true)

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
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

struct HintRow: View {
    let icon: String
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.tertiary)
        }
    }
}
