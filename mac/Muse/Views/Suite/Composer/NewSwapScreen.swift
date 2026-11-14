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
        VStack(spacing: Space.s4) {
            HStack(alignment: .top, spacing: 20) {
                Group {
                    if store.suite.claude.open && store.isOwner {
                        SuiteClaudePanel()
                    } else if store.suite.feedOpen {
                        ComposerFeed()
                    } else {
                        NewSwapStage()
                            .padding(Space.s4)
                            .suiteStagePanel(t)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(.vertical, showsIndicators: false) {
                    NewSwapPanel(onScreen: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s4)
                }
                .frame(width: narrow ? 272 : 294)
                .frame(maxHeight: .infinity, alignment: .top)
                .suitePanel(t)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            NewSwapBar()
                .frame(height: 48)
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
    @State private var replaceOpen = false
    /// The clip's player, shared by the viewer, the play button and the trimmer's playhead.
    @State private var playback = ViewerPlayback()

    private func replaceItem(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            replaceOpen = false
            run()
        } label: {
            Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(.horizontal, Space.s3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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
            HStack(alignment: .top, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).font(t.body(15, .semibold)).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
                    // "0:09 · 9:16 · 1080 × 1920": the clip's own length, shape and size.
                    Text([Take.clock(c.durationSec), ShotStageTake.shape(c.width, c.height), "\(c.width) × \(c.height)"].compactMap { $0 }.joined(separator: " · "))
                        .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                }
                Spacer(minLength: Space.s2)
                // A button with a popover, not a Menu (a menu label draws its icon unsized).
                Button { replaceOpen.toggle() } label: {
                    HStack(spacing: Space.s2) {
                        Ph("upload-simple", 14).frame(width: 16, height: 16)
                        Text("Replace clip").font(t.scale.label.font)
                    }
                    .foregroundStyle(t.roles.ink)
                    .padding(.horizontal, Space.s3).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.raised))
                    .overlay(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize()
                .help("Use another video")
                .popover(isPresented: $replaceOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        replaceItem("From the Library…") { replaceLibrary = true }
                        replaceItem("Upload a file…") { store.pickClip() }
                        replaceItem("Paste a link…") { store.openLinkImport(.swap) }
                    }
                    .padding(.vertical, Space.s2).frame(width: 200)
                    .environment(\.theme, t)
                }
                .sheet(isPresented: $replaceLibrary) { NewSwapLibrarySheet { replaceLibrary = false }.environment(store).environment(\.theme, t) }
            }
            TakeViewer(media: ViewerMedia(id: c.id, videoURL: store.clipVideo, poster: store.clipPoster, width: c.width, height: c.height, label: c.name),
                       context: .source, autoplay: false, startMuted: true, sharedPlayback: playback)
                .id(c.id)
                .frame(maxHeight: .infinity)
            HStack(alignment: .top, spacing: Space.s3) {
                StagePlayButton(playback: playback)
                NewSwapTrimmer(clip: c, playback: playback)
            }
            .frame(maxWidth: 520)
        }
    }
}

// MARK: The source (empty state)

