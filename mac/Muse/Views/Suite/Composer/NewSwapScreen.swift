import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// New Swap's own screen (plans/swap-viewer-design.md §A, owner-approved 2026-11-12). Not the composer with a panel:
// - The stage: before a video, the source (Library grid, Upload, Paste link; a file can be dropped anywhere on it);
//   with one, the clip in the take viewer at its own shape, and a filmstrip trimmer under it.
// - The right column: the four changes (NewSwapPanel, onScreen), each with one field.
// - The bottom bar: clip sound, the model, the price and Generate · $x. No prompt box.
// While a take renders, and once it's done, the stage shows it (the result pane); "Back to the clip" returns.

struct NewSwapScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var narrow: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.s6) {
                Group {
                    if store.suite.claude.open && store.isOwner {
                        SuiteClaudePanel()
                    } else if store.suite.feedOpen {
                        ComposerFeed()
                    } else {
                        NewSwapStage()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(.vertical, showsIndicators: false) {
                    NewSwapPanel(onScreen: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: narrow ? 320 : 352)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .padding(.bottom, Space.s4)
            Rectangle().fill(t.roles.hairline).frame(height: 1)
            ComposerBottomBar()
                .padding(.top, Space.s3)
                .accessibilityIdentifier("newSwap.bottomBar")
        }
    }
}

// MARK: The stage

struct NewSwapStage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The take rendering or just made is on the stage (after Generate); "Back to the clip" clears it.
    @State private var showResult = false
    @State private var dropping = false
    @State private var replaceLibrary = false

    var body: some View {
        Group {
            if showResult {
                VStack(alignment: .leading, spacing: Space.s3) {
                    Button { showResult = false } label: {
                        HStack(spacing: Space.s1) { Ph("caret-left", 14); Text("Back to the clip").font(t.scale.label.font) }
                            .foregroundStyle(t.roles.ink).frame(minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the clip and the trimmer again")
                    ComposerMediaPane()
                }
            } else if let c = store.clip {
                filled(c)
            } else {
                NewSwapSourcePicker()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            if u.isFileURL { store.importClip(u) } else { store.openLinkImport(.swap, link: u.absoluteString) }
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: t.radii.container)
                    .strokeBorder(t.roles.accent, lineWidth: 2)
                    .overlay(Text("Drop to use this video").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.raised)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.suite.generating) { _, on in if on { showResult = true } }
        .onChange(of: store.clip?.id) { _, _ in showResult = false }
    }

    private func filled(_ c: Clip) -> some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Text(c.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.s2)
                Text("\(Take.clock(c.durationSec)), \(c.width) × \(c.height)").font(t.scale.caption.font).monospacedDigit()
                    .foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                Menu {
                    Button("From the Library…") { replaceLibrary = true }
                    Button("Upload a file…") { store.pickClip() }
                    Button("Paste a link…") { store.openLinkImport(.swap) }
                } label: {
                    HStack(spacing: Space.s1) { Text("Replace").font(t.scale.label.font); Ph("caret-down", 12) }.foregroundStyle(t.roles.ink)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Use another video")
                .popover(isPresented: $replaceLibrary, arrowEdge: .bottom) {
                    NewSwapLibraryPicker { replaceLibrary = false }
                        .environment(store)
                        .environment(\.theme, PickerTheme.dark)
                        .environment(\.colorScheme, .dark)
                }
            }
            .frame(maxWidth: 600)
            .frame(height: 32)
            TakeViewer(media: ViewerMedia(id: c.id, videoURL: store.clipVideo, poster: store.clipPoster, width: c.width, height: c.height, label: c.name),
                       context: .source, autoplay: false, startMuted: true, previewControls: false)
                .id(c.id)
                .frame(maxHeight: .infinity)
            NewSwapTrimmer(clip: c)
                .frame(maxWidth: 600)
        }
    }
}

// MARK: The source (empty state)

