import Foundation

enum DesignTokenGroup: String, CaseIterable, Identifiable, Sendable {
    case color
    case fontFamily
    case fontSize
    case fontWeight
    case spacing
    case radius
    case shadow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: String(localized: "Colors")
        case .fontFamily: String(localized: "Font Families")
        case .fontSize: String(localized: "Font Sizes")
        case .fontWeight: String(localized: "Font Weights")
        case .spacing: String(localized: "Spacing")
        case .radius: String(localized: "Corner Radius")
        case .shadow: String(localized: "Shadows")
        }
    }

    /// Key of the group in Tailwind's `theme.extend`.
    fileprivate var tailwindKey: String {
        switch self {
        case .color: "colors"
        case .fontFamily: "fontFamily"
        case .fontSize: "fontSize"
        case .fontWeight: "fontWeight"
        case .spacing: "spacing"
        case .radius: "borderRadius"
        case .shadow: "boxShadow"
        }
    }
}

struct DesignToken: Identifiable, Hashable, Sendable {
    let group: DesignTokenGroup
    /// Full token name, used as the CSS custom property (`--space-16`).
    let name: String
    /// The name without its group prefix, used as the Tailwind key (`16`).
    let shortName: String
    let value: String
    /// How many sampled elements use the value. Authored CSS variables count 0.
    let usage: Int
    /// True when the name comes from a custom property the site declares.
    let isAuthored: Bool

    var id: String { "\(group.rawValue)|\(name)" }
    var cssVariable: String { "--\(name)" }
}

enum DesignTokenFormat: String, CaseIterable, Identifiable, Sendable {
    case css
    case json
    case tailwind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .css: String(localized: "CSS Custom Properties")
        case .json: String(localized: "Design Tokens JSON")
        case .tailwind: String(localized: "Tailwind Theme")
        }
    }

    var fileExtension: String {
        switch self {
        case .css: "css"
        case .json: "tokens.json"
        case .tailwind: "tailwind.config.js"
        }
    }
}

/// The design decisions a page repeats, lifted into named tokens.
///
/// Values come from the sampled elements, so they describe what the page
/// renders, not every rule in its stylesheets. Colors the site names in custom
/// properties keep those names, because they are the ones a designer would
/// recognize.
struct DesignTokenSet: Sendable {
    let tokens: [DesignToken]

    var isEmpty: Bool { tokens.isEmpty }

    func tokens(in group: DesignTokenGroup) -> [DesignToken] {
        tokens.filter { $0.group == group }
    }

    static func extract(
        samples: [APIClient.VisualElementSampleDTO],
        cssVariables: [APIClient.VisualCSSVariableDTO]
    ) -> DesignTokenSet {
        var tokens: [DesignToken] = []
        tokens += colorTokens(samples: samples, cssVariables: cssVariables)
        tokens += fontFamilyTokens(samples)
        tokens += lengthTokens(samples.map(\.fontSize), group: .fontSize, prefix: "text", limit: 12)
        tokens += fontWeightTokens(samples)
        tokens += spacingTokens(samples)
        tokens += radiusTokens(samples)
        tokens += shadowTokens(samples)
        return DesignTokenSet(tokens: tokens)
    }

    // MARK: Extraction

    private static func colorTokens(
        samples: [APIClient.VisualElementSampleDTO],
        cssVariables: [APIClient.VisualCSSVariableDTO]
    ) -> [DesignToken] {
        var names = UniqueNames()
        var result: [DesignToken] = []
        var coveredHexes = Set<String>()

        for entry in cssVariables.colorTokens(limit: 24) {
            let name = names.claim(slug(entry.caption, fallback: "color"))
            result.append(DesignToken(group: .color, name: name, shortName: name, value: entry.hex,
                                      usage: 0, isAuthored: true))
            coveredHexes.insert(entry.hex)
        }

        var counters: [String: Int] = [:]
        for entry in samples.paintedPalette(limit: 16) where !coveredHexes.contains(entry.hex) {
            let role: String = switch entry.caption {
            case "text": "text"
            case "surface": "surface"
            default: "color"
            }
            counters[role, default: 0] += 1
            let name = names.claim("\(role)-\(counters[role]!)")
            result.append(DesignToken(group: .color, name: name, shortName: name, value: entry.hex,
                                      usage: entry.occurrences, isAuthored: false))
        }
        return result
    }

