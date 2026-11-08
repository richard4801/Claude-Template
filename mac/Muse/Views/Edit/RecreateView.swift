import AppKit
import AVFoundation
import AVKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// "Recreate this edit" inside Edit (plans/recreate/README.md, mock design/recreate/render.py): the start page (drop a
/// video, or open a reference analysed before), the analysis steps while it's read, then Recipe and Compare. The same
/// 56 pt top bar, 328 pt panel and 268 pt lanes as the editor (plans/edit-layout.md).
struct RecreateView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        VStack(spacing: 0) {
            RecreateTopBar()
            SuiteRule()
            Group {
                if let ref = rs.reference {
                    if ref.isReady {
                        if rs.mode == .compare { RecreateCompare() } else { RecreateRecipe() }
                    } else if ref.isFailed {
                        ErrorState("The analysis didn’t finish", ref.error ?? "This video couldn’t be read. Try another one.",
                                   actionTitle: "Back to references") { store.leaveRecreateReference() }
                            .padding(Space.s6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        RecreateAnalysing(reference: ref)
                    }
                } else {
                    RecreateStart()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(t.roles.canvas)
        .sheet(isPresented: Binding(get: { store.recreate.askBuild }, set: { store.recreate.askBuild = $0 })) {
            RecreateBuildConfirm()
        }
    }
}

/// Build's one confirmation: the real total from the slot estimates, a line per new shot, and any shot that can't be made
/// said plainly (never offered to spend on). Nothing is spent before "Build · $x".
struct RecreateBuildConfirm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        let paid = rs.confirmSlots
        let cant = rs.toGenerate.filter { rs.estimateErrors[$0] != nil }
        let total = rs.confirmTotal
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(paid.isEmpty ? "Build the edit?" : "Build the edit for \(RecreateText.money(total))?")
                .scaled(t.scale.title, t.roles.ink).lineLimit(1).fitProbe("confirm title")
            Text(message(paid: paid.count, cant: cant.count))
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            if !paid.isEmpty || !cant.isEmpty {
                VStack(spacing: 0) {
                    ForEach(paid, id: \.self) { s in
                        row(s, detail: rs.estimates[s]?.priceLine, price: rs.estimates[s].map { RecreateText.money($0.estimate) }, problem: nil)
                    }
                    ForEach(cant, id: \.self) { s in row(s, detail: nil, price: nil, problem: rs.estimateErrors[s]) }
                }
            }
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Cancel") { store.recreate.askBuild = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                SuiteToolButton(title: paid.isEmpty ? "Build the edit" : "Build · \(RecreateText.money(total))", accent: true) { store.confirmRecreateBuild() }
                    .keyboardShortcut(.defaultAction)
                    .background(SnapshotFrame(key: "confirm"))
            }
        }
        .padding(Space.s5)
        .frame(width: 460, alignment: .leading)
        .background(t.roles.canvas)
    }

    private func message(paid: Int, cant: Int) -> String {
        let rs = store.recreate
        let yours = rs.fill?.slots.filter { $0.state == "matched" || $0.state == "ready" }.count ?? 0
        var out: [String] = []
        if paid == 1 { out.append("The new shot is made with your model and charged to the studio.") }
        if paid > 1 { out.append("The \(paid) new shots are made with your model and charged to the studio.") }
        if yours > 0 { out.append(yours == 1 ? "1 shot comes from your takes." : "\(yours) shots come from your takes.") }
        if cant > 0 { out.append(cant == 1 ? "1 shot can’t be made and is left out." : "\(cant) shots can’t be made and are left out.") }
        if paid > 0 {
            out.append("They take a few minutes; you can leave this page meanwhile.")
        } else {
            out.append("Nothing is generated or charged.")
        }
        return out.joined(separator: " ")
    }

    private func row(_ slotId: String, detail: String?, price: String?, problem: String?) -> some View {
        let rs = store.recreate
        let slot = rs.slots.first { $0.id == slotId }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s3) {
                Text(rs.shotName(slotId)).scaled(t.scale.label, t.roles.ink).lineLimit(1).fixedSize()
                Text(slot.flatMap { RecreateText.brief($0.brief) } ?? slot.map { String(format: "%.1f s", $0.length) } ?? "")
                    .scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: Space.s2)
                Text(price ?? "–").scaled(t.scale.label, t.roles.ink).monospacedDigit().lineLimit(1).fixedSize().fitProbe("confirm price \(slotId)")
            }
            if let problem {
                Text(problem).scaled(t.scale.caption, t.roles.caution).fixedSize(horizontal: false, vertical: true)
            } else if let detail, !detail.isEmpty {
                Text(detail.prefix(1).uppercased() + detail.dropFirst()).scaled(t.scale.caption, t.roles.ink2).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.vertical, Space.s2)
        .overlay(alignment: .top) { SuiteRule() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Top bar

/// Back (Close on the start page), the reference's name over its facts, Recipe | Compare in the centre, and the one
/// primary on the right: Build the edit with its total right beside it (owner note 2), or Open in the editor.
struct RecreateTopBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        HStack(spacing: Space.s3) {
            if rs.reference == nil {
                SuiteIconButton(systemName: "caret-left", label: "Close") { store.closeRecreate() }
            } else {
                SuiteIconButton(systemName: "caret-left", label: "Back to references") { store.leaveRecreateReference() }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1).fitProbe("recreate title")
                Text(subtitle).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1).fitProbe("recreate facts")
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s2)
            if rs.reference?.isReady == true {
                EditSeg(options: [(RecreateMode.recipe, "Recipe"), (.compare, "Compare")], selection: rs.mode) { m in
                    if m == .compare && rs.match == nil {
                        store.showToast("Compare opens once the edit is built")
                    } else {
                        rs.mode = m
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Recipe or compare")
                Spacer(minLength: Space.s2)
                if rs.mode == .recipe {
                    if let f = rs.fill {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(RecreateText.makingSummary(f, prices: rs.prices, unavailable: rs.unpriceable)).font(t.scale.label.font).monospacedDigit().foregroundStyle(t.roles.ink)
                                .lineLimit(1).fixedSize().fitProbe("recreate cost")
                            Text(note).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                                .lineLimit(1).fixedSize().fitProbe("recreate approve")
                        }
                        .accessibilityElement(children: .combine)
                        .background(SnapshotFrame(key: "cost"))
                    }
                    SuiteToolButton(title: rs.estimating ? "Pricing the shots" : "Build the edit", icon: "hammer", accent: true,
                                    disabled: rs.fill == nil || rs.building || rs.estimating || rs.isGenerating) {
                        Task { await store.requestRecreateBuild() }
                    }
                    .accessibilityLabel("Build the edit")
                    .background(SnapshotFrame(key: "build"))
                } else {
                    SuiteToolButton(title: "Open in the editor", icon: "export", accent: true) { store.openRecreateInEditor() }
                        .accessibilityLabel("Open in the editor")
                        .background(SnapshotFrame(key: "open"))
                }
            }
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 56)
        .background(t.roles.canvas)
    }

    /// Under the total: the approval promise, or what happens while new shots generate.
    private var note: String {
        let rs = store.recreate
        guard rs.isGenerating else { return RecreateText.approveNote }
        return rs.reference.map { rs.buildWhenReady.contains($0.id) } == true ? "The edit is built when they’re ready." : "Build the edit once they’re ready."
    }

    private var title: String {
        guard let r = store.recreate.reference else { return "Recreate an edit" }
        return r.name ?? "Reference"
    }

    private var subtitle: String {
        let rs = store.recreate
        guard let r = rs.reference else { return "Drop a video and MUSE reads how it’s edited" }
        if r.isAnalyzing { return "Reading the reference" }
        var parts = ["Reference"]
        if let d = r.durationSec ?? r.recipe?.durationSec { parts.append(String(format: "%.1f s", d)) }
        if r.isReady { parts.append(rs.slots.count == 1 ? "1 shot" : "\(rs.slots.count) shots") }
        if r.keep == true {
            parts.append("kept")
        } else if let c = r.createdAt, let e = r.expiresAt, e > c {
            parts.append("kept \(Int((Double(e - c) / 86_400_000).rounded())) days")
        }
        return parts.joined(separator: " · ")
    }
}

