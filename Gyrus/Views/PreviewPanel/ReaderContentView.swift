import SwiftUI

enum ReaderContentBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
}

enum ReaderContentParser {
    static func parse(_ content: String) -> [ReaderContentBlock] {
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [ReaderContentBlock] = []
        var paragraph: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [String] = []
        var quotes: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        func flushListsAndQuotes() {
            if !unorderedItems.isEmpty {
                blocks.append(.unorderedList(unorderedItems))
                unorderedItems.removeAll()
            }
            if !orderedItems.isEmpty {
                blocks.append(.orderedList(orderedItems))
                orderedItems.removeAll()
            }
            if !quotes.isEmpty {
                blocks.append(.quote(quotes.joined(separator: " ")))
                quotes.removeAll()
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushListsAndQuotes()
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                flushListsAndQuotes()
                blocks.append(heading)
            } else if let item = unorderedItem(from: line) {
                flushParagraph()
                if !orderedItems.isEmpty || !quotes.isEmpty { flushListsAndQuotes() }
                unorderedItems.append(item)
            } else if let item = orderedItem(from: line) {
                flushParagraph()
                if !unorderedItems.isEmpty || !quotes.isEmpty { flushListsAndQuotes() }
                orderedItems.append(item)
            } else if line.hasPrefix(">") {
                flushParagraph()
                if !unorderedItems.isEmpty || !orderedItems.isEmpty { flushListsAndQuotes() }
                quotes.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                flushListsAndQuotes()
                paragraph.append(line)
            }
        }

        flushParagraph()
        flushListsAndQuotes()
        return blocks
    }

    private static func heading(from line: String) -> ReaderContentBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let number = line[..<separator]
        guard !number.isEmpty, number.count <= 3, number.allSatisfy(\.isNumber) else { return nil }
        let remainder = line[line.index(after: separator)...]
        guard remainder.first?.isWhitespace == true else { return nil }
        let item = remainder.trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }
}

struct ReaderFormattedContent: View {
    let content: String

    private var blocks: [ReaderContentBlock] {
        ReaderContentParser.parse(content)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ReaderContentBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inlineMarkdown(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 2)
        case let .paragraph(text):
            inlineMarkdown(text)
                .font(.body)
                .lineSpacing(5)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").foregroundStyle(.secondary)
                        inlineMarkdown(item).font(.body).lineSpacing(4)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 22, alignment: .trailing)
                        inlineMarkdown(item).font(.body).lineSpacing(4)
                    }
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                inlineMarkdown(text)
                    .font(.body.italic())
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}
