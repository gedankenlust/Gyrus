import SwiftUI

struct DesignWebsiteBrowser: View {
    let viewport: APIClient.VisualViewportDTO
    let structure: APIClient.VisualSiteStructureDTO?
    let navigation: [APIClient.VisualNavigationGroupDTO]
    @State private var section = "Content"
    @State private var query = ""
    @State private var assetKind = "Images"
    @State private var pageKind = "Pages"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Website area", selection: $section) {
                Text("Content").tag("Content")
                Text("Pages & menus").tag("Pages & menus")
                Text("Files").tag("Files")
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case "Pages & menus": pages
                    case "Files": files
                    default: content
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
            }.id(section)
        }.onChange(of: section) { _, _ in query = "" }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What this page says about itself: title, search description and headings.")
                .font(.callout).foregroundStyle(.secondary)
            InspectorField(title: "Page title", value: viewport.seo?.title ?? viewport.pageTitle ?? "")
            InspectorField(title: "Search description", value: viewport.seo?.metaDescription ?? viewport.metaDescription ?? "")
            HStack(alignment: .top) {
                InspectorField(title: "Language", value: viewport.seo?.language ?? "")
                InspectorField(title: "Robots", value: viewport.seo?.robots ?? "")
            }
            InspectorField(title: "Canonical URL", value: viewport.seo?.canonical ?? "")
            SnapshotSection(title: "Headings", icon: "textformat.123") {
                let headings = viewport.structure.h1.map { "H1 · \($0)" } + viewport.structure.h2.map { "H2 · \($0)" }
                InspectorPage(items: InspectorString.rows(headings), pageSize: 5) { CopyRow(value: $0.value) }
            }
            DisclosureGroup("Social previews & structured data") {
                VStack(alignment: .leading, spacing: 12) {
                    MetaList(title: "Open Graph", items: viewport.seo?.openGraph ?? [])
                    MetaList(title: "Twitter Cards", items: viewport.seo?.twitter ?? [])
                    InspectorPage(items: InspectorString.rows(viewport.seo?.jsonLd ?? []), pageSize: 3) { value in
                        InspectorField(title: "JSON-LD", value: value.value)
                    }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }

    private var pages: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discovered pages belong to this site. Menus show links captured on the inspected page.")
                .font(.caption).foregroundStyle(.secondary)
            if let structure {
                HStack(spacing: 12) {
                    Text("\(structure.listedPageCount) pages found")
                    Text("\(navigation.count) menus")
                }.font(.caption.weight(.semibold))
                if structure.crawlLimitReached == true || structure.sitemapLimitReached == true {
                    Label("Partial inventory: the inspection limit was reached.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Structure area", selection: $pageKind) {
                Text("Pages").tag("Pages")
                Text("Menus").tag("Menus")
            }.pickerStyle(.menu)
            if pageKind == "Pages" {
                TextField("Find page title or URL…", text: $query).textFieldStyle(.roundedBorder)
                let pages = (structure?.pages ?? []).filter {
                    query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
                }
                InspectorPage(items: pages, pageSize: 6) { page in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.title.isEmpty ? page.path : page.title).font(.callout.weight(.medium)).lineLimit(2)
                        CopyRow(value: page.url).foregroundStyle(.secondary).help(page.url)
                    }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if navigation.isEmpty {
                Text("No navigation structure detected.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(navigation) { group in
                    SnapshotSection(title: LocalizedStringKey(group.label), icon: "list.bullet.indent") {
                        OutlineGroup(group.items, children: \.outlineChildren) { item in
                            InspectorField(title: LocalizedStringKey(item.label), value: item.url ?? "")
                        }
                    }
                }
            }
            DisclosureGroup("Discovery details") {
                VStack(alignment: .leading, spacing: 12) {
                    InspectorField(title: "Sitemap", value: structure.map { String($0.sitemapPageCount) } ?? "")
                    InspectorField(title: "Crawled", value: structure.map { String($0.crawledPageCount) } ?? "")
                    InspectorPage(items: InspectorString.rows(structure?.sitemapSources ?? []), pageSize: 4) { InspectorField(title: "Sitemap source", value: $0.value) }
                    InspectorPage(items: InspectorString.rows(structure?.errors ?? []), pageSize: 4) { InspectorField(title: "Crawler note", value: $0.value) }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }

    private var files: some View {
        let assets: [APIClient.VisualAssetDTO]
        switch assetKind {
        case "Icons": assets = viewport.assets?.icons ?? []
        case "Stylesheets": assets = viewport.assets?.stylesheets ?? []
        case "Scripts": assets = viewport.assets?.scripts ?? []
        default: assets = viewport.assets?.images ?? []
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Files referenced by the captured page. Choose a type or search for a filename.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("File type", selection: $assetKind) {
                ForEach(["Images", "Icons", "Stylesheets", "Scripts"], id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
            }.pickerStyle(.menu)
            TextField("Find file or URL…", text: $query).textFieldStyle(.roundedBorder)
            let matches = assets.enumerated().filter { query.isEmpty || ($0.element.url ?? "").localizedCaseInsensitiveContains(query)
                || ($0.element.selectorHint ?? "").localizedCaseInsensitiveContains(query)
                || ($0.element.alt ?? "").localizedCaseInsensitiveContains(query) }
                .map { InspectorAsset(id: $0.offset, asset: $0.element) }
            InspectorPage(items: matches, pageSize: 6) { item in
                let asset = item.asset
                let url = asset.url ?? asset.selectorHint ?? ""
                let filename = URL(string: url)?.lastPathComponent ?? ""
                let title = (asset.alt?.isEmpty == false ? asset.alt : nil)
                    ?? (filename.isEmpty || filename == "/" ? URL(string: url)?.host ?? url : filename)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    CopyRow(value: url).help(url)
                    if let width = asset.width, let height = asset.height, width > 0 || height > 0 {
                        Text("\(width) × \(height) px").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    let details = AssetList(title: assetKind, assets: []).assetDetails(asset)
                    if !details.isEmpty || asset.selectorHint?.isEmpty == false {
                        DisclosureGroup("File details") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(details, id: \.self) { CopyRow(value: $0) }
                                if let selector = asset.selectorHint, !selector.isEmpty { CopyRow(value: selector) }
                            }.padding(.top, 4)
                        }.font(.caption)
                    }
                }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }.id(assetKind)
        }
    }
}

/// Repeated references can share a URL and selector but are separate captured elements.
private struct InspectorAsset: Identifiable {
    let id: Int
    let asset: APIClient.VisualAssetDTO
}
