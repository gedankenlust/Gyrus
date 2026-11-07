import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Side-by-side comparison lives in the Responsive section, where the
/// breakpoint numbers are; the overview only switches between the stored
/// screenshot and the live page.
private enum DesignReviewMode: String, CaseIterable, Identifiable {
    case snapshot
    case live

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .snapshot: "Snapshot"
        case .live: "Live"
        }
    }
}

/// The captured screenshot, or the live page at the same viewport size.
struct DesignReviewView: View {
    let snapshot: APIClient.VisualSnapshotDTO
    let viewport: APIClient.VisualViewportDTO
    /// Used for the PDF filename when the page had no title.
    let fallbackTitle: String

    @State private var mode: DesignReviewMode = .snapshot
    @State private var isExportingPDF = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $mode) {
                    ForEach(DesignReviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 0)

                Button {
                    Task { await exportViewportPDF() }
                } label: {
                    if isExportingPDF {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Label("PDF", systemImage: "doc.richtext")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(snapshot.viewports.isEmpty || isExportingPDF)
                .help("Export every captured viewport as a PDF")
            }

            switch mode {
            case .snapshot:
                SnapshotViewportFrame(viewport: viewport)
            case .live:
                LiveViewportFrame(url: URL(string: snapshot.url), viewport: viewport)
            }
        }
    }

    @MainActor
    private func exportViewportPDF() async {
        isExportingPDF = true
        defer { isExportingPDF = false }

        do {
            var pages: [(viewport: APIClient.VisualViewportDTO, image: NSImage)] = []
            for viewport in snapshot.viewports {
                let url = APIClient.shared.visualSnapshotFileURL(path: viewport.screenshotURL)
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    pages.append((viewport, image))
                }
            }

            guard !pages.isEmpty else {
                AppStore.shared.uiStateStore.showError(String(localized: "No screenshots available for PDF export."))
                return
            }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "\(safeFilename(snapshot.title.isEmpty ? fallbackTitle : snapshot.title))-viewports.pdf"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let outputURL = panel.url else { return }

            guard let data = viewportPDFData(snapshot: snapshot, pages: pages) else {
                AppStore.shared.uiStateStore.showError(String(localized: "Could not create PDF."))
                return
            }

            try data.write(to: outputURL)
            AppStore.shared.uiStateStore.showInfo(String(localized: "Viewport PDF exported."))
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }
}
