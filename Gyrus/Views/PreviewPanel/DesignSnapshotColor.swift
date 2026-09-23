import SwiftUI
import AppKit

struct SnapshotColor: Identifiable, Hashable {
    let hex: String
    let source: String

    var id: String { hex }

    static func unique(from values: [String]) -> [SnapshotColor] {
        var seen = Set<String>()
        var result: [SnapshotColor] = []
        for value in values {
            guard let color = normalize(value), !seen.contains(color.hex) else { continue }
            seen.insert(color.hex)
            result.append(color)
        }
        return result
    }

    static func normalize(_ value: String) -> SnapshotColor? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        guard lowered != "transparent", lowered != "none", lowered != "currentcolor" else { return nil }

        if raw.hasPrefix("#") {
            var hex = raw
            if hex.count == 4 {
                let chars = Array(hex.dropFirst())
                hex = "#" + chars.map { "\($0)\($0)" }.joined()
            }
            guard hex.count == 7, UInt32(hex.dropFirst(), radix: 16) != nil else { return nil }
            return SnapshotColor(hex: hex.lowercased(), source: raw)
        }

        if lowered.hasPrefix("rgb") {
            guard let parts = components(of: raw), parts.count >= 3 else { return nil }
            if parts.count >= 4, parts[3].value == 0 { return nil }
            // A channel may be written 0-255 or as a percentage of full scale.
            func channel(_ part: ColorComponent) -> Double {
                part.unit == "%" ? part.value / 100 : part.value / 255
            }
            return SnapshotColor(hex: hexString(channel(parts[0]), channel(parts[1]), channel(parts[2])), source: raw)
        }

        // Chromium only serializes computed styles back to rgb() for legacy
        // color spaces. Values authored as hsl() or oklch() survive into
        // getComputedStyle unchanged, so without these two branches every such
        // color was silently discarded and never reached the palette.
        if lowered.hasPrefix("hsl") {
            guard let parts = components(of: raw), parts.count >= 3 else { return nil }
            if parts.count >= 4, parts[3].value == 0 { return nil }
            let (r, g, b) = hslToRGB(
                hue: parts[0].degrees,
                saturation: parts[1].value / 100,
                lightness: parts[2].value / 100
            )
            return SnapshotColor(hex: hexString(r, g, b), source: raw)
        }

        if lowered.hasPrefix("oklch") {
            guard let parts = components(of: raw), parts.count >= 3 else { return nil }
            if parts.count >= 4, parts[3].value == 0 { return nil }
            // Lightness is 0-1, or a percentage of that range. The unit has to
            // decide: guessing from magnitude misreads "oklch(1% 0 0)" — a very
            // dark color — as fully lit white.
            let lightness = parts[0].unit == "%" ? parts[0].value / 100 : parts[0].value
            let (r, g, b) = oklchToRGB(lightness: lightness, chroma: parts[1].value, hue: parts[2].degrees)
            return SnapshotColor(hex: hexString(r, g, b), source: raw)
        }

        return nil
    }

    /// One argument of a CSS color function, with its unit preserved.
    struct ColorComponent {
        let value: Double
        /// "%", "deg", "turn", "rad", "grad", or "" when the number is bare.
        let unit: String

        /// The component read as an angle. CSS allows every angle unit wherever
        /// a hue is expected, and a bare number means degrees.
        var degrees: Double {
            switch unit {
            case "turn": value * 360
            case "rad": value * 180 / .pi
            case "grad": value * 0.9
            default: value
            }
        }
    }

    /// Splits a CSS color function into its arguments, keeping units attached.
    ///
    /// Returns nil rather than skipping an argument it cannot read. The previous
    /// version `compactMap`ped failures away, so a single unparsed component
    /// silently shifted every later one into the wrong slot: `hsla(120deg, 100%,
    /// 50%, .5)` lost its hue and read the lightness as an alpha, landing on
    /// near-black instead of green.
    private static func components(of raw: String) -> [ColorComponent]? {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close else {
            return nil
        }
        let body = raw[raw.index(after: open)..<close]

        var parsed: [ColorComponent] = []
        for token in body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased() == "none" {
                // A missing component in the modern syntax means zero.
                parsed.append(ColorComponent(value: 0, unit: ""))
                continue
            }
            let numberPart = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
            guard let value = Double(numberPart) else { return nil }
            let unit = trimmed.dropFirst(numberPart.count).lowercased()
            parsed.append(ColorComponent(value: value, unit: String(unit)))
        }
        return parsed
    }

    private static func hexString(_ r: Double, _ g: Double, _ b: Double) -> String {
        func channel(_ value: Double) -> Int {
            max(0, min(255, Int((value * 255).rounded())))
        }
        return String(format: "#%02x%02x%02x", channel(r), channel(g), channel(b))
    }

    private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let s = max(0, min(1, saturation))
        let l = max(0, min(1, lightness))
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return (l, l, l) }

        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q

        func component(_ offset: Double) -> Double {
            var t = h + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }

        return (component(1.0 / 3), component(0), component(-1.0 / 3))
    }

    /// OKLCh -> OKLab -> linear sRGB -> gamma-encoded sRGB, using Björn
    /// Ottosson's published matrices. Out-of-gamut values are clamped by
    /// `hexString`, which is fine here: the swatch only has to be recognisable.
    private static func oklchToRGB(lightness: Double, chroma: Double, hue: Double) -> (Double, Double, Double) {
        let hueRadians = hue * .pi / 180
        let a = chroma * cos(hueRadians)
        let bComponent = chroma * sin(hueRadians)

        let l_ = lightness + 0.3963377774 * a + 0.2158037573 * bComponent
        let m_ = lightness - 0.1055613458 * a - 0.0638541728 * bComponent
        let s_ = lightness - 0.0894841775 * a - 1.2914855480 * bComponent

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        let red = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func gamma(_ value: Double) -> Double {
            let c = max(0, min(1, value))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }

        return (gamma(red), gamma(green), gamma(blue))
    }
}

/// A color the page actually declares, as opposed to one sampled out of the
/// rendered screenshot.
struct PaletteEntry: Identifiable, Hashable {
    let hex: String
    /// A token name such as `--gold`, or the roles a color is painted in.
    let caption: String
    /// Combined box area in px². Ordering only — the color covering the most
    /// surface is the one a designer reads as "the" background.
    let area: Double
    let occurrences: Int

    var id: String { "\(hex)|\(caption)" }
}

extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let intValue = Int(value, radix: 16) else { return nil }
        let red = Double((intValue >> 16) & 0xff) / 255
        let green = Double((intValue >> 8) & 0xff) / 255
        let blue = Double(intValue & 0xff) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
