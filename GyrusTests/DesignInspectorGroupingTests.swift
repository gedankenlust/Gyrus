import XCTest
import AppKit
@testable import Gyrus

/// Covers the geometry that cuts component thumbnails out of a page screenshot.
@MainActor
final class SnapshotImageCropTests: XCTestCase {

    /// A screenshot captured at 2x for a 1440pt viewport.
    private func screenshot(pixelWidth: Int, pixelHeight: Int, pointWidth: Int) -> NSImage {
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let pointHeight = pixelHeight * pointWidth / pixelWidth
        return NSImage(cgImage: cgImage, size: NSSize(width: pointWidth, height: pointHeight))
    }

    /// Element rectangles are in CSS pixels, the screenshot is in device pixels.
    /// The returned image is sized back in points, so a 108x42 button plus the
    /// 6pt context margin on each side comes back as 120x54 regardless of ratio.
    func testCropScalesByDevicePixelRatio() throws {
        let image = screenshot(pixelWidth: 2880, pixelHeight: 1800, pointWidth: 1440)
        let cropped = try XCTUnwrap(
            SnapshotImageStore.shared.crop(
                image, x: 32, y: 152, width: 108, height: 42, viewportWidth: 1440
            )
        )
        XCTAssertEqual(cropped.size.width, 120, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 54, accuracy: 0.5)
    }

    func testCropWorksAtOneToOne() throws {
        let image = screenshot(pixelWidth: 1440, pixelHeight: 900, pointWidth: 1440)
        let cropped = try XCTUnwrap(
            SnapshotImageStore.shared.crop(
                image, x: 100, y: 100, width: 200, height: 100, viewportWidth: 1440
            )
        )
        XCTAssertEqual(cropped.size.width, 212, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 112, accuracy: 0.5)
    }

    /// An element flush against the top-left corner makes the padded rect start
    /// at a negative offset. `cropping(to:)` returns nil for a rect that leaves
    /// the image, so it has to be clamped rather than passed through.
    func testCropClampsAtTheImageEdge() throws {
        let image = screenshot(pixelWidth: 1440, pixelHeight: 900, pointWidth: 1440)
        let cropped = try XCTUnwrap(
            SnapshotImageStore.shared.crop(
                image, x: 0, y: 0, width: 50, height: 20, viewportWidth: 1440
            )
        )
        // Only the trailing margin survives on each axis.
        XCTAssertEqual(cropped.size.width, 56, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 26, accuracy: 0.5)
    }

    func testCropRejectsDegenerateGeometry() {
        let image = screenshot(pixelWidth: 1440, pixelHeight: 900, pointWidth: 1440)
        XCTAssertNil(SnapshotImageStore.shared.crop(image, x: 10, y: 10, width: 0, height: 20, viewportWidth: 1440))
        XCTAssertNil(SnapshotImageStore.shared.crop(image, x: 10, y: 10, width: 20, height: 0, viewportWidth: 1440))
        XCTAssertNil(SnapshotImageStore.shared.crop(image, x: 10, y: 10, width: 20, height: 20, viewportWidth: 0))
    }

    /// Elements below the fold sit far down a full-page screenshot; the crop has
    /// to reach them rather than assuming a viewport-tall image.
    func testCropReachesContentBelowTheFold() throws {
        let image = screenshot(pixelWidth: 1440, pixelHeight: 6000, pointWidth: 1440)
        let cropped = try XCTUnwrap(
            SnapshotImageStore.shared.crop(
                image, x: 20, y: 4800, width: 300, height: 120, viewportWidth: 1440
            )
        )
        XCTAssertEqual(cropped.size.width, 312, accuracy: 0.5)
        XCTAssertEqual(cropped.size.height, 132, accuracy: 0.5)
    }
}

/// Covers the derivations behind the Design tab's System and Components panels.
final class DesignInspectorGroupingTests: XCTestCase {

    private func variable(_ name: String, _ value: String) -> APIClient.VisualCSSVariableDTO {
        APIClient.VisualCSSVariableDTO(name: name, value: value)
    }

