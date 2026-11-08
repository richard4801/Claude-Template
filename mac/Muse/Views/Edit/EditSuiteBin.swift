import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The media panel (E1, plans/edit-layout.md): a 72 pt rail of tabs with icon and label (Takes, Uploads, Music, Text,
/// Stickers, Templates), then the tab's panel: a heading with "Hide media", its content, and Import / Record VO.
struct EditSuiteBin: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var hide: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            rail
            SuiteRule(vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Space.s2) {
                    Text(session.binTab.label).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1).fitProbe("media heading")
                    Spacer(minLength: 0)
                    SuiteIconButton(systemName: "caret-double-left", label: "Hide media", tint: t.roles.ink2, action: hide)
                }
                .padding(.horizontal, Space.s4)
                .padding(.top, Space.s3)
                .padding(.bottom, Space.s2)
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s3) { content }
                        .padding(.horizontal, Space.s4)
                        .padding(.bottom, Space.s4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s2) { importButton; recordButton }
                    VStack(alignment: .leading, spacing: Space.s2) { importButton; recordButton }
                }
                .padding(Space.s4)
            }
        }
        .background(t.roles.canvas)
    }

    private var importButton: some View {
        SuiteToolButton(title: "Import", icon: "upload-simple") { importAudio(kind: session.binTab == .music ? .music : .voice) }
    }

    private var recordButton: some View {
        SuiteToolButton(title: session.isRecordingVO ? "Stop recording" : "Record VO", icon: session.isRecordingVO ? "stop.circle.fill" : "microphone") {
            Task { await session.toggleRecordVO() }
        }
        .help(session.isRecordingVO ? "Stop and add the voice-over to the voice row" : "Record a voice-over with the microphone")
        .accessibilityLabel(session.isRecordingVO ? "Stop recording the voice-over" : "Record a voice-over")
    }

    private var rail: some View {
        VStack(spacing: Space.s1) {
            ForEach(EditSuite.BinTab.allCases) { tab in
                let on = session.binTab == tab
                Button { session.binTab = tab } label: {
                    VStack(spacing: Space.s1) {
                        Ph(icon(tab), 16)
                        Text(tab.label).font(t.scale.micro.font).lineLimit(1).fitProbe("media tab \(tab.label)")
                    }
                    .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                    .frame(width: 64, height: 56)
                    .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(on ? t.roles.field : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s3)
        .frame(width: 72)
    }

    private func icon(_ tab: EditSuite.BinTab) -> String {
        switch tab {
        case .takes: return "film-strip"
        case .uploads: return "upload-simple"
        case .music: return "music-notes"
        case .text: return "text-aa"
        case .stickers: return "sticker"
        case .templates: return "stack"
        }
    }

    @ViewBuilder private var content: some View {
        switch session.binTab {
        case .takes: takes
        case .uploads, .music: audioList
        case .text: textList
        case .stickers:
            Note("Sticker packs are coming soon.")
        case .templates: templates
        }
    }

    // MARK: Takes

    /// Two columns: picture, name, duration in tabular figures. Double-click adds a take to the end.
    private var takes: some View {
        let list = store.editSuiteTakes
        return VStack(alignment: .leading, spacing: Space.s3) {
            if list.isEmpty { Note("No video takes yet.") }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s2), GridItem(.flexible(), spacing: Space.s2)], alignment: .leading, spacing: Space.s3) {
                ForEach(list) { tk in
                    let used = session.project.assets.contains { $0.take == tk.id }
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Color.clear
                            .frame(height: 112)
                            .frame(maxWidth: .infinity)
                            .overlay { MuseImage(ref: tk.thumb, symbol: "film") }
                            .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                            .overlay(alignment: .topLeading) {
                                if used {
                                    Ph("check", 10).foregroundStyle(t.roles.onAction)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(t.roles.action))
                                        .padding(Space.s1 + 2)
                                        .accessibilityHidden(true)
                                }
                            }
                        Text(tk.title).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let d = tk.durationSec {
                            Text(String(format: "%.1f s", d)).font(t.scale.micro.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { session.addTake(tk) }
                    .contextMenu {
                        Button("Add to the end") { session.addTake(tk) }
                        Button("Add as overlay at the playhead") { session.addTake(tk, overlay: true) }
                    }
                    .help("Double-click to add to the end, right-click for an overlay")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Take \(tk.title)")
                    .accessibilityAction(named: "Add to the end") { session.addTake(tk) }
                }
            }
        }
    }

    // MARK: Uploads / music

    private var audioList: some View {
        let audio = session.project.assets.filter { $0.kind == .audio }
        return VStack(alignment: .leading, spacing: Space.s3) {
            if audio.isEmpty {
                Note(session.binTab == .music ? "Import a song (MP3, M4A, WAV) to put it under the video." : "Import voice-overs and sounds from this Mac.")
            }
            ForEach(audio) { a in
                HStack(spacing: Space.s2) {
                    Ph("waveform", 15).foregroundStyle(t.roles.ink2)
                    Text(session.state.assetNames[a.id] ?? a.id).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Spacer()
                    if let d = a.durationSec { Text(EditSuite.clock(d)).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2) }
                    Menu {
                        Button("Add as music") { session.edit { $0.addAudio(a, kind: .music) } }
                        Button("Add as voice-over") { session.edit { $0.addAudio(a, kind: .voice) } }
                        Button("Add as sound effect") { session.edit { $0.addAudio(a, kind: .sfx) } }
                    } label: { Image(nsImage: Ph.menuImage("plus", 16)) } // a Menu label ignores frames; the image comes at its size
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .frame(width: 28, height: 28)
                        .help("Add")
                        .accessibilityLabel("Add \(session.state.assetNames[a.id] ?? "audio")")
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                SuiteToolButton(title: "Import music", icon: "music-notes") { importAudio(kind: .music) }
                SuiteToolButton(title: "Import sound", icon: "speaker-high") { importAudio(kind: .sfx) }
            }
        }
    }

    private func importAudio(kind: EditV2.TrackKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.importAudio(url, kind: kind) }
    }

    // MARK: Text and templates

    private var textList: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SuiteToolButton(title: "Add text", icon: "plus") { session.edit { $0.addText() } }
                .help("Add text at the playhead")
            SuiteLabel("Hooks")
            ForEach(EditV2.hooks) { h in hookRow(h) }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                SuiteLabel("Hook templates")
                Text("For the first 2 seconds").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
            ForEach(EditV2.hooks) { h in hookRow(h) }
            SuiteLabel("Caption styles").padding(.top, Space.s2)
            ForEach(EditV2.suiteCaptionStyles, id: \.self) { p in
                Button { session.edit { $0.setCaptionPreset(p) } } label: {
                    HStack {
                        Text(EditV2.captionStyleLabel(p)).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        Spacer()
                        if session.state.captionStyle?.preset == p { Ph("check", 15).foregroundStyle(t.roles.accent) }
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.project.captionTrack == nil)
            }
            if session.project.captionTrack == nil { Note("Add captions first (Make captions in the inspector).") }
        }
    }

    /// The hook drawn on black above its name.
    private func hookRow(_ h: EditV2.HookTemplate) -> some View {
        Button { session.edit { $0.addHook(h) } } label: {
            VStack(alignment: .leading, spacing: Space.s1) {
                HookChip(template: h)
                    .frame(height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: min(t.radii.control, 8), style: .continuous))
                HStack(spacing: Space.s2) {
                    Text(h.label).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(2)
                    Spacer(minLength: 0)
                    Ph("plus", 14).foregroundStyle(t.roles.ink2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add hook \(h.label)")
    }
}

/// A hook template drawn small, on black (its font, colours and background).
struct HookChip: View {
    var template: EditV2.HookTemplate
    var body: some View {
        let s = template.style
        let fg = Color(hex: UInt32(s.color.dropFirst(), radix: 16) ?? 0xFFFFFF)
        let bg = s.background.map { Color(hex: UInt32($0.color.dropFirst(), radix: 16) ?? 0, alpha: $0.opacity) }
        ZStack {
            Rectangle().fill(Color(hex: 0x141210))
            Text(s.uppercase == true ? template.text.uppercased() : template.text)
                .font(.system(size: 10, weight: s.weight >= 900 ? .black : s.weight >= 700 ? .bold : .regular,
                              design: s.font == .serif ? .serif : s.font == .mono ? .monospaced : s.font == .rounded ? .rounded : .default))
                .foregroundStyle(fg)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .background(bg ?? .clear)
                .padding(.horizontal, 4)
        }
        .accessibilityHidden(true)
    }
}