/// Review mode only: reports a view's frame (window space) for the fit check, so the cost line and Build are proved on screen.
struct SnapshotFrame: View {
    var key: String
    var body: some View {
        if SnapshotRunner.probing {
            GeometryReader { g in
                Color.clear
                    .onAppear { SnapshotRunner.state.recreateFrames[key] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in SnapshotRunner.state.recreateFrames[key] = f }
                    .onDisappear { SnapshotRunner.state.recreateFrames[key] = nil }
            }
        }
    }
}

// MARK: Start

/// Drop a video (or choose one); references analysed before, newest first. Nothing is uploaded until a video is chosen.
struct RecreateStart: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        let rs = store.recreate
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.s5) {
                Text("MUSE reads a video’s cuts, text, speed, beat and look, then rebuilds it with your takes and new shots. You see the total before anything is made.")
                    .scaled(t.scale.body, t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                Button { importing = true } label: {
                    DropZone(title: "Drop a video", hint: "Up to 60 s. It’s read in about a minute and kept for 30 days.", buttonTitle: "Choose a video", targeted: targeted)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 640)
                .accessibilityLabel("Choose a video")
                .disabled(rs.uploading)
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }) else { return false }
                    Task { await store.createRecreateReference(from: url) }
                    return true
                } isTargeted: { targeted = $0 }
                if rs.uploading {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Uploading").scaled(t.scale.label, t.roles.ink)
                        RProgress(value: store.uploadProgress ?? 0).frame(maxWidth: 640)
                    }
                }
                if let e = rs.error { InlineNotice(e, tone: .danger).frame(maxWidth: 640) }
                if rs.loadingList && rs.references.isEmpty {
                    SkeletonBlock(width: 150, height: 267)
                } else if !rs.references.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text("Your references").scaled(t.scale.heading, t.roles.ink)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: Space.s4)], alignment: .leading, spacing: Space.s4) {
                            ForEach(rs.references) { r in
                                Button { Task { await store.openRecreateReference(r.id) } } label: { tile(r) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open \(r.name ?? "reference")")
                            }
                        }
                    }
                }
            }
            .padding(Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await store.createRecreateReference(from: url)
            }
        }
    }

    private func tile(_ r: RecreateReference) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            RecreateStill(link: r.posterUrl, tone: 0)
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
            Text(r.name ?? "Reference").scaled(t.scale.label, t.roles.ink).lineLimit(1).padding(.top, Space.s1)
            Text(r.isAnalyzing ? "Reading · \(Int(r.progress ?? 0))%" : r.isFailed ? "Couldn’t be read" : String(format: "%.1f s", r.durationSec ?? 0))
                .scaled(t.scale.caption, t.roles.ink2).monospacedDigit().lineLimit(1)
        }
    }
}

