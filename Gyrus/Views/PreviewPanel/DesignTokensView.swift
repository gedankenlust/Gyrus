import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File and pasteboard plumbing for the token export, kept apart from the view
/// so the naming rules can be tested.
enum DesignTokenExport {
    /// `example.com.css`, `example.com.tokens.json`, … The host says where the
    /// tokens came from without the user having to rename the file.
    static func defaultFilename(pageURL: String, format: DesignTokenFormat) -> String {
        let host = URL(string: pageURL)?.host ?? ""
        let base = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return "\(safeFilename(base.isEmpty ? "design-tokens" : base)).\(format.fileExtension)"
    }

    /// JSON is JSON; CSS and the Tailwind config are text files whose own
    /// type is used, so the save panel keeps their extension instead of
    /// offering `.txt`. `public.css` is declared as text but not as plain
    /// text, so the declared type is asked for first.
    static func contentType(for format: DesignTokenFormat) -> UTType {
        if format == .json { return .json }
        // `tokens.json` and `tailwind.config.js` are compound; the type
        // belongs to the last part.
        let pathExtension = format.fileExtension.split(separator: ".").last.map(String.init) ?? format.fileExtension
        if let declared = UTType(filenameExtension: pathExtension), declared.conforms(to: .text) {
            return declared
        }
        return UTType(filenameExtension: pathExtension, conformingTo: .plainText) ?? .plainText
    }

    static func source(pageURL: String) -> String? {
        pageURL.isEmpty ? nil : pageURL
    }

    @MainActor
    static func copyToPasteboard(_ tokens: DesignTokenSet, as format: DesignTokenFormat, pageURL: String) {
        copy(tokens.export(format, source: source(pageURL: pageURL)))
        AppStore.shared.uiStateStore.showInfo(String(localized: "Copied tokens as \(format.title)."))
    }

    @MainActor
    static func save(_ tokens: DesignTokenSet, as format: DesignTokenFormat, pageURL: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType(for: format)]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(pageURL: pageURL, format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try tokens.export(format, source: source(pageURL: pageURL))
                .write(to: url, atomically: true, encoding: .utf8)
            AppStore.shared.uiStateStore.showInfo(String(localized: "Design tokens saved."))
        } catch {
            AppStore.shared.uiStateStore.showError(error.localizedDescription)
        }
    }
}

/// The page's repeated values as named tokens, ready to paste into a project.
struct DesignTokensView: View {
    let tokens: DesignTokenSet
    let pageURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Text("Values the page repeats, named as tokens. Site-declared colors keep their own names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                exportMenu
            }

            if tokens.isEmpty {
                Text("No tokens could be extracted from this viewport.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(DesignTokenGroup.allCases) { group in
                    let members = tokens.tokens(in: group)
                    if !members.isEmpty {
                        DesignTokenGroupView(group: group, tokens: members)
                    }
                }
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(DesignTokenFormat.allCases) { format in
                Button {
                    DesignTokenExport.copyToPasteboard(tokens, as: format, pageURL: pageURL)
                } label: {
                    Text("Copy as \(format.title)")
                }
            }
            Divider()
            Menu("Save…") {
                ForEach(DesignTokenFormat.allCases) { format in
                    Button {
                        DesignTokenExport.save(tokens, as: format, pageURL: pageURL)
                    } label: {
                        Text(verbatim: "\(format.title) (.\(format.fileExtension))")
                    }
                }
            }
        } label: {
            Label("Export Tokens", systemImage: "square.and.arrow.up")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tokens.isEmpty)
        .help("Copy or save the tokens as CSS, JSON or a Tailwind theme")
    }
}

private struct DesignTokenGroupView: View {
    let group: DesignTokenGroup
    let tokens: [DesignToken]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tokens) { token in
                    DesignTokenRow(token: token)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: group.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(verbatim: "\(tokens.count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DesignTokenRow: View {
    let token: DesignToken

    private var declaration: String { "\(token.cssVariable): \(token.value);" }

    var body: some View {
        HStack(spacing: 10) {
            DesignTokenSpecimen(token: token)
                .frame(width: 44, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: token.cssVariable)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: token.value)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(token.value)
            }
            .textSelection(.enabled)

            Spacer(minLength: 4)

            if token.isAuthored {
                Label("Site", systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .help("Declared by the site as a CSS custom property")
                    .accessibilityLabel(Text("Declared by the site"))
            } else {
                Text(verbatim: "\(token.usage)×")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Sampled elements using this value")
                    .accessibilityLabel(Text("Used by \(token.usage) sampled elements"))
            }

            Button {
                copy(declaration)
                AppStore.shared.uiStateStore.showInfo(String(localized: "Copied \(token.cssVariable)."))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy CSS declaration")
            .accessibilityLabel(Text("Copy \(token.cssVariable)"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            token.isAuthored ? Color.accentColor.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu {
            Button("Copy CSS declaration") { copy(declaration) }
            Button("Copy value") { copy(token.value) }
        }
    }
}

/// A small picture of what the value does: the color itself, the face, the
/// size, a bar as long as the spacing, a corner with the radius.
private struct DesignTokenSpecimen: View {
    let token: DesignToken

    private var length: Double { cssLengthValue(token.value) ?? 0 }

    var body: some View {
        Group {
            switch token.group {
            case .color:
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hexString: token.value) ?? .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.3), lineWidth: 1))
                    .accessibilityLabel(Text("Color \(token.value.uppercased())"))
            case .fontFamily:
                Text(verbatim: "Aa")
                    .font(.custom(DesignTokenSet.fontFamilyList(token.value).first ?? "", size: 17))
                    .accessibilityHidden(true)
            case .fontSize:
                Text(verbatim: "Aa")
                    .font(.system(size: CGFloat(min(max(length, 8), 26))))
                    .accessibilityHidden(true)
            case .fontWeight:
                Text(verbatim: "Aa")
                    .font(.system(size: 17, weight: fontWeight(Int(token.value) ?? 400)))
                    .accessibilityHidden(true)
            case .spacing:
                Capsule()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: CGFloat(min(max(length, 2), 44)), height: 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            case .radius:
                UnevenRoundedRectangle(topLeadingRadius: CGFloat(min(length, 14)))
                    .stroke(Color.secondary, lineWidth: 1.5)
                    .frame(width: 26, height: 22)
                    .accessibilityHidden(true)
            case .shadow:
                // Box-shadow syntax is too varied to reproduce faithfully; a
                // generic raised card says "this is a shadow" without lying
                // about its exact offset.
                RoundedRectangle(cornerRadius: 4)
                    .fill(.background)
                    .frame(width: 26, height: 18)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fontWeight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<200: .ultraLight
        case 200..<300: .light
        case 300..<500: .regular
        case 500..<600: .medium
        case 600..<700: .semibold
        case 700..<800: .bold
        default: .heavy
        }
    }
}
