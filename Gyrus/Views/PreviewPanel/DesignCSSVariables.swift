import SwiftUI
import AppKit

extension Array where Element == APIClient.VisualCSSVariableDTO {
    /// Custom properties whose value is a color. These are the site's authored
    /// tokens, which is what a designer is usually after, and they were
    /// previously only reachable as text inside the variable dump.
    func colorTokens(limit: Int = 24) -> [PaletteEntry] {
        var seen = Set<String>()
        var result: [PaletteEntry] = []
        for variable in self {
            guard let color = SnapshotColor.normalize(variable.value) else { continue }
            let key = "\(variable.name)|\(color.hex)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(PaletteEntry(hex: color.hex, caption: variable.name, area: 0, occurrences: 1))
            if result.count >= limit { break }
        }
        return result
    }
}

/// Declared at file scope because `Array` extensions are generic contexts, and
/// Swift does not allow a type to be nested inside a generic function.
private struct PaletteAccumulator {
    var roles: Set<String> = []
    var area: Double = 0
    var occurrences: Int = 0
}

extension Array where Element == APIClient.VisualElementSampleDTO {
    /// The palette as painted: every sampled element contributes its text color
    /// and its background color, weighted by the area it occupies.
    func paintedPalette(limit: Int = 24) -> [PaletteEntry] {
        var buckets: [String: PaletteAccumulator] = [:]

        func add(_ raw: String, role: String, area: Double) {
            guard let color = SnapshotColor.normalize(raw) else { return }
            var bucket = buckets[color.hex] ?? PaletteAccumulator()
            bucket.roles.insert(role)
            bucket.area += area
            bucket.occurrences += 1
            buckets[color.hex] = bucket
        }

        for sample in self {
            // Swift.max, not Array.max(): inside an Array extension the bare
            // name resolves to the instance method.
            let area = Double(Swift.max(sample.width, 0)) * Double(Swift.max(sample.height, 0))
            add(sample.color, role: "text", area: area)
            add(sample.backgroundColor, role: "surface", area: area)
        }

        // Ties broken by hex so the order is stable between renders.
        return buckets
            .map { hex, bucket in
                PaletteEntry(
                    hex: hex,
                    caption: bucket.roles.sorted().joined(separator: " · "),
                    area: bucket.area,
                    occurrences: bucket.occurrences
                )
            }
            .sorted { lhs, rhs in
                if lhs.area == rhs.area { return lhs.hex < rhs.hex }
                return lhs.area > rhs.area
            }
            .prefix(limit)
            .map { $0 }
    }
}

struct CSSVariableGroup: Identifiable {
    let key: String
    let title: LocalizedStringKey
    let variables: [APIClient.VisualCSSVariableDTO]
    /// Framework bookkeeping is kept, not dropped, but folded away.
    let collapsed: Bool

    var id: String { key }
}

/// Sorts custom properties by the shape of their VALUE, never by their name.
///
/// Name-based rules look tempting — drop everything starting with `--tw-` — but
/// they are wrong in both directions: Tailwind v4 emits genuine `@theme` tokens
/// as `--color-*` and `--spacing-*`, and every Bootstrap token carries a `--bs-`
/// prefix. Value grammar is framework-agnostic and does not misclassify either.
func groupCSSVariables(_ variables: [APIClient.VisualCSSVariableDTO]) -> [CSSVariableGroup] {
    // Values a framework leaves on :root purely so a later rule can override
    // them. They carry no design decision.
    let sentinels: Set<String> = [
        "", "0", "0s", "0px", "none", "solid", "initial", "auto",
        // Lowercase throughout: these are compared against `lowered`.
        "0 0 #0000", "border-box", "content-box", "translatex(0)", "translate(0)",
        "100%", "1", "normal",
    ]

    var colors: [APIClient.VisualCSSVariableDTO] = []
    var shadows: [APIClient.VisualCSSVariableDTO] = []
    var motion: [APIClient.VisualCSSVariableDTO] = []
    var fonts: [APIClient.VisualCSSVariableDTO] = []
    var sizes: [APIClient.VisualCSSVariableDTO] = []
    var other: [APIClient.VisualCSSVariableDTO] = []
    var internals: [APIClient.VisualCSSVariableDTO] = []

    for variable in variables {
        let value = variable.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()

        if sentinels.contains(lowered) {
            internals.append(variable)
            continue
        }
        if SnapshotColor.normalize(value) != nil {
            colors.append(variable)
            continue
        }
        // Shadows are checked before sizes because every shadow contains a length.
        let hasColor = lowered.contains("rgb") || lowered.contains("#") || lowered.contains("hsl") || lowered.contains("oklch")
        if hasColor && lowered.contains("px") {
            shadows.append(variable)
            continue
        }
        // Parenthesised deliberately: `&&` binds tighter than `||`, so the
        // earlier unparenthesised chain applied the numeric guard only to the
        // bare-"s" arm. Everything ending in the letters "ms" counted as a
        // duration, which filed a font stack named "Comic Sans MS" under Motion
        // before it could ever reach the font branch. Easings are matched
        // exactly rather than by substring, so a token like "increase" is safe.
        let easingKeywords: Set<String> = [
            "ease", "ease-in", "ease-out", "ease-in-out", "linear", "step-start", "step-end",
        ]
        let isDuration = (lowered.hasSuffix("ms") || lowered.hasSuffix("s")) && cssLengthValue(lowered) != nil
        if isDuration || easingKeywords.contains(lowered)
            || lowered.hasPrefix("cubic-bezier(") || lowered.hasPrefix("steps(") {
            motion.append(variable)
            continue
        }
        if lowered.contains(",") && (lowered.contains("sans-serif") || lowered.contains("serif")
            || lowered.contains("monospace") || lowered.contains("system-ui")) {
            fonts.append(variable)
            continue
        }
        let lengthUnits = ["px", "rem", "em", "vh", "vw", "vmin", "vmax", "ch", "%"]
        if lowered.hasPrefix("clamp(") || lowered.hasPrefix("calc(") || lowered.hasPrefix("min(")
            || lowered.hasPrefix("max(") || lengthUnits.contains(where: { lowered.hasSuffix($0) }) {
            sizes.append(variable)
            continue
        }
        other.append(variable)
    }

    return [
        CSSVariableGroup(key: "color", title: "Colors", variables: colors, collapsed: false),
        CSSVariableGroup(key: "size", title: "Sizing & spacing", variables: sizes, collapsed: false),
        CSSVariableGroup(key: "font", title: "Font stacks", variables: fonts, collapsed: false),
        CSSVariableGroup(key: "shadow", title: "Shadows", variables: shadows, collapsed: false),
        CSSVariableGroup(key: "motion", title: "Motion", variables: motion, collapsed: true),
        CSSVariableGroup(key: "other", title: "Other", variables: other, collapsed: true),
        CSSVariableGroup(key: "internals", title: "Framework internals", variables: internals, collapsed: true),
    ]
    .filter { !$0.variables.isEmpty }
}