    private func group(_ key: String, in groups: [CSSVariableGroup]) -> [String] {
        groups.first { $0.key == key }?.variables.map(\.name) ?? []
    }

    // MARK: - groupCSSVariables

    /// A value ending in the letters "ms" is not a duration. The condition used
    /// to read `hasSuffix("ms") || (hasSuffix("s") && numeric)` because `&&`
    /// binds tighter than `||`, so a font stack was filed under Motion — and
    /// because Motion is tested first, it could never reach the font branch.
    func testFontStackEndingInMSIsNotMotion() {
        let groups = groupCSSVariables([
            variable("--font-fun", "Comic Sans MS, cursive"),
            variable("--duration", "300ms"),
        ])
        XCTAssertEqual(group("motion", in: groups), ["--duration"])
        XCTAssertTrue(group("motion", in: groups).allSatisfy { $0 != "--font-fun" })
    }

    func testDurationsAndEasingsAreMotion() {
        let groups = groupCSSVariables([
            variable("--a", "300ms"),
            variable("--b", "0.4s"),
            variable("--c", "cubic-bezier(0.4, 0, 0.2, 1)"),
            variable("--d", "ease-in-out"),
        ])
        XCTAssertEqual(Set(group("motion", in: groups)), ["--a", "--b", "--c", "--d"])
    }

    /// Substring matching on "ease" would swallow ordinary words.
    func testWordsContainingEaseAreNotMotion() {
        let groups = groupCSSVariables([variable("--label", "increase")])
        XCTAssertTrue(group("motion", in: groups).isEmpty)
    }

    func testColorsAreDetectedAcrossSyntaxes() {
        let groups = groupCSSVariables([
            variable("--gold", "#c9a94d"),
            variable("--ink", "rgb(20, 20, 20)"),
            variable("--modern", "oklch(0.72 0.19 45)"),
        ])
        XCTAssertEqual(Set(group("color", in: groups)), ["--gold", "--ink", "--modern"])
    }

    func testFrameworkPlaceholdersAreKeptButSeparated() {
        let groups = groupCSSVariables([
            variable("--tw-ring-shadow", "0 0 #0000"),
            variable("--tw-empty", ""),
            variable("--brand", "#c9a94d"),
        ])
        XCTAssertEqual(Set(group("internals", in: groups)), ["--tw-ring-shadow", "--tw-empty"])
        XCTAssertEqual(group("color", in: groups), ["--brand"])
    }

    /// Bootstrap prefixes every real token, and Tailwind v4 emits genuine
    /// `@theme` tokens, so classification must not key on the name.
    func testPrefixedTokensAreClassifiedByValueNotName() {
        let groups = groupCSSVariables([
            variable("--bs-primary", "#0d6efd"),
            variable("--tw-color-brand", "#c9a94d"),
        ])
        XCTAssertEqual(Set(group("color", in: groups)), ["--bs-primary", "--tw-color-brand"])
        XCTAssertTrue(group("internals", in: groups).isEmpty)
    }

    // MARK: - spacingScale

    private func sample(padding: String, margin: String = "0px") -> APIClient.VisualElementSampleDTO {
        let json = """
        {
          "tag": "div", "selector_hint": ".x", "text": "",
          "x": 0, "y": 0, "width": 10, "height": 10,
          "display": "block", "position": "static",
          "color": "rgb(0, 0, 0)", "background_color": "rgba(0, 0, 0, 0)",
          "font_family": "Inter", "font_size": "16px", "font_weight": "400",
          "line_height": "1.5", "letter_spacing": "normal", "text_transform": "none",
          "margin": "\(margin)", "padding": "\(padding)",
          "border_radius": "0px", "box_shadow": "none"
        }
        """
        return try! JSONDecoder().decode(APIClient.VisualElementSampleDTO.self, from: Data(json.utf8))
    }

    /// Keying on the bare number merged "1rem" and "1px" into a single entry
    /// labelled with whichever was seen last.
    func testUnitsAreNotConflated() {
        let scale = [sample(padding: "1rem"), sample(padding: "1px"), sample(padding: "1px")].spacingScale()
        XCTAssertTrue(scale.contains { $0.hasPrefix("1rem") }, "\(scale)")
        XCTAssertTrue(scale.contains { $0.hasPrefix("1px") }, "\(scale)")
    }

