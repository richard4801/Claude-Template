import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The inspector (E1 right, E2 panels; plans/edit-layout.md): "Inspector" with "Hide inspector", its sections as a 3 × 2
/// grid of labelled buttons (Captions, Text, Video, Audio, Speed, Animate), then the section's settings scrolling inside.
struct EditSuiteInspector: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                Text("Inspector").font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer(minLength: 0)
                SuiteIconButton(systemName: "sidebar-simple", label: "Hide inspector", tint: t.roles.ink2, action: hide)
            }
            .padding(.horizontal, Space.s4)
            .padding(.top, Space.s3)
            .padding(.bottom, Space.s2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s1), count: 3), alignment: .leading, spacing: Space.s1) {
                ForEach(EditSuite.InspectorTab.allCases) { tab in
                    let on = session.state.tab == tab
                    Button { session.view { $0.tab = tab } } label: {
                        HStack(spacing: Space.s1 + 2) {
                            Ph(icon(tab), 14)
                            Text(tab.label).font(t.scale.label.font).lineLimit(1).fitProbe("inspector \(tab.label)")
                        }
                        .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                        .padding(.horizontal, Space.s1 + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(on ? t.roles.field : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.label)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s3)
            SuiteRule().padding(.horizontal, Space.s4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch session.state.tab {
                    case .captions: CaptionsPanel(session: session)
                    case .text: TextPanel(session: session)
                    case .video: VideoPanels(session: session)
                    case .audio: AudioPanels(session: session)
                    case .speed: SpeedPanel(session: session)
                    case .anim: AnimPanel(session: session)
                    }
                }
                .padding(.vertical, Space.s1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(t.roles.canvas)
    }

    private func icon(_ tab: EditSuite.InspectorTab) -> String {
        switch tab {
        case .captions: return "closed-captioning"
        case .text: return "text-t"
        case .video: return "film-strip"
        case .audio: return "waveform"
        case .speed: return "timer"
        case .anim: return "arrows-clockwise"
        }
    }
}

/// "Select a clip" note for panels that need one.
struct InspectorEmpty: View {
    @Environment(\.theme) private var t
    var text: String
    var body: some View {
        Text(text).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).padding(Space.s4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Captions

/// A caption style drawn as in the design's tiles: "I ALWAYS ORDER" on black with the preset's active-word look.
struct CaptionStyleTile: View {
    @Environment(\.theme) private var t
    var preset: EditV2.CaptionPreset
    var on: Bool

    var body: some View {
        let st = EditV2.captionStyle(preset)
        let hl = Color(hex: UInt32(st.highlightColor.dropFirst(), radix: 16) ?? 0xFFE14D)
        let base = Color(hex: UInt32(st.color.dropFirst(), radix: 16) ?? 0xFFFFFF)
        let font = Font.system(size: 12, weight: .black)
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.editViewer)
                HStack(spacing: 3) {
                    switch preset {
                    case .plain:
                        Text("I always order the").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    case .karaoke:
                        Text("I").font(font).foregroundStyle(hl)
                        Text("ALWAYS").font(font).foregroundStyle(hl)
                        Text("ORDER").font(font).foregroundStyle(Color.gray)
                    case .box:
                        Text("I").font(font).foregroundStyle(.white)
                        Text("ALWAYS").font(font).foregroundStyle(Color(hex: 0x141210)).padding(.horizontal, 3).background(Color.white)
                    case .highlighter:
                        Text("I").font(font).foregroundStyle(.white)
                        Text("ALWAYS").font(font).foregroundStyle(.white)
                            .background(alignment: .bottom) { Rectangle().fill(hl).frame(height: 6) }
                    case .neon:
                        Text("I ALWAYS").font(font).foregroundStyle(base).shadow(color: hl, radius: 4)
                    default:
                        Text("I").font(font).foregroundStyle(.white)
                        Text("ALWAYS").font(font).foregroundStyle(Color(hex: 0x141210)).padding(.horizontal, 3).background(Color(hex: 0xFFE14D))
                        Text("ORDER").font(font).foregroundStyle(.white)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
            }
            .frame(height: 56)
            .overlay(RoundedRectangle(cornerRadius: t.radii.control + 3, style: .continuous).strokeBorder(on ? t.roles.selection : .clear, lineWidth: 2).padding(-3))
            Text(EditV2.captionStyleLabel(preset)).font(t.scale.caption.font).foregroundStyle(on ? t.roles.ink : t.roles.ink2).lineLimit(1)
        }
    }
}

struct CaptionStyleGrid: View {
    @Bindable var session: EditSuiteSession
    var body: some View {
        let current = session.state.captionStyle?.preset
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s3), GridItem(.flexible(), spacing: Space.s3)], spacing: Space.s3) {
            ForEach(EditV2.suiteCaptionStyles, id: \.self) { p in
                Button { session.edit { $0.setCaptionPreset(p) } } label: { CaptionStyleTile(preset: p, on: current == p) }
                    .buttonStyle(.plain)
                    .disabled(session.project.captionTrack == nil)
                    .accessibilityLabel("Caption style \(EditV2.captionStyleLabel(p))")
                    .accessibilityAddTraits(current == p ? .isSelected : [])
            }
        }
    }
}

