import SwiftUI
import AppKit

func frequency(_ values: [String], limit: Int = 8) -> [String] {
    let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
    return counts
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .prefix(limit)
        .map { "\($0.key) (\($0.value)x)" }
}

/// Sorts every sampled element into exactly one bucket.
///
/// The previous version ran five independent filters, so a `.card-btn` was
/// listed under both Cards and CTA and the counts added up to more than the
/// number of elements on the page. Categories are tried most-specific first and
/// each element is claimed once.
func classifyComponents(_ samples: [APIClient.VisualElementSampleDTO], limit: Int = 12) -> [ComponentGroup] {
    let formTags: Set<String> = ["form", "input", "textarea", "select", "label"]
    let navTags: Set<String> = ["nav", "header"]
    let sectionTags: Set<String> = ["main", "section", "article", "aside", "footer"]

    var forms: [APIClient.VisualElementSampleDTO] = []
    var cta: [APIClient.VisualElementSampleDTO] = []
    var navigation: [APIClient.VisualElementSampleDTO] = []
    var cards: [APIClient.VisualElementSampleDTO] = []
    var sections: [APIClient.VisualElementSampleDTO] = []

    for sample in samples {
        let tag = sample.tag.lowercased()
        let selector = sample.selectorHint.lowercased()

        if formTags.contains(tag) {
            forms.append(sample)
        } else if tag == "button" || selector.contains("btn") || selector.contains("cta") {
            cta.append(sample)
        } else if navTags.contains(tag) || selector.contains("nav") || selector.contains("menu") {
            navigation.append(sample)
        } else if selector.contains("card") || selector.contains("tile") {
            cards.append(sample)
        } else if sectionTags.contains(tag) || selector.contains("hero") || selector.contains("section") {
            sections.append(sample)
        }
    }

    func group(_ title: String, _ icon: String, _ members: [APIClient.VisualElementSampleDTO]) -> ComponentGroup {
        ComponentGroup(
            title: title,
            icon: icon,
            variants: members.groupedVariants(limit: limit),
            instanceCount: members.count
        )
    }

    return [
        group("Navigation", "point.3.connected.trianglepath.dotted", navigation),
        group("Hero / Sections", "rectangle.topthird.inset.filled", sections),
        group("CTA / Buttons", "button.programmable", cta),
        group("Cards", "rectangle.stack", cards),
        group("Forms", "rectangle.and.pencil.and.ellipsis", forms),
    ]
    .filter { !$0.variants.isEmpty }
}

/// Repeated instances of one component, collapsed into a single row.
struct ComponentVariant: Identifiable {
    let representative: APIClient.VisualElementSampleDTO
    let count: Int
    /// The differing copy across instances — what actually varies between them.
    let texts: [String]

    var id: String { representative.id }
}

extension Array where Element == APIClient.VisualElementSampleDTO {
    /// Collapses instances that share a visual signature.
    ///
    /// A component inventory exists to say "this pattern appears N times". The
    /// list used to render one row per instance, so two identical buttons read
    /// as two unrelated components. Position and copy are deliberately excluded
    /// from the key; everything that makes the thing *look* the way it does is
    /// included.
    func groupedVariants(limit: Int = 12) -> [ComponentVariant] {
        func signature(_ sample: APIClient.VisualElementSampleDTO) -> String {
            // Sizes are rounded to a 4px grid so that near-identical instances,
            // for example buttons whose width follows their label, still merge.
            let width = (sample.width / 4) * 4
            let height = (sample.height / 4) * 4
            return [
                sample.tag, sample.selectorHint, sample.fontSize, sample.fontWeight,
                sample.color, sample.backgroundColor, sample.borderRadius,
                sample.padding, sample.boxShadow, "\(width)x\(height)",
            ].joined(separator: "|")
        }

        var order: [String] = []
        var buckets: [String: [APIClient.VisualElementSampleDTO]] = [:]

        for sample in self {
            let key = signature(sample)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(sample)
        }

        return order.compactMap { key -> ComponentVariant? in
            guard let members = buckets[key], let first = members.first else { return nil }
            let texts = members
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var seen = Set<String>()
            let uniqueTexts = texts.filter { seen.insert($0).inserted }
            return ComponentVariant(representative: first, count: members.count, texts: uniqueTexts)
        }
        .sorted { $0.count > $1.count }
        .prefix(limit)
        .map { $0 }
    }
}
