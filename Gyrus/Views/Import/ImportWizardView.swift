import SwiftUI
import UniformTypeIdentifiers

struct ImportWizardView: View {
    @Binding var isPresented: Bool
    @Environment(AppStore.self) private var appStore
    
    @State private var isDragging = false
    @State private var isImporting = false
    @State private var result: ImportResult? = nil
    @State private var errorMessage: String? = nil
    @State private var folderName = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("Import Bookmarks")
                    .font(.title2.bold())
                Text("Drag & drop your browser's bookmark export file")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Works with Brave, Arc, Chrome, Firefox, Safari")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let result {
                importResultView(result)
            } else {
                VStack(spacing: 14) {
                    folderField
                    dropZone
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var folderField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import into folder (optional)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. Brave", text: $folderName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragging ? Color.accentColor : Color(.separatorColor),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    isDragging ? Color.accentColor.opacity(0.06) : Color(.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )

            if isImporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Importing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("Drop bookmarks.html here")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Choose File…") { openFilePicker() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(height: 160)
        .onDrop(of: [.html, .fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private func importResultView(_ result: ImportResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Import complete")
                .font(.headline)
            HStack(spacing: 24) {
                statView(value: result.imported, label: "Imported")
                statView(value: result.collectionsCreated, label: "Folders")
                statView(value: result.skipped, label: "Skipped")
            }
        }
        .padding(20)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statView(value: Int, label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Strategy 1: Finder drops provide a file URL as data.
        // The data often contains a null terminator — strip it before parsing.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data else { return }
                let cleaned = Data(data.filter { $0 != 0 })
                guard let raw = String(data: cleaned, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: raw) ?? URL(string: raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
                else { return }
                Task { @MainActor in await processFile(url) }
            }
            return true
        }

        // Strategy 2: provider gives us the HTML bytes directly.
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    isImporting = true
                    errorMessage = nil
                    result = try? await appStore.importHTML(data: data, filename: "bookmarks.html", rootFolderName: folderName)
                    isImporting = false
                }
            }
            return true
        }

        return false
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await processFile(url) }
        }
    }

    private func processFile(_ url: URL) async {
        isImporting = true
        errorMessage = nil
        do {
            let data = try Data(contentsOf: url)
            result = try await appStore.importHTML(data: data, filename: url.lastPathComponent, rootFolderName: folderName)
        } catch {
            errorMessage = error.localizedDescription
        }
        isImporting = false
    }
}
