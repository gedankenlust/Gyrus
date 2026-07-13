import SwiftUI

private let designMetricColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

extension VisualSnapshotTabView {
    func styleSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            colorsSection
            typographySection(viewport)
            layoutSection(viewport)
        }
    }

    var colorsSection: some View {
        SnapshotSection(title: "Colors", icon: "eyedropper") {
            VStack(alignment: .leading, spacing: 12) {
                if colors.isEmpty {
                    Text("No colors captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                        ForEach(colors) { color in
                            SnapshotColorChip(color: color)
                        }
                    }
                }

                if let variables = selectedViewport?.cssVariables, !variables.isEmpty {
                    InspectorList(title: "CSS Variables", values: variables.prefix(80).map { "\($0.name): \($0.value)" })
                }
            }
        }
    }

    func typographySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Typography", icon: "textformat") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewport.observedFonts.enumerated()), id: \.offset) { _, font in
                    CopyRow(value: font, systemImage: "doc.on.doc")
                }
            }
        }
    }

    func structureSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Structure", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Links", value: viewport.structure.links)
                    MetricPill(label: "Buttons", value: viewport.structure.buttons)
                    MetricPill(label: "Images", value: viewport.structure.images)
                    MetricPill(label: "SVG", value: viewport.structure.svgs)
                    MetricPill(label: "Forms", value: viewport.structure.forms)
                }

                ForEach(viewport.structure.h1, id: \.self) { heading in
                    CopyRow(value: "H1: \(heading)", systemImage: "h.square")
                }

                ForEach(viewport.structure.h2.prefix(8), id: \.self) { heading in
                    CopyRow(value: "H2: \(heading)", systemImage: "h.square")
                }
            }
        }
    }

    func componentsSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let samples = viewport.elementSamples ?? []
        let groups = [
            ComponentGroup(title: "Navigation", icon: "point.3.connected.trianglepath.dotted", samples: samples.matching(["nav", "header", "menu"])),
            ComponentGroup(title: "Hero / Sections", icon: "rectangle.topthird.inset.filled", samples: samples.matching(["hero", "section", "main", "article"])),
            ComponentGroup(title: "CTA / Buttons", icon: "button.programmable", samples: samples.filter { $0.tag == "button" || $0.selectorHint.localizedCaseInsensitiveContains("btn") || $0.selectorHint.localizedCaseInsensitiveContains("cta") }),
            ComponentGroup(title: "Cards", icon: "rectangle.stack", samples: samples.matching(["card", "tile", "item"])),
            ComponentGroup(title: "Forms", icon: "rectangle.and.pencil.and.ellipsis", samples: samples.filter { ["form", "input", "textarea", "select", "label"].contains($0.tag) }),
        ]

        return SnapshotSection(title: "Components", icon: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups.filter { !$0.samples.isEmpty }) { group in
                    ComponentGroupView(group: group)
                }

                if groups.allSatisfy({ $0.samples.isEmpty }) {
                    Text("No obvious component patterns found yet. Raw computed elements are still available in Raw.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    func layoutSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let samples = viewport.elementSamples ?? []
        let maxWidth = samples.map(\.width).max() ?? 0
        let commonRadii = frequency(samples.map(\.borderRadius).filter { !$0.isEmpty && $0 != "0px" })
        let commonPadding = frequency(samples.map(\.padding).filter { !$0.isEmpty })
        let commonDisplay = frequency(samples.map(\.display).filter { !$0.isEmpty })

        return SnapshotSection(title: "Layout", icon: "rectangle.3.group") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Viewport W", value: viewport.width)
                    MetricPill(label: "Viewport H", value: viewport.height)
                    MetricPill(label: "Max Element W", value: maxWidth)
                }

                InspectorList(title: "Display Patterns", values: commonDisplay)
                InspectorList(title: "Padding Patterns", values: commonPadding)
                InspectorList(title: "Radius Patterns", values: commonRadii)
            }
        }
    }

    func assetsSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Assets", icon: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Images", value: viewport.assets?.images?.count ?? viewport.structure.images)
                    MetricPill(label: "Icons", value: viewport.assets?.icons?.count ?? 0)
                    MetricPill(label: "CSS", value: viewport.assets?.stylesheets?.count ?? 0)
                    MetricPill(label: "Scripts", value: viewport.assets?.scripts?.count ?? 0)
                }

                AssetList(title: "Images", assets: viewport.assets?.images ?? [])
                AssetList(title: "Icons", assets: viewport.assets?.icons ?? [])
                AssetList(title: "Stylesheets", assets: viewport.assets?.stylesheets ?? [])
                AssetList(title: "Scripts", assets: viewport.assets?.scripts ?? [])
            }
        }
    }

    func seoSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "SEO / Content", icon: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                if let title = viewport.seo?.title ?? viewport.pageTitle, !title.isEmpty {
                    CopyRow(value: "Title: \(title)", systemImage: "textformat.size")
                }
                if let metaDescription = viewport.seo?.metaDescription ?? viewport.metaDescription, !metaDescription.isEmpty {
                    CopyRow(value: "Description: \(metaDescription)", systemImage: "text.quote")
                }
                if let canonical = viewport.seo?.canonical, !canonical.isEmpty {
                    CopyRow(value: "Canonical: \(canonical)", systemImage: "link")
                }
                if let language = viewport.seo?.language, !language.isEmpty {
                    CopyRow(value: "Language: \(language)", systemImage: "globe")
                }
                if let robots = viewport.seo?.robots, !robots.isEmpty {
                    CopyRow(value: "Robots: \(robots)", systemImage: "gearshape")
                }
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Internal", value: viewport.seo?.internalLinks ?? 0)
                    MetricPill(label: "External", value: viewport.seo?.externalLinks ?? 0)
                    MetricPill(label: "JSON-LD", value: viewport.seo?.jsonLd?.count ?? 0)
                    MetricPill(label: "OG", value: viewport.seo?.openGraph?.count ?? 0)
                    MetricPill(label: "Twitter", value: viewport.seo?.twitter?.count ?? 0)
                }

                structureSection(viewport)
                MetaList(title: "Open Graph", items: viewport.seo?.openGraph ?? [])
                MetaList(title: "Twitter Cards", items: viewport.seo?.twitter ?? [])
                InspectorList(title: "JSON-LD", values: (viewport.seo?.jsonLd ?? []).prefix(8).map { $0 })
            }
        }
    }

    func accessibilitySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Accessibility", icon: "accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Missing Alt", value: viewport.accessibility?.missingAltImages?.count ?? 0)
                    MetricPill(label: "Empty Buttons", value: viewport.accessibility?.emptyButtons?.count ?? 0)
                    MetricPill(label: "Unlabeled Inputs", value: viewport.accessibility?.unlabeledInputs?.count ?? 0)
                    MetricPill(label: "Heading Skips", value: viewport.accessibility?.headingSkips?.count ?? 0)
                }

                AssetList(title: "Images Missing Alt", assets: viewport.accessibility?.missingAltImages ?? [])
                A11yItemList(title: "Buttons Without Accessible Text", items: viewport.accessibility?.emptyButtons ?? [])
                A11yItemList(title: "Inputs Without Labels", items: viewport.accessibility?.unlabeledInputs ?? [])
                HeadingSkipList(skips: viewport.accessibility?.headingSkips ?? [])
            }
        }
    }

    func issuesSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            responsiveIssuesSection(viewport)
            accessibilitySection(viewport)
            networkSection(viewport)
            consoleSection(viewport)
        }
    }

    func websiteSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            seoSection(viewport)
            assetsSection(viewport)
        }
    }

    func responsiveIssuesSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let issues = viewport.responsiveIssues ?? []
        let high = issues.filter { $0.severity == "high" }.count
        let medium = issues.filter { $0.severity == "medium" }.count
        let low = issues.filter { $0.severity == "low" }.count

        return SnapshotSection(title: "Responsive issues", icon: "rectangle.3.group.bubble.left") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    IssueMetricPill(label: "High", value: high, color: .red)
                    IssueMetricPill(label: "Medium", value: medium, color: .orange)
                    IssueMetricPill(label: "Low", value: low, color: .secondary)
                }

                if issues.isEmpty {
                    Label("No responsive problems detected in this viewport.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(issues) { issue in
                        ResponsiveIssueRow(issue: issue)
                    }
                }
            }
        }
    }

    func networkSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Network", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Requests", value: viewport.network?.requestCount ?? 0)
                    MetricPill(label: "Failed", value: viewport.network?.failedRequests?.count ?? 0)
                    MetricPill(label: "Large", value: viewport.network?.largeRequests?.count ?? 0)
                }
                if let counts = viewport.network?.resourceCounts, !counts.isEmpty {
                    InspectorList(title: "Resource Types", values: counts.map { "\($0.type): \($0.count)" })
                }
                NetworkRequestList(title: "Failed Requests", requests: viewport.network?.failedRequests ?? [])
                NetworkRequestList(title: "Large Requests", requests: viewport.network?.largeRequests ?? [])
            }
        }
    }

    func consoleSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        SnapshotSection(title: "Console", icon: "terminal") {
            let messages = viewport.consoleMessages ?? []
            VStack(alignment: .leading, spacing: 8) {
                if messages.isEmpty {
                    Text("No console messages captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(messages.prefix(80)) { message in
                        CopyRow(value: "[\(message.type ?? "log")] \(message.text ?? "")", systemImage: "terminal")
                    }
                }
            }
        }
    }

}
