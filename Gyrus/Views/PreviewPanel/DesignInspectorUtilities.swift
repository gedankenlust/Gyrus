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
            guard hex.count == 7 else { return nil }
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

/// Keeps one decoded screenshot per viewport so that cropping thumbnails out of
/// it does not refetch and redecode a multi-megabyte PNG per component.
@MainActor
final class SnapshotImageStore {
    static let shared = SnapshotImageStore()

    private var cache: [String: NSImage] = [:]
    /// Insertion order, used to evict the oldest entry.
    private var order: [String] = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Three viewports for the current capture plus a little room for a run the
    /// user stepped back to. Full-page screenshots are large enough that an
    /// unbounded cache would matter.
    private let limit = 6

    func image(atPath path: String) async -> NSImage? {
        if let cached = cache[path] { return cached }
        if let running = inFlight[path] { return await running.value }

        let task = Task<NSImage?, Never> {
            let url = APIClient.shared.visualSnapshotFileURL(path: path)
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[path] = task
        let image = await task.value
        inFlight[path] = nil

        if let image {
            cache[path] = image
            order.append(path)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                cache[oldest] = nil
            }
        }
        return image
    }

    /// Cuts one element out of a full-page screenshot.
    ///
    /// Element geometry is in CSS pixels while the screenshot is captured at the
    /// device pixel ratio, so everything is scaled by the ratio between the
    /// image width and the viewport width.
    func crop(
        _ image: NSImage,
        x: Int, y: Int, width: Int, height: Int,
        viewportWidth: Int,
        padding: CGFloat = 6
    ) -> NSImage? {
        guard width > 0, height > 0, viewportWidth > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let scale = CGFloat(cgImage.width) / CGFloat(viewportWidth)
        let inset = padding * scale
        let rect = CGRect(
            x: CGFloat(x) * scale - inset,
            y: CGFloat(y) * scale - inset,
            width: CGFloat(width) * scale + inset * 2,
            height: CGFloat(height) * scale + inset * 2
        )
        // An element can sit at the very edge, and a rect reaching outside the
        // image makes `cropping(to:)` return nil rather than clamping.
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let clamped = rect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = cgImage.cropping(to: clamped)
        else { return nil }

        return NSImage(cgImage: cropped, size: NSSize(width: clamped.width / scale, height: clamped.height / scale))
    }
}

/// Parses the backend's `captured_at`, written as
/// `datetime.now(timezone.utc).isoformat()`, so with a UTC offset and six
/// fractional digits. Older runs may lack the fraction, hence the second pass.
func snapshotCaptureDate(_ raw: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: raw) { return date }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: raw)
}

func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

func viewportPDFData(
    snapshot: APIClient.VisualSnapshotDTO,
    pages: [(viewport: APIClient.VisualViewportDTO, image: NSImage)]
) -> Data? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data) else { return nil }
    var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

    let margin: CGFloat = 36
    let titleHeight: CGFloat = 54
    let pageWidth: CGFloat = 595
    let imageWidth = pageWidth - margin * 2

    for page in pages {
        guard let cgImage = page.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let imageSize = page.image.size
        let scale = imageWidth / max(imageSize.width, 1)
        let imageHeight = imageSize.height * scale
        let pageHeight = max(CGFloat(842), imageHeight + titleHeight + margin * 2)
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        context.beginPDFPage([kCGPDFContextMediaBox as String: pageRect] as CFDictionary)
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
        context.fill(pageRect)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title = "\(page.viewport.name.capitalized) \(page.viewport.width)x\(page.viewport.height)"
        let subtitle = snapshot.url
        (title as NSString).draw(
            in: CGRect(x: margin, y: pageHeight - margin - 22, width: imageWidth, height: 22),
            withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        (subtitle as NSString).draw(
            in: CGRect(x: margin, y: pageHeight - margin - 42, width: imageWidth, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSGraphicsContext.restoreGraphicsState()

        let imageRect = CGRect(x: margin, y: margin, width: imageWidth, height: imageHeight)
        context.interpolationQuality = .high
        context.draw(cgImage, in: imageRect)
        context.endPDFPage()
    }

    context.closePDF()
    return data as Data
}

func safeFilename(_ value: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let cleaned = value
        .components(separatedBy: illegal)
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "gyrus" : String(cleaned.prefix(80))
}

func reviewPreviewSize(for viewport: APIClient.VisualViewportDTO) -> CGSize {
    let scale = reviewPreviewScale(for: viewport)
    return CGSize(
        width: CGFloat(viewport.width) * scale,
        height: CGFloat(viewport.height) * scale
    )
}

func reviewPreviewScale(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    let viewportWidth = CGFloat(max(viewport.width, 1))
    let viewportHeight = CGFloat(max(viewport.height, 1))
    return min(
        1,
        max(0.18, reviewFrameMaxWidth(for: viewport) / viewportWidth),
        max(0.18, reviewFrameMaxHeight(for: viewport) / viewportHeight)
    )
}

func reviewFrameMaxWidth(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    switch viewport.name {
    case "desktop":
        620
    case "tablet":
        340
    case "mobile":
        220
    default:
        min(CGFloat(viewport.width), 620)
    }
}

func reviewFrameMaxHeight(for viewport: APIClient.VisualViewportDTO) -> CGFloat {
    switch viewport.name {
    case "desktop":
        420
    case "tablet":
        420
    case "mobile":
        420
    default:
        min(CGFloat(viewport.height), 560)
    }
}

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
func classifyComponents(_ samples: [APIClient.VisualElementSampleDTO]) -> [ComponentGroup] {
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
            variants: members.groupedVariants(),
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