struct CaptionsPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        let style = session.state.captionStyle
        VStack(alignment: .leading, spacing: 0) {
            if style == nil {
                EditPanel(title: "Auto-captions") {
                    Text("Word-timed captions from what's said in the video. Edit the words in Captions and hooks.")
                        .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s2) {
                        SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Make captions", icon: "closed-captioning",
                                        disabled: session.isRunning(.captions) || !session.helperAvailable(.captions)) { Task { await session.autoCaptions() } }
                        if session.isRunning(.captions) { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        Text(session.estimateLabel(.captions) ?? "").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                    }
                    HelperNote(text: session.helperNote(.captions))
                }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                SuiteLabel("Style", trailing: style == nil ? nil : "Word-by-word")
                CaptionStyleGrid(session: session)
                ContentCaptionChips(session: session)
                if style != nil { TranslateCaptionsRow(session: session) }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            if let st = style {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(EditV2.Font.bundled, id: \.self) { f in
                                Button(fontName(f)) { session.edit { $0.changeCaptionStyle { $0.font = f } } }
                            }
                            // The content library's families (WS8 929bcf2), loaded when chosen.
                            Divider()
                            ForEach(EditV2.Font.allCases.filter(\.isContent), id: \.self) { f in
                                Button(fontName(f)) { session.edit { $0.changeCaptionStyle { $0.font = f } } }
                            }
                        } label: {
                            Text("\(fontName(st.font)) · \(Int((st.sizePct * 1920 / 1.35).rounded()))").font(t.scale.caption.font).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.borderlessButton)
                        .padding(.horizontal, Space.s3)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                        .accessibilityLabel("Caption font")
                        SuiteSwatch(hex: st.color, label: "Text colour") { c in session.edit { $0.changeCaptionStyle { $0.color = c } } }
                        SuiteSwatch(hex: st.highlightColor, label: "Highlight colour") { c in session.edit { $0.changeCaptionStyle { $0.highlightColor = c } } }
                        SuiteSwatch(hex: st.stroke?.color ?? "#000000", label: "Outline colour") { c in
                            session.edit { $0.changeCaptionStyle { $0.stroke = EditV2.Stroke(color: c, widthPct: $0.stroke?.widthPct ?? 0.1) } }
                        }
                    }
                    SuiteSlider("Size", value: st.sizePct, range: 0.02...0.09, format: { "\(Int(($0 * 1000).rounded()) / 10) %" }) { v in
                        session.edit { $0.changeCaptionStyle { $0.sizePct = (v * 1000).rounded() / 1000 } }
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Position").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        EditSeg(options: EditSuite.CaptionPosition.allCases.map { ($0, $0.label) },
                                 selection: EditSuite.CaptionPosition.nearest(st.y ?? 0.72)) { pos in
                            session.edit { $0.changeCaptionStyle { $0.y = pos.y } }
                        }
                    }
                    SuiteToggleRow(title: "Word-by-word highlight", hint: "Active word pops in the highlight colour", isOn: st.preset != .plain) { on in
                        session.edit { $0.setCaptionPreset(on ? .pop : .plain) }
                    }
                    SuiteToggleRow(title: "Upper case", isOn: st.uppercase == true) { on in session.edit { $0.changeCaptionStyle { $0.uppercase = on ? true : nil } } }
                    SuiteToolButton(title: "Edit the words", icon: "text.cursor") { session.mode = .captions }
                        .help("Edit the words in Captions and hooks")
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
            }
        }
    }

    func fontName(_ f: EditV2.Font) -> String { f.label }
}

