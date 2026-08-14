import Foundation

// Decodable payloads for the Design tab (visual snapshots) and persisted AI
// Brain chats. Declared inside `extension APIClient` so the call sites keep
// using `APIClient.VisualViewportDTO` etc. — moved out of
// APIClient+Brain.swift to keep that file about requests, not shapes.

extension APIClient {
    struct VisualSnapshotDTO: Decodable {
        let bookmarkId: String
        let schemaVersion: Int?
        let runId: String?
        let url: String
        let title: String
        let capturedAt: String
        /// "completed", "partial" (some viewports threw) or "failed" (none captured).
        let status: String?
        let viewports: [VisualViewportDTO]
        /// Why individual viewports are missing. The backend has always written
        /// this alongside the viewports; it just had nowhere to go until the
        /// inspector started explaining a partial capture.
        let errors: [VisualSnapshotErrorDTO]?

        enum CodingKeys: String, CodingKey {
            case url, title, status, viewports, errors
            case bookmarkId = "bookmark_id"
            case schemaVersion = "schema_version"
            case runId = "run_id"
            case capturedAt = "captured_at"
        }
    }

    struct VisualSnapshotErrorDTO: Decodable, Identifiable {
        let viewport: String?
        let message: String?

        var id: String { "\(viewport ?? "?")-\(message ?? "")" }
    }

    struct VisualSnapshotJobStatus: Decodable, JobStatusReporting {
        let running: Bool
        let bookmarkId: String?
        let stage: String?
        let completed: Int?
        let total: Int?
        let error: String?
        let snapshot: VisualSnapshotDTO?

        enum CodingKeys: String, CodingKey {
            case running, stage, completed, total, error, snapshot
            case bookmarkId = "bookmark_id"
        }
    }

    struct VisualViewportDTO: Decodable {
        let pageTitle: String?
        let metaDescription: String?
        let name: String
        let width: Int
        let height: Int
        let screenshot: String
        let screenshotURL: String
        let dominantColors: [String]
        let observedColors: [String]
        let observedFonts: [String]
        let structure: VisualStructureDTO
        let elementSamples: [VisualElementSampleDTO]?
        let seo: VisualSEODTO?
        let assets: VisualAssetsDTO?
        let accessibility: VisualAccessibilityDTO?
        let cssVariables: [VisualCSSVariableDTO]?
        let network: VisualNetworkDTO?
        let consoleMessages: [VisualConsoleMessageDTO]?
        let responsiveIssues: [VisualResponsiveIssueDTO]?

        enum CodingKeys: String, CodingKey {
            case name, width, height, screenshot, structure, seo, assets, accessibility, network
            case pageTitle = "page_title"
            case metaDescription = "meta_description"
            case screenshotURL = "screenshot_url"
            case dominantColors = "dominant_colors"
            case observedColors = "observed_colors"
            case observedFonts = "observed_fonts"
            case elementSamples = "element_samples"
            case cssVariables = "css_variables"
            case consoleMessages = "console_messages"
            case responsiveIssues = "responsive_issues"
        }
    }

