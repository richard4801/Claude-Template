import AppKit
import MuseCore
import SwiftUI

// Claude's replies drawn from ChatMarkdown's blocks (plans/claude-chat-mac.md): headings, lists, quotes, code with Copy,
// tables and rules in the theme's type scale and roles. The markup itself never reaches the screen.

struct ChatMarkdownView: View {
    @Environment(\.theme) private var t
    let blocks: [ChatBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: ChatBlock) -> some View {
        switch b {
        case .paragraph(let runs):
            ChatRunsText(runs: runs, style: t.scale.body, color: t.roles.ink)
        case .heading(let level, let runs):
            ChatRunsText(runs: runs, style: level <= 2 ? t.scale.heading : t.scale.body, color: t.roles.ink, weight: .semibold)
                .padding(.top, level <= 2 ? Space.s1 : 0)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let ordered, let number, let depth, let checked, let runs):
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                marker(ordered: ordered, number: number, depth: depth, checked: checked)
                ChatRunsText(runs: runs, style: t.scale.body, color: checked == true ? t.roles.ink2 : t.roles.ink)
            }
            .padding(.leading, CGFloat(depth) * Space.s4)
            .padding(.top, -Space.s1)   // list items sit closer than paragraphs
        case .quote(let inner):
            HStack(alignment: .top, spacing: Space.s3) {
                Rectangle().fill(t.roles.ink2.opacity(0.5)).frame(width: 2)
                ChatMarkdownView(blocks: inner).environment(\.chatQuoted, true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let text, let closed):
            ChatCodeBlock(language: language, code: text, closed: closed)
        case .table(let header, let rows, let align):
            ChatTable(header: header, rows: rows, align: align)
        case .rule:
            Rectangle().fill(t.roles.hairline).frame(height: 1).padding(.vertical, Space.s1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func marker(ordered: Bool, number: Int, depth: Int, checked: Bool?) -> some View {
        if let checked {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(t.roles.ink2, lineWidth: 1.2)
                .frame(width: 13, height: 13)
                .overlay { if checked { Ph("check", 9).foregroundStyle(t.roles.ink) } }
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                .accessibilityLabel(checked ? "Done" : "To do")
        } else if ordered {
            Text("\(number).").font(t.scale.body.font.monospacedDigit()).foregroundStyle(t.roles.ink2)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text(depth == 0 ? "•" : "◦").font(t.scale.body.font).foregroundStyle(t.roles.ink2).frame(width: 12)
        }
    }
}

private struct ChatQuotedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Inside a blockquote: text in ink2.
    var chatQuoted: Bool {
        get { self[ChatQuotedKey.self] }
        set { self[ChatQuotedKey.self] = newValue }
    }
}

/// Styled runs as one selectable Text: bold, italic, strikethrough, inline code (tinted, monospaced) and links.
struct ChatRunsText: View {
    @Environment(\.theme) private var t
    @Environment(\.chatQuoted) private var quoted
    let runs: [ChatRun]
    let style: TypeScale.Style
    let color: Color
    var weight: Font.Weight?

    var body: some View {
        Text(ChatRunsText.attributed(runs, theme: t, size: style.size))
            .font(weight.map { Fonts.font(t.scale.textFamily, style.size, $0) } ?? style.font)
            .lineSpacing(style.leading)
            .foregroundStyle(quoted ? t.roles.ink2 : color)
            .tint(t.roles.link)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ runs: [ChatRun], theme t: Theme, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var a = AttributedString(r.text)
            var intent: InlinePresentationIntent = []
            if r.bold { intent.insert(.stronglyEmphasized) }
            if r.italic { intent.insert(.emphasized) }
            if r.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { a.inlinePresentationIntent = intent }
            if r.code {
                a.swiftUI.font = .system(size: max(10, size - 1.5), weight: r.bold ? .semibold : .regular, design: .monospaced)
                a.swiftUI.backgroundColor = t.roles.field
            }
            if let l = r.link, let url = URL(string: l), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                a.link = url
                a.swiftUI.foregroundColor = t.roles.link
                a.swiftUI.underlineStyle = .single
            }
            out += a
        }
        return out
    }
}

/// A fenced code block: monospaced, scrolls sideways, with its language and Copy.
struct ChatCodeBlock: View {
    @Environment(\.theme) private var t
    let language: String?
    let code: String
    let closed: Bool
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                Text(language.map(ChatCodeBlock.languageName) ?? "Code").scaled(t.scale.micro, t.roles.ink2)
                Spacer(minLength: Space.s2)
                Button {
                    ChatPasteboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    HStack(spacing: Space.s1) {
                        Ph(copied ? "check" : "copy", 12)
                        Text(copied ? "Copied" : "Copy").font(t.scale.micro.font)
                    }
                    .foregroundStyle(t.roles.ink2)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!closed && code.isEmpty)
                .help("Copy this code")
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, Space.s3)
            .padding(.top, Space.s1)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(t.roles.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s3)
                    .padding(.top, Space.s1)
            }
        }
        .background(shape.fill(t.roles.field))
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code\(language.map { ", \(ChatCodeBlock.languageName($0))" } ?? "")")
    }

    static func languageName(_ l: String) -> String {
        let names = ["js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript", "py": "Python",
                     "python": "Python", "swift": "Swift", "bash": "Shell", "sh": "Shell", "zsh": "Shell", "shell": "Shell", "json": "JSON",
                     "yaml": "YAML", "yml": "YAML", "html": "HTML", "css": "CSS", "sql": "SQL", "md": "Markdown", "markdown": "Markdown",
                     "kotlin": "Kotlin", "kt": "Kotlin", "go": "Go", "rust": "Rust", "rs": "Rust", "ruby": "Ruby", "text": "Text", "txt": "Text"]
        return names[l.lowercased()] ?? l.capitalized
    }
}

/// A markdown table: header in semibold, a hairline under it, columns aligned as written; scrolls sideways when wide.
struct ChatTable: View {
    @Environment(\.theme) private var t
    let header: [[ChatRun]]
    let rows: [[[ChatRun]]]
    let align: [ChatAlign]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        cell(header[c], bold: true).gridColumnAlignment(alignment(c))
                    }
                }
                Rectangle().fill(t.roles.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], bold: false) }
                    }
                }
            }
            .padding(.bottom, Space.s1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table, \(rows.count) row\(rows.count == 1 ? "" : "s")")
    }

    private func alignment(_ c: Int) -> HorizontalAlignment {
        switch c < align.count ? align[c] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func cell(_ runs: [ChatRun], bold: Bool) -> some View {
        Text(ChatRunsText.attributed(runs, theme: t, size: t.scale.caption.size))
            .font(bold ? Fonts.font(t.scale.textFamily, t.scale.caption.size, .semibold) : t.scale.caption.font)
            .monospacedDigit()
            .foregroundStyle(t.roles.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: false)
    }
}

enum ChatPasteboard {
    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