// MARK: Analysing

/// While the reference is read: the steps as they finish ("Finding the cuts", "Reading the text"…) and the progress.
struct RecreateAnalysing: View {
    @Environment(\.theme) private var t
    var reference: RecreateReference

    var body: some View {
        let current = RecreateText.analysisStep(phase: reference.phase, state: reference.state)
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Reading the reference").scaled(t.scale.title, t.roles.ink)
                Text("About a minute. You can leave this page; it carries on.").scaled(t.scale.body, t.roles.ink2)
            }
            HStack(spacing: Space.s3) {
                RProgress(value: (reference.progress ?? 0) / 100).frame(width: 360)
                Text("\(Int(reference.progress ?? 0))%").scaled(t.scale.caption, t.roles.ink2).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(RecreateText.analysisSteps.indices, id: \.self) { i in
                    HStack(spacing: Space.s3) {
                        Group {
                            if i < current {
                                Ph("check", 16).foregroundStyle(t.roles.ink)
                            } else if i == current {
                                ProgressView().controlSize(.small)
                            } else {
                                Circle().strokeBorder(t.roles.hairline, lineWidth: 1.5).frame(width: 14, height: 14)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(RecreateText.analysisSteps[i]).scaled(t.scale.body, i <= current ? t.roles.ink : t.roles.ink2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(i < current ? "Done" : i == current ? "In progress" : "Waiting")
                }
            }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Media

extension Color {
    /// A Look swatch ("#RRGGBB"); clear when unreadable.
    init(swatch: String) { self = Color(hexString: swatch) ?? .clear }
}

/// Stand-in footage for demo mode (no media there): a calm tone from the reference's softened Look, never a picture of
/// anyone. With a server, the authenticated still (poster, a shot's frame) loads over it with the session token.
struct RecreateStill: View {
    @Environment(AppStore.self) private var store
    var link: String?
    /// Which softened Look swatch tints the stand-in.
    var tone: Int
    var icon = true
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: link) { image = await RecreateMediaLoader.image(store.recreateMedia(link)) }
    }

    private var placeholder: some View {
        let soft = RecreateSwatches.soften(store.recreate.recipe?.grade?.swatches ?? [])
        let base = soft.isEmpty ? Color(hex: 0x3A3D42) : Color(swatch: soft[tone % soft.count])
        return ZStack {
            base
            Color.black.opacity(0.45)
            if icon { Ph("film-strip", 20).foregroundStyle(.white.opacity(0.55)) }
        }
    }
}

/// Loads the reference's authenticated routes with the session token. A redirect to storage on another host drops the
/// token (signed storage links refuse it).
enum RecreateMediaLoader {
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var r = request
            if request.url?.host != task.originalRequest?.url?.host { r.setValue(nil, forHTTPHeaderField: "Authorization") }
            completionHandler(r)
        }
    }

    @MainActor private static var images: [URL: NSImage] = [:]
    @MainActor private static var videos: [URL: URL] = [:]

    private static func request(_ m: (url: URL, token: String?)) -> URLRequest {
        var r = URLRequest(url: m.url)
        if let t = m.token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    @MainActor static func image(_ m: (url: URL, token: String?)?) async -> NSImage? {
        guard let m else { return nil }
        if let hit = images[m.url] { return hit }
        guard let got = try? await URLSession.shared.data(for: request(m), delegate: Redirects()),
              ((got.1 as? HTTPURLResponse)?.statusCode ?? 200) < 300, let img = NSImage(data: got.0) else { return nil }
        images[m.url] = img
        return img
    }

    /// The reference video, downloaded to a temporary file (≤ 60 s) so the player needs no token.
    @MainActor static func video(_ m: (url: URL, token: String?)?) async -> URL? {
        guard let m else { return nil }
        if let hit = videos[m.url] { return hit }
        guard let got = try? await URLSession.shared.download(for: request(m), delegate: Redirects()),
              ((got.1 as? HTTPURLResponse)?.statusCode ?? 200) < 300 else { return nil }
        let tmp = got.0
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-recreate-\(UUID().uuidString).mp4")
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return nil }
        videos[m.url] = dest
        return dest
    }
}

/// The player's picture: AVPlayerView without controls (the transport is ours).
struct RecreateVideoSurface: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// One player: its label above the picture on the viewer tone. The reference plays its video when the server has it;
/// otherwise (demo mode) the stand-in for the shot under the playhead, with the recipe's text where the reference shows it.
struct RecreatePlayer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var label: String
    var yours = false
    @State private var player: AVPlayer?