// MARK: - Text

struct TextPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var draft = ""
    @State private var editingId: String?

    var body: some View {
        if let tx = session.state.selectedItem?.textItem {
            editor(tx)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                InspectorEmpty(text: "Select a text or hook on the timeline, or add one.")
                VStack(alignment: .leading, spacing: 10) {
                    SuiteToolButton(title: "Add text at the playhead", icon: "plus") { session.edit { $0.addText() } }
                    SuiteToolButton(title: "Hook ideas", icon: "sparkles") { session.mode = .captions }
                }
                .padding(.horizontal, Space.s4)
            }
        }
    }

    private func change(_ f: @escaping (inout EditV2.TextItem) -> Void) {
        session.edit { s in s.changeSelected { it in if case .text(var x) = it { f(&x); it = .text(x) } } }
    }

    @ViewBuilder private func editor(_ tx: EditV2.TextItem) -> some View {
        let st = tx.style
        EditPanel(title: tx.template.flatMap { id in EditV2.hooks.first { $0.id == id }?.label } ?? "Text") {
            TextField("Text", text: Binding(get: { editingId == tx.id ? draft : tx.text }, set: { draft = $0; editingId = tx.id }), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(t.scale.label.font)
                .padding(Space.s2)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                .onSubmit { commitText(tx) }
                .onChange(of: session.state.selection) { _, _ in editingId = nil }
            HStack {
                SuiteToolButton(title: "Apply text", disabled: editingId != tx.id) { commitText(tx) }
                Spacer()
            }
        }
        EditPanel(title: "Style") {
            HStack(spacing: Space.s2) {
                Menu {
                    ForEach(EditV2.Font.bundled, id: \.self) { f in Button(f.label) { change { $0.style.font = f; $0.style.fontAsset = nil } } }
                    // The content library's families (WS8 929bcf2), loaded when chosen.
                    Divider()
                    ForEach(EditV2.Font.allCases.filter(\.isContent), id: \.self) { f in Button(f.label) { change { $0.style.font = f; $0.style.fontAsset = nil } } }
                    // Own fonts (contract, WS8 6ccd9aa): each one in this edit, then a new one from this Mac.
                    let own = session.state.ownFonts
                    if !own.isEmpty {
                        Divider()
                        ForEach(own) { a in Button(a.name ?? "Your font") { session.edit { $0.setTextFont(a) } } }
                    }
                    Divider()
                    Button("Your font…") { pickFont() }
                } label: {
                    Text(st.fontAsset.flatMap { id in session.project.asset(id)?.name } ?? st.font.label)
                        .font(t.scale.caption.font).frame(maxWidth: .infinity, alignment: .leading)
                }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, Space.s3)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                    .accessibilityLabel("Font")
                SuiteSwatch(hex: st.color, label: "Text colour") { c in change { $0.style.color = c } }
            }
            // An own font is drawn as its own face: no weight to pick.
            if st.fontAsset == nil {
                EditSeg(options: [(400, "Regular"), (700, "Bold"), (900, "Black")], selection: st.weight) { w in change { $0.style.weight = w } }
            }
            SuiteSlider("Size", value: st.sizePct, range: 0.015...0.15, format: { "\(Int(($0 * 1000).rounded()) / 10) %" }) { v in
                change { $0.style.sizePct = (v * 1000).rounded() / 1000 }
            }
            EditSeg(options: [(EditV2.Align.left, "Left"), (.center, "Centre"), (.right, "Right")], selection: st.align, mono: false) { a in change { $0.style.align = a } }
            SuiteToggleRow(title: "Outline", isOn: st.stroke != nil) { on in change { $0.style.stroke = on ? EditV2.Stroke(color: "#000000", widthPct: 0.12) : nil } }
            if let sk = st.stroke {
                // Parity wave 1: the outline's colour and width.
                HStack(alignment: .bottom, spacing: Space.s2) {
                    SuiteSlider("Outline width", value: sk.widthPct, range: 0.02...0.3, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                        change { $0.style.stroke?.widthPct = (v * 100).rounded() / 100 }
                    }
                    SuiteSwatch(hex: sk.color, label: "Outline colour") { c in change { $0.style.stroke?.color = c } }
                }
            }
            SuiteToggleRow(title: "Shadow", isOn: st.shadow != nil) { on in
                change { $0.style.shadow = on ? EditV2.Shadow(color: "#000000", opacity: 0.6, blurPct: 0.15, dyPct: 0.06) : nil }
            }
            if let sh = st.shadow {
                HStack(alignment: .bottom, spacing: Space.s2) {
                    SuiteSlider("Shadow blur", value: sh.blurPct, range: 0...0.5, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                        change { $0.style.shadow?.blurPct = (v * 100).rounded() / 100 }
                    }
                    SuiteSwatch(hex: sh.color, label: "Shadow colour") { c in change { $0.style.shadow?.color = c } }
                }
                SuiteSlider("Shadow strength", value: sh.opacity, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                    change { $0.style.shadow?.opacity = (v * 100).rounded() / 100 }
                }
            }
            SuiteSlider("Letter spacing", value: st.letterSpacing ?? 0, range: -0.1...0.5, format: { String(format: "%.2f em", $0) }) { v in
                change { $0.style.letterSpacing = abs(v) < 0.005 ? nil : (v * 100).rounded() / 100 }
            }
            SuiteSlider("Line height", value: st.lineHeight ?? 1.15, range: 0.8...2, format: { String(format: "%.2f", $0) }) { v in
                change { $0.style.lineHeight = (v * 100).rounded() / 100 }
            }
            SuiteToggleRow(title: "Background box", isOn: st.background != nil) { on in
                change { $0.style.background = on ? EditV2.TextBackground(color: "#FFFFFF", opacity: 1, paddingPct: 0.3, radiusPct: 0.2) : nil }
            }
            if let bg = st.background {
                HStack {
                    Text("Box colour").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    Spacer()
                    SuiteSwatch(hex: bg.color, label: "Box colour") { c in change { $0.style.background?.color = c } }
                }
            }
            SuiteToggleRow(title: "Upper case", isOn: st.uppercase == true) { on in change { $0.style.uppercase = on ? true : nil } }
        }
        EditPanel(title: "Timing") {
            SuiteSlider("Duration", value: tx.durationSec, range: 0.3...max(0.4, min(30, session.duration - tx.startSec)),
                        format: { String(format: "%.1f s", $0) }) { v in change { $0.durationSec = (v * 10).rounded() / 10 } }
        }
    }

    /// "Your font…": a .ttf / .otf from this Mac, uploaded, checked and set on this text.
    private func pickFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a font (.ttf or .otf, up to 10 MB)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.importFont(url) }
    }

    private func commitText(_ tx: EditV2.TextItem) {
        guard editingId == tx.id else { return }
        let v = String(draft.prefix(EditV2.maxText))
        editingId = nil
        guard !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        change { $0.text = v }
    }
}

