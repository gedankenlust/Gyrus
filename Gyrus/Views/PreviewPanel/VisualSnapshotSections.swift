import SwiftUI

private let designMetricColumns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

extension VisualSnapshotTabView {
    func styleSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            colorsSection
            typographySection(viewport)
            layoutSection(viewport)
            cssVariablesSection(viewport)
        }
    }

    /// Three bands instead of one flat grid.
    ///
    /// The old section concatenated `dominantColors + observedColors` and let
    /// first-wins deduplication decide, which always put the screenshot's
    /// quantized pixels ahead of the colors the page actually declares. A
    /// designer opens this to lift a palette, so the authored tokens come first
    /// and the sampled pixels are demoted to a collapsed afterthought.
    var colorsSection: some View {
        let tokens = selectedViewport?.cssVariables?.colorTokens() ?? []
        let painted = (selectedViewport?.elementSamples ?? []).paintedPalette()
        let screenshot = SnapshotColor.unique(from: selectedViewport?.dominantColors ?? [])

        return SnapshotSection(title: "Colors", icon: "eyedropper") {
            VStack(alignment: .leading, spacing: 14) {
                if tokens.isEmpty && painted.isEmpty && screenshot.isEmpty {
                    Text("No colors captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !tokens.isEmpty {
                    PaletteBand(
                        title: "Design tokens",
                        subtitle: "Custom properties the site declares",
                        entries: tokens
                    )
                }

                if !painted.isEmpty {
                    PaletteBand(
                        title: "In use",
                        subtitle: "Painted on the page, largest area first",
                        entries: painted
                    )
                }

                if !screenshot.isEmpty {
                    DisclosureGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                            ForEach(screenshot) { color in
                                SnapshotColorChip(color: color)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Screenshot palette")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text("Averaged from the rendered image, not exact values")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    func typographySection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let scale = (viewport.elementSamples ?? []).typeScale()

        return SnapshotSection(title: "Typography", icon: "textformat") {
            VStack(alignment: .leading, spacing: 8) {
                if scale.isEmpty {
                    ForEach(Array(viewport.observedFonts.enumerated()), id: \.offset) { _, font in
                        CopyRow(value: font)
                    }
                } else {
                    Text("Type scale, largest first")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(scale) { step in
                        TypeScaleRow(step: step)
                    }

                    if !viewport.observedFonts.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(viewport.observedFonts.enumerated()), id: \.offset) { _, font in
                                    CopyRow(value: font)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("All font stacks")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Custom properties, grouped by the shape of their value.
    ///
    /// Previously a flat list capped at 80 entries, which on a utility-CSS site
    /// meant the real tokens were pushed out of view by framework bookkeeping
    /// like `--tw-ring-shadow: 0 0 #0000`.
    @ViewBuilder
    func cssVariablesSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let groups = groupCSSVariables(viewport.cssVariables ?? [])
        if !groups.isEmpty {
            SnapshotSection(title: "CSS Variables", icon: "curlybraces") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        CSSVariableGroupView(group: group)
                    }
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
        let groups = classifyComponents(samples)
        // The capture samples at most 24 elements per selector and 90 in total,
        // so once that ceiling is reached the instance counts are a floor rather
        // than a census. Say so instead of implying precision.
        let sampleCeilingReached = samples.count >= 90

        return SnapshotSection(title: "Components", icon: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 10) {
                if groups.isEmpty {
                    Text("No obvious component patterns found in this viewport.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groups) { group in
                        ComponentGroupView(
                            group: group,
                            screenshotPath: viewport.screenshotURL,
                            viewportWidth: viewport.width
                        )
                    }

                    if sampleCeilingReached {
                        Label("Counts are a lower bound: the capture samples a limited number of elements per page.", systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    func layoutSection(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let samples = viewport.elementSamples ?? []
        let maxWidth = samples.map(\.width).max() ?? 0
        let commonRadii = frequency(samples.map(\.borderRadius).filter { !$0.isEmpty && $0 != "0px" })
        let commonDisplay = frequency(samples.map(\.display).filter { !$0.isEmpty })

        return SnapshotSection(title: "Layout", icon: "rectangle.3.group") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: designMetricColumns, spacing: 8) {
                    MetricPill(label: "Viewport W", value: viewport.width)
                    MetricPill(label: "Viewport H", value: viewport.height)
                    MetricPill(label: "Max Element W", value: maxWidth)
                }

                InspectorList(title: "Spacing Scale", values: samples.spacingScale())
                InspectorList(title: "Radius Patterns", values: commonRadii)
                InspectorList(title: "Display Patterns", values: commonDisplay)
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

                if viewport.responsiveIssues == nil {
                    Label("Reinspect this page to run responsive checks.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if issues.isEmpty {
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
