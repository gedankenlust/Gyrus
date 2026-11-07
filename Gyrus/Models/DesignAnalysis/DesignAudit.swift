import Foundation

enum AuditSeverity: Int, Comparable, CaseIterable, Sendable {
    case info = 0
    case warning = 1
    case critical = 2

    static func < (lhs: AuditSeverity, rhs: AuditSeverity) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .info: String(localized: "Notice")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }

    /// The label after a count: "1 Warning" but "3 Warnings".
    func title(count: Int) -> String {
        guard count != 1 else { return title }
        switch self {
        case .info: return String(localized: "Notices")
        case .warning: return String(localized: "Warnings")
        case .critical: return title
        }
    }

    /// Points a finding of this severity takes off the score.
    fileprivate var penalty: Int {
        switch self {
        case .info: 2
        case .warning: 6
        case .critical: 15
        }
    }
}

enum AuditCategory: String, CaseIterable, Identifiable, Sendable {
    case contrast
    case accessibility
    case seo
    case responsive
    case network
    case console

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contrast: String(localized: "Contrast")
        case .accessibility: String(localized: "Accessibility")
        case .seo: String(localized: "SEO")
        case .responsive: String(localized: "Responsive")
        case .network: String(localized: "Network")
        case .console: String(localized: "Console")
        }
    }

    var systemImage: String {
        switch self {
        case .contrast: "circle.lefthalf.filled"
        case .accessibility: "accessibility"
        case .seo: "magnifyingglass"
        case .responsive: "rectangle.3.group"
        case .network: "network"
        case .console: "terminal"
        }
    }
}

struct AuditFinding: Identifiable, Hashable, Sendable {
    let id: String
    let category: AuditCategory
    let severity: AuditSeverity
    let title: String
    let detail: String
    /// Affected elements, requests or messages; 0 when the finding is a single
    /// fact about the page (e.g. a missing title).
    let count: Int
}

/// A prioritized checklist for one captured viewport.
///
/// Every check reads data the snapshot already holds, so the audit works on
/// captures taken before it existed. The score is a rough guide for comparing
/// pages, not a standard: it starts at 100 and loses a fixed number of points
/// per finding by severity.
struct DesignAudit: Sendable {
    let findings: [AuditFinding]
    let contrastPairs: [ContrastPair]

    var score: Int {
        max(0, 100 - findings.reduce(0) { $0 + $1.severity.penalty })
    }

    func count(_ severity: AuditSeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }

    func findings(in category: AuditCategory) -> [AuditFinding] {
        findings.filter { $0.category == category }
    }

