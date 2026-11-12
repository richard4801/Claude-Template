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
            NewSwapBar()
                .frame(height: 64)
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
            HStack(spacing: Space.s3) {
                Text(c.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.s2)
                Text("\(Take.clock(c.durationSec)), \(c.width) × \(c.height)").font(t.scale.caption.font).monospacedDigit()
                    .foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                // A button with a popover, not a Menu (a menu label draws its icon unsized).
                Button { replaceOpen.toggle() } label: {
                    HStack(spacing: Space.s1) {
                        Text("Replace").font(t.scale.label.font)
                        Ph("caret-down", 12).frame(width: 14, height: 14)
                    }
                    .foregroundStyle(t.roles.ink)
                    .padding(.horizontal, Space.s3).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
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
            .frame(maxWidth: 600)
            .frame(height: 32)
            .padding(.top, Space.s2)
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

/// Before a video (approved mockup newswap-mac-empty): a centred drop zone with one line of what this is and the three
/// ways in. Library opens a picker sheet; it never fills the stage.
struct NewSwapSourcePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var libraryOpen = false

    var body: some View {
        VStack(spacing: Space.s4) {
            VStack(spacing: Space.s1) {
                Text("Add the video to remix").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                Text("Drop a video here, or pick one. Then switch on what should change.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s2) {
                source("From the Library", icon: "squares-four") { libraryOpen = true }
                source("Upload a file", icon: "upload-simple") { store.pickClip() }
                source("Paste a link", icon: "link") { store.openLinkImport(.swap) }
            }
            Text("MP4 or MOV. MUSE checks the clip after it arrives.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
        }
        .padding(Space.s6)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
        .overlay(RoundedRectangle(cornerRadius: t.radii.container).strokeBorder(t.roles.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .sheet(isPresented: $libraryOpen) { NewSwapLibrarySheet { libraryOpen = false }.environment(store).environment(\.theme, t) }
    }

    private func source(_ title: String, icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: Space.s2) {
                Ph(icon, 15).frame(width: 18, height: 18)
                Text(title).font(t.scale.label.font).lineLimit(1).fixedSize()
            }
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, Space.s3).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
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

    var body: some View {
        HStack(spacing: Space.s3) {
            Button { store.suite.remix.keepAudio.toggle() } label: {
                HStack(spacing: Space.s2) {
                    Ph(d.keepAudio ? "speaker-high" : "speaker-slash", 15).frame(width: 18, height: 18)
                    Text("Clip sound").font(t.scale.label.font).lineLimit(1).fixedSize()
                }
                .foregroundStyle(d.keepAudio ? t.roles.ink : t.roles.ink2)
                .padding(.horizontal, Space.s3).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).fixedSize()
            .help(d.keepAudio ? "The clip's own sound goes back on the take (click to turn off)" : "No sound from the clip (click to keep it)")
            .accessibilityLabel(d.keepAudio ? "Clip sound on" : "Clip sound off")
            RemixModelPill()
                .padding(.horizontal, Space.s1)
                .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
                .fixedSize()
            Text(why).font(t.scale.caption.font).foregroundStyle(d.missing != nil ? t.roles.caution : t.roles.ink2)
                .lineLimit(1).truncationMode(.tail)
                .help(why)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
            if let spec { Text(spec).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize() }
            GenerateButton(label: label, accessibility: label, enabled: store.clip != nil && canGenerate, busy: store.suite.generating, height: 40) {
                store.generateRemix()
            }
            .background { if SnapshotRunner.dir != nil { GenerateFrameProbe(label: label) } } // CI fit check: Generate on screen
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.top, Space.s3)
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
