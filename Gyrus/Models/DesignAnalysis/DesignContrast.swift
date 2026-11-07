import Foundation

/// An sRGB color with channels in 0...1, parsed from the `#rrggbb` strings that
/// `SnapshotColor.normalize` produces.
struct RGBColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let packed = UInt32(value, radix: 16) else { return nil }
        red = Double((packed >> 16) & 0xff) / 255
        green = Double((packed >> 8) & 0xff) / 255
        blue = Double(packed & 0xff) / 255
    }

    /// WCAG 2.x relative luminance.
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

enum WCAGContrast {
    /// The contrast ratio between two colors, 1...21, independent of order.
    static func ratio(_ first: RGBColor, _ second: RGBColor) -> Double {
        let lighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func ratio(hex first: String, hex second: String) -> Double? {
        guard let a = RGBColor(hex: first), let b = RGBColor(hex: second) else { return nil }
        return ratio(a, b)
    }

    /// WCAG "large text": at least 24 CSS px, or 18.66 px (14 pt) when bold.
    static func isLargeText(fontSize: String, fontWeight: String) -> Bool {
        guard let pixels = cssPixels(fontSize) else { return false }
        let weight = Int(fontWeight.trimmingCharacters(in: .whitespaces))
            ?? (fontWeight.lowercased().contains("bold") ? 700 : 400)
        return pixels >= 24 || (pixels >= 18.66 && weight >= 700)
    }

    /// Computed styles always serialize font sizes in px; anything else is
    /// treated as unknown rather than guessed.
    private static func cssPixels(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasSuffix("px") else { return nil }
        return Double(trimmed.dropLast(2))
    }
}

/// How a text/background pair fares against WCAG 2.x success criterion 1.4.3
/// (AA) and 1.4.6 (AAA).
enum ContrastRating: Int, Comparable, Sendable {
    case fail = 0
    case aa = 1
    case aaa = 2

    static func < (lhs: ContrastRating, rhs: ContrastRating) -> Bool { lhs.rawValue < rhs.rawValue }

    init(ratio: Double, isLargeText: Bool) {
        let aaThreshold = isLargeText ? 3.0 : 4.5
        let aaaThreshold = isLargeText ? 4.5 : 7.0
        if ratio >= aaaThreshold {
            self = .aaa
        } else if ratio >= aaThreshold {
            self = .aa
        } else {
            self = .fail
        }
    }

    var label: String {
        switch self {
        case .fail: String(localized: "Fails")
        case .aa: "AA"
        case .aaa: "AAA"
        }
    }
}

/// One text color painted over one background, with every element that uses
/// the combination.
struct ContrastPair: Identifiable, Hashable, Sendable {
    let foregroundHex: String
    let backgroundHex: String
    let ratio: Double
    let isLargeText: Bool
    let rating: ContrastRating
    let occurrences: Int
    /// Up to three selector hints with their text, to find the element again.
    let examples: [String]
    /// True when no sampled ancestor declared a background and white was
    /// assumed. The ratio is then a best guess, not a measurement.
    let backgroundIsAssumed: Bool

    var id: String { "\(foregroundHex)|\(backgroundHex)|\(isLargeText)" }

    /// Uses the reader's decimal separator, so the German audit text reads
    /// "1,20:1" next to the "4,5:1" threshold instead of mixing separators.
    var formattedRatio: String { ratio.formatted(.number.precision(.fractionLength(2))) + ":1" }
}

enum ContrastAnalyzer {
    /// The background a page shows when nothing paints one: browsers default
    /// the canvas to white.
    static let canvasHex = "#ffffff"

    /// Text/background pairs found in the sampled elements, failures first.
    ///
    /// Computed styles report `transparent` for most text elements, because
    /// the color behind them comes from an ancestor. The sample set has no DOM
    /// tree, so the nearest painted ancestor is approximated by the smallest
    /// sampled box that encloses the element and has an opaque background,
    /// falling back to `body` and then to the white canvas.
    static func pairs(in samples: [APIClient.VisualElementSampleDTO]) -> [ContrastPair] {
        let painted = samples.compactMap { sample -> (rect: SampleRect, hex: String)? in
            guard let color = SnapshotColor.normalize(sample.backgroundColor) else { return nil }
            return (SampleRect(sample), color.hex)
        }
        let bodyHex = samples
            .first { $0.tag.lowercased() == "body" }
            .flatMap { SnapshotColor.normalize($0.backgroundColor)?.hex }

        var buckets: [String: PairAccumulator] = [:]
        var order: [String] = []

        for sample in samples {
            let text = sample.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let foreground = SnapshotColor.normalize(sample.color) else { continue }

            let backgroundHex: String
            var assumed = false
            if let own = SnapshotColor.normalize(sample.backgroundColor) {
                backgroundHex = own.hex
            } else {
                let rect = SampleRect(sample)
                let enclosing = painted
                    .filter { $0.rect != rect && $0.rect.contains(rect) }
                    .min { $0.rect.area < $1.rect.area }
                if let enclosing {
                    backgroundHex = enclosing.hex
                } else if let bodyHex {
                    backgroundHex = bodyHex
                } else {
                    backgroundHex = canvasHex
                    assumed = true
                }
            }

            let isLarge = WCAGContrast.isLargeText(fontSize: sample.fontSize, fontWeight: sample.fontWeight)
            let key = "\(foreground.hex)|\(backgroundHex)|\(isLarge)"
            var bucket: PairAccumulator
            if let existing = buckets[key] {
                bucket = existing
            } else {
                guard let ratio = WCAGContrast.ratio(hex: foreground.hex, hex: backgroundHex) else { continue }
                bucket = PairAccumulator(
                    foregroundHex: foreground.hex, backgroundHex: backgroundHex,
                    ratio: ratio, isLargeText: isLarge
                )
                order.append(key)
            }
            bucket.occurrences += 1
            bucket.assumed = bucket.assumed || assumed
            if bucket.examples.count < 3 {
                bucket.examples.append("\(sample.selectorHint) “\(text.prefix(40))”")
            }
            buckets[key] = bucket
        }

        return order.compactMap { buckets[$0] }
            .map { bucket in
                ContrastPair(
                    foregroundHex: bucket.foregroundHex,
                    backgroundHex: bucket.backgroundHex,
                    ratio: bucket.ratio,
                    isLargeText: bucket.isLargeText,
                    rating: ContrastRating(ratio: bucket.ratio, isLargeText: bucket.isLargeText),
                    occurrences: bucket.occurrences,
                    examples: bucket.examples,
                    backgroundIsAssumed: bucket.assumed
                )
            }
            // Worst first; ties keep a stable order so the list doesn't jump
            // between renders.
            .sorted { lhs, rhs in
                if lhs.rating != rhs.rating { return lhs.rating < rhs.rating }
                if lhs.ratio != rhs.ratio { return lhs.ratio < rhs.ratio }
                return lhs.id < rhs.id
            }
    }
}

private struct PairAccumulator {
    let foregroundHex: String
    let backgroundHex: String
    let ratio: Double
    let isLargeText: Bool
    var occurrences = 0
    var assumed = false
    var examples: [String] = []
}

private struct SampleRect: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ sample: APIClient.VisualElementSampleDTO) {
        x = sample.x
        y = sample.y
        width = max(sample.width, 0)
        height = max(sample.height, 0)
    }

    var area: Int { width * height }

    func contains(_ other: SampleRect) -> Bool {
        other.x >= x && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }
}
