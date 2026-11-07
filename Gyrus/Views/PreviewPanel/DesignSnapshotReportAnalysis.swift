import Foundation

/// The report sections derived from the captured data rather than copied from
/// it: the audit and the design tokens. They run the same analysis as the
/// inspector, so the report and the screen never disagree.
extension DesignSnapshotReport {
    static func appendAudit(
        _ snapshot: APIClient.VisualSnapshotDTO,
        to report: inout MarkdownReportBuilder
    ) {
        report.heading(2, "Audit")
        if snapshot.viewports.isEmpty {
            report.empty("No viewport was captured.")
            return
        }
        report.line("_The score starts at 100 and loses points per finding by severity. It is a guide for comparing pages, not a standard._")

        for viewport in snapshot.viewports {
            let audit = DesignAudit.run(viewport)
            report.viewportHeading(viewport)
            report.field("Score", "\(audit.score) / 100")
            report.field(
                "Findings",
                "\(audit.count(.critical)) critical, \(audit.count(.warning)) warning, \(audit.count(.info)) notice"
            )
            if audit.findings.isEmpty {
                report.empty("No findings.")
            }
            for finding in audit.findings {
                let count = finding.count > 0 ? " (\(finding.count))" : ""
                report.item("[\(severityLabel(finding.severity))] \(finding.category.rawValue): \(finding.title)\(count)")
                report.indentedField("Detail", finding.detail)
            }

            let failing = audit.contrastPairs.filter { $0.rating == .fail }
            report.heading(4, "Failing contrast pairs")
            if failing.isEmpty {
                report.empty("Every sampled text/background pair meets WCAG AA.")
            }
            for pair in failing {
                let size = pair.isLargeText ? "large text" : "body text"
                let assumed = pair.backgroundIsAssumed ? ", background assumed white" : ""
                report.item("\(pair.foregroundHex) on \(pair.backgroundHex) — \(pair.formattedRatio), \(size), \(pair.occurrences) elements\(assumed)")
                for example in pair.examples {
                    report.indentedField("Example", example)
                }
            }
        }
    }

    /// Tokens from the first viewport only: the custom properties are the same
    /// at every width, and three near-identical blocks would bury the one a
    /// reader wants to paste.
    static func appendDesignTokens(
        _ snapshot: APIClient.VisualSnapshotDTO,
        to report: inout MarkdownReportBuilder
    ) {
        report.heading(2, "Design Tokens")
        guard let viewport = snapshot.viewports.first else {
            report.empty("No viewport was captured.")
            return
        }
        let tokens = DesignTokenSet.extract(
            samples: viewport.elementSamples ?? [],
            cssVariables: viewport.cssVariables ?? []
        )
        report.field("Source viewport", "\(viewport.name.capitalized) (\(viewport.width) x \(viewport.height))")
        guard !tokens.isEmpty else {
            report.empty("No design tokens could be extracted.")
            return
        }
        // Token values are page text. A backtick run inside them could close
        // the fence early and turn the rest of the page's text into Markdown.
        let css = tokens.export(.css, source: snapshot.url)
            .replacingOccurrences(of: "`", with: "'")
            .trimmingCharacters(in: .newlines)
        report.line("")
        report.line("```css")
        for line in css.components(separatedBy: "\n") {
            report.line(line)
        }
        report.line("```")
    }

    private static func severityLabel(_ severity: AuditSeverity) -> String {
        switch severity {
        case .critical: "CRITICAL"
        case .warning: "WARNING"
        case .info: "NOTICE"
        }
    }
}

struct MarkdownReportBuilder {
    private(set) var lines: [String] = []

    var output: String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    mutating func line(_ value: String) {
        lines.append(value)
    }

    mutating func heading(_ level: Int, _ title: String) {
        if !lines.isEmpty, lines.last != "" { lines.append("") }
        lines.append("\(String(repeating: "#", count: level)) \(clean(title))")
        lines.append("")
    }

    mutating func viewportHeading(_ viewport: APIClient.VisualViewportDTO) {
        heading(3, "\(viewport.name.capitalized) (\(viewport.width) x \(viewport.height))")
    }

    mutating func field(_ label: String, _ value: String?) {
        guard let value, !clean(value).isEmpty else { return }
        lines.append("- **\(clean(label)):** \(clean(value))")
    }

    mutating func indentedField(_ label: String, _ value: String?) {
        guard let value, !clean(value).isEmpty else { return }
        lines.append("  - **\(clean(label)):** \(clean(value))")
    }

    mutating func item(_ value: String) {
        let cleaned = clean(value)
        guard !cleaned.isEmpty else { return }
        lines.append("- \(cleaned)")
    }

    mutating func empty(_ value: String) {
        lines.append("_\(clean(value))_")
    }

    func clean(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: "`", with: "'")
    }
}