    private static func fontFamilyTokens(_ samples: [APIClient.VisualElementSampleDTO]) -> [DesignToken] {
        var names = UniqueNames()
        return ranked(samples.map(\.fontFamily), limit: 4).map { value, count in
            let first = fontFamilyList(value).first ?? value
            let short = names.claim(slug(first, fallback: "font"))
            return DesignToken(group: .fontFamily, name: "font-\(short)", shortName: short,
                               value: value, usage: count, isAuthored: false)
        }
    }

    private static func fontWeightTokens(_ samples: [APIClient.VisualElementSampleDTO]) -> [DesignToken] {
        ranked(samples.map(\.fontWeight).filter { Int($0) != nil }, limit: 6)
            .sorted { (Int($0.value) ?? 0) < (Int($1.value) ?? 0) }
            .map { value, count in
                DesignToken(group: .fontWeight, name: "weight-\(value)", shortName: value,
                            value: value, usage: count, isAuthored: false)
            }
    }

    private static func spacingTokens(_ samples: [APIClient.VisualElementSampleDTO]) -> [DesignToken] {
        let edges = samples.flatMap { sample in
            (sample.padding + " " + sample.margin).split(separator: " ").map(String.init)
        }
        return lengthTokens(edges, group: .spacing, prefix: "space", limit: 12)
    }

    private static func radiusTokens(_ samples: [APIClient.VisualElementSampleDTO]) -> [DesignToken] {
        var names = UniqueNames()
        let values = samples.map(\.borderRadius).filter { value in
            value.split(separator: " ").contains { (cssLengthValue(String($0)) ?? 0) > 0 }
        }
        return ranked(values, limit: 6)
            .sorted { (cssLengthValue($0.value) ?? 0) < (cssLengthValue($1.value) ?? 0) }
            .map { value, count in
                // Pill shapes are written as a huge radius; the number itself
                // carries no meaning, so they get the conventional name.
                let leading = cssLengthValue(value) ?? 0
                let base = leading >= 999 || value.contains("%") && leading >= 50 ? "full" : number(leading)
                let short = names.claim(base)
                return DesignToken(group: .radius, name: "radius-\(short)", shortName: short,
                                   value: value, usage: count, isAuthored: false)
            }
    }

    private static func shadowTokens(_ samples: [APIClient.VisualElementSampleDTO]) -> [DesignToken] {
        let values = samples.map(\.boxShadow).filter {
            let lowered = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !lowered.isEmpty && lowered != "none"
        }
        return ranked(values, limit: 6).enumerated().map { index, entry in
            DesignToken(group: .shadow, name: "shadow-\(index + 1)", shortName: "\(index + 1)",
                        value: entry.value, usage: entry.count, isAuthored: false)
        }
    }

    /// The most used px lengths, presented ascending. Other units are left out
    /// because computed styles resolve them to px anyway; what remains is
    /// usually `auto` or `normal`.
    private static func lengthTokens(
        _ raw: [String], group: DesignTokenGroup, prefix: String, limit: Int
    ) -> [DesignToken] {
        let lengths = raw.compactMap { value -> String? in
            let token = value.trimmingCharacters(in: .whitespaces).lowercased()
            guard token.hasSuffix("px"), let pixels = Double(token.dropLast(2)), pixels > 0 else { return nil }
            return "\(number(pixels))px"
        }
        return ranked(lengths, limit: limit)
            .sorted { (cssLengthValue($0.value) ?? 0) < (cssLengthValue($1.value) ?? 0) }
            .map { value, count in
                let short = slug(String(value.dropLast(2)), fallback: "0")
                return DesignToken(group: group, name: "\(prefix)-\(short)", shortName: short,
                                   value: value, usage: count, isAuthored: false)
            }
    }