struct NewSwapSourcePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    enum Tab: String, CaseIterable { case library = "Library", upload = "Upload", link = "Paste link" }
    @State private var tab: Tab = .library

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Add the video to remix").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                Text("Pick a take from your Library, upload a file, or paste a link. You can also drop a file anywhere here.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Source", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch tab {
            case .library: library
            case .upload: upload
            case .link: link
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var library: some View {
        let list = store.extendableTakes
        return Group {
            if list.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("No finished videos yet. Upload one, or paste a link.").font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                    MButton("Upload a file…") { tab = .upload; store.pickClip() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 120), spacing: Space.s4, alignment: .top)], alignment: .leading,
                              spacing: Space.s5) {
                        ForEach(list) { item in
                            Button { store.useTakeAsRemixSource(item.take) } label: { tile(item) }
                                .buttonStyle(.plain)
                                .help("Use \(item.take.caption)")
                                .accessibilityLabel("Use \(item.take.caption)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func tile(_ item: ExtendTakeOption) -> some View {
        let r = ViewerFrame.aspect(width: item.take.width, height: item.take.height, isVideo: true)
        return VStack(alignment: .leading, spacing: Space.s1) {
            Color.clear
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay {
                    // The take at its own shape inside the tile's 9:16 cell, centred on the page tone.
                    MuseImage(ref: item.take.thumb).aspectRatio(r, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
                }
                .overlay(alignment: .bottomLeading) {
                    if let s = item.source.seconds {
                        Text(Take.clock(s)).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(.black.opacity(0.55)))
                            .padding(Space.s2)
                    }
                }
            Text(item.take.caption).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var upload: some View {
        VStack(spacing: Space.s3) {
            Text("Drop a video here, or").font(t.scale.body.font).foregroundStyle(t.roles.ink2)
            MButton("Choose a file…") { store.pickClip() }
            Text("MP4 or MOV. MUSE checks it after the upload.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: 280)
        .background(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(t.roles.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("A link to a video on the web. MUSE downloads it and checks it, as with an upload.")
                .font(t.scale.body.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            MButton("Paste a link…") { store.openLinkImport(.swap) }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: The filmstrip trimmer

/// The part of the clip used, picked on a strip of its frames: drag a handle to change the length (within the model's
/// limits), drag the middle to slide it. A clip longer than the model takes is never cut silently: until a part is
/// picked, the line asks for it (and Generate waits).
struct NewSwapTrimmer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var clip: Clip
    @State private var frames: [CGImage] = []
    /// The window while dragging (the store gets it when the drag ends, so the price is asked once).
    @State private var live: TrimWindow?
    @State private var dragStart: TrimWindow?

    private var d: RemixDraft { store.suite.remix }
    private var row: RemixModels.Row? { store.suite.remixModels?.models.first { d.engineModel == nil ? $0.auto : $0.model == d.engineModel } }
    private var maxS: Double { store.suite.remixEstimate?.remix?.trim.maxSeconds ?? row?.limits.maxSeconds ?? clip.durationSec }
    private var minS: Double { store.suite.remixEstimate?.remix?.trim.minSeconds ?? row?.limits.minSeconds ?? 1 }

    private var window: TrimWindow {
        live ?? TrimWindow.initial(duration: clip.durationSec, minLen: minS, maxLen: maxS, range: d.range.map { ($0.from, $0.to) })
    }

    var body: some View {
        let w = window
        let needed = !w.wholeClipFits && d.range == nil
        VStack(alignment: .leading, spacing: Space.s2) {
            GeometryReader { g in strip(w, width: g.size.width) }
                .frame(height: 56)
            HStack(spacing: Space.s3) {
                Text(needed ? "Pick the part to use: \(row?.label ?? "this model") takes up to \(Pricing.trimNum(maxS)) s." : w.line(model: row?.label))
                    .font(t.scale.caption.font).monospacedDigit()
                    .foregroundStyle(needed ? t.roles.caution : t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s2)
                if needed {
                    Button("Use \(Take.clock(w.from))–\(Take.clock(w.to))") { store.setRemixRange(from: w.from, to: w.to) }
                        .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link).fixedSize()
                } else if w.wholeClipFits && d.range != nil {
                    Button("Use the whole clip") { store.suite.remix.range = nil }
                        .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link).fixedSize()
                }
            }
        }
        .task(id: store.clipVideo) { frames = await Filmstrip.frames(store.clipVideo, count: 12) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Part of the clip used: \(Take.clock(w.from)) to \(Take.clock(w.to))")
    }

    private func strip(_ w: TrimWindow, width: CGFloat) -> some View {
        let dur = max(clip.durationSec, 0.1)
        let x = { (s: Double) -> CGFloat in CGFloat(s / dur) * width }
        let a = x(w.from), b = x(w.to)
        let cell = width / 12
        return ZStack(alignment: .topLeading) {
            // The frames (or the poster, until they load); the part not used at 35 %.
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { i in
                    Group {
                        if frames.indices.contains(i) {
                            Image(decorative: frames[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            MuseImage(ref: store.clipPoster)
                        }
                    }
                    .frame(width: cell, height: 56).clipped()
                    .opacity(CGFloat(i) * cell + cell / 2 >= a && CGFloat(i) * cell + cell / 2 <= b ? 1 : 0.35)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
            // The window: drag to slide it.
            Rectangle().fill(Color.clear)
                .frame(width: max(0, b - a), height: 56)
                .overlay(alignment: .top) { Rectangle().fill(t.roles.accent).frame(height: 2) }
                .overlay(alignment: .bottom) { Rectangle().fill(t.roles.accent).frame(height: 2) }
                .contentShape(Rectangle())
                .offset(x: a)
                .gesture(drag { start, dx in var n = start; n.slide(by: dx); return n }, including: .all)
                .help("Drag to slide the part used")
            handle(at: a) { start, dx in var n = start; n.moveStart(to: start.from + dx); return n }
                .help("Drag to change where it starts")
            handle(at: b) { start, dx in var n = start; n.moveEnd(to: start.to + dx); return n }
                .help("Drag to change where it ends")
        }
        .frame(width: width, height: 56, alignment: .leading)
        .onAppear { stripWidth = width }
        .onChange(of: width) { _, v in stripWidth = v }
    }

    private func handle(at x: CGFloat, change: @escaping (TrimWindow, Double) -> TrimWindow) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(t.roles.accent)
            .frame(width: 8, height: 60)
            .frame(width: 20, height: 60) // a wider target than it looks
            .contentShape(Rectangle())
            .offset(x: x - 10, y: -2)
            .gesture(drag(change))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .accessibilityElement()
            .accessibilityLabel("Trim handle")
    }

    /// A drag in points turned into seconds; the store gets the result when the drag ends.
    private func drag(_ change: @escaping (TrimWindow, Double) -> TrimWindow) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? window
                if dragStart == nil { dragStart = start }
                live = change(start, Double(v.translation.width) * max(clip.durationSec, 0.1) / Double(max(stripWidth, 1)))
            }
            .onEnded { _ in
                if let l = live { store.setRemixRange(from: l.from, to: l.to) }
                live = nil
                dragStart = nil
            }
    }

    /// The strip's width, for turning a drag into seconds (the trimmer is at most 600 pt wide).
    @State private var stripWidth: CGFloat = 600
}

/// A clip's frames for the trimmer, small (AVAssetImageGenerator on the local file or the take's video).
enum Filmstrip {
    static func frames(_ url: URL?, count: Int) async -> [CGImage] {
        guard let url, count > 0 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [CGImage] = []
        for i in 0..<count {
            if Task.isCancelled { return out }
            let at = CMTime(seconds: d.seconds * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let r = try? await gen.image(at: at) { out.append(r.image) }
        }
        return out
    }
}
