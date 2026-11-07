import XCTest
@testable import Gyrus

final class DesignAnalysisTests: XCTestCase {
    // MARK: Fixtures

    private func sample(
        tag: String = "p", selector: String = ".x", text: String = "Hello",
        x: Int = 0, y: Int = 0, width: Int = 100, height: Int = 20,
        color: String = "rgb(0, 0, 0)", background: String = "rgba(0, 0, 0, 0)",
        fontFamily: String = "Inter, sans-serif", fontSize: String = "16px", fontWeight: String = "400",
        margin: String = "0px 0px 0px 0px", padding: String = "0px 0px 0px 0px",
        radius: String = "0px", shadow: String = "none"
    ) -> APIClient.VisualElementSampleDTO {
        let object: [String: Any] = [
            "tag": tag, "selector_hint": selector, "text": text,
            "x": x, "y": y, "width": width, "height": height,
            "display": "block", "position": "static",
            "color": color, "background_color": background,
            "font_family": fontFamily, "font_size": fontSize, "font_weight": fontWeight,
            "line_height": "normal", "letter_spacing": "normal", "text_transform": "none",
            "margin": margin, "padding": padding,
            "border_radius": radius, "box_shadow": shadow,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(APIClient.VisualElementSampleDTO.self, from: data)
    }

    private func variable(_ name: String, _ value: String) -> APIClient.VisualCSSVariableDTO {
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "value": value])
        return try! JSONDecoder().decode(APIClient.VisualCSSVariableDTO.self, from: data)
    }

    private func viewport(_ extra: [String: Any] = [:], h1: [String] = ["Title"]) -> APIClient.VisualViewportDTO {
        var object: [String: Any] = [
            "name": "desktop", "width": 1440, "height": 900,
            "screenshot": "desktop.png", "screenshot_url": "/x/desktop.png",
            "dominant_colors": [], "observed_colors": [], "observed_fonts": [],
            "structure": ["h1": h1, "h2": [], "links": 0, "buttons": 0, "images": 0, "svgs": 0, "forms": 0],
        ]
        object.merge(extra) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(APIClient.VisualViewportDTO.self, from: data)
    }

    // MARK: WCAG

    func testBlackOnWhiteIsTwentyOne() {
        XCTAssertEqual(WCAGContrast.ratio(hex: "#000000", hex: "#ffffff")!, 21, accuracy: 0.001)
    }

    func testRatioIsSymmetricAndOneForSameColor() {
        XCTAssertEqual(WCAGContrast.ratio(hex: "#777777", hex: "#777777")!, 1, accuracy: 0.0001)
        XCTAssertEqual(
            WCAGContrast.ratio(hex: "#336699", hex: "#ffffff")!,
            WCAGContrast.ratio(hex: "#ffffff", hex: "#336699")!,
            accuracy: 0.0001
        )
    }

    func testKnownGreyRatio() {
        // #767676 on white is the classic lightest grey that still passes AA.
        let ratio = WCAGContrast.ratio(hex: "#767676", hex: "#ffffff")!
        XCTAssertEqual(ratio, 4.54, accuracy: 0.01)
        XCTAssertEqual(ContrastRating(ratio: ratio, isLargeText: false), .aa)
    }

    func testRatingThresholdsDependOnTextSize() {
        XCTAssertEqual(ContrastRating(ratio: 3.2, isLargeText: false), .fail)
        XCTAssertEqual(ContrastRating(ratio: 3.2, isLargeText: true), .aa)
        XCTAssertEqual(ContrastRating(ratio: 4.6, isLargeText: true), .aaa)
        XCTAssertEqual(ContrastRating(ratio: 7.0, isLargeText: false), .aaa)
    }

    func testLargeTextRule() {
        XCTAssertTrue(WCAGContrast.isLargeText(fontSize: "24px", fontWeight: "400"))
        XCTAssertFalse(WCAGContrast.isLargeText(fontSize: "18px", fontWeight: "700"))
        XCTAssertTrue(WCAGContrast.isLargeText(fontSize: "19px", fontWeight: "700"))
        XCTAssertFalse(WCAGContrast.isLargeText(fontSize: "1.5rem", fontWeight: "400"))
    }

    // MARK: Contrast pairs

    func testTransparentTextUsesSmallestEnclosingBackground() {
        let samples = [
            sample(tag: "body", text: "", width: 1000, height: 1000, background: "rgb(255, 255, 255)"),
            sample(tag: "section", text: "", x: 10, y: 10, width: 500, height: 500, background: "rgb(0, 0, 0)"),
            sample(text: "Inside", x: 20, y: 20, width: 100, height: 20, color: "rgb(255, 255, 255)"),
        ]
        let pairs = ContrastAnalyzer.pairs(in: samples)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].foregroundHex, "#ffffff")
        XCTAssertEqual(pairs[0].backgroundHex, "#000000")
        XCTAssertFalse(pairs[0].backgroundIsAssumed)
    }

    func testFallsBackToBodyThenCanvas() {
        let withBody = ContrastAnalyzer.pairs(in: [
            sample(tag: "body", text: "", x: 0, y: 0, width: 10, height: 10, background: "rgb(17, 17, 17)"),
            sample(text: "Outside", x: 50, y: 50, color: "rgb(238, 238, 238)"),
        ])
        XCTAssertEqual(withBody.first?.backgroundHex, "#111111")

        let canvas = ContrastAnalyzer.pairs(in: [sample(text: "Alone", color: "rgb(200, 200, 200)")])
        XCTAssertEqual(canvas.first?.backgroundHex, "#ffffff")
        XCTAssertTrue(canvas.first?.backgroundIsAssumed ?? false)
    }

    func testPairsGroupAndSortFailuresFirst() {
        let samples = [
            sample(selector: ".a", text: "Good", color: "rgb(0, 0, 0)", background: "rgb(255, 255, 255)"),
            sample(selector: ".b", text: "Good too", color: "rgb(0, 0, 0)", background: "rgb(255, 255, 255)"),
            sample(selector: ".c", text: "Faint", color: "rgb(204, 204, 204)", background: "rgb(255, 255, 255)"),
            sample(selector: ".d", text: "", color: "rgb(204, 204, 204)", background: "rgb(255, 255, 255)"),
        ]
        let pairs = ContrastAnalyzer.pairs(in: samples)
        XCTAssertEqual(pairs.count, 2, "elements without text are not text pairs")
        XCTAssertEqual(pairs[0].rating, .fail)
        XCTAssertEqual(pairs[1].occurrences, 2)
        XCTAssertEqual(pairs[1].examples.count, 2)
    }

    // MARK: Tokens

    func testAuthoredColorsKeepTheirNamesAndPaintedOnesAreNotRepeated() {
        let set = DesignTokenSet.extract(
            samples: [
                sample(color: "rgb(255, 0, 0)", background: "rgb(0, 0, 255)"),
                sample(color: "rgb(0, 128, 0)"),
            ],
            cssVariables: [variable("--brand-primary", "#ff0000")]
        )
        let colors = set.tokens(in: .color)
        XCTAssertEqual(colors.first?.name, "brand-primary")
        XCTAssertTrue(colors.first?.isAuthored ?? false)
        XCTAssertEqual(colors.filter { $0.value == "#ff0000" }.count, 1)
        XCTAssertTrue(colors.contains { $0.value == "#0000ff" && $0.name.hasPrefix("surface-") })
        XCTAssertTrue(colors.contains { $0.value == "#008000" && $0.name.hasPrefix("text-") })
    }

    func testSpacingAndFontSizesAreAscendingPxTokens() {
        let set = DesignTokenSet.extract(
            samples: [
                sample(fontSize: "32px", padding: "24px 16px 24px 16px"),
                sample(fontSize: "16px", margin: "8px 0px 8px 0px", padding: "1.5rem 0px 0px 0px"),
            ],
            cssVariables: []
        )
        XCTAssertEqual(set.tokens(in: .fontSize).map(\.name), ["text-16", "text-32"])
        XCTAssertEqual(set.tokens(in: .spacing).map(\.value), ["8px", "16px", "24px"])
    }

    func testRadiusAndShadowTokens() {
        let set = DesignTokenSet.extract(
            samples: [
                sample(radius: "9999px"), sample(radius: "8px"), sample(radius: "8px"),
                sample(radius: "0px"), sample(shadow: "rgba(0, 0, 0, 0.1) 0px 1px 2px 0px"),
            ],
            cssVariables: []
        )
        XCTAssertEqual(set.tokens(in: .radius).map(\.name), ["radius-8", "radius-full"])
        XCTAssertEqual(set.tokens(in: .shadow).map(\.name), ["shadow-1"])
    }

    func testFontFamilyTokenNamedAfterFirstFamily() {
        let set = DesignTokenSet.extract(samples: [sample(fontFamily: "\"Helvetica Neue\", Arial, sans-serif")],
                                         cssVariables: [])
        let token = set.tokens(in: .fontFamily).first
        XCTAssertEqual(token?.name, "font-helvetica-neue")
        XCTAssertEqual(DesignTokenSet.fontFamilyList(token?.value ?? ""), ["Helvetica Neue", "Arial", "sans-serif"])
    }

    func testCSSExport() {
        let set = DesignTokenSet.extract(samples: [sample(padding: "8px 0px 0px 0px")],
                                         cssVariables: [variable("--brand", "#123456")])
        let css = set.export(.css)
        XCTAssertTrue(css.contains(":root {"))
        XCTAssertTrue(css.contains("  --brand: #123456;"))
        XCTAssertTrue(css.contains("  --space-8: 8px;"))
        XCTAssertTrue(css.hasSuffix("}\n"))
    }

    func testJSONExportIsValidDesignTokensFormat() throws {
        let set = DesignTokenSet.extract(samples: [sample(fontWeight: "700")],
                                         cssVariables: [variable("--brand", "#123456")])
        let json = set.export(.json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let brand = try XCTUnwrap((root["color"] as? [String: Any])?["brand"] as? [String: Any])
        XCTAssertEqual(brand["$type"] as? String, "color")
        XCTAssertEqual(brand["$value"] as? String, "#123456")
        let weight = try XCTUnwrap((root["fontWeight"] as? [String: Any])?["700"] as? [String: Any])
        XCTAssertEqual(weight["$value"] as? Int, 700)
        let family = try XCTUnwrap((root["fontFamily"] as? [String: Any])?["inter"] as? [String: Any])
        XCTAssertEqual(family["$value"] as? [String], ["Inter", "sans-serif"])
    }

    func testTailwindExportEscapesQuotes() {
        let set = DesignTokenSet.extract(samples: [sample(fontFamily: "'Bob's Font', serif")], cssVariables: [])
        let config = set.export(.tailwind)
        XCTAssertTrue(config.contains("module.exports = {"))
        XCTAssertTrue(config.contains("fontFamily: {"))
        XCTAssertFalse(config.contains("'Bob's"), "a raw quote would end the JS string")
    }

    func testSlug() {
        XCTAssertEqual(DesignTokenSet.slug("--bs-Primary_Color", fallback: "x"), "bs-primary-color")
        XCTAssertEqual(DesignTokenSet.slug("—", fallback: "color"), "color")
    }

    // MARK: Audit

    func testCleanPageScoresFullMarks() {
        let page = viewport([
            "seo": [
                "title": "A good title", "meta_description": String(repeating: "d", count: 80),
                "canonical": "https://example.com/", "language": "en",
                "open_graph": [["name": "og:title", "content": "x"]],
            ],
            "element_samples": [],
        ])
        let audit = DesignAudit.run(page)
        XCTAssertEqual(audit.findings, [])
        XCTAssertEqual(audit.score, 100)
    }

    func testFindingsAreOrderedBySeverityAndScored() {
        let page = viewport([
            "accessibility": [
                "missing_alt_images": [["url": "https://example.com/a.png"]],
                "empty_buttons": [["selector_hint": ".icon"]],
            ],
            "console_messages": [["type": "error", "text": "boom"], ["type": "log", "text": "fine"]],
        ], h1: [])
        let audit = DesignAudit.run(page)
        XCTAssertEqual(audit.findings.first?.severity, .critical)
        XCTAssertTrue(audit.findings.contains { $0.id == "a11y.alt" && $0.count == 1 })
        XCTAssertTrue(audit.findings.contains { $0.id == "console.errors" && $0.count == 1 })
        XCTAssertTrue(audit.findings.contains { $0.id == "a11y.h1.missing" })
        XCTAssertTrue(audit.findings.contains { $0.id == "seo.title" })
        let expected = 100 - audit.findings.reduce(0) { total, finding in
            total + [AuditSeverity.info: 2, .warning: 6, .critical: 15][finding.severity]!
        }
        XCTAssertEqual(audit.score, max(0, expected))
        XCTAssertEqual(
            audit.findings.map(\.severity),
            audit.findings.map(\.severity).sorted(by: >)
        )
    }

    func testContrastFailureBecomesCriticalFinding() {
        let findings = DesignAudit.contrastFindings(ContrastAnalyzer.pairs(in: [
            sample(text: "Faint", color: "rgb(220, 220, 220)", background: "rgb(255, 255, 255)"),
        ]))
        XCTAssertEqual(findings.map(\.id), ["contrast.body"])
        XCTAssertEqual(findings.first?.severity, .critical)
    }
}
