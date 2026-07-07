import SwiftUI

/// Post-batch tag review: lists the tags the LLM *created* during a bulk
/// auto-tag run so junk ("appliances", "kitchen", …) can be discarded in one
/// pass before it settles into the sidebar. Checked = keep.
struct TagReviewSheet: View {
    let payload: TagReviewPayload
    var onFinish: (_ discard: [CreatedTagInfo]) -> Void

    @State private var keep: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Tags Created")
                    .font(.headline)
                Group {
                    if payload.tags.count == 1 {
                        Text("The AI created 1 new tag during this run. Uncheck it if you don't want to keep it.")
                    } else {
                        Text("The AI created \(payload.tags.count) new tags during this run. Uncheck any you don't want to keep.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(payload.tags) { tag in
                        Toggle(isOn: Binding(
                            get: { keep.contains(tag.id) },
                            set: { on in if on { keep.insert(tag.id) } else { keep.remove(tag.id) } }
                        )) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: tag.color ?? "") ?? .accentColor)
                                    .frame(width: 9, height: 9)
                                Text(tag.name)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 3)
                    }
                }
                .padding()
            }
            .frame(minHeight: 120, maxHeight: 320)

            Divider()

            HStack {
                Button("Keep All") { onFinish([]) }
                Spacer()
                Button("Apply") {
                    onFinish(payload.tags.filter { !keep.contains($0.id) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keep.count == payload.tags.count)
            }
            .padding()
        }
        .frame(width: 380)
        .onAppear { keep = Set(payload.tags.map(\.id)) }
    }
}