    /// The list is trimmed by usage, not by size. Trimming an ascending list
    /// kept the smallest values, so hairlines pushed out the real rhythm.
    func testMostUsedStepsSurviveTheLimit() {
        var samples: [APIClient.VisualElementSampleDTO] = []
        // One-off small values, plus a heavily used large one.
        for i in 1...20 { samples.append(sample(padding: "\(i)px")) }
        for _ in 1...30 { samples.append(sample(padding: "64px")) }

        let scale = [APIClient.VisualElementSampleDTO](samples).spacingScale(limit: 5)
        XCTAssertEqual(scale.count, 5)
        XCTAssertTrue(scale.contains { $0.hasPrefix("64px") }, "64px was dropped: \(scale)")
    }

    func testScaleIsPresentedAscending() {
        var samples: [APIClient.VisualElementSampleDTO] = []
        for _ in 1...3 { samples.append(sample(padding: "32px")) }
        for _ in 1...5 { samples.append(sample(padding: "8px")) }
        for _ in 1...4 { samples.append(sample(padding: "16px")) }

        let values = samples.spacingScale().compactMap { cssLengthValue($0) }
        XCTAssertEqual(values, values.sorted(), "expected ascending order, got \(values)")
    }

    func testZeroLengthsAreIgnored() {
        let scale = [sample(padding: "0px 0px")].spacingScale()
        XCTAssertTrue(scale.isEmpty, "\(scale)")
    }

    // MARK: - typeScale

    func testTypeScaleOrdersBySizeThenWeightThenFamily() {
        func typed(_ size: String, _ weight: String, _ family: String) -> APIClient.VisualElementSampleDTO {
            let json = """
            {
              "tag": "p", "selector_hint": ".t", "text": "Specimen",
              "x": 0, "y": 0, "width": 10, "height": 10,
              "display": "block", "position": "static",
              "color": "rgb(0, 0, 0)", "background_color": "rgba(0, 0, 0, 0)",
              "font_family": "\(family)", "font_size": "\(size)", "font_weight": "\(weight)",
              "line_height": "1.5", "letter_spacing": "normal", "text_transform": "none",
              "margin": "0px", "padding": "0px",
              "border_radius": "0px", "box_shadow": "none"
            }
            """
            return try! JSONDecoder().decode(APIClient.VisualElementSampleDTO.self, from: Data(json.utf8))
        }

        let samples = [
            typed("16px", "400", "Zeta"),
            typed("48px", "700", "Alpha"),
            typed("16px", "700", "Alpha"),
            typed("16px", "400", "Alpha"),
        ]

        let ids = samples.typeScale().map(\.id)
        XCTAssertEqual(ids, [
            "48px|700|Alpha",
            "16px|700|Alpha",
            "16px|400|Alpha",
            "16px|400|Zeta",
        ])
    }

    /// Repeated runs must agree; dictionary enumeration alone does not
    /// guarantee that without a total ordering.
    func testTypeScaleOrderIsStableAcrossRuns() {
        func typed(_ family: String) -> APIClient.VisualElementSampleDTO {
            let json = """
            {
              "tag": "p", "selector_hint": ".t", "text": "",
              "x": 0, "y": 0, "width": 10, "height": 10,
              "display": "block", "position": "static",
              "color": "rgb(0, 0, 0)", "background_color": "rgba(0, 0, 0, 0)",
              "font_family": "\(family)", "font_size": "16px", "font_weight": "400",
              "line_height": "1.5", "letter_spacing": "normal", "text_transform": "none",
              "margin": "0px", "padding": "0px",
              "border_radius": "0px", "box_shadow": "none"
            }
            """
            return try! JSONDecoder().decode(APIClient.VisualElementSampleDTO.self, from: Data(json.utf8))
        }

        let samples = ["Delta", "Alpha", "Charlie", "Bravo"].map(typed)
        let first = samples.typeScale().map(\.id)
        for _ in 0..<20 {
            XCTAssertEqual(samples.typeScale().map(\.id), first)
        }
    }
}