    // MARK: Export

    func export(_ format: DesignTokenFormat, source: String? = nil) -> String {
        switch format {
        case .css: cssExport(source: source)
        case .json: jsonExport()
        case .tailwind: tailwindExport(source: source)
        }
    }

    private func cssExport(source: String?) -> String {
        var lines = ["/* Design tokens extracted by Gyrus\(source.map { " from \($0)" } ?? ""). */", ":root {"]
        for group in DesignTokenGroup.allCases {
            let members = tokens(in: group)
            guard !members.isEmpty else { continue }
            if lines.count > 2 { lines.append("") }
            lines.append("  /* \(group.rawValue) */")
            for token in members {
                lines.append("  \(token.cssVariable): \(token.value);")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// W3C Design Tokens Community Group format, which Style Dictionary,
    /// Tokens Studio and Figma variables importers read.
    private func jsonExport() -> String {
        var root: [String: Any] = [:]
        for group in DesignTokenGroup.allCases {
            let members = tokens(in: group)
            guard !members.isEmpty else { continue }
            var entries: [String: Any] = [:]
            for token in members {
                var entry: [String: Any] = [:]
                switch group {
                case .color:
                    entry["$type"] = "color"
                    entry["$value"] = token.value
                case .fontFamily:
                    entry["$type"] = "fontFamily"
                    entry["$value"] = Self.fontFamilyList(token.value)
                case .fontSize, .spacing:
                    entry["$type"] = "dimension"
                    entry["$value"] = token.value
                case .fontWeight:
                    entry["$type"] = "fontWeight"
                    entry["$value"] = Int(token.value) ?? token.value
                case .radius:
                    // A shorthand with several corners is not a single
                    // dimension, so only the simple case gets the type.
                    if !token.value.contains(" ") { entry["$type"] = "dimension" }
                    entry["$value"] = token.value
                case .shadow:
                    entry["$value"] = token.value
                    entry["$description"] = "CSS box-shadow"
                }
                entries[token.shortName] = entry
            }
            root[group.rawValue] = entries
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}\n" }
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private func tailwindExport(source: String?) -> String {
        var lines = [
            "// Design tokens extracted by Gyrus\(source.map { " from \($0)" } ?? "").",
            "/** @type {import('tailwindcss').Config} */",
            "module.exports = {",
            "  theme: {",
            "    extend: {",
        ]
        for group in DesignTokenGroup.allCases {
            let members = tokens(in: group)
            guard !members.isEmpty else { continue }
            lines.append("      \(group.tailwindKey): {")
            for token in members {
                let value: String = switch group {
                case .fontFamily:
                    "[" + Self.fontFamilyList(token.value).map(Self.jsString).joined(separator: ", ") + "]"
                default:
                    Self.jsString(token.value)
                }
                lines.append("        \(Self.jsString(token.shortName)): \(value),")
            }
            lines.append("      },")
        }
        lines += ["    },", "  },", "};"]
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers

    /// `"Inter", Helvetica, sans-serif` → `["Inter", "Helvetica", "sans-serif"]`.
    static func fontFamilyList(_ stack: String) -> [String] {
        stack.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return "'\(escaped)'"
    }

    /// Lowercase letters, digits and single dashes; never empty.
    static func slug(_ raw: String, fallback: String) -> String {
        var result = ""
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty && !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }

    /// `16.0` → `"16"`, `18.5` → `"18.5"`.
    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }

    /// Values by how often they occur, most frequent first, ties by value so
    /// the result is stable.
    private static func ranked(_ values: [String], limit: Int) -> [(value: String, count: Int)] {
        let counts = Dictionary(grouping: values.filter { !$0.isEmpty }, by: { $0 }).mapValues(\.count)
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(limit)
            .map { (value: $0.key, count: $0.value) }
    }
}

/// Hands out names that are unique within one group by appending -2, -3 …
private struct UniqueNames {
    private var used = Set<String>()

    mutating func claim(_ base: String) -> String {
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}
