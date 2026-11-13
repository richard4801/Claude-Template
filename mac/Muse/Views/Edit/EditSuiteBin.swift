import AppKit
import ImageIO
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The media panel (E1, plans/edit-layout.md): a 72 pt rail of tabs with icon and label (Takes, Uploads, Music, Text,
/// Stickers, Templates), then the tab's panel: one header (the tab's name, at most one "Add", "Hide media") and its content.
///
/// Owner, 2026-11-12 ("redundant features, and the AI-ish info… not properly visually optimised"): Uploads is a media bin
/// (plans/design/edit-panels/uploads-{b,a}.png). One "Add" (From this Mac, From a link, Record voice-over; the file decides
/// the kind), drop anywhere on the panel, a grid of thumbnails with "+" and drag-to-place, filter chips only when the kinds
/// are mixed, and an empty state of one drop zone and one line. The import bar that sat under every tab is gone; each tab
/// that adds something has its own "Add" in the header.
struct EditSuiteBin: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var hide: () -> Void
    @State private var filter: EditSuite.UploadFilter = .all
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 0) {
            rail
            SuiteRule(vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                header
                if session.binTab == .uploads, session.isRecordingVO { recordingStrip }
                if session.binTab == .uploads, session.uploads.isEmpty {
                    dropZone
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) { content }
                            .padding(.horizontal, Space.s3)
                            .padding(.bottom, Space.s4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .overlay {
                // Dropping files anywhere on the panel: one outline in the selection colour, nothing else.
                if dropping {
                    RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                        .strokeBorder(t.roles.accent, lineWidth: 2)
                        .padding(Space.s1)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else {
                    // A link dropped on the panel imports like From a link.
                    return urls.first.map { store.importDroppedLink($0, for: .edit) } ?? false
                }
                Task { await session.addFiles(files) }
                return true
            } isTargeted: { dropping = $0 }
        }
        .background(t.roles.canvas)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.s2) {
            Text(session.binTab.label).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1).fitProbe("media heading")
            Spacer(minLength: 0)
            headerAction
            SuiteIconButton(systemName: "caret-double-left", label: "Hide media", size: 28, tint: t.roles.ink2, action: hide)
        }
        .padding(.leading, Space.s4)
        .padding(.trailing, Space.s2)
        .frame(height: 48)
    }

    @ViewBuilder private var headerAction: some View {
        switch session.binTab {
        case .uploads:
            if !session.isRecordingVO {
                AddMenu(label: "Add to Uploads") {
                    Button("From this Mac…") { chooseFiles() }.keyboardShortcut("i", modifiers: .command)
                    Button("From a link…") { store.openLinkImport(.edit) }
                    Button("Record voice-over") { Task { await session.toggleRecordVO() } }
                    Divider()
                    Toggle("Play the video while recording", isOn: $session.voPlayback)
                }
            }
        case .music:
            AddButton(label: "Add a song from this Mac") { chooseSong() }
        case .text:
            AddButton(label: "Add text at the playhead") { session.edit { $0.addText() } }
        case .stickers:
            AddMenu(label: "Add a sticker") {
                Button("Picture from this Mac…") { choosePicture() }
                Button(session.isRunning(.cutout) ? "Cutting out…" : "Cut out a picture…") { chooseCutout() }
                    .disabled(session.isRunning(.cutout))
            }
        case .takes, .templates:
            EmptyView()
        }
    }

    /// Recording a voice-over: the header's Add gives way to the live strip.
    private var recordingStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let secs = session.voStartedAt.map { max(0, ctx.date.timeIntervalSince($0)) } ?? 0
            HStack(spacing: Space.s2) {
                Circle().fill(t.roles.danger).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Recording").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                Text(EditSuite.UploadBin.length(secs) ?? "0:00").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                Spacer(minLength: 0)
                SuiteToolButton(title: "Stop", plain: true) { Task { await session.toggleRecordVO() } }
                    .help("Stop and add the voice-over to the voice row")
                    .accessibilityLabel("Stop recording the voice-over")
            }
            .padding(.leading, Space.s3)
            .padding(.trailing, Space.s1)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
            .padding(.horizontal, Space.s3)
            .padding(.bottom, Space.s3)
        }
    }

    // MARK: Rail

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
        case .uploads: uploads
        case .music: music
        case .text: textList
        case .stickers: stickers
        case .templates: templates
        }
    }

    private let grid = [GridItem(.flexible(), spacing: Space.s2), GridItem(.flexible(), spacing: Space.s2)]

    // MARK: Takes

    /// The studio's video takes as tiles: "+" puts one into the sequence at the playhead, dragging places it.
    private var takes: some View {
        let list = store.editSuiteTakes
        return Group {
            if list.isEmpty {
                Text("No video takes yet").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            } else {
                LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s3) {
                    ForEach(list) { tk in
                        MediaTile(name: tk.title.isEmpty ? "Take" : tk.displayTitle, mark: "film-strip", length: EditSuite.UploadBin.length(tk.durationSec),
                                  used: session.project.assets.contains { $0.take == tk.id }, drag: BinDrag.take(tk.id),
                                  plusHelp: "Add at the playhead") {
                            session.placeTake(tk)
                        } thumb: {
                            MuseImage(ref: tk.thumb, symbol: "film")
                        }
                        .contextMenu {
                            Button("Add at the playhead") { session.placeTake(tk) }
                            Button("Add to the end") { session.addTake(tk) }
                            Button("Add as overlay at the playhead") { session.addTake(tk, overlay: true) }
                            Button("Add its sound at the playhead") { session.addTakeSound(tk) }
                            Button("Replace the clip with this take") { session.replaceClip(with: tk) }
                        }
                        .accessibilityLabel("Take \(tk.title)")
                    }
                }
            }
        }
    }

    // MARK: Uploads

    private var uploads: some View {
        let all = session.uploads
        let chips = EditSuite.UploadBin.filters(all)
        let shown = EditSuite.UploadBin.filtered(all, by: filter)
        return VStack(alignment: .leading, spacing: Space.s3) {
            if !chips.isEmpty {
                HStack(spacing: Space.s1) {
                    ForEach(chips) { f in
                        Chip(f.label, on: (chips.contains(filter) ? filter : .all) == f) { filter = f }
                            .accessibilityLabel("Show \(f.label.lowercased())")
                    }
                }
            }
            LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s3) {
                ForEach(shown) { u in uploadTile(u) }
            }
        }
    }

    private func uploadTile(_ u: EditSuite.Upload) -> some View {
        let mark = u.kind == .video ? "film-strip" : u.kind == .picture ? "image" : "waveform"
        let file = session.files[u.id]
        return MediaTile(name: u.name, mark: mark, length: EditSuite.UploadBin.length(u.durationSec), drag: BinDrag.upload(u.id),
                         plusHelp: "Add at the playhead") {
            session.placeUpload(u.id)
        } thumb: {
            switch u.kind {
            case .audio: WaveTile(url: file)
            case .video: FrameTile(url: file, video: true, at: min(1, (u.durationSec ?? 0) / 2))
            case .picture: FrameTile(url: file, video: false, at: 0)
            }
        }
        .contextMenu {
            Button("Add at the playhead") { session.placeUpload(u.id) }
            switch u.kind {
            case .video:
                Button("Add as overlay at the playhead") { session.placeUpload(u.id, lane: .video) }
            case .audio:
                Button("Add as music") { session.placeUpload(u.id, audioKind: .music) }
                Button("Add as voice-over") { session.placeUpload(u.id, audioKind: .voice) }
                Button("Add as sound effect") { session.placeUpload(u.id, audioKind: .sfx) }
            case .picture:
                EmptyView()
            }
        }
        .accessibilityLabel(u.name)
    }

    /// Nothing uploaded yet: one drop zone and one line.
    private var dropZone: some View {
        Button { chooseFiles() } label: {
            VStack(spacing: Space.s2) {
                Ph("upload-simple", 24)
                Text("Drop files here or Add").font(t.scale.caption.font)
            }
            .foregroundStyle(t.roles.ink2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                .strokeBorder(t.roles.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.s3)
        .padding(.top, Space.s1)
        .padding(.bottom, Space.s3)
        .accessibilityLabel("Add files from this Mac")
    }

    // MARK: Music

    /// Songs in this edit, then the sound effects library.
    private var music: some View {
        let songs = session.uploads.filter { $0.kind == .audio }
        return VStack(alignment: .leading, spacing: Space.s5) {
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(songs) { a in
                        HStack(spacing: Space.s2) {
                            Ph("waveform", 16).foregroundStyle(t.roles.ink2).frame(width: 28)
                            Text(a.name).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle).help(a.name)
                            Spacer(minLength: Space.s2)
                            if let l = EditSuite.UploadBin.length(a.durationSec) {
                                Text(l).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                            }
                            SuiteIconButton(systemName: "plus", label: "Add \(a.name) as music", size: 28) { session.placeUpload(a.id, audioKind: .music) }
                        }
                        .frame(height: 36)
                        .contextMenu {
                            Button("Add as music") { session.placeUpload(a.id, audioKind: .music) }
                            Button("Add as voice-over") { session.placeUpload(a.id, audioKind: .voice) }
                            Button("Add as sound effect") { session.placeUpload(a.id, audioKind: .sfx) }
                        }
                    }
                }
            }
            ContentSounds(session: session)
        }
    }

    // MARK: Text and templates

    private var textList: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SuiteLabel("Hooks")
            ForEach(EditV2.hooks) { h in hookRow(h) }
        }
    }

    /// Caption styles (the hooks live in Text: they were listed twice).
    private var templates: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SuiteLabel("Caption styles")
            if session.project.captionTrack == nil {
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Make captions", icon: "closed-captioning",
                                    disabled: session.isRunning(.captions) || !session.helperAvailable(.captions)) { Task { await session.autoCaptions() } }
                        .help(session.helperNote(.captions) ?? session.estimateLabel(.captions).map { "Word-timed captions from what's said, \($0)" } ?? "Word-timed captions from what's said")
                    if session.isRunning(.captions) { ProgressView().controlSize(.small) }
                }
                .padding(.bottom, Space.s1)
            }
            ForEach(EditV2.suiteCaptionStyles, id: \.self) { p in
                Button { session.edit { $0.setCaptionPreset(p) } } label: {
                    HStack {
                        Text(EditV2.captionStyleLabel(p)).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        Spacer()
                        if session.state.captionStyle?.preset == p { Ph("check", 16).foregroundStyle(t.roles.accent) }
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.project.captionTrack == nil)
            }
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
                    Ph("plus", 16).foregroundStyle(t.roles.ink2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add hook \(h.label)")
    }

    // MARK: Stickers

    /// The content library's stickers, then this edit's own pictures (shown once there are some).
    private var stickers: some View {
        let pics = session.pictureAssets
        return VStack(alignment: .leading, spacing: Space.s3) {
            ContentStickers(session: session)
            if !pics.isEmpty {
                SuiteLabel("Your pictures").padding(.top, Space.s2)
                LazyVGrid(columns: grid, spacing: Space.s2) {
                    ForEach(pics) { a in
                        let name = session.state.assetNames[a.id] ?? "Picture"
                        Button { session.edit { $0.addImage(a) } } label: {
                            FrameTile(url: session.files[a.id], video: false, at: 0, fit: true)
                                .frame(height: 72).frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel("Add sticker \(name)")
                    }
                }
            }
        }
    }

    // MARK: Files

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .png, .jpeg, .heic, .webP, .audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await session.addFiles(urls) }
    }

    private func chooseSong() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.importAudio(url, kind: .music) }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        // From Stickers each picture also goes on at the playhead (Stickers row), as it did before the bin.
        Task {
            for url in urls {
                let before = Set(session.uploads.map(\.id))
                await session.addFiles([url])
                if let added = session.uploads.first(where: { !before.contains($0.id) }) { session.placeUpload(added.id) }
            }
            session.binTab = .stickers
        }
    }

    private func chooseCutout() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.cutoutPicture(url) }
    }
}