/// Before a video (redesign frame "New Swap, empty"): a dashed drop zone with the film icon, what to drop, and the ways in
/// (Library, a file, a link); then the newest finished videos as "Recent clips", one click uses one.
struct NewSwapSourcePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var libraryOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(spacing: Space.s3) {
                Ph("film-strip", 22).foregroundStyle(t.roles.ink)
                Text("Drop a clip to swap into").font(t.body(17, .semibold)).foregroundStyle(t.roles.ink)
                Text("MP4 or MOV. Vertical clips work best.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                HStack(spacing: Space.s2) {
                    source("Choose from Library", icon: "squares-four") { libraryOpen = true }
                    source("Upload file", icon: "upload-simple") { store.pickClip() }
                    source("Paste a link", icon: "link") { store.openLinkImport(.swap) }
                }
                .padding(.top, Space.s2)
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, minHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(t.roles.ink2.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            recent
        }
        .padding(.top, Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $libraryOpen) { NewSwapLibrarySheet { libraryOpen = false }.environment(store).environment(\.theme, t) }
    }

    /// The newest finished videos (the Library's), as 9:16 tiles with their names and lengths.
    @ViewBuilder private var recent: some View {
        let list = Array(store.extendableTakes.prefix(5))
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Recent clips").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(list) { item in
                        Button { store.useTakeAsRemixSource(item.take) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                MuseImage(ref: item.take.thumb)
                                    .frame(width: 80, height: 142)
                                    .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                                Text(item.take.caption).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1)
                                    .frame(width: 80, alignment: .leading)
                                if let sec = item.source.seconds {
                                    Text(Take.clock(sec)).font(t.scale.micro.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Use \(item.take.caption)")
                        .accessibilityLabel("Use \(item.take.caption)")
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func source(_ title: String, icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: Space.s2) {
                Ph(icon, 15).frame(width: 18, height: 18)
                Text(title).font(t.scale.label.font).lineLimit(1).fixedSize()
            }
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, Space.s3).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.raised))
            .overlay(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// Play and pause for a stage's player.
struct StagePlayButton: View {
    @Environment(\.theme) private var t
    var playback: ViewerPlayback

    var body: some View {
        Button { playback.togglePlay() } label: {
            Ph(playback.playing ? "pause" : "play", 14).foregroundStyle(t.roles.ink2)
                .frame(width: 28, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(playback.playing ? "Pause" : "Play")
        .accessibilityLabel(playback.playing ? "Pause" : "Play")
    }
}

/// The Library as a sheet: finished video takes as 9:16 tiles with their length and name; one click uses it.
struct NewSwapLibrarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onDone: () -> Void

    var body: some View {
        let list = store.extendableTakes
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("Pick a video from your Library").font(t.scale.title.font).foregroundStyle(t.roles.ink)
                Spacer()
                MButton("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
            }
            if list.isEmpty {
                Text("No finished videos yet. Upload one, or paste a link.").font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: Space.s4, alignment: .top), count: 5), alignment: .leading,
                              spacing: Space.s5) {
                        ForEach(list) { item in
                            Button {
                                store.useTakeAsRemixSource(item.take)
                                onDone()
                            } label: { tile(item) }
                            .buttonStyle(.plain)
                            .help("Use \(item.take.caption)")
                            .accessibilityLabel("Use \(item.take.caption)")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(Space.s5)
        .frame(width: 5 * 104 + 4 * Space.s4 + 2 * Space.s5 + 16, height: 560)
        .background(t.roles.canvas)
    }

    private func tile(_ item: ExtendTakeOption) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            MuseImage(ref: item.take.thumb)
                .frame(width: 104, height: 185)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
                .overlay(alignment: .bottomLeading) {
                    if let s = item.source.seconds {
                        Text(Take.clock(s)).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(.black.opacity(0.55)))
                            .padding(Space.s2)
                    }
                }
            Text(item.take.caption).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1).frame(width: 104, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

// MARK: The bottom bar

/// Approved mockup: Clip sound, the model (text, bordered, with a caret), why Auto picked it, then the length and
/// resolution and Generate · $x. Nothing else: no quality pill, no prompt box.
struct NewSwapBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var d: RemixDraft { store.suite.remix }
    private var row: RemixModels.Row? { store.suite.remixModels?.models.first { d.engineModel == nil ? $0.auto : $0.model == d.engineModel } }
    private var price: GeneratePrice { GeneratePrice.of(store.suite.remixEstimate) }
    private var pricing: Bool { store.suite.remixEstimate == nil && store.suite.remixError == nil && store.remixRequest != nil }
    private var canGenerate: Bool { store.suite.remixEstimate?.remix?.trim.needed != true && price.canGenerate }

    private var label: String {
        if store.clip == nil { return "Generate" }
        if pricing { return "Generate · Pricing…" }
        return price.buttonText
    }

    /// "10 s, 1080p": the part used and the model's resolution.
    private var spec: String? {
        guard let c = store.clip else { return nil }
        let secs = d.range.map { $0.to - $0.from } ?? min(c.durationSec, row?.limits.maxSeconds ?? c.durationSec)
        let res = row?.price.resolution
        return ["\(Pricing.trimNum(secs)) s", res].compactMap { $0 }.joined(separator: ", ")
    }

    /// The one line under the model: why Auto picked it, what's missing, or the price problem.
    private var why: String {
        if store.clip == nil { return "The model and price show once a video is added" }
        if let m = d.missing { return m }
        if let e = store.suite.remixError { return e }
        if let p = price.problem { return p }
        if d.engineModel == nil { return store.suite.remixEstimate?.remix?.why ?? store.suite.remixModels?.auto?.why ?? "" }
        return row?.adaptedLine ?? row?.detail ?? ""
    }

    /// The part used, in seconds: the picked part, else what the model takes of the clip.
    private var seconds: Double? {
        guard let c = store.clip else { return nil }
        return d.range.map { $0.to - $0.from } ?? min(c.durationSec, row?.limits.maxSeconds ?? c.durationSec)
    }

    var body: some View {
        // The redesign's bar (frame "New Swap"): the take's length, shape and resolution as read-outs, why the model was
        // picked (or what's missing), the model, and Generate · $x. The clip's sound is in the panel (Sound).
        HStack(spacing: Space.s2) {
            info("length", icon: "clock", value: seconds.map { "\(Pricing.trimNum($0)) s" } ?? "—", help: "Length of the take: the part of the clip used")
            info("shape", icon: "device-mobile", value: store.clip.flatMap { ShotStageTake.shape($0.width, $0.height) } ?? (store.clip == nil ? "9:16" : "Clip"),
                 help: "Shape: the clip's own")
            info("resolution", icon: "stack", value: row?.price.resolution ?? "—", help: "Resolution the model makes")
            Text(why).font(t.scale.caption.font).foregroundStyle(d.missing != nil ? t.roles.caution : t.roles.ink2)
                .lineLimit(1).truncationMode(.tail)
                .help(why)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Space.s2)
                .layoutPriority(-1)
            RemixModelPill()
                .padding(.horizontal, Space.s1)
                .overlay(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
                .fixedSize()
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill model") } }
            SuiteTestRenderSwitch(free: price == .free)
            GenerateButton(label: label, accessibility: label, enabled: store.clip != nil && canGenerate, busy: store.suite.generating, height: 40) {
                store.generateRemix()
            }
            .background { if SnapshotRunner.dir != nil { GenerateFrameProbe(label: label) } } // CI fit check: Generate on screen
            .fixedSize()
            .layoutPriority(2)
        }
    }

    private func info(_ id: String, icon: String, value: String, help: String) -> some View {
        SuitePillLabel(icon: icon, value: value)
            .fitProbe("composer pill \(id)") // CI fit check: a wrapped or cut label is a CUT line
            .fixedSize()
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill \(id)") } }
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(help): \(value)")
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
    /// The clip's player (the stage's): its playhead on the strip and "0:03 / 0:09" beside it.
    var playback: ViewerPlayback? = nil
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
            HStack(spacing: Space.s3) {
                GeometryReader { g in strip(w, width: g.size.width) }
                    .frame(height: 40)
                if let playback {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        Text("\(Take.clock(min(playback.time, clip.durationSec))) / \(Take.clock(clip.durationSec))")
                            .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                    }
                }
            }
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
                    .frame(width: cell, height: 40).clipped()
                    .opacity(CGFloat(i) * cell + cell / 2 >= a && CGFloat(i) * cell + cell / 2 <= b ? 1 : 0.35)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
            // The window: drag to slide it.
            Rectangle().fill(Color.clear)
                .frame(width: max(0, b - a), height: 40)
                // The frame's look: the part used outlined in ink; the accent is only the playhead.
                .overlay(RoundedRectangle(cornerRadius: t.radii.chip).strokeBorder(t.roles.ink.opacity(0.85), lineWidth: 1.5))
                .contentShape(Rectangle())
                .offset(x: a)
                .gesture(drag { start, dx in var n = start; n.slide(by: dx); return n }, including: .all)
                .help("Drag to slide the part used")
            // The playhead (where the clip is playing).
            if let playback {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let x = CGFloat(min(playback.time, dur) / dur) * width
                    Rectangle().fill(t.roles.accent).frame(width: 2, height: 46)
                        .offset(x: max(0, min(width - 2, x - 1)), y: -3)
                }
                .allowsHitTesting(false)
            }
            handle(at: a) { start, dx in var n = start; n.moveStart(to: start.from + dx); return n }
                .help("Drag to change where it starts")
            handle(at: b) { start, dx in var n = start; n.moveEnd(to: start.to + dx); return n }
                .help("Drag to change where it ends")
        }
        .frame(width: width, height: 40, alignment: .leading)
        .onAppear { stripWidth = width }
        .onChange(of: width) { _, v in stripWidth = v }
    }

    private func handle(at x: CGFloat, change: @escaping (TrimWindow, Double) -> TrimWindow) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(t.roles.ink)
            .frame(width: 4, height: 44)
            .frame(width: 20, height: 44) // a wider target than it looks
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
