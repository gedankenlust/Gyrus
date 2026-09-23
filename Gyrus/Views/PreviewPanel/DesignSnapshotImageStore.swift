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