    static func run(_ viewport: APIClient.VisualViewportDTO) -> DesignAudit {
        let pairs = ContrastAnalyzer.pairs(in: viewport.elementSamples ?? [])
        var findings: [AuditFinding] = []
        findings += contrastFindings(pairs)
        findings += accessibilityFindings(viewport)
        findings += seoFindings(viewport)
        findings += responsiveFindings(viewport.responsiveIssues ?? [])
        findings += networkFindings(viewport.network)
        findings += consoleFindings(viewport.consoleMessages ?? [])
        let ordered = findings.enumerated().sorted { lhs, rhs in
            if lhs.element.severity != rhs.element.severity { return lhs.element.severity > rhs.element.severity }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return DesignAudit(findings: ordered, contrastPairs: pairs)
    }

    // MARK: Checks

    static func contrastFindings(_ pairs: [ContrastPair]) -> [AuditFinding] {
        let failing = pairs.filter { $0.rating == .fail }
        var result: [AuditFinding] = []
        let body = failing.filter { !$0.isLargeText }
        let large = failing.filter(\.isLargeText)
        if !body.isEmpty {
            result.append(AuditFinding(
                id: "contrast.body", category: .contrast, severity: .critical,
                title: String(localized: "Body text below WCAG AA contrast"),
                detail: String(localized: "Text under 24 px needs a contrast of at least 4.5:1. Worst pair: \(body[0].formattedRatio)."),
                count: body.reduce(0) { $0 + $1.occurrences }
            ))
        }
        if !large.isEmpty {
            result.append(AuditFinding(
                id: "contrast.large", category: .contrast, severity: .warning,
                title: String(localized: "Large text below WCAG AA contrast"),
                detail: String(localized: "Large or bold text needs a contrast of at least 3:1. Worst pair: \(large[0].formattedRatio)."),
                count: large.reduce(0) { $0 + $1.occurrences }
            ))
        }
        return result
    }

    static func accessibilityFindings(_ viewport: APIClient.VisualViewportDTO) -> [AuditFinding] {
        var result: [AuditFinding] = []
        let accessibility = viewport.accessibility
        if let buttons = accessibility?.emptyButtons, !buttons.isEmpty {
            result.append(AuditFinding(
                id: "a11y.buttons", category: .accessibility, severity: .critical,
                title: String(localized: "Buttons without an accessible name"),
                detail: String(localized: "Screen readers announce these only as “button”. Add text or an aria-label."),
                count: buttons.count
            ))
        }
        if let inputs = accessibility?.unlabeledInputs, !inputs.isEmpty {
            result.append(AuditFinding(
                id: "a11y.inputs", category: .accessibility, severity: .critical,
                title: String(localized: "Form fields without a label"),
                detail: String(localized: "A placeholder is not a label. Connect a <label> or set aria-label."),
                count: inputs.count
            ))
        }
        if let images = accessibility?.missingAltImages, !images.isEmpty {
            result.append(AuditFinding(
                id: "a11y.alt", category: .accessibility, severity: .warning,
                title: String(localized: "Images without alt text"),
                detail: String(localized: "Describe meaningful images; mark decorative ones with alt=\"\"."),
                count: images.count
            ))
        }
        if let skips = accessibility?.headingSkips, !skips.isEmpty {
            result.append(AuditFinding(
                id: "a11y.headings", category: .accessibility, severity: .warning,
                title: String(localized: "Skipped heading levels"),
                detail: String(localized: "Headings jump a level, which breaks the outline screen reader users navigate by."),
                count: skips.count
            ))
        }
        let h1Count = viewport.structure.h1.count
        if h1Count == 0 {
            result.append(AuditFinding(
                id: "a11y.h1.missing", category: .accessibility, severity: .warning,
                title: String(localized: "No top-level heading"),
                detail: String(localized: "The page has no <h1> that names its content."),
                count: 0
            ))
        } else if h1Count > 1 {
            result.append(AuditFinding(
                id: "a11y.h1.multiple", category: .accessibility, severity: .info,
                title: String(localized: "Several top-level headings"),
                detail: String(localized: "More than one <h1> makes the main topic ambiguous."),
                count: h1Count
            ))
        }
        return result
    }

    static func seoFindings(_ viewport: APIClient.VisualViewportDTO) -> [AuditFinding] {
        var result: [AuditFinding] = []
        let seo = viewport.seo
        let title = (seo?.title ?? viewport.pageTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (seo?.metaDescription ?? viewport.metaDescription ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty {
            result.append(AuditFinding(
                id: "seo.title", category: .seo, severity: .critical,
                title: String(localized: "Missing page title"),
                detail: String(localized: "Search results and browser tabs show the <title>."),
                count: 0
            ))
        } else if title.count > 60 {
            result.append(AuditFinding(
                id: "seo.title.long", category: .seo, severity: .info,
                title: String(localized: "Long page title"),
                detail: String(localized: "Search results cut titles off after about 60 characters; this one has \(title.count)."),
                count: 0
            ))
        }

        if description.isEmpty {
            result.append(AuditFinding(
                id: "seo.description", category: .seo, severity: .warning,
                title: String(localized: "Missing meta description"),
                detail: String(localized: "Without one, search engines pick a snippet from the page."),
                count: 0
            ))
        } else if description.count < 50 || description.count > 160 {
            result.append(AuditFinding(
                id: "seo.description.length", category: .seo, severity: .info,
                title: String(localized: "Meta description length"),
                detail: String(localized: "Aim for 50–160 characters; this one has \(description.count)."),
                count: 0
            ))
        }

        if let seo {
            if (seo.language ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AuditFinding(
                    id: "seo.lang", category: .seo, severity: .warning,
                    title: String(localized: "No document language"),
                    detail: String(localized: "Set <html lang> so screen readers and translators pick the right language."),
                    count: 0
                ))
            }
            if (seo.canonical ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AuditFinding(
                    id: "seo.canonical", category: .seo, severity: .info,
                    title: String(localized: "No canonical URL"),
                    detail: String(localized: "A canonical link tells search engines which address is the original."),
                    count: 0
                ))
            }
            if (seo.openGraph ?? []).isEmpty {
                result.append(AuditFinding(
                    id: "seo.og", category: .seo, severity: .info,
                    title: String(localized: "No Open Graph tags"),
                    detail: String(localized: "Shared links show no preview image or title in chats and social apps."),
                    count: 0
                ))
            }
            if (seo.robots ?? "").lowercased().contains("noindex") {
                result.append(AuditFinding(
                    id: "seo.noindex", category: .seo, severity: .warning,
                    title: String(localized: "Page asks not to be indexed"),
                    detail: String(localized: "The robots meta tag contains noindex."),
                    count: 0
                ))
            }
        }
        return result
    }

    static func responsiveFindings(_ issues: [APIClient.VisualResponsiveIssueDTO]) -> [AuditFinding] {
        let bySeverity = Dictionary(grouping: issues) { issue -> AuditSeverity in
            switch issue.severity.lowercased() {
            case "high": .critical
            case "medium": .warning
            default: .info
            }
        }
        return AuditSeverity.allCases.reversed().compactMap { severity in
            guard let members = bySeverity[severity], !members.isEmpty else { return nil }
            let kinds = Array(Set(members.map(\.localizedTitle))).sorted().prefix(3).joined(separator: ", ")
            return AuditFinding(
                id: "responsive.\(severity.rawValue)", category: .responsive, severity: severity,
                title: String(localized: "Layout issues at this width"),
                detail: kinds,
                count: members.count
            )
        }
    }

    static func networkFindings(_ network: APIClient.VisualNetworkDTO?) -> [AuditFinding] {
        var result: [AuditFinding] = []
        if let failed = network?.failedRequests, !failed.isEmpty {
            result.append(AuditFinding(
                id: "network.failed", category: .network, severity: .warning,
                title: String(localized: "Failed requests"),
                detail: String(localized: "Resources that returned an error or never loaded."),
                count: failed.count
            ))
        }
        if let large = network?.largeRequests, !large.isEmpty {
            result.append(AuditFinding(
                id: "network.large", category: .network, severity: .info,
                title: String(localized: "Large downloads"),
                detail: String(localized: "Heavy resources slow the first visit, especially on mobile."),
                count: large.count
            ))
        }
        return result
    }

    static func consoleFindings(_ messages: [APIClient.VisualConsoleMessageDTO]) -> [AuditFinding] {
        let errors = messages.filter { ($0.type ?? "").lowercased() == "error" }
        guard !errors.isEmpty else { return [] }
        return [AuditFinding(
            id: "console.errors", category: .console, severity: .warning,
            title: String(localized: "JavaScript errors"),
            detail: String(localized: "The page logged errors to the console while loading."),
            count: errors.count
        )]
    }
}

/// What one viewport looks like in numbers, for comparing breakpoints side by
/// side.
struct ViewportSummary: Identifiable, Sendable {
    let name: String
    let width: Int
    let height: Int
    let largestFontSize: Double?
    let smallestFontSize: Double?
    let sampledElements: Int
    let responsiveIssues: Int
    let highSeverityIssues: Int
    let contrastFailures: Int
    let score: Int