// MARK: - Pieces

/// What a tile carries when dragged to the timeline (TimelineCanvas reads it back).
enum BinDrag {
    static func upload(_ id: String) -> String { "muse-upload:\(id)" }
    static func take(_ id: String) -> String { "muse-take:\(id)" }
    /// (kind, id) of a dragged string, or nil when it isn't one of ours.
    static func parse(_ s: String) -> (take: Bool, id: String)? {
        if s.hasPrefix("muse-upload:") { return (false, String(s.dropFirst("muse-upload:".count))) }
        if s.hasPrefix("muse-take:") { return (true, String(s.dropFirst("muse-take:".count))) }
        return nil
    }
}

/// The header's one "Add", as a plain button.
private struct AddButton: View {
    var label: String
    var action: () -> Void
    var body: some View {
        SuiteToolButton(title: "Add", icon: "plus", action: action)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// The header's one "Add", opening a small menu.
private struct AddMenu<Items: View>: View {
    @Environment(\.theme) private var t
    var label: String
    @ViewBuilder var items: () -> Items
    @State private var hover = false

    var body: some View {
        Menu(content: items) {
            Label { Text("Add") } icon: { Image(nsImage: Ph.menuImage("plus", 14)) }
                .labelStyle(.titleAndIcon)
                .font(t.scale.label.font)
                .foregroundStyle(t.roles.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, Space.s2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.hairline : t.roles.field))
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A media tile: the picture (or waveform) with its type mark and length on a scrim, the name under it (the full name
/// on hover), "+" while the pointer is over it, and dragging onto the timeline places it.
private struct MediaTile<Thumb: View>: View {
    @Environment(\.theme) private var t
    var name: String
    var mark: String
    var length: String?
    var used = false
    var drag: String
    var plusHelp: String
    var onPlus: () -> Void
    @ViewBuilder var thumb: () -> Thumb
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s1) {
            Color.clear
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .overlay { thumb() }
                .background(t.roles.field)
                .clipShape(shape)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: Space.s1) {
                        Ph(mark, 12)
                        if let length { Text(length).font(t.scale.micro.font).monospacedDigit() }
                        if used { Ph("check", 12).accessibilityLabel("In this edit") }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(Color.black.opacity(0.55)))
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Button(action: onPlus) {
                            Ph("plus", 16).foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(Color.black.opacity(0.55)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(plusHelp)
                        .padding(6)
                    }
                }
            Text(name).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onPlus)
        .help(name)
        .draggable(drag)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: plusHelp, onPlus)
    }
}

/// A video's frame or a picture, read small (thumbnails, not full files) and kept for the session.
private struct FrameTile: View {
    @Environment(\.theme) private var t
    var url: URL?
    var video: Bool
    var at: Double
    var fit = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                Ph(video ? "film-strip" : "image", 20).foregroundStyle(t.roles.ink2).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let key = "\(url.path)#\(video ? at : -1)" as NSString
            if let hit = BinThumbs.images.object(forKey: key) { image = hit; return }
            let cg: CGImage?
            if video {
                cg = await EditSuiteMedia.frame(url, at: at, maxSide: 320)
            } else {
                cg = await Task.detached(priority: .utility) { () -> CGImage? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: 320]
                    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                }.value
            }
            guard let cg, !Task.isCancelled else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            BinThumbs.images.setObject(img, forKey: key)
            image = img
        }
    }
}

