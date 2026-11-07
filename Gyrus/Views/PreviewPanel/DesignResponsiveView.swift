import SwiftUI

/// Every captured breakpoint in numbers, then in pictures, then what breaks at
/// the selected one.
///
/// Switching viewports one at a time answers "what does this look like on
/// mobile", but not "what changes between desktop and mobile", and the second
/// question is the one a responsive design actually has to answer.
struct DesignResponsiveView: View {
    let viewports: [APIClient.VisualViewportDTO]
    @Binding var selectedName: String?

    private var selected: APIClient.VisualViewportDTO? {
        viewports.first { $0.name == selectedName } ?? viewports.first
    }

    var body: some View {
        // One summary (and so one audit) per viewport per render.
        let summaries = viewports.map(ViewportSummary.init)

        VStack(alignment: .leading, spacing: 20) {
            SnapshotSection(title: "Breakpoints", icon: "tablecells") {
                comparisonGrid(summaries)
            }

            SnapshotSection(title: "Side by side", icon: "rectangle.split.3x1") {
                if viewports.count > 1 {
                    ViewportComparisonStrip(viewports: viewports)
                } else {
                    Text("Only one viewport was captured, so there is nothing to compare.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let selected {
                issues(selected)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Comparison

    private func comparisonGrid(_ summaries: [ViewportSummary]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(summaries) { summary in
                    columnHeader(summary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)

            metricRow("Size", summaries) { Text(verbatim: "\($0.width) × \($0.height)") }
            metricRow("Largest text", summaries) { Text(verbatim: pixels($0.largestFontSize)) }
            metricRow("Smallest text", summaries) { summary in
                // Below 12 px is where text stops being comfortably readable
                // on a phone, which is what this row is for.
                Text(verbatim: pixels(summary.smallestFontSize))
                    .foregroundStyle((summary.smallestFontSize ?? 12) < 12 ? Color.orange : Color.primary)
            }
            metricRow("Sampled elements", summaries) { Text(verbatim: "\($0.sampledElements)") }
            metricRow("Layout issues", summaries) { summary in
                Text(verbatim: "\(summary.responsiveIssues)")
                    .foregroundStyle(issueColor(total: summary.responsiveIssues, high: summary.highSeverityIssues))
                    .help(Text("\(summary.highSeverityIssues) of high severity"))
            }
            metricRow("Contrast failures", summaries) { summary in
                Text(verbatim: "\(summary.contrastFailures)")
                    .foregroundStyle(summary.contrastFailures > 0 ? Color.red : Color.primary)
            }
            metricRow("Score", summaries) { summary in
                Text(verbatim: "\(summary.score)")
                    .fontWeight(.semibold)
                    .foregroundStyle(designScoreColor(summary.score))
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func columnHeader(_ summary: ViewportSummary) -> some View {
        let isSelected = summary.name == selected?.name
        return Button {
            selectedName = summary.name
        } label: {
            Label {
                Text(LocalizedStringKey(summary.name.capitalized))
            } icon: {
                Image(systemName: designViewportIcon(summary.name))
            }
            .font(.caption.weight(isSelected ? .bold : .semibold))
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Show the issues of this viewport")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func metricRow<Cell: View>(
        _ title: LocalizedStringKey,
        _ summaries: [ViewportSummary],
        @ViewBuilder cell: @escaping (ViewportSummary) -> Cell
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(summaries) { summary in
                cell(summary)
                    .lineLimit(1)
            }
        }
    }

    private func pixels(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%g px", value)
    }

    private func issueColor(total: Int, high: Int) -> Color {
        if high > 0 { return .red }
        return total > 0 ? .orange : .primary
    }

    // MARK: Issues of the selected viewport

    private func issues(_ viewport: APIClient.VisualViewportDTO) -> some View {
        let issues = viewport.responsiveIssues ?? []

        return SnapshotSection(title: "Responsive issues", icon: "rectangle.3.group.bubble.left") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Checked at \(viewport.name.capitalized), \(viewport.width) × \(viewport.height).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if viewport.responsiveIssues == nil {
                    Label("Reinspect this page to run responsive checks.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if issues.isEmpty {
                    Label("No responsive problems detected in this viewport.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        IssueMetricPill(label: "High", value: issues.filter { $0.severity == "high" }.count, color: .red)
                        IssueMetricPill(label: "Medium", value: issues.filter { $0.severity == "medium" }.count, color: .orange)
                        IssueMetricPill(label: "Low", value: issues.filter { $0.severity == "low" }.count, color: .secondary)
                    }
                    ForEach(issues) { issue in
                        ResponsiveIssueRow(issue: issue)
                    }
                }
            }
        }
    }
}