    struct VisualResponsiveIssueDTO: Decodable, Identifiable {
        let id: String
        let kind: String
        let severity: String
        let title: String
        let detail: String
        let selectorHint: String
        let text: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let metric: String
        let evidenceURL: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, severity, title, detail, text, x, y, width, height, metric
            case selectorHint = "selector_hint"
            case evidenceURL = "evidence_url"
        }
    }

    struct VisualStructureDTO: Decodable {
        let h1: [String]
        let h2: [String]
        let links: Int
        let buttons: Int
        let images: Int
        let svgs: Int
        let forms: Int
    }

    struct VisualSEODTO: Decodable {
        let title: String?
        let metaDescription: String?
        let canonical: String?
        let language: String?
        let robots: String?
        let openGraph: [VisualMetaDTO]?
        let twitter: [VisualMetaDTO]?
        let jsonLd: [String]?
        let headings: [VisualHeadingDTO]?
        let internalLinks: Int?
        let externalLinks: Int?

        enum CodingKeys: String, CodingKey {
            case title, canonical, language, robots, twitter, headings
            case metaDescription = "meta_description"
            case openGraph = "open_graph"
            case jsonLd = "json_ld"
            case internalLinks = "internal_links"
            case externalLinks = "external_links"
        }
    }

    struct VisualMetaDTO: Decodable, Identifiable {
        var id: String { "\(name ?? "")-\(content ?? "")" }
        let name: String?
        let content: String?
    }

    struct VisualHeadingDTO: Decodable, Identifiable {
        var id: String { "\(level)-\(text)" }
        let level: Int
        let text: String
    }

    struct VisualAssetsDTO: Decodable {
        let images: [VisualAssetDTO]?
        let icons: [VisualAssetDTO]?
        let stylesheets: [VisualAssetDTO]?
        let scripts: [VisualAssetDTO]?
    }

    struct VisualAssetDTO: Decodable, Identifiable {
        var id: String { "\(kind ?? "")-\(url ?? "")-\(selectorHint ?? "")" }
        let kind: String?
        let url: String?
        let alt: String?
        let width: Int?
        let height: Int?
        let loading: String?
        let selectorHint: String?
        let rel: String?
        let sizes: String?
        let type: String?
        let media: String?
        let isAsync: Bool?
        let isDeferred: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, url, alt, width, height, loading, rel, sizes, type, media
            case selectorHint = "selector_hint"
            case isAsync = "async"
            case isDeferred = "defer"
        }
    }

    struct VisualAccessibilityDTO: Decodable {
        let missingAltImages: [VisualAssetDTO]?
        let emptyButtons: [VisualAccessibilityItemDTO]?
        let unlabeledInputs: [VisualAccessibilityItemDTO]?
        let headingSkips: [VisualHeadingSkipDTO]?

        enum CodingKeys: String, CodingKey {
            case missingAltImages = "missing_alt_images"
            case emptyButtons = "empty_buttons"
            case unlabeledInputs = "unlabeled_inputs"
            case headingSkips = "heading_skips"
        }
    }

    struct VisualAccessibilityItemDTO: Decodable, Identifiable {
        var id: String { "\(selectorHint ?? "")-\(text ?? "")-\(name ?? "")-\(placeholder ?? "")" }
        let selectorHint: String?
        let text: String?
        let ariaLabel: String?
        let type: String?
        let name: String?
        let placeholder: String?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case text, type, name, placeholder, label
            case selectorHint = "selector_hint"
            case ariaLabel = "aria_label"
        }
    }

    struct VisualHeadingSkipDTO: Decodable, Identifiable {
        var id: String { "\(from?.id ?? "")-\(to?.id ?? "")" }
        let from: VisualHeadingDTO?
        let to: VisualHeadingDTO?
    }

    struct VisualCSSVariableDTO: Decodable, Identifiable {
        var id: String { name }
        let name: String
        let value: String
    }

    struct VisualNetworkDTO: Decodable {
        let requestCount: Int?
        let resourceCounts: [VisualResourceCountDTO]?
        let failedRequests: [VisualNetworkRequestDTO]?
        let largeRequests: [VisualNetworkRequestDTO]?

        enum CodingKeys: String, CodingKey {
            case requestCount = "request_count"
            case resourceCounts = "resource_counts"
            case failedRequests = "failed_requests"
            case largeRequests = "large_requests"
        }
    }

    struct VisualResourceCountDTO: Decodable, Identifiable {
        var id: String { type }
        let type: String
        let count: Int
    }

    struct VisualNetworkRequestDTO: Decodable, Identifiable {
        var id: String { "\(method ?? "")-\(url ?? "")-\(status ?? 0)" }
        let url: String?
        let method: String?
        let resourceType: String?
        let status: Int?
        let contentType: String?
        let failure: String?
        let contentLength: Int?

        enum CodingKeys: String, CodingKey {
            case url, method, status, failure
            case resourceType = "resource_type"
            case contentType = "content_type"
            case contentLength = "content_length"
        }
    }

    struct VisualConsoleMessageDTO: Decodable, Identifiable {
        var id: String { "\(type ?? "")-\(text ?? "")-\(location?.url ?? "")-\(location?.lineNumber ?? 0)" }
        let type: String?
        let text: String?
        let location: VisualConsoleLocationDTO?
    }

    struct VisualConsoleLocationDTO: Decodable {
        let url: String?
        let lineNumber: Int?
        let columnNumber: Int?

        enum CodingKeys: String, CodingKey {
            case url
            case lineNumber = "lineNumber"
            case columnNumber = "columnNumber"
        }
    }

    struct VisualElementSampleDTO: Decodable, Identifiable {
        var id: String {
            "\(selectorHint)-\(x)-\(y)-\(width)-\(height)-\(text)"
        }

        let tag: String
        let selectorHint: String
        let text: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let display: String
        let position: String
        let fontFamily: String
        let fontSize: String
        let fontWeight: String
        let lineHeight: String
        let color: String
        let backgroundColor: String
        let borderRadius: String
        let boxShadow: String
        let letterSpacing: String
        let textTransform: String
        let margin: String
        let padding: String

        enum CodingKeys: String, CodingKey {
            case tag, text, x, y, width, height, display, position, color, margin, padding
            case selectorHint = "selector_hint"
            case fontFamily = "font_family"
            case fontSize = "font_size"
            case fontWeight = "font_weight"
            case lineHeight = "line_height"
            case backgroundColor = "background_color"
            case borderRadius = "border_radius"
            case boxShadow = "box_shadow"
            case letterSpacing = "letter_spacing"
            case textTransform = "text_transform"
        }
    }

    struct BrainMessageDTO: Decodable {
        let id: String
        let bookmarkId: String
        let role: String
        let content: String
        let model: String?
        let status: String
        let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, role, content, model, status
            case bookmarkId = "bookmark_id"
            case createdAt = "created_at"
        }
    }
}