/// A sound as a waveform tile.
private struct WaveTile: View {
    @Environment(\.theme) private var t
    var url: URL?
    @State private var peaks: [Float] = []
    private static let bars = 24

    var body: some View {
        GeometryReader { g in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<Self.bars, id: \.self) { i in
                    let v = peaks.isEmpty ? 0.08 : CGFloat(peaks[min(i, peaks.count - 1)])
                    RoundedRectangle(cornerRadius: 1).fill(t.roles.ink2.opacity(0.85))
                        .frame(height: max(2, (g.size.height - 52) * min(1, max(0.06, v))))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: g.size.width, height: g.size.height)
            .offset(y: -6)
        }
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { return }
            if let hit = BinThumbs.peaks.object(forKey: url.path as NSString) as? [Float] { peaks = hit; return }
            let w = await EditSuiteMedia.waveform(url, count: Self.bars)
            guard !Task.isCancelled, !w.isEmpty else { return }
            let top = max(w.max() ?? 1, 0.0001)
            let norm = w.map { $0 / top }
            BinThumbs.peaks.setObject(norm as NSArray, forKey: url.path as NSString)
            peaks = norm
        }
    }
}

/// Thumbnails and waveforms already read, by file (the grid scrolls back over them).
private enum BinThumbs {
    static let images: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 300; return c }()
    static let peaks: NSCache<NSString, NSArray> = { let c = NSCache<NSString, NSArray>(); c.countLimit = 300; return c }()
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
