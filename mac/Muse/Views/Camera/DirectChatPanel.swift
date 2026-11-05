import MuseCore
import SwiftUI

/// "Direct with Claude" (D6 right column, `chat_panel` in design/source/ai_desktop.py): status rows, the shared transcript
/// with tool chips, the Guides ready card, the working strip while a turn streams, the composer and the no-spend footer.
struct DirectChatPanel: View {
    @Environment(\.theme) private var t
    @Bindable var model: CameraModel
    var session: CameraSession
    /// "Use for Shot 01" on the guides card (nil hides it).
    var useLabel: String?
    var onUse: (() -> Void)?
    var onOpenConnections: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            transcript
            if let turn = model.turn, !turn.finished { working(turn) }
            composer
        }
        .frame(width: 404)
        .frame(maxHeight: .infinity)
        .background(t.surface)
        .overlay(alignment: .leading) { Rectangle().fill(t.line).frame(width: 1) }
    }

    // MARK: Header and status

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Direct with Claude").font(t.body(16, .bold)).foregroundStyle(t.ink)
                Spacer()
                if model.live {
                    Text(t.isA ? "● LIVE" : "● Live").font(t.mono(10.5, .medium)).tracking(0.8).foregroundStyle(t.good)
                        .padding(.horizontal, 8).frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 11).strokeBorder(t.good, lineWidth: 1))
                        .help("Live updates are connected")
                }
            }
            ForEach(CameraStatus.rows(session, inAppChat: model.connections?.inAppChat, busy: model.busy, now: model.now, machine: model.machine), id: \.title) { row in
                HStack(spacing: 8) {
                    Circle().fill(color(row.tone)).frame(width: 7, height: 7)
                    Text(row.title).font(t.body(13, .semibold)).foregroundStyle(t.ink)
                    Spacer(minLength: 8)
                    Text(row.detail).font(t.body(12.5)).foregroundStyle(t.muted).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func color(_ tone: CameraTone) -> Color {
        switch tone {
        case .good: return t.good
        case .warn: return t.warn
        case .bad: return t.accent
        case .neutral: return t.ink
        case .off: return t.muted
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let items = CameraTranscript.items(session.messages ?? [], devices: model.sentHere)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty {
                        Text("Tell Claude what happens in the shot: who walks where, when they turn, how the camera moves. Claude blocks it in Blender on your Mac and renders the guides.")
                            .font(t.body(13)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .user(_, let label, let text): userBubble(label, text)
                        case .claude(_, let label, let text, let chips): claudeBlock(label, text, chips)
                        }
                    }
                    if let card = CameraGuides.card(session) { guidesCard(card) }
                    if let e = model.chatError { errorNote(e) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .onChange(of: items.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private func userBubble(_ label: String, _ text: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Lbl(label)
            Text(text).font(t.body(13)).foregroundStyle(t.bg).lineSpacing(3)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r).fill(t.ink))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 300, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func claudeBlock(_ label: String, _ text: String, _ chips: [ToolChip]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Lbl(label)
            if !text.isEmpty {
                Text(text).font(t.body(13)).foregroundStyle(t.ink).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !chips.isEmpty {
                FlowLayout(spacing: 4) { ForEach(Array(chips.enumerated()), id: \.offset) { _, c in toolChip(c) } }
            }
        }
    }

    private func toolChip(_ c: ToolChip) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "cube").font(.system(size: 9.5))
            Text(c.text).font(t.mono(9.5, .medium)).tracking(0.5)
        }
        .foregroundStyle(c.ok ? t.muted : t.accent)
        .padding(.horizontal, 7).frame(height: 20)
        .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 4).strokeBorder(c.ok ? t.line : t.accent, lineWidth: 1))
        .help(c.ok ? c.text : "\(c.text) · failed")
    }

    private func guidesCard(_ items: [GuideItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Guides ready · rev \(session.revision)").font(t.body(13, .bold)).foregroundStyle(t.ink)
                Spacer()
                Text("\(CameraText.seconds(session.durationSec)) · \(Int(session.fps)) fps").font(t.mono(11)).foregroundStyle(t.muted)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(items) { g in
                    let still = g.asset.kind.hasPrefix("keyframe_")
                    VStack(spacing: 4) {
                        GuideThumb(item: g).frame(width: still ? 32 : 44, height: still ? 56 : 78)
                        Text(g.label).font(t.mono(9.5)).foregroundStyle(t.muted)
                    }
                }
            }
            if let useLabel, let onUse {
                HStack(spacing: 8) {
                    MButton(useLabel, kind: .primary, size: .small, off: model.applying) { onUse() }
                    if model.applying { ProgressView().controlSize(.small) }
                }
                if let e = model.applyError { Text(e).font(t.body(12)).foregroundStyle(t.accent) }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(t.line, lineWidth: 1))
    }

    @ViewBuilder private func errorNote(_ e: String) -> some View {
        if model.chatErrorCode == "director_unavailable" {
            VStack(alignment: .leading, spacing: 6) {
                Note(icon: "exclamationmark.triangle", warn: true, e)
                LinkText("Open Connections", action: onOpenConnections)
            }
        } else {
            Note(icon: "exclamationmark.circle", warn: true, e)
        }
    }

    // MARK: Working strip

    private func working(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Lbl(turn.title, color: t.ink)
                Spacer()
                Text(turn.percent()).font(t.mono(11)).foregroundStyle(t.ink)
            }
            if let q = turn.quote { Text(q).font(t.body(12)).foregroundStyle(t.ink).lineLimit(2) }
            HStack(spacing: 10) {
                ProgressLine(value: turn.progress(), height: 4)
                Text("\(turn.stepsDone) / \(max(turn.stepsSeen, 1)) steps").font(t.mono(11)).foregroundStyle(t.muted).fixedSize()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(t.surface2)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Composer

    private var composer: some View {
        let blocked = model.busy || session.claude?.chatBusy == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(CameraText.composerPlaceholder, text: $model.composer, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { model.send() }
                    .fieldChrome()
                Button { model.send() } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(MuseButtonStyle(kind: .primary, off: blocked || model.composer.trimmingCharacters(in: .whitespaces).isEmpty))
                .frame(width: 44)
                .disabled(blocked)
                .help(blocked ? CameraText.chatBusy : "Send to Claude")
                .keyboardShortcut(.return, modifiers: .command)
            }
            if blocked { Text(CameraText.chatBusy).font(t.body(12)).foregroundStyle(t.muted) }
            Text(CameraText.footer(session.shotDraft)).font(t.body(12)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
    }
}

/// A guide's thumbnail: a still loads its image; a video shows a grey tile with a play mark (opens in the browser/QuickTime).
struct GuideThumb: View {
    @Environment(\.theme) private var t
    @Environment(\.openURL) private var openURL
    var item: GuideItem

    var body: some View {
        ZStack {
            if item.isImage, let u = item.asset.url {
                MuseImage(ref: ImageRef(url: u), symbol: "photo")
            } else {
                LinearGradient(colors: [t.surface2, t.line], startPoint: .top, endPoint: .bottom)
                Image(systemName: item.isVideo ? "play.fill" : "doc.text").font(.system(size: 12)).foregroundStyle(t.ink.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : 4))
        .contentShape(Rectangle())
        .onTapGesture { if let u = item.asset.url, let url = URL(string: u) { openURL(url) } }
        .help(item.asset.url == nil ? item.label : "Open \(item.label)")
    }
}
