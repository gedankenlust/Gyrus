import XCTest
import UniformTypeIdentifiers
@testable import Gyrus

/// Covers the parts of the Design inspector v2 that are logic rather than
/// layout: the stored section, the token export plumbing and the report.
final class DesignInspectorReportTests: XCTestCase {
    // MARK: Section persistence

    func testStoredSectionFallsBackToOverviewForRetiredValues() {
        // Raw values written by the previous inspector.
        for retired in ["preview", "system", "issues", "", "garbage"] {
            XCTAssertEqual(DesignInspectorSection(storedValue: retired), .overview, retired)
        }
        for section in DesignInspectorSection.allCases {
            XCTAssertEqual(DesignInspectorSection(storedValue: section.rawValue), section)
        }
    }

    func testSectionsAreInReviewOrder() {
        XCTAssertEqual(
            DesignInspectorSection.allCases,
            [.overview, .styles, .components, .responsive, .audit, .website]
        )
    }

    // MARK: Token export

    func testTokenFilenameUsesTheHostWithoutWWW() {
        XCTAssertEqual(
            DesignTokenExport.defaultFilename(pageURL: "https://www.example.com/pricing", format: .css),
            "example.com.css"
        )
        XCTAssertEqual(
            DesignTokenExport.defaultFilename(pageURL: "https://shop.example.com", format: .json),
            "shop.example.com.tokens.json"
        )
        XCTAssertEqual(
            DesignTokenExport.defaultFilename(pageURL: "https://example.com", format: .tailwind),
            "example.com.tailwind.config.js"
        )
        XCTAssertEqual(
            DesignTokenExport.defaultFilename(pageURL: "not a url", format: .css),
            "design-tokens.css"
        )
    }

    func testTokenContentTypes() {
        XCTAssertEqual(DesignTokenExport.contentType(for: .json), .json)
        XCTAssertTrue(DesignTokenExport.contentType(for: .css).conforms(to: .text))
        XCTAssertTrue(DesignTokenExport.contentType(for: .tailwind).conforms(to: .text))
        XCTAssertEqual(DesignTokenExport.contentType(for: .css).preferredFilenameExtension, "css")
        XCTAssertEqual(DesignTokenExport.contentType(for: .tailwind).preferredFilenameExtension, "js")
    }

    func testTokenSourceOmitsEmptyURL() {
        XCTAssertNil(DesignTokenExport.source(pageURL: ""))
        XCTAssertEqual(DesignTokenExport.source(pageURL: "https://example.com"), "https://example.com")
    }

    // MARK: Report

    private func snapshot(samples: [[String: Any]], variables: [[String: String]] = []) throws -> APIClient.VisualSnapshotDTO {
        let object: [String: Any] = [
            "bookmark_id": "b", "schema_version": 7, "url": "https://example.com", "title": "Example",
            "captured_at": "2026-11-01T08:00:00Z",
            "viewports": [[
                "name": "desktop", "width": 1440, "height": 900,
                "screenshot": "d.png", "screenshot_url": "/d.png",
                "dominant_colors": [], "observed_colors": [], "observed_fonts": [],
                "structure": ["h1": ["Hi"], "h2": [], "links": 0, "buttons": 0, "images": 0, "svgs": 0, "forms": 0],
                "element_samples": samples,
                "css_variables": variables,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(APIClient.VisualSnapshotDTO.self, from: data)
    }

    private func sample(text: String, color: String, background: String = "rgba(0, 0, 0, 0)") -> [String: Any] {
        [
            "tag": "p", "selector_hint": ".copy", "text": text,
            "x": 0, "y": 0, "width": 100, "height": 20,
            "display": "block", "position": "static",
            "color": color, "background_color": background,
            "font_family": "Inter, sans-serif", "font_size": "16px", "font_weight": "400",
            "line_height": "normal", "letter_spacing": "normal", "text_transform": "none",
            "margin": "0px", "padding": "16px", "border_radius": "8px", "box_shadow": "none",
        ]
    }

    func testReportContainsAuditWithFailingContrast() throws {
        let report = DesignSnapshotReport.markdown(snapshot: try snapshot(samples: [
            sample(text: "Faint", color: "rgb(220, 220, 220)", background: "rgb(255, 255, 255)"),
        ]))

        XCTAssertTrue(report.contains("## Audit"))
        XCTAssertTrue(report.contains("**Score:**"))
        XCTAssertTrue(report.contains("[CRITICAL] contrast:"))
        XCTAssertTrue(report.contains("#### Failing contrast pairs"))
        XCTAssertTrue(report.contains("#dcdcdc on #ffffff"))
        XCTAssertTrue(report.contains("“Faint”"))
    }

    func testReportContainsTokensInAClosedCSSFence() throws {
        let report = DesignSnapshotReport.markdown(snapshot: try snapshot(
            samples: [sample(text: "Body", color: "rgb(0, 0, 0)")],
            variables: [["name": "--brand", "value": "#112233"], ["name": "--evil", "value": "```js"]]
        ))

        XCTAssertTrue(report.contains("## Design Tokens"))
        XCTAssertTrue(report.contains("```css\n/* Design tokens extracted by Gyrus from https://example.com. */\n:root {"))
        XCTAssertTrue(report.contains("--brand: #112233;"))
        XCTAssertTrue(report.contains("--space-16: 16px;"))
        let fences = report.components(separatedBy: "\n").filter { $0.hasPrefix("```") }
        XCTAssertEqual(fences, ["```css", "```"])
    }

    func testReportSaysWhenNoTokensExist() throws {
        let report = DesignSnapshotReport.markdown(snapshot: try snapshot(samples: []))
        XCTAssertTrue(report.contains("## Design Tokens"))
        XCTAssertTrue(report.contains("_No design tokens could be extracted._"))
        XCTAssertFalse(report.contains("```css"))
    }
}