// MARK: - Anim

struct AnimPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        let item = session.state.selectedItem
        switch item {
        case .text(let x): panels(animIn: x.animIn, animOut: x.animOut, text: true)
        case .image(let x): panels(animIn: x.animIn, animOut: x.animOut, text: false)
        case .video(let x): panels(animIn: x.animIn, animOut: x.animOut, text: false)   // video clips too (contract, as Android)
        default:
            VStack(alignment: .leading, spacing: 0) {
                InspectorEmpty(text: "Select a clip, text, hook or sticker to animate it in and out.")
            }
        }
    }

    private func set(_ isIn: Bool, _ a: EditV2.Anim?) {
        session.edit { s in
            s.changeSelected { it in
                switch it {
                case .text(var x): if isIn { x.animIn = a } else { x.animOut = a }; it = .text(x)
                case .image(var x): if isIn { x.animIn = a } else { x.animOut = a }; it = .image(x)
                case .video(var x): if isIn { x.animIn = a } else { x.animOut = a }; it = .video(x)
                default: break
                }
            }
        }
    }

    @ViewBuilder private func panels(animIn: EditV2.Anim?, animOut: EditV2.Anim?, text: Bool) -> some View {
        ForEach([true, false], id: \.self) { isIn in
            let a = isIn ? animIn : animOut
            EditPanel(title: isIn ? "In" : "Out") {
                FlowLayout(spacing: 6) {
                    ForEach(EditV2.AnimKind.allCases.filter { text || $0 != .typewriter }, id: \.self) { k in
                        Chip(label(k), on: (a?.kind ?? .none) == k) {
                            set(isIn, k == .none ? nil : EditV2.Anim(kind: k, durationSec: a?.durationSec ?? (k == .typewriter ? 1.2 : 0.3)))
                        }
                    }
                }
                if let a {
                    SuiteSlider("Duration", value: a.durationSec, range: 0.1...2, format: { String(format: "%.1f s", $0) }) { v in
                        set(isIn, EditV2.Anim(kind: a.kind, durationSec: (v * 10).rounded() / 10))
                    }
                }
            }
        }
        // Loop animations (contract, WS8 57fe40c): overlays, pictures and text; not the main track.
        if session.state.canLoop {
            let l = session.state.selectedLoop
            EditPanel(title: "Loop") {
                FlowLayout(spacing: 6) {
                    Chip("None", on: l == nil) { session.edit { $0.setLoop(nil) } }
                    ForEach(EditV2.LoopKind.all, id: \.self) { k in
                        Chip(k.label, on: l?.kind == k) {
                            session.edit { $0.setLoop(EditV2.AnimLoop(kind: k, periodSec: l?.periodSec ?? (k == .spin ? 4 : 1.5), amount: l?.amount)) }
                        }
                    }
                }
                if let l {
                    SuiteSlider("Speed", value: l.periodSec, range: 0.2...5, format: { String(format: "%.1f s a cycle", $0) }) { v in
                        session.edit { $0.setLoop(EditV2.AnimLoop(kind: l.kind, periodSec: (v * 10).rounded() / 10, amount: l.amount)) }
                    }
                    if l.kind != .spin {
                        SuiteSlider("Amount", value: l.amount ?? 0.5, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                            session.edit { $0.setLoop(EditV2.AnimLoop(kind: l.kind, periodSec: l.periodSec, amount: (v * 100).rounded() / 100)) }
                        }
                    }
                }
            }
        }
    }

    private func label(_ k: EditV2.AnimKind) -> String {
        switch k {
        case .none: return "None"
        case .fade: return "Fade"
        case .pop: return "Pop"
        case .slideUp: return "Slide up"
        case .slideDown: return "Slide down"
        case .zoom: return "Zoom"
        case .typewriter: return "Typewriter"
        }
    }
}


