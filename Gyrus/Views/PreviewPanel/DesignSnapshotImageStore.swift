import SwiftUI
import AppKit

/// Keeps one decoded screenshot per viewport so that cropping thumbnails out of
/// it does not refetch and redecode a multi-megabyte PNG per component.
@MainActor
final class SnapshotImageStore {
    static let shared = SnapshotImageStore()

    private var cache: [String: NSImage] = [:]
    /// Insertion order, used to evict the oldest entry.
    private var order: [String] = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// The three viewports of the capture on screen. Screenshots cover the
    /// whole page (up to 24 million pixels each, about 96 MB decoded), so a
    /// run the user steps back to is decoded again rather than kept around.
    private let limit = 3

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
    ///
    /// With `boxAspect`, an element much wider or taller than the box it is
    /// shown in is cut to its top-left part instead of being squeezed whole:
    /// a 1440 × 64 navigation bar fitted into a card used to become an
    /// unreadable strip a few points high.
    func crop(
        _ image: NSImage,
        x: Int, y: Int, width: Int, height: Int,
        viewportWidth: Int,
        padding: CGFloat = 6,
        boxAspect: CGFloat? = nil
    ) -> NSImage? {
        guard width > 0, height > 0, viewportWidth > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        var cssWidth = CGFloat(width) + padding * 2
        var cssHeight = CGFloat(height) + padding * 2
        if let boxAspect, boxAspect > 0 {
            let stretch = Self.maximumAspectStretch
            cssWidth = min(cssWidth, cssHeight * boxAspect * stretch)
            cssHeight = min(cssHeight, cssWidth / boxAspect * stretch)
        }

        let scale = CGFloat(cgImage.width) / CGFloat(viewportWidth)
        let rect = CGRect(
            x: (CGFloat(x) - padding) * scale,
            y: (CGFloat(y) - padding) * scale,
            width: cssWidth * scale,
            height: cssHeight * scale
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

    /// How far a crop may stray from the box's aspect ratio before it is cut.
    static let maximumAspectStretch: CGFloat = 1.75

    /// Whether a crop shows nothing but one flat color: an area the page had
    /// not drawn when it was captured (some sites render only what is on
    /// screen), which would otherwise appear as an empty white card.
    static func isBlank(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return true }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        for channel in 0..<3 {
            var low = UInt8.max, high = UInt8.min
            for index in stride(from: channel, to: pixels.count, by: 4) {
                low = min(low, pixels[index])
                high = max(high, pixels[index])
            }
            if Int(high) - Int(low) > 6 { return false }
        }
        return true
    }
}
