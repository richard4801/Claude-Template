import AppKit
import MuseCore
import SwiftUI

/// Captions & hooks (E3): the word-timed transcript (filler words in red, cuttable pauses as grey marks; delete words here
/// and the video cuts with them), Remove fillers / Cut silences, the preview, caption styles and hook templates.
struct EditSuiteCaptionsMode: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var picked: Set<Int> = []
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                transcript.frame(width: max(320, g.size.width * 0.3))
                SuiteRule(vertical: true)
                preview.frame(maxWidth: .infinity)
                SuiteRule(vertical: true)
                side.frame(width: max(300, min(380, g.size.width * 0.27)))
            }
        }
        .onKeyPress(.delete) {
            guard !picked.isEmpty, editing == nil else { return .ignored }
            deletePicked()
            return .handled
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        let words = session.state.transcript()
        let fillers = words.filter { $0.isFiller && $0.kept }.count
        let silences = session.state.silenceCuts().count
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("TRANSCRIPT · WORD-TIMED").font(t.mono(11, .medium)).tracking(1.1).foregroundStyle(t.ink)
                    Spacer()
                    if let lang = session.jobs[.captions]?.result?.language { Text(languageName(lang)).font(t.body(12)).foregroundStyle(t.muted) }
                }
                if words.isEmpty {
                    Text("No captions yet. Auto-captions writes down what's said, word by word, so you can edit the video by editing the text.")
                        .font(t.body(13)).foregroundStyle(t.muted)
                    HStack {
                        SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Auto-captions", icon: "captions.bubble", accent: true,
                                        disabled: session.isRunning(.captions)) { Task { await session.autoCaptions() } }
                        if session.isRunning(.captions) {
                            ProgressView().controlSize(.small)
                            Text(session.jobs[.captions]?.phase ?? "").font(t.body(12)).foregroundStyle(t.muted)
                        }
                        Spacer()
                        Text(session.estimateLabel(.captions) ?? "").font(t.mono(11)).foregroundStyle(t.muted)
                    }
                    .task { await session.loadEstimate(.captions) }
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(words) { w in
                            wordView(w)
                            if let gap = w.pauseAfter, w.kept {
                                Text("▪ \(String(format: "%.1f", gap)) s").font(t.mono(10.5)).foregroundStyle(t.muted)
                                    .padding(.horizontal, 5).frame(height: 22).background(t.surface2)
                                    .accessibilityLabel(String(format: "Pause, %.1f seconds", gap))
                            }
                        }
                    }
                    SuiteRule()
                    HStack(spacing: 8) {
                        SuiteToolButton(title: "Remove \(fillers) filler\(fillers == 1 ? "" : "s")", icon: "scissors", accent: fillers > 0, disabled: fillers == 0) {
                            session.removeFillers()
                        }
                        SuiteToolButton(title: "Cut \(silences) silence\(silences == 1 ? "" : "s")", disabled: silences == 0) {
                            Task { await session.cutSilences() }
                        }
                        SuiteToolButton(title: "Translate…", disabled: true) {}
                            .help("Coming soon")
                    }
                    if !picked.isEmpty {
                        HStack {
                            SuiteToolButton(title: "Cut \(picked.count) word\(picked.count == 1 ? "" : "s")", icon: "delete.left", filled: true) { deletePicked() }
                            SuiteToolButton(title: "Clear") { picked = [] }
                        }
                    }
                    Text("Red = filler words · grey = silences. Delete words here and the video cuts with them (jump cuts). Click a word to jump there, ⇧-click to pick more, double-click to fix its spelling.")
                        .font(t.body(12)).foregroundStyle(t.muted)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(t.bg)
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    @ViewBuilder private func wordView(_ w: EditSuite.TranscriptWord) -> some View {
        let active = isActive(w)
        let on = picked.contains(w.index)
        if editing == w.index {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(t.body(17))
                .frame(width: max(50, CGFloat(draft.count) * 10))
                .padding(.horizontal, 3)
                .overlay(Rectangle().strokeBorder(t.accent))
                .onSubmit {
                    session.edit { $0.editWord(w.index, text: draft) }
                    editing = nil
                }
                .onExitCommand { editing = nil }
        } else {
            Text(w.text)
                .font(t.body(17))
                .strikethrough(w.isFiller || !w.kept, color: w.isFiller ? t.accent : t.muted)
                .foregroundStyle(!w.kept ? t.muted.opacity(0.6) : w.isFiller ? t.accent : t.ink)
                .padding(.horizontal, 2)
                .background(active ? Color(hex: 0xFFE14D) : on ? t.accent.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    draft = w.text
                    editing = w.index
                }
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.shift) {
                        if on { picked.remove(w.index) } else { picked.insert(w.index) }
                    } else {
                        picked = [w.index]
                        if w.kept, let tl = timelineStart(w) { session.seek(tl) }
                    }
                }
                .accessibilityLabel(w.text + (w.isFiller ? ", filler" : "") + (w.kept ? "" : ", cut"))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }
    }

    private func timelineStart(_ w: EditSuite.TranscriptWord) -> Double? {
        EditV2.captionWords(session.project).first { $0.index == w.index }?.startSec
    }

    private func isActive(_ w: EditSuite.TranscriptWord) -> Bool {
        guard w.kept, let tw = EditV2.captionWords(session.project).first(where: { $0.index == w.index }) else { return false }
        return session.playhead >= tw.startSec && session.playhead < tw.endSec
    }

    private func deletePicked() {
        let p = picked
        picked = []
        session.edit { $0.deleteWords(p) }
    }

    // MARK: Preview and side

    private var preview: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                let c = session.project.canvas
                let aspect = CGFloat(c.width) / CGFloat(max(1, c.height))
                let h = min(g.size.width / aspect, g.size.height)
                ZStack {
                    SuitePlayerSurface(player: session.player)
                    if let a = session.state.safeArea { SafeAreaGuide(area: a) }
                }
                .frame(width: h * aspect, height: h)
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .padding(20)
            HStack(spacing: 12) {
                SuiteIconButton(systemName: session.playing ? "pause.fill" : "play.fill", label: session.playing ? "Pause" : "Play", size: 32, tint: .white) {
                    session.togglePlay()
                }
                Text("\(EditSuite.clockTenths(session.playhead)) / \(EditSuite.clockTenths(session.duration))")
                    .font(t.mono(12)).foregroundStyle(Color(hex: 0xE7E1D6)).monospacedDigit()
            }
            .frame(height: 44)
        }
        .background(suiteStage)
    }

    private var side: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    SuiteLabel("Caption style")
                    CaptionStyleGrid(session: session)
                }
                .padding(18)
                SuiteRule()
                VStack(alignment: .leading, spacing: 0) {
                    SuiteLabel("Hook templates", trailing: "First 2 seconds").padding(.bottom, 10)
                    ForEach(EditV2.hooks) { h in
                        Button { session.edit { $0.addHook(h, text: hookText(h)) } } label: {
                            HStack(spacing: 10) {
                                HookChip(template: h).frame(width: 96, height: 32)
                                Text(hookText(h) ?? h.label).font(t.body(13)).foregroundStyle(t.ink).lineLimit(1)
                                Spacer()
                                Ph("plus").foregroundStyle(t.ink)
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { SuiteRule() }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add hook \(h.label)")
                    }
                }
                .padding(18)
            }
        }
        .background(t.chrome)
    }

    /// Hook ideas: a template's text with the video's own first words where it fits ("POV: …").
    private func hookText(_ h: EditV2.HookTemplate) -> String? {
        let first = session.state.transcript().filter { $0.kept && !$0.isFiller }.prefix(5).map(\.text).joined(separator: " ")
        guard !first.isEmpty else { return nil }
        switch h.id {
        case "hook-box": return "POV: \(first.lowercased())…"
        case "hook-question": return "Would you try this?"
        case "hook-serif", "hook-caption": return first
        default: return nil
        }
    }
}
