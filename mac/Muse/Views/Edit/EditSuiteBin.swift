import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The media bin (E1): Takes ("From the AI suite"), Uploads, Music, Text, Stickers, Templates; Import and Record VO.
struct EditSuiteBin: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        VStack(spacing: 0) {
            tabs
            SuiteRule()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SuiteRule()
            HStack(spacing: 8) {
                SuiteToolButton(title: "Import", icon: "square.and.arrow.up") { importAudio(kind: session.binTab == .music ? .music : .voice) }
                SuiteToolButton(title: session.isRecordingVO ? "Stop recording" : "Record VO", icon: session.isRecordingVO ? "stop.circle.fill" : "mic") {
                    Task { await session.toggleRecordVO() }
                }
                .help(session.isRecordingVO ? "Stop and add the voice-over to the voice row" : "Record a voice-over with the microphone")
                .accessibilityLabel(session.isRecordingVO ? "Stop recording the voice-over" : "Record a voice-over")
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(t.chrome)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(EditSuite.BinTab.allCases) { tab in
                let on = session.binTab == tab
                Button { session.binTab = tab } label: {
                    VStack(spacing: 4) {
                        Ph(icon(tab), 15)
                        Text(tab.label).font(t.scale.micro.font).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? t.accent : t.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? t.accent : .clear).frame(height: 2) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
    }

    private func icon(_ tab: EditSuite.BinTab) -> String {
        switch tab {
        case .takes: return "video"
        case .uploads: return "square.and.arrow.up"
        case .music: return "music.note"
        case .text: return "textformat"
        case .stickers: return "sparkle"
        case .templates: return "rectangle.stack"
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

    private var takes: some View {
        let list = store.editSuiteTakes
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("From the AI suite").font(t.scale.label.font).foregroundStyle(t.ink)
                Text(session.title).font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
            }
            if list.isEmpty { Note("No video takes yet.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 8)], alignment: .leading, spacing: 10) {
                ForEach(list) { tk in
                    let used = session.project.assets.contains { $0.take == tk.id }
                    VStack(alignment: .leading, spacing: 4) {
                        MuseImage(ref: tk.thumb, symbol: "film")
                            .aspectRatio(9 / 16, contentMode: .fit)
                            .overlay(alignment: .topLeading) {
                                if used {
                                    Ph("checkmark", 9).foregroundStyle(.white)
                                        .frame(width: 16, height: 16).background(t.accent).padding(5)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if let d = tk.durationSec {
                                    Text(String(format: "%.1fs", d)).font(t.mono(10)).foregroundStyle(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color.black.opacity(0.55)).padding(4)
                                }
                            }
                        Text(tk.title).font(t.scale.micro.font).foregroundStyle(t.muted).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { session.addTake(tk) }
                    .contextMenu {
                        Button("Add to the end") { session.addTake(tk) }
                        Button("Add as overlay at the playhead") { session.addTake(tk, overlay: true) }
                    }
                    .help("Double-click to add to the end · right-click for an overlay")
                    .accessibilityLabel("Take \(tk.title)")
                    .accessibilityAction(named: "Add to the end") { session.addTake(tk) }
                }
            }
        }
    }

    // MARK: Uploads / music

    private var audioList: some View {
        let audio = session.project.assets.filter { $0.kind == .audio }
        return VStack(alignment: .leading, spacing: 10) {
            SuiteLabel(session.binTab == .music ? "Music" : "Uploads")
            if audio.isEmpty {
                Note(session.binTab == .music ? "Import a song (MP3, M4A, WAV) to put it under the video." : "Import voice-overs and sounds from this Mac.")
            }
            ForEach(audio) { a in
                HStack(spacing: 8) {
                    Ph("waveform").foregroundStyle(t.muted)
                    Text(session.state.assetNames[a.id] ?? a.id).font(t.body(12.5)).foregroundStyle(t.ink).lineLimit(1)
                    Spacer()
                    if let d = a.durationSec { Text(EditSuite.clock(d)).font(t.mono(11)).foregroundStyle(t.muted) }
                    Menu {
                        Button("Add as music") { session.edit { $0.addAudio(a, kind: .music) } }
                        Button("Add as voice-over") { session.edit { $0.addAudio(a, kind: .voice) } }
                        Button("Add as sound effect") { session.edit { $0.addAudio(a, kind: .sfx) } }
                    } label: { Image(nsImage: Ph.menuImage("plus", 16)) } // a Menu label ignores frames; the image comes at its size
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Add \(session.state.assetNames[a.id] ?? "audio")")
                }
            }
            HStack(spacing: 8) {
                SuiteToolButton(title: "Import music", icon: "music.note") { importAudio(kind: .music) }
                SuiteToolButton(title: "Import sound", icon: "speaker.wave.2") { importAudio(kind: .sfx) }
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
        VStack(alignment: .leading, spacing: 10) {
            SuiteToolButton(title: "Add text at the playhead", icon: "plus") { session.edit { $0.addText() } }
            SuiteLabel("Hooks")
            ForEach(EditV2.hooks) { h in hookRow(h) }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 10) {
            SuiteLabel("Hook templates", trailing: "First 2 seconds")
            ForEach(EditV2.hooks) { h in hookRow(h) }
            SuiteLabel("Caption styles")
            ForEach(EditV2.suiteCaptionStyles, id: \.self) { p in
                Button { session.edit { $0.setCaptionPreset(p) } } label: {
                    HStack {
                        Text(EditV2.captionStyleLabel(p)).font(t.body(13)).foregroundStyle(t.ink)
                        Spacer()
                        if session.state.captionStyle?.preset == p { Ph("checkmark").foregroundStyle(t.accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.project.captionTrack == nil)
            }
            if session.project.captionTrack == nil { Note("Add captions first (Auto-captions under the timeline).") }
        }
    }

    private func hookRow(_ h: EditV2.HookTemplate) -> some View {
        Button { session.edit { $0.addHook(h) } } label: {
            HStack(spacing: 10) {
                HookChip(template: h).frame(width: 96, height: 32)
                Text(h.label).font(t.body(12.5)).foregroundStyle(t.ink).lineLimit(1)
                Spacer()
                Ph("plus").foregroundStyle(t.ink)
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
