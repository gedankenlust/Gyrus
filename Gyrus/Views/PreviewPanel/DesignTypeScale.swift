import SwiftUI
import AppKit

/// One rung of the site's type scale.
struct TypeScaleStep: Identifiable, Hashable {
    let pixels: Double
    let fontSize: String
    let fontWeight: String
    let fontFamily: String
    let lineHeight: String
    let letterSpacing: String
    let occurrences: Int
    /// A real sentence from the page, so the specimen shows the actual face.
    let specimen: String

    var id: String { "\(fontSize)|\(fontWeight)|\(fontFamily)" }

    var css: String {
        """
        font-family: \(fontFamily);
        font-size: \(fontSize);
        font-weight: \(fontWeight);
        line-height: \(lineHeight);
        letter-spacing: \(letterSpacing);
        """
    }
}

/// Leading number of a CSS length, ignoring its unit. Good enough for ordering.
func cssLengthValue(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let number = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" }
    return Double(number)
}

private struct TypeScaleAccumulator {
    var occurrences = 0
    var specimen = ""
}

extension Array where Element == APIClient.VisualElementSampleDTO {
    /// The type scale, which is the thing most worth lifting from a reference
    /// site. Every sample already carries size, weight, line height and
    /// tracking; until now only the bare font-family strings were shown and the
    /// rest sat unread inside a collapsed CSS blob.
    func typeScale(limit: Int = 12) -> [TypeScaleStep] {
        var buckets: [String: TypeScaleAccumulator] = [:]
        var meta: [String: APIClient.VisualElementSampleDTO] = [:]

        for sample in self {
            guard !sample.fontSize.isEmpty, cssLengthValue(sample.fontSize) != nil else { continue }
            let key = "\(sample.fontSize)|\(sample.fontWeight)|\(sample.fontFamily)"
            var bucket = buckets[key] ?? TypeScaleAccumulator()
            bucket.occurrences += 1
            // Prefer the longest text found for this step; it reads better as a
            // specimen than a one-word label.
            let text = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > bucket.specimen.count {
                bucket.specimen = String(text.prefix(90))
            }
            buckets[key] = bucket
            if meta[key] == nil { meta[key] = sample }
        }

        return buckets.compactMap { key, bucket -> TypeScaleStep? in
            guard let sample = meta[key], let pixels = cssLengthValue(sample.fontSize) else { return nil }
            return TypeScaleStep(
                pixels: pixels,
                fontSize: sample.fontSize,
                fontWeight: sample.fontWeight,
                fontFamily: sample.fontFamily,
                lineHeight: sample.lineHeight,
                letterSpacing: sample.letterSpacing,
                occurrences: bucket.occurrences,
                specimen: bucket.specimen
            )
        }
        // Every field of the identity takes part in the ordering. Dictionary
        // enumeration is unordered and Array.sort is not stable, so a tiebreak
        // that stopped at the weight let two rungs differing only by family
        // swap places — and swap which one survived the limit — between
        // launches.
        .sorted { lhs, rhs in
            if lhs.pixels != rhs.pixels { return lhs.pixels > rhs.pixels }
            if lhs.fontWeight != rhs.fontWeight { return lhs.fontWeight > rhs.fontWeight }
            return lhs.fontFamily < rhs.fontFamily
        }
        .prefix(limit)
        .map { $0 }
    }

    /// The spacing scale hiding inside padding and margin.
    ///
    /// `frequency()` used to run over whole shorthands like "16px 24px 16px
    /// 24px", so every distinct combination counted as its own value and the
    /// underlying 4/8/12/16/24 rhythm never became visible. Splitting the
    /// shorthand into its edges first is what turns it into a scale.
    func spacingScale(limit: Int = 12) -> [String] {
        // Keyed on the whole token, unit included: keying on the bare number
        // collapsed "1rem" and "1px" into one entry whose label was whichever
        // happened to be seen last.
        var counts: [String: Int] = [:]

        for sample in self {
            for shorthand in [sample.padding, sample.margin] {
                for edge in shorthand.split(separator: " ") {
                    let token = String(edge).lowercased()
                    guard let value = cssLengthValue(token), value > 0 else { continue }
                    counts[token, default: 0] += 1
                }
            }
        }

        // Take the most *used* steps, then present them ascending. Trimming a
        // list that was already sorted ascending kept the twelve smallest
        // values instead, so one-off 1px hairlines crowded out the 16/24/32
        // rhythm this is meant to reveal.
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .sorted { lhs, rhs in
                let left = cssLengthValue(lhs.key) ?? 0
                let right = cssLengthValue(rhs.key) ?? 0
                if left == right { return lhs.key < rhs.key }
                return left < right
            }
            .map { "\($0.key) (\($0.value)x)" }
    }
}
