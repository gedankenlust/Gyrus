import SwiftUI

// MARK: Shared audit styling

/// Green, orange or red. The thresholds are coarse on purpose: the score itself
/// is only a rough guide, so the color should not suggest finer distinctions.
func designScoreColor(_ score: Int) -> Color {
    switch score {
    case 85...: .green
    case 60..<85: .orange
    default: .red
    }
}

extension AuditSeverity {
    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    var systemImage: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

extension ContrastRating {
    var color: Color {
        switch self {
        case .aaa: .green
        case .aa: .teal
        case .fail: .red
        }
    }
}

/// The audit score as a ring that fills up to the score.
struct DesignScoreGauge: View {
    let score: Int
    var diameter: CGFloat = 44

    private var lineWidth: CGFloat { max(3, diameter / 11) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                .stroke(designScoreColor(score), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(score)")
                .font(.system(size: diameter * 0.34, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Design score"))
        .accessibilityValue(Text("\(score) of 100"))
    }
}

/// Critical / warning / notice counts in one line.
struct DesignSeverityCounts: View {
    let audit: DesignAudit

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AuditSeverity.allCases.reversed(), id: \.self) { severity in
                let count = audit.count(severity)
                HStack(spacing: 3) {
                    Image(systemName: severity.systemImage)
                        .foregroundStyle(count > 0 ? severity.color : Color.secondary)
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                    Text(verbatim: severity.title(count: count))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(severity.title): \(count)"))
            }
        }
    }
}

// MARK: Audit section

/// The prioritized checklist for one viewport, then the contrast pairs it is
/// based on, then the raw evidence behind every other finding.
struct DesignAuditView: View {
    let viewport: APIClient.VisualViewportDTO

    var body: some View {
        // Computed once per render and handed down, never inside a ForEach.
        let audit = DesignAudit.run(viewport)

        VStack(alignment: .leading, spacing: 20) {
            scoreHeader(audit)
            findings(audit)
            DesignContrastList(pairs: audit.contrastPairs)
            DesignAuditEvidence(viewport: viewport)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreHeader(_ audit: DesignAudit) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                DesignScoreGauge(score: audit.score, diameter: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Design score")
                        .font(.headline)
                    DesignSeverityCounts(audit: audit)
                    Text("Starts at 100 and loses points per finding. A guide for comparing pages, not a standard.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func findings(_ audit: DesignAudit) -> some View {
        if audit.findings.isEmpty {
            Label("No problems found in this viewport.", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(AuditCategory.allCases) { category in
                    let members = audit.findings(in: category)
                    if !members.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text(verbatim: category.title)
                            } icon: {
                                Image(systemName: category.systemImage)
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                            ForEach(members) { finding in
                                DesignFindingRow(finding: finding)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DesignFindingRow: View {
    let finding: AuditFinding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity.systemImage)
                .foregroundStyle(finding.severity.color)
                .help(Text(verbatim: finding.severity.title))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: finding.title)
                    .font(.caption.weight(.semibold))
                if !finding.detail.isEmpty {
                    Text(verbatim: finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            if finding.count > 0 {
                Text(verbatim: "\(finding.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Affected elements, requests or messages")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(finding.severity.title): \(finding.title)"))
        .accessibilityValue(Text(verbatim: finding.count > 0 ? "\(finding.count)" : ""))
        .accessibilityHint(Text(verbatim: finding.detail))
    }
}

// MARK: Contrast

/// Failing pairs first and always visible; passing ones folded away, because
/// they are only interesting once the failures are fixed.
struct DesignContrastList: View {
    let pairs: [ContrastPair]

    var body: some View {
        let failing = pairs.filter { $0.rating == .fail }
        let passing = pairs.filter { $0.rating != .fail }

        SnapshotSection(title: "Contrast", icon: "circle.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 8) {
                if pairs.isEmpty {
                    Text("No sampled text to measure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Text and background pairs from the sampled elements, rated against WCAG 2.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if failing.isEmpty {
                        Label("Every sampled pair meets WCAG AA.", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(failing) { DesignContrastRow(pair: $0) }

                    if !passing.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(passing) { DesignContrastRow(pair: $0) }
                            }
                            .padding(.top, 6)
                        } label: {
                            HStack {
                                Text("Passing pairs")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(verbatim: "\(passing.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if pairs.contains(where: \.backgroundIsAssumed) {
                        Label(
                            "Pairs marked “background assumed” had no sampled element painting behind them, so white was assumed. Their ratio is an estimate.",
                            systemImage: "questionmark.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct DesignContrastRow: View {
    let pair: ContrastPair

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DesignContrastChip(foregroundHex: pair.foregroundHex, backgroundHex: pair.backgroundHex,
                               isLargeText: pair.isLargeText)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: pair.formattedRatio)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    DesignRatingBadge(rating: pair.rating)
                    if pair.isLargeText {
                        Text("Large text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("At least 24 px, or 18.66 px bold: WCAG allows a lower contrast here.")
                    }
                }
                Text("\(pair.foregroundHex.uppercased()) on \(pair.backgroundHex.uppercased())")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                ForEach(Array(pair.examples.enumerated()), id: \.offset) { _, example in
                    Text(verbatim: example)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(example)
                }
                if pair.backgroundIsAssumed {
                    Text("Background assumed")
                        .font(.caption2.italic())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Text(verbatim: "\(pair.occurrences)×")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Sampled elements using this pair")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

/// "Aa" painted exactly as the page paints it. The page colors are literal, so
/// the chip looks the same in light and dark mode; the hairline keeps a white
/// background visible on a light window.
struct DesignContrastChip: View {
    let foregroundHex: String
    let backgroundHex: String
    var isLargeText = false

    var body: some View {
        Text(verbatim: "Aa")
            .font(.system(size: 15, weight: isLargeText ? .bold : .regular))
            .foregroundStyle(Color(hexString: foregroundHex) ?? .primary)
            .frame(width: 44, height: 32)
            .background(Color(hexString: backgroundHex) ?? .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct DesignRatingBadge: View {
    let rating: ContrastRating

    var body: some View {
        Text(verbatim: rating.label)
            .font(.caption2.bold())
            .foregroundStyle(rating.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(rating.color.opacity(0.15), in: Capsule())
            .accessibilityLabel(Text("WCAG rating: \(rating.label)"))
    }
}