/// Translated captions (XL, owner-approved): the captions' language, "Translate…" (the sheet: on this Mac free, or the
/// server's Standard / Best quality with the price shown first), and "Show <language>" once translated.
struct TranslateCaptionsRow: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var showSheet = false

    var body: some View {
        let s = session.state
        let name = { (code: String?) -> String? in code.map { c in session.translateLanguages.first { $0.code == c }?.name
            ?? EditSuiteTranslateSheet.languages.first { $0.0 == c }?.1 ?? c } }
        VStack(alignment: .leading, spacing: Space.s2) {
            SuiteLabel("Language", trailing: name(s.captionLanguage))
            HStack(spacing: Space.s2) {
                SuiteToolButton(title: session.isRunning(.translate) ? "Translating…" : "Translate…", icon: "chat-circle-text",
                                disabled: session.isRunning(.translate)) { showSheet = true }
                if session.isRunning(.translate) { ProgressView().controlSize(.small) }
                if s.captionsTranslated {
                    // The other set of words (the original, or the translation once switched back).
                    SuiteToolButton(title: "Show \(name(s.captionOriginalLanguage) ?? "original")", plain: true) { session.edit { $0.swapCaptionOriginal() } }
                        .help("Switches the captions between the two languages")
                }
                Spacer(minLength: 0)
            }
        }
        .sheet(isPresented: $showSheet) { EditSuiteTranslateSheet(session: session) }
    }
}
