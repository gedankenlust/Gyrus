import SwiftUI

/// Review an in-memory taxonomy draft before it changes the library.
struct TagReviewSheet: View {
    let payload: TagReviewPayload
    var onCancel: () -> Void
    var onApply: ([TaxonomyTagEdit]) -> Void

    @State private var edits: [TaxonomyTagEdit]
    @State private var expanded: Set<String> = []

    init(payload: TagReviewPayload, onCancel: @escaping () -> Void,
         onApply: @escaping ([TaxonomyTagEdit]) -> Void) {
        self.payload = payload
        self.onCancel = onCancel
        self.onApply = onApply
        _edits = State(initialValue: payload.draft.tags.map {
            TaxonomyTagEdit(id: $0.id, name: $0.name, enabled: true)
        })
    }

    private var enabledCount: Int { edits.filter(\.enabled).count }
    private var canApply: Bool {
        edits.contains { $0.enabled && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            tagList
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Review Tag System")
                .font(.title3.weight(.semibold))
            Text("Nothing has been changed yet. Rename tags, disable weak suggestions, then apply the system once.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Label("\(payload.draft.tags.count) tags", systemImage: "tag")
                Label("\(payload.draft.assigned) of \(payload.draft.total) bookmarks", systemImage: "bookmark")
                if payload.draft.withoutTags > 0 {
                    Label("\(payload.draft.withoutTags) without a tag", systemImage: "exclamationmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(18)
    }

    private var tagList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach($edits) { $edit in
                    if let suggestion = payload.draft.tags.first(where: { $0.id == edit.id }) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 10) {
                                Toggle("", isOn: $edit.enabled)
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                TextField("Tag name", text: $edit.name)
                                    .textFieldStyle(.plain)
                                    .disabled(!edit.enabled)
                                Text("\(suggestion.bookmarkCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)
                                Button {
                                    if expanded.contains(edit.id) {
                                        expanded.remove(edit.id)
                                    } else {
                                        expanded.insert(edit.id)
                                    }
                                } label: {
                                    Image(systemName: expanded.contains(edit.id) ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.plain)
                                .help("Show assigned bookmarks")
                            }

                            if expanded.contains(edit.id) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(suggestion.bookmarkTitles.enumerated()), id: \.offset) { _, title in
                                        Text(title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.leading, 26)
                                .padding(.bottom, 3)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        Divider().padding(.leading, 18)
                    }
                }
                if !payload.draft.untagged.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Button {
                            if expanded.contains("untagged") {
                                expanded.remove("untagged")
                            } else {
                                expanded.insert("untagged")
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle")
                                Text("Without a tag")
                                Spacer()
                                Text("\(payload.draft.untagged.count)")
                                    .font(.caption.monospacedDigit())
                                Image(systemName: expanded.contains("untagged") ? "chevron.up" : "chevron.down")
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expanded.contains("untagged") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(payload.draft.untagged) { bookmark in
                                    Text(bookmark.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.leading, 26)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(enabledCount) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
            Button("Apply Tag System") { onApply(edits) }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .padding(18)
    }
}