    var body: some View {
        let rs = store.recreate
        let aspect = aspectRatio
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(label).scaled(t.scale.label, t.roles.ink).lineLimit(1)
            ZStack {
                t.editViewer
                ZStack {
                    if let player, !yours {
                        RecreateVideoSurface(player: player)
                    } else {
                        frame
                        if !yours || store.isDemo { overlayText }
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.vertical, Space.s3)
            }
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel(label)
        }
        .task(id: rs.reference?.videoUrl) {
            guard !yours, let file = await RecreateMediaLoader.video(store.recreateMedia(rs.reference?.videoUrl)) else { return }
            player = AVPlayer(url: file)
            player?.isMuted = false
            _ = await player?.seek(to: CMTime(seconds: rs.time, preferredTimescale: 600))
        }
        .onChange(of: rs.playing) { _, on in
            guard let player else { return }
            if on { player.play() } else { player.pause() }
        }
        .onChange(of: rs.time) { _, time in
            guard let player, !rs.playing else { return }
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private var aspectRatio: CGFloat {
        let s = store.recreate.recipe?.source
        if let w = s?.width, let h = s?.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9 / 16
    }

    @ViewBuilder private var frame: some View {
        let rs = store.recreate
        let i = rs.slotAtTime ?? 0
        let slot = rs.slots.indices.contains(i) ? rs.slots[i] : nil
        if yours, !store.isDemo, let id = slot.flatMap({ rs.slotFill($0.id)?.takeId }), let take = store.takes.first(where: { $0.id == id }) {
            MuseImage(ref: take.thumb, symbol: "film")
        } else {
            RecreateStill(link: yours ? nil : (slot?.thumbUrl ?? rs.reference?.posterUrl), tone: i + (yours ? 1 : 0), icon: false)
        }
    }

    private var overlayText: some View {
        let rs = store.recreate
        let items = (rs.recipe?.text ?? []).filter { $0.startSec <= rs.time && rs.time < $0.endSec && ($0.words ?? "").isEmpty == false }
        return GeometryReader { g in
            ForEach(items) { x in
                let cx = (x.box?.x ?? 0.1) + (x.box?.w ?? 0.8) / 2, cy = (x.box?.y ?? 0.7) + (x.box?.h ?? 0.07) / 2
                Text(x.words ?? "")
                    .font(.system(size: max(9, g.size.height * CGFloat(x.sizeFrac ?? 0.04)), weight: .bold))
                    .foregroundStyle(Color(hexString: x.color ?? "#FFFFFF") ?? .white)
                    .lineLimit(1)
                    .position(x: CGFloat(cx) * g.size.width, y: CGFloat(cy) * g.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The timecode, back / play / forward and sound, under the players.
struct RecreateTransport: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        HStack(spacing: Space.s2) {
            Text("\(RecreateText.time(rs.time)) / \(RecreateText.time(rs.duration))")
                .scaled(t.scale.label, t.roles.ink).monospacedDigit().lineLimit(1).fixedSize()
                .frame(width: 140, alignment: .leading)
            Spacer(minLength: 0)
            SuiteIconButton(systemName: "skip-back", label: "Back 1 frame") { store.stepRecreate(-1) }
            Button { store.toggleRecreatePlay() } label: {
                Ph(rs.playing ? "pause" : "play", 18)
                    .foregroundStyle(t.roles.canvas)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(t.roles.ink))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(rs.playing ? "Pause" : "Play")
            .accessibilityLabel(rs.playing ? "Pause" : "Play")
            SuiteIconButton(systemName: "skip-forward", label: "Forward 1 frame") { store.stepRecreate(1) }
            Spacer(minLength: 0)
            Color.clear.frame(width: 140, height: 1)
        }
        .frame(height: 40)
    }
}