    var id: String { name }

    init(_ viewport: APIClient.VisualViewportDTO) {
        let samples = viewport.elementSamples ?? []
        let sizes = samples.compactMap { sample -> Double? in
            guard sample.fontSize.hasSuffix("px"), !sample.text.isEmpty else { return nil }
            return Double(sample.fontSize.dropLast(2))
        }
        let audit = DesignAudit.run(viewport)
        name = viewport.name
        width = viewport.width
        height = viewport.height
        largestFontSize = sizes.max()
        smallestFontSize = sizes.min()
        sampledElements = samples.count
        responsiveIssues = viewport.responsiveIssues?.count ?? 0
        highSeverityIssues = viewport.responsiveIssues?.filter { $0.severity.lowercased() == "high" }.count ?? 0
        contrastFailures = audit.contrastPairs.filter { $0.rating == .fail }.count
        score = audit.score
    }
}

extension APIClient.VisualResponsiveIssueDTO {
    /// The backend writes issue titles in English; known kinds get the app's
    /// translation, so the audit summary and the issue list say the same.
    var localizedTitle: String {
        switch kind {
        case "missing_viewport_meta": String(localized: "Mobile viewport configuration is missing")
        case "horizontal_overflow": String(localized: "Page overflows horizontally")
        case "offscreen_element": String(localized: "Element extends beyond the viewport")
        case "clipped_content": String(localized: "Content may be clipped")
        case "small_text": String(localized: "Very small text")
        case "small_touch_target": String(localized: "Small touch target")
        case "large_sticky_element": String(localized: "Sticky element covers much of the viewport")
        case "overlapping_controls": String(localized: "Interactive controls overlap")
        default: Bundle.main.localizedString(forKey: title, value: title, table: nil)
        }
    }
}
