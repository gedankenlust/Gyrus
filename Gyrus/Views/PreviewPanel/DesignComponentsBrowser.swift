import SwiftUI

struct DesignComponentsBrowser: View {
    let viewport: APIClient.VisualViewportDTO
    @State private var category = "all"
    @State private var query = ""
    @State private var selected: ComponentVariant?
    private var groups: [ComponentGroup] { classifyComponents(viewport.elementSamples ?? [], limit: .max) }
    private var variants: [ComponentVariant] {
        groups.filter { category == "all" || $0.id == category }.flatMap(\.variants).filter {
            query.isEmpty || $0.representative.text.localizedCaseInsensitiveContains(query)
                || $0.representative.selectorHint.localizedCaseInsensitiveContains(query)
                || $0.representative.tag.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected {
                HStack {
                    Button { self.selected = nil } label: { Label("All components", systemImage: "chevron.left") }
                    Spacer()
                    Text("\(selected.count) occurrences").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
                ScrollView { detail(selected).padding(.bottom, 16) }.id(selected.id)
            } else {
                Text("Captured patterns at a glance. Select a card for a larger preview and its measured styles.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Component category", selection: $category) {
                        Text("All components").tag("all")
                        ForEach(groups) { Text(LocalizedStringKey($0.title)).tag($0.id) }
                    }.pickerStyle(.menu)
                    Spacer(minLength: 0)
                }
                TextField("Find component or selector…", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    InspectorPage(items: variants, pageSize: 4, grid: true, columnCount: 2) { variant in
                        Button { selected = variant } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ComponentThumbnail(sample: variant.representative, screenshotPath: viewport.screenshotURL,
                                    viewportWidth: viewport.width, boxWidth: 130, boxHeight: 82)
                                    .frame(maxWidth: .infinity)
                                Text(componentTitle(variant.representative)).font(.callout.weight(.semibold)).lineLimit(2)
                                    .frame(height: 34, alignment: .topLeading)
                                Text("\(variant.count) occurrences").font(.caption).foregroundStyle(.secondary)
                                Text("\(variant.representative.width) × \(variant.representative.height) px")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(variant.representative.selectorHint)
                    }
                    Text("Samples are an inventory of detected patterns, not every element on the page.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 10)
                }
            }
        }
    }

    private func componentTitle(_ sample: APIClient.VisualElementSampleDTO) -> String {
        let text = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(70)) }
        switch sample.tag.lowercased() {
        case "button": return String(localized: "Button")
        case "a": return String(localized: "Link")
        case "input", "textarea": return String(localized: "Text field")
        case "nav": return String(localized: "Navigation")
        default: return "<\(sample.tag)>"
        }
    }

    private func detail(_ variant: ComponentVariant) -> some View {
        let sample = variant.representative
        return VStack(alignment: .leading, spacing: 16) {
            Text(componentTitle(sample)).font(.headline).textSelection(.enabled)
            ComponentThumbnail(sample: sample, screenshotPath: viewport.screenshotURL,
                viewportWidth: viewport.width, boxWidth: 300, boxHeight: 190)
                .frame(maxWidth: .infinity)
            Text("Screenshot crop from the captured page").font(.caption2).foregroundStyle(.secondary)
            InspectorField(title: "Element", value: "<\(sample.tag)> · \(sample.width) × \(sample.height) px")
            InspectorField(title: "Selector", value: sample.selectorHint)
            HStack(alignment: .top) {
                InspectorField(title: "Text color", value: sample.color)
                InspectorField(title: "Background", value: sample.backgroundColor)
            }
            InspectorField(title: "Typography", value: "\(sample.fontSize) · \(sample.fontWeight) · \(sample.fontFamily)")
            InspectorField(title: "Spacing & corners", value: "padding: \(sample.padding) · radius: \(sample.borderRadius)")
            DisclosureGroup("CSS & text details") {
                VStack(alignment: .leading, spacing: 10) {
                    let css = ElementSampleRow(sample: sample).cssText
                    Button("Copy CSS") { copy(css); AppStore.shared.uiStateStore.showInfo("CSS copied.") }
                        .buttonStyle(.borderless)
                    Text(css).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InspectorPage(items: InspectorString.rows(variant.texts), pageSize: 4) { CopyRow(value: $0.value) }
                }.padding(.top, 8)
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
