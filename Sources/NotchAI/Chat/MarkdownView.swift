import SwiftUI

/// Minimal chat markdown: headings, fenced code, paragraphs, inline emphasis/links.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph(String)
        case heading(String, level: Int)
        case code(String, language: String?)
        case listItem(String, marker: String, depth: Int)
        case quote(String)
    }

    var id = 0
    let kind: Kind
}

enum MarkdownParser {
    static func blocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let paragraph = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty {
                blocks.append(MarkdownBlock(kind: .paragraph(paragraph)))
            }
            paragraphLines.removeAll()
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(MarkdownBlock(kind: .code(codeLines.joined(separator: "\n"), language: codeLanguage)))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let item = listItem(from: trimmed) {
                flushParagraph()
                let depth = min(line.prefix(while: { $0 == " " }).count / 2, 3)
                blocks.append(MarkdownBlock(kind: .listItem(item.text, marker: item.marker, depth: depth)))
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote(String(trimmed.dropFirst(2)))))
                continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let content = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                if hashes <= 3, !content.isEmpty {
                    flushParagraph()
                    blocks.append(MarkdownBlock(kind: .heading(content, level: hashes)))
                    continue
                }
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }

        if inCode {
            blocks.append(MarkdownBlock(kind: .code(codeLines.joined(separator: "\n"), language: codeLanguage)))
        }
        flushParagraph()
        return blocks.enumerated().map { index, value in
            var block = value
            block.id = index
            return block
        }
    }

    private static func listItem(from line: String) -> (text: String, marker: String)? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), "•")
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), String(digits) + ".")
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct MarkdownView: View, Equatable {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownParser.blocks(from: text)) { block in
                MarkdownContentBlock(kind: block.kind).equatable()
            }
        }
    }
}

/// Keep already-rendered paragraphs/code intact as new tokens arrive at the end of the reply.
private struct MarkdownContentBlock: View, Equatable {
    let kind: MarkdownBlock.Kind

    var body: some View {
        switch kind {
        case let .paragraph(paragraph):
            Text(MarkdownParser.inline(paragraph))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .heading(heading, level):
            Text(MarkdownParser.inline(heading))
                .font(.system(size: level == 1 ? 17 : 15, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, 5)
        case let .code(code, language):
            CodeBlockView(code: code, language: language)
        case let .listItem(text, marker, depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(MarkdownParser.inline(text))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 14))
            .padding(.leading, CGFloat(depth) * 12)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.24)).frame(width: 2)
                Text(MarkdownParser.inline(text))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(copied ? 0.8 : 0.45))
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
