import SwiftUI
import AppKit

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

    // PDF readers commonly refuse pages taller than 200 inches. A full-page
    // screenshot of a long site scaled to the page width exceeds that, so it
    // continues on further pages.
    let maximumPageHeight: CGFloat = 14_400
    let maximumImageHeight = maximumPageHeight - titleHeight - margin * 2

    for page in pages {
        guard let cgImage = page.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let imageSize = page.image.size
        let scale = imageWidth / max(imageSize.width, 1)
        let pixelsPerPoint = CGFloat(cgImage.height) / max(imageSize.height, 1)
        let slicePixels = max(1, Int((maximumImageHeight / scale * pixelsPerPoint).rounded(.down)))
        var top = 0
        var part = 1
        let parts = (cgImage.height + slicePixels - 1) / slicePixels

        while top < cgImage.height {
            let height = min(slicePixels, cgImage.height - top)
            guard let slice = cgImage.cropping(to: CGRect(x: 0, y: top, width: cgImage.width, height: height)) else { break }
            let imageHeight = CGFloat(height) / pixelsPerPoint * scale
            let pageHeight = max(CGFloat(842), imageHeight + titleHeight + margin * 2)
            let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

            context.beginPDFPage([kCGPDFContextMediaBox as String: pageRect] as CFDictionary)
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
            context.fill(pageRect)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            var title = "\(page.viewport.name.capitalized) \(page.viewport.width)x\(page.viewport.height)"
            if parts > 1 { title += " (\(part)/\(parts))" }
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
            context.draw(slice, in: imageRect)
            context.endPDFPage()

            top += height
            part += 1
        }
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
