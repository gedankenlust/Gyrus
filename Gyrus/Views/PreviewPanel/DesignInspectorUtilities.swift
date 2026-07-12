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
        guard !raw.isEmpty, raw.lowercased() != "transparent" else { return nil }

        if raw.hasPrefix("#") {
            var hex = raw
            if hex.count == 4 {
                let chars = Array(hex.dropFirst())
                hex = "#" + chars.map { "\($0)\($0)" }.joined()
            }
            guard hex.count == 7 else { return nil }
            return SnapshotColor(hex: hex.lowercased(), source: raw)
        }

        guard raw.lowercased().hasPrefix("rgb") else { return nil }
        let body = raw
            .replacingOccurrences(of: "rgba", with: "")
            .replacingOccurrences(of: "rgb", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = body
            .split { char in char == "," || char == " " || char == "/" }
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        if parts.count >= 4, parts[3] == 0 { return nil }
        let r = max(0, min(255, Int(parts[0].rounded())))
        let g = max(0, min(255, Int(parts[1].rounded())))
        let b = max(0, min(255, Int(parts[2].rounded())))
        return SnapshotColor(hex: String(format: "#%02x%02x%02x", r, g, b), source: raw)
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

extension Array where Element == APIClient.VisualElementSampleDTO {
    func matching(_ needles: [String]) -> [APIClient.VisualElementSampleDTO] {
        filter { sample in
            let haystack = "\(sample.tag) \(sample.selectorHint) \(sample.text)".lowercased()
            return needles.contains { haystack.contains($0.lowercased()) }
        }
    }
}
