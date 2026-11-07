import XCTest
import SwiftUI
import AppKit
@testable import Gyrus

/// The inspector column takes the widest minimum of what it shows. A preview
/// with a fixed width therefore widened the column in one section and let it
/// snap back in the next.
@MainActor
final class DesignInspectorWidthTests: XCTestCase {
    private func viewport(_ name: String, _ width: Int, _ height: Int) -> APIClient.VisualViewportDTO {
        let object: [String: Any] = [
            "name": name, "width": width, "height": height,
            "screenshot": "\(name).png", "screenshot_url": "/x/\(name).png",
            "dominant_colors": [], "observed_colors": [], "observed_fonts": [],
            "structure": ["h1": [], "h2": [], "links": 0, "buttons": 0, "images": 0, "svgs": 0, "forms": 0],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(APIClient.VisualViewportDTO.self, from: data)
    }

    private func fitted(_ maximum: CGSize, width: CGFloat) -> CGSize {
        let box = ViewportPreviewBox(maximum: maximum) { _ in Color.gray }
        return NSHostingController(rootView: box).sizeThatFits(in: CGSize(width: width, height: .infinity))
    }

    func testPreviewsShrinkWithTheInspectorAndKeepTheirProportions() {
        for viewport in [viewport("desktop", 1440, 900), viewport("tablet", 768, 1024), viewport("mobile", 390, 844)] {
            let maximum = reviewPreviewSize(for: viewport)
            let narrow = fitted(maximum, width: 200)
            XCTAssertLessThanOrEqual(narrow.width, 200, viewport.name)
            XCTAssertEqual(narrow.height, narrow.width * maximum.height / maximum.width, accuracy: 1, viewport.name)
        }
    }

    func testPreviewsStopAtTheirSizeInAWideInspector() {
        let desktop = reviewPreviewSize(for: viewport("desktop", 1440, 900))
        let wide = fitted(desktop, width: 2000)
        XCTAssertEqual(wide.width, desktop.width, accuracy: 1)
        XCTAssertEqual(wide.height, desktop.height, accuracy: 1)
    }
}
