import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Export bookmarks (all, or one folder) as HTML / CSV / Markdown / Plain Text.
struct ExportSheet: View {
    @Binding var isPresented: Bool
    @Environment(CollectionStore.self) private var collectionStore
    var filterCollectionId: String? = nil
    var filterCollectionName: String? = nil

    enum Format: String, CaseIterable, Identifiable {
        case html = "HTML"
        case csv = "CSV"
        case markdown = "Markdown"
        case txt = "Plain Text"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .html: return "globe"
            case .csv: return "tablecells"
            case .markdown: return "doc.richtext"
            case .txt: return "doc.plaintext"
            }
        }
        var ext: String {
            switch self {
            case .html: return "html"
            case .csv: return "csv"
            case .markdown: return "md"
            case .txt: return "txt"
            }
        }
        var detail: LocalizedStringKey {
            switch self {
            case .html: return "Browser-compatible (Chrome, Firefox, Safari)"
            case .csv: return "Spreadsheet (Excel, Numbers, Google Sheets)"
            case .markdown: return "Grouped by folder, with title and URL"
            case .txt: return "One URL per line, compact and simple"
            }
        }
    }

    @State private var selected: Format = .html
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Bookmarks")
                    .font(.title3.bold())
                if let name = filterCollectionName {
                    Text("Folder: \"\(name)\"")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(filterCollectionId == nil ? LocalizedStringKey("All bookmarks, excluding Trash") : LocalizedStringKey("Includes subfolders; excludes Trash"))
                .font(.caption).foregroundStyle(.secondary)
            if let exportError {
                Label(exportError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            VStack(spacing: 6) {
                ForEach(Format.allCases) { fmt in
                    Button {
                        selected = fmt
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: fmt.icon)
                                .frame(width: 22)
                                .foregroundStyle(selected == fmt ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(fmt.rawValue)).font(.callout.weight(.medium))
                                Text(fmt.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selected == fmt {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            selected == fmt ? Color.accentColor.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    selected == fmt
                                        ? Color.accentColor.opacity(0.35)
                                        : Color(.separatorColor).opacity(0.5),
                                    lineWidth: 0.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            .disabled(isExporting)

            HStack {
                Button("Cancel") { exportTask?.cancel(); isPresented = false }.buttonStyle(.bordered)
                Spacer()
                Button {
                    exportTask = Task { await doExport() }
                } label: {
                    if isExporting {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export as .\(selected.ext)", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onDisappear { exportTask?.cancel() }
        .onAppear {
            selected = Format.allCases.first { $0.ext == AppSettings.shared.defaultExportFmt } ?? .html
        }
    }

    // MARK: Export logic

    @MainActor
    private func doExport() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let (data, filename) = try await buildExport()
            try Task.checkCancellation()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.allowedContentTypes = [UTType(filenameExtension: selected.ext) ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            isPresented = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            exportError = String(localized: "Export failed. Please try again.") + " " + error.localizedDescription
        }
    }

    private func buildExport() async throws -> (Data, String) {
        let suffix = filterCollectionName.map { "-\($0.replacingOccurrences(of: " ", with: "-"))" } ?? ""
        switch selected {
        case .html:
            let data = try await APIClient.shared.exportHTML(collectionId: filterCollectionId)
            return (data, "gyrus-export\(suffix).html")
        case .csv:
            let bms = try await fetchAll()
            return (Data(buildCSV(bms).utf8), "gyrus-export\(suffix).csv")
        case .markdown:
            let bms = try await fetchAll()
            return (Data(buildMarkdown(bms).utf8), "gyrus-export\(suffix).md")
        case .txt:
            let bms = try await fetchAll()
            let txt = bms.map { $0.url }.joined(separator: "\n")
            return (Data(txt.utf8), "gyrus-links\(suffix).txt")
        }
    }

    private func fetchAll() async throws -> [Bookmark] {
        var all: [Bookmark] = []
        var offset = 0
        while true {
            let page = try await APIClient.shared.exportBookmarks(collectionId: filterCollectionId, limit: 200, offset: offset)
            try Task.checkCancellation()
            all.append(contentsOf: page)
            if page.count < 200 { break }
            offset += page.count
        }
        return all
    }

    private func buildCSV(_ bms: [Bookmark]) -> String {
        let colMap = Dictionary(uniqueKeysWithValues: collectionStore.flatCollections.map { ($0.id, $0.name) })
        var lines = ["Title,URL,Description,Tags,Folder,\"Date Added\""]
        for bm in bms {
            let folder = bm.collectionId.flatMap { colMap[$0] } ?? ""
            lines.append([
                bm.title, bm.url, bm.description ?? "",
                bm.tags.map { $0.name }.joined(separator: "; "),
                folder,
                bm.createdAt.formatted(date: .numeric, time: .omitted)
            ].map { csvEsc($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func buildMarkdown(_ bms: [Bookmark]) -> String {
        var out = ["# Gyrus Bookmark Export",
                   "",
                   "_\(bms.count) bookmarks, exported on \(Date().formatted(date: .abbreviated, time: .omitted))_",
                   ""]
        var grouped: [String: [Bookmark]] = [:]
        for bm in bms { grouped[bm.collectionId ?? "", default: []].append(bm) }

        if let noFolder = grouped[""], !noFolder.isEmpty {
            out += ["## No folder", ""]
            for bm in noFolder { out.append(mdLink(bm)) }
            out.append("")
        }
        for col in collectionStore.flatCollections {
            guard let items = grouped[col.id], !items.isEmpty else { continue }
            out += ["## \(col.name)", ""]
            for bm in items { out.append(mdLink(bm)) }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private func mdLink(_ bm: Bookmark) -> String {
        let title = bm.title.isEmpty ? (URL(string: bm.url)?.host ?? bm.url) : bm.title
        let desc  = (bm.description.map { $0.isEmpty ? "" : " — \($0)" }) ?? ""
        return "- [\(title)](\(bm.url))\(desc)"
    }

    private func csvEsc(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
