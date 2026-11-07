import SwiftUI

/// The captured data behind the audit findings.
///
/// A finding says "3 buttons without an accessible name"; this is where the
/// three buttons are. Folded by default so the checklist above stays the first
/// thing you read.
struct DesignAuditEvidence: View {
    let viewport: APIClient.VisualViewportDTO

    private var accessibilityCount: Int {
        guard let accessibility = viewport.accessibility else { return 0 }
        return (accessibility.missingAltImages?.count ?? 0)
            + (accessibility.emptyButtons?.count ?? 0)
            + (accessibility.unlabeledInputs?.count ?? 0)
            + (accessibility.headingSkips?.count ?? 0)
    }

    private var networkCount: Int {
        (viewport.network?.failedRequests?.count ?? 0) + (viewport.network?.largeRequests?.count ?? 0)
    }

    var body: some View {
        SnapshotSection(title: "Evidence", icon: "doc.text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 8) {
                evidenceGroup("Accessibility", icon: "accessibility", count: accessibilityCount) {
                    accessibility
                }
                evidenceGroup("SEO", icon: "magnifyingglass", count: nil) {
                    seo
                }
                evidenceGroup("Network requests", icon: "network", count: networkCount) {
                    network
                }
                evidenceGroup("Console", icon: "terminal", count: viewport.consoleMessages?.count ?? 0) {
                    console
                }
            }
        }
    }

    private func evidenceGroup<Content: View>(
        _ title: LocalizedStringKey,
        icon: String,
        count: Int?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let body = content()
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) { body }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var accessibility: some View {
        if let accessibility = viewport.accessibility {
            if accessibilityCount == 0 {
                emptyNote("No accessibility problems were captured.")
            }
            AssetList(title: "Images Missing Alt", assets: accessibility.missingAltImages ?? [])
            A11yItemList(title: "Buttons Without Accessible Text", items: accessibility.emptyButtons ?? [])
            A11yItemList(title: "Inputs Without Labels", items: accessibility.unlabeledInputs ?? [])
            HeadingSkipList(skips: accessibility.headingSkips ?? [])
        } else {
            emptyNote("Reinspect this page to run accessibility checks.")
        }
    }

    @ViewBuilder
    private var seo: some View {
        let seo = viewport.seo
        let title = seo?.title ?? viewport.pageTitle ?? ""
        let description = seo?.metaDescription ?? viewport.metaDescription ?? ""

        InspectorField(title: "Page title", value: title)
        if !title.isEmpty {
            characterCount(title)
        }
        InspectorField(title: "Search description", value: description)
        if !description.isEmpty {
            characterCount(description)
        }
        InspectorField(title: "Language", value: seo?.language ?? "")
        InspectorField(title: "Robots", value: seo?.robots ?? "")
        InspectorField(title: "Canonical URL", value: seo?.canonical ?? "")
        MetaList(title: "Open Graph", items: seo?.openGraph ?? [])
    }

    private func characterCount(_ value: String) -> some View {
        Text("\(value.trimmingCharacters(in: .whitespacesAndNewlines).count) characters")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var network: some View {
        if let network = viewport.network {
            LabeledContent("Requests", value: network.requestCount.map(String.init) ?? "–")
                .font(.caption)
            if let counts = network.resourceCounts, !counts.isEmpty {
                InspectorList(title: "Resource Types", values: counts.map { "\($0.type): \($0.count)" })
            }
            if networkCount == 0 {
                emptyNote("No failed or unusually large requests.")
            }
            NetworkRequestList(title: "Failed Requests", requests: network.failedRequests ?? [])
            NetworkRequestList(title: "Large Requests", requests: network.largeRequests ?? [])
        } else {
            emptyNote("Network data was not captured.")
        }
    }

    @ViewBuilder
    private var console: some View {
        let messages = viewport.consoleMessages ?? []
        if messages.isEmpty {
            emptyNote("No console messages captured.")
        } else {
            ForEach(messages.prefix(80)) { message in
                CopyRow(value: "[\(message.type ?? "log")] \(message.text ?? "")", systemImage: "terminal")
            }
            if messages.count > 80 {
                Text("Showing the first 80 of \(messages.count) messages. The copied report contains all of them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
