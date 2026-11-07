import SwiftUI

/// Where a block of the overview leads when clicked.
enum DesignOverviewTarget {
    case audit
    case colors
    case typography
    case technologies
}

/// The first screen of the Design tab: the gist of the selected viewport in
/// four blocks, each a shortcut into the section that has the detail, and the
/// screenshot underneath.
struct DesignOverviewView: View {
    let snapshot: APIClient.VisualSnapshotDTO
    let viewport: APIClient.VisualViewportDTO
    let fallbackTitle: String
    let onNavigate: (DesignOverviewTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DesignOverviewSummary(viewport: viewport, onNavigate: onNavigate)
            DesignReviewView(snapshot: snapshot, viewport: viewport, fallbackTitle: fallbackTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DesignOverviewSummary: View {
    let viewport: APIClient.VisualViewportDTO
    let onNavigate: (DesignOverviewTarget) -> Void

    private var samples: [APIClient.VisualElementSampleDTO] { viewport.elementSamples ?? [] }

    var body: some View {
        // Computed once per render; the score block and its accessibility
        // label read the same instance.
        let audit = DesignAudit.run(viewport)
        let colors = paletteColors
        let families = primaryFontFamilies
        let sizes = samples.typeScale(limit: .max).map(\.pixels)

        VStack(alignment: .leading, spacing: 8) {
            block(.audit, title: "Audit", help: "Show the audit", label: scoreLabel(audit)) {
                HStack(spacing: 12) {
                    DesignScoreGauge(score: audit.score, diameter: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Design score")
                            .font(.callout.weight(.semibold))
                        DesignSeverityCounts(audit: audit)
                    }
                }
            }

            block(.colors, title: "Colors", help: "Show all colors",
                  label: Text("Colors: \(colors.map { $0.hex.uppercased() }.joined(separator: ", "))")) {
                if colors.isEmpty {
                    emptyNote("No colors captured.")
                } else {
                    HStack(spacing: 3) {
                        ForEach(colors) { color in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hexString: color.hex) ?? .clear)
                                .frame(height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25), lineWidth: 1))
                                .help(color.hex.uppercased())
                        }
                    }
                }
            }

            block(.typography, title: "Typography", help: "Show the type scale",
                  label: Text("Typography: \(families.joined(separator: ", "))")) {
                if families.isEmpty {
                    emptyNote("No fonts captured.")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(families, id: \.self) { family in
                            // Rendered in the family itself when it is
                            // installed here; SwiftUI falls back to the system
                            // font otherwise.
                            Text(verbatim: family)
                                .font(.custom(family, size: 14))
                                .lineLimit(1)
                        }
                        if let smallest = sizes.min(), let largest = sizes.max() {
                            Text("\(sizes.count) sizes, \(pixelString(smallest))–\(pixelString(largest))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            block(.technologies, title: "Technologies", help: "Show the technology stack",
                  label: Text("Technologies: \(technologyNames.joined(separator: ", "))")) {
                technologies
            }
        }
    }

    // MARK: Blocks

    private func block<Content: View>(
        _ target: DesignOverviewTarget,
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        label accessibilityText: Text,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            onNavigate(target)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    content()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(Text(help))
        .accessibilityAddTraits(.isButton)
    }

    private func scoreLabel(_ audit: DesignAudit) -> Text {
        Text("Design score \(audit.score) of 100. \(audit.count(.critical)) critical, \(audit.count(.warning)) warnings, \(audit.count(.info)) notices.")
    }

    @ViewBuilder
    private var technologies: some View {
        if let technologies = viewport.technologies {
            if technologies.isEmpty {
                emptyNote("No technology signatures detected.")
            } else {
                let shown = rankedTechnologies.prefix(6)
                DesignFlowLayout(spacing: 4) {
                    ForEach(Array(shown)) { technology in
                        (pageText(technology.name, localize: true)
                            + Text(verbatim: technology.version.map { " \($0)" } ?? ""))
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    if technologies.count > shown.count {
                        Text(verbatim: "+\(technologies.count - shown.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                }
            }
        } else {
            emptyNote("Reinspect this page to detect its technology stack.")
        }
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Data

    /// The six colors covering the most area, shown dark to light. A page
    /// without samples falls back to an even spread of its authored tokens.
    private var paletteColors: [InspectorPaletteColor] {
        let painted = samples.paintedPalette(limit: 6)
        if !painted.isEmpty { return InspectorPaletteColor.grouped(painted) }
        let tokens = (viewport.cssVariables ?? []).colorTokens(limit: .max)
        return InspectorPaletteColor.preview(InspectorPaletteColor.grouped(tokens), limit: 6)
    }

    /// The leading family of the most used font stacks. The stack's fallbacks
    /// say nothing about the design, so only the first name counts.
    private var primaryFontFamilies: [String] {
        let stacks = samples.map(\.fontFamily).filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for stack in stacks.isEmpty ? viewport.observedFonts : stacks {
            if let family = DesignTokenSet.fontFamilyList(stack).first {
                counts[family, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map(\.key)
    }

    /// High-confidence detections first, otherwise in the backend's order.
    private var rankedTechnologies: [APIClient.VisualTechnologyDTO] {
        let all = viewport.technologies ?? []
        return all.filter { $0.confidence == "high" } + all.filter { $0.confidence != "high" }
    }

    private var technologyNames: [String] {
        rankedTechnologies.map(\.name)
    }

    private func pixelString(_ value: Double) -> String {
        String(format: "%g px", value)
    }
}

/// Lays chips out left to right and wraps them onto new lines, which neither
/// HStack nor an adaptive grid does for items of different widths.
struct DesignFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
