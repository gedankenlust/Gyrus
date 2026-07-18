import SwiftUI

struct BulkTagAssignmentSheet: View {
    let bookmarkIds: Set<String>
    let bookmarks: [Bookmark]
    let tags: [Tag]
    let onCancel: () -> Void
    let onCreateTag: (_ suggestedName: String) -> Void
    let onApply: (_ addTagIds: Set<String>, _ removeTagIds: Set<String>) -> Void

    @State private var searchText = ""
    @State private var choices: [String: Bool] = [:]

    private var filteredTags: [Tag] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var addTagIds: Set<String> {
        Set(choices.compactMap { $0.value ? $0.key : nil })
    }

    private var removeTagIds: Set<String> {
        Set(choices.compactMap { !$0.value ? $0.key : nil })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose Tags")
                        .font(.title3.bold())
                    Text("\(bookmarkIds.count) bookmarks selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if tags.isEmpty {
                ContentUnavailableView(
                    "No tags available",
                    systemImage: "tag",
                    description: Text("No tags yet. Create tags in the sidebar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search tags", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(16)

                if shouldOfferNewTag {
                    Button {
                        onCreateTag(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Label("Create “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredTags) { tag in
                            tagRow(tag)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            HStack {
                Text("A dash means the tag is assigned to only some bookmarks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    onApply(addTagIds, removeTagIds)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(choices.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }

    private func tagRow(_ tag: Tag) -> some View {
        let presence = presence(of: tag.id)
        let target = choices[tag.id]
        let visualPresence: TagPresence = target.map { $0 ? .all : .none } ?? presence

        return Button {
            choices[tag.id] = visualPresence != .all
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: visualPresence))
                    .font(.body.weight(.medium))
                    .foregroundStyle(visualPresence == .none ? Color.secondary : Color.accentColor)
                    .frame(width: 20)
                Circle()
                    .fill(Color(hex: tag.color ?? "") ?? .accentColor)
                    .frame(width: 8, height: 8)
                Text(tag.name)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(tag.bookmarkCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 6))
    }

    private var shouldOfferNewTag: Bool {
        let name = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return !tags.contains { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private func presence(of tagId: String) -> TagPresence {
        let selected = bookmarks.filter { bookmarkIds.contains($0.id) }
        let count = selected.lazy.filter { bookmark in
            bookmark.tags.contains { $0.id == tagId }
        }.count
        if count == 0 { return .none }
        if count == selected.count { return .all }
        return .some
    }

    private func icon(for presence: TagPresence) -> String {
        switch presence {
        case .all: return "checkmark.square.fill"
        case .some: return "minus.square.fill"
        case .none: return "square"
        }
    }
}
