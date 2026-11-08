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
            HStack(spacing: 0) {
                Group {
                    if let ref = rs.reference {
                        if ref.isReady {
                            if rs.mode == .compare { RecreateCompare() } else { RecreateRecipe() }
                        } else if ref.failedFetchingLink {
                            RecreateLinkFailed(reference: ref)
                        } else if ref.isFailed {
                            VStack(alignment: .leading, spacing: Space.s3) {
                                ErrorState("The analysis didn’t finish", ref.error ?? "This video couldn’t be read. Try again, or try another one.",
                                           actionTitle: "Retry") { store.retryRecreateReference() }
                                RButton("Back to references", kind: .plain, small: true) { store.leaveRecreateReference() }
                            }
                                .padding(Space.s6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            RecreateAnalysing(reference: ref, reconnecting: rs.reconnecting, lost: rs.pollLost) { store.pollRecreateReference(ref.id) }
                        }
                    } else {
                        RecreateStart()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Claude runs the flow from here (owner only): the editor's own chat, with Recreate's context.
                if rs.claudeOpen && store.isOwner {
                    SuiteRule(vertical: true)
                    RecreateClaudePanel()
                        .frame(width: RecreateClaudePanel.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(t.roles.canvas)
        .sheet(isPresented: Binding(get: { store.recreate.askBuild }, set: { store.recreate.askBuild = $0 })) {
            RecreateBuildConfirm()
        }
        .sheet(isPresented: Binding(get: { store.recreate.exportOpen }, set: { store.recreate.exportOpen = $0 })) {
            RecreateExportSheet()
        }
        .sheet(isPresented: Binding(get: { store.recreate.askBriefs }, set: { store.recreate.askBriefs = $0 })) {
            RecreateBriefsConfirm()
        }
        .sheet(isPresented: Binding(get: { store.recreate.fixSlot != nil }, set: { if !$0 { store.closeRecreateFix() } })) {
            RecreateFixSheet()
        }
        .sheet(item: Binding(get: { store.recreate.claudeAsk }, set: { store.recreate.claudeAsk = $0 })) { p in
            RecreateClaudeAsk(pending: p)
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
        let offered = rs.confirmSlots
        let paid = rs.confirmPicked
        let skipped = offered.count - paid.count
        let cant = rs.toGenerate.filter { rs.estimateErrors[$0] != nil }
        let total = rs.confirmTotal
        let noneTicked = !offered.isEmpty && paid.isEmpty
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(paid.isEmpty || noneTicked ? "Build the edit?" : "Build the edit for \(RecreateText.money(total))?")
                .scaled(t.scale.title, t.roles.ink).lineLimit(1).fitProbe("confirm title")
            Text(message(paid: paid.count, cant: cant.count, skipped: skipped))
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            if !paid.isEmpty, let lead = store.recreateLead {
                // The Cast step's choice (Release 1 item E): who the new shots are made with.
                HStack(spacing: Space.s3) {
                    MuseImage(ref: lead.cover).frame(width: 28, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
                    Text("Lead").scaled(t.scale.caption, t.roles.ink2).fixedSize()
                    Text(lead.name).scaled(t.scale.label, t.roles.ink).lineLimit(1).fitProbe("confirm lead")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            if !offered.isEmpty || !cant.isEmpty {
                VStack(spacing: 0) {
                    // "Generate all the missing shots, or pick which ones": each shot can be unticked (all ticked at first).
                    ForEach(offered, id: \.self) { s in
                        row(s, detail: length(s), price: rs.estimates[s].map { RecreateText.money($0.estimate) }, problem: nil,
                            ticked: Binding(get: { !store.recreate.confirmSkipped.contains(s) },
                                            set: { on in if on { store.recreate.confirmSkipped.remove(s) } else { store.recreate.confirmSkipped.insert(s) } }))
                    }
                    ForEach(cant, id: \.self) { s in row(s, detail: nil, price: nil, problem: rs.estimateErrors[s]) }
                }
            }
            HStack(spacing: Space.s3) {
                if noneTicked {
                    Text("Tick at least one shot").scaled(t.scale.caption, t.roles.caution).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                SuiteToolButton(title: "Cancel") { store.recreate.askBuild = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                SuiteToolButton(title: paid.isEmpty ? "Build the edit" : "Build · \(RecreateText.money(total))", accent: true) { store.confirmRecreateBuild() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(noneTicked)
                    .background(SnapshotFrame(key: "confirm"))
            }
        }
        .padding(Space.s5)
        .frame(width: 460, alignment: .leading)
        .background(t.roles.canvas)
    }

    private func message(paid: Int, cant: Int, skipped: Int = 0) -> String {
        let rs = store.recreate
        let yours = rs.fill?.slots.filter { $0.state == "matched" || $0.state == "ready" }.count ?? 0
        var out: [String] = []
        let who = store.recreateLead?.shortName ?? "your model"
        if paid == 1 { out.append("The new shot is made with \(who) and charged to the studio.") }
        if paid > 1 { out.append("The \(paid) new shots are made with \(who) and charged to the studio.") }
        if yours > 0 { out.append(yours == 1 ? "1 shot comes from your takes." : "\(yours) shots come from your takes.") }
        if cant > 0 { out.append(cant == 1 ? "1 shot can’t be made and is left out." : "\(cant) shots can’t be made and are left out.") }
        if skipped > 0 { out.append(skipped == 1 ? "1 unticked shot stays to generate later." : "\(skipped) unticked shots stay to generate later.") }
        if paid > 0 {
            out.append("They take a few minutes; you can leave this page meanwhile.")
        } else {
            out.append("Nothing is generated or charged.")
        }
        return out.joined(separator: " ")
    }

    /// "A 2 s shot, cut to 1.2 s": what is made, and how much of it the edit uses.
    private func length(_ slotId: String) -> String? {
        let rs = store.recreate
        guard let e = rs.estimates[slotId], e.seconds > 0 else { return nil }
        // A swap (G2): the method and the server's own line ("Swap in · 2.0 s · $0.41").
        if let info = rs.estimateInfo[slotId], info.isSwap {
            let setting = info.background.map { ", \($0.line)" } ?? (rs.ownSetting.contains(slotId) ? ", your own setting" : "")
            return "Swapped into the reference shot\(setting) · \(e.buttonLabel.isEmpty ? e.priceLine : e.buttonLabel)"
        }
        let made = "A new \(Int(e.seconds.rounded())) s shot"
        guard let slot = rs.slots.first(where: { $0.id == slotId }), slot.length < e.seconds - 0.05 else { return made }
        return "\(made), cut to \(String(format: "%.1f", slot.length)) s"
    }

    private func row(_ slotId: String, detail: String?, price: String?, problem: String?, ticked: Binding<Bool>? = nil) -> some View {
        let rs = store.recreate
        let slot = rs.slots.first { $0.id == slotId }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s3) {
                if let ticked {
                    Toggle("Make \(rs.shotName(slotId))", isOn: ticked).toggleStyle(.checkbox).labelsHidden()
                        .help(ticked.wrappedValue ? "Untick to leave this shot for later" : "Tick to make this shot now")
                        .accessibilityLabel("Make \(rs.shotName(slotId))")
                }
                Text(rs.shotName(slotId)).scaled(t.scale.label, t.roles.ink).lineLimit(1).fixedSize()
                Text(slot.flatMap { RecreateText.brief($0.brief) } ?? slot.map { String(format: "%.1f s", $0.length) } ?? "")
                    .scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: Space.s2)
                Text(price ?? "–").scaled(t.scale.label, ticked?.wrappedValue == false ? t.roles.ink2 : t.roles.ink).monospacedDigit().lineLimit(1).fixedSize().fitProbe("confirm price \(slotId)")
            }
            if let problem {
                Text(problem).scaled(t.scale.caption, t.roles.caution).fixedSize(horizontal: false, vertical: true)
            } else if let detail, !detail.isEmpty {
                Text(detail).scaled(t.scale.caption, t.roles.ink2).monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Space.s2)
        .overlay(alignment: .top) { SuiteRule() }
        .accessibilityElement(children: ticked == nil ? .combine : .contain)
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
                    claudeButton(iconOnly: true)
                    if let f = rs.fill {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(RecreateText.makingSummary(f, prices: rs.prices, unavailable: rs.unpriceable, swaps: Set(rs.estimateInfo.filter { $0.value.method == "swap" }.keys))).font(t.scale.label.font).monospacedDigit().foregroundStyle(t.roles.ink)
                                .lineLimit(1).fixedSize().fitProbe("recreate cost")
                            Text(note).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                                .lineLimit(1).fixedSize().fitProbe("recreate approve")
                        }
                        .accessibilityElement(children: .combine)
                        .background(SnapshotFrame(key: "cost"))
                    }
                    // Disabled (pricing, generating, building), it steps back from the accent so its label stays readable.
                    let busy = rs.fill == nil || rs.building || rs.estimating || rs.isGenerating
                    SuiteToolButton(title: rs.estimating ? "Pricing the shots" : "Build the edit", icon: "hammer", accent: !busy, disabled: busy) {
                        Task { await store.requestRecreateBuild() }
                    }
                    .accessibilityLabel("Build the edit")
                    .background(SnapshotFrame(key: "build"))
                } else {
                    SuiteToolButton(title: "Open in the editor", icon: "pencil-simple", plain: true) { store.openRecreateInEditor() }
                        .accessibilityLabel("Open in the editor")
                        .background(SnapshotFrame(key: "open"))
                    claudeButton(iconOnly: true)
                    // Export is the one primary after Build (plans/recreate/README.md): the sound as a guide, or silent.
                    SuiteToolButton(title: "Export", icon: "export", accent: true) { store.openRecreateExport() }
                        .accessibilityLabel("Export")
                        .background(SnapshotFrame(key: "export"))
                }
            }
            if rs.reference?.isReady != true { claudeButton(iconOnly: false) }
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 56)
        .background(t.roles.canvas)
    }

    /// Claude (owner only): opens the chat beside the Recreate screens, as in the editor.
    @ViewBuilder private func claudeButton(iconOnly: Bool) -> some View {
        if store.isOwner {
            let on = store.recreate.claudeOpen
            SuiteToolButton(title: "Claude", icon: "chat-circle-text", filled: on, plain: !on, iconOnly: iconOnly) { store.toggleRecreateClaude() }
                .accessibilityLabel(on ? "Hide Claude" : "Show Claude")
                .help("Claude can analyse a video, explain a shot or fix one")
        }
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

/// Drop a video (anywhere on the page), choose one, paste a link, or ⌘V either; references analysed before, newest first.
/// Nothing is uploaded until a video is chosen. A link refusal says why, with the file offered right there.
struct RecreateStart: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var importing = false
    @State private var targeted = false
    @FocusState private var linkFocused: Bool

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
                .disabled(rs.uploading || rs.fetchingLink)
                linkRow
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
        // The whole page takes a dropped video (or a dropped link), not only the drop zone.
        .dropDestination(for: URL.self) { urls, _ in RecreateDrop.take(urls, store: store) } isTargeted: { targeted = $0 }
        .background {
            // ⌘V anywhere on the page but the link field (which pastes as usual, then fetches a whole link).
            if !linkFocused {
                Button("") { store.pasteIntoRecreate() }
                    .keyboardShortcut("v", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie]) { result in
            RecreateDrop.imported(result, store: store)
        }
    }

    /// "Or paste a link": the field, Fetch, the fetching line and a refusal with the file offered beside it.
    private var linkRow: some View {
        @Bindable var rs = store.recreate
        let empty = rs.linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("Or paste a link").scaled(t.scale.label, t.roles.ink)
            HStack(spacing: Space.s2) {
                TextField("A TikTok, Instagram Reel or YouTube link", text: $rs.linkText)
                    .focused($linkFocused)
                    .onSubmit { Task { await store.createRecreateReference(link: rs.linkText) } }
                    .roleField(focused: linkFocused)
                    .accessibilityLabel("Video link")
                    .disabled(rs.fetchingLink)
                    .onChange(of: rs.linkText) { old, new in
                        // A whole link pasted into an empty field is fetched at once.
                        if old.isEmpty, RecreateLinks.detect(new) != nil { Task { await store.createRecreateReference(link: new) } }
                    }
                RButton(rs.fetchingLink ? "Fetching" : "Fetch", kind: .quiet, off: empty || rs.fetchingLink || rs.uploading) {
                    Task { await store.createRecreateReference(link: rs.linkText) }
                }
                .disabled(empty || rs.fetchingLink || rs.uploading)
                .fixedSize()
                .accessibilityLabel("Fetch the video")
            }
            if rs.fetchingLink {
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack(spacing: Space.s2) {
                        ProgressView().controlSize(.small)
                        Text(rs.linkStatus ?? "Fetching the video…").scaled(t.scale.caption, t.roles.ink2).monospacedDigit()
                        Spacer(minLength: Space.s2)
                        RButton("Stop", kind: .plain, small: true) { store.stopRecreateLinkFetch() }
                            .fixedSize()
                            .accessibilityLabel("Stop fetching")
                    }
                    if let v = rs.linkProgress { RProgress(value: v) }
                }
                .background(SnapshotFrame(key: "linkFetching"))
            } else if let p = rs.linkProblem {
                RecreateLinkProblemNote(problem: p) { importing = true }
            } else {
                Text("Public videos only. MUSE fetches it once and keeps it private, like a dropped file.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
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

/// A link refusal: what happened in the server's words, and (for every link_* code) the file offered right there.
struct RecreateLinkProblemNote: View {
    var problem: RecreateLinkProblem
    var chooseFile: () -> Void

    var body: some View {
        Group {
            if problem.offersFile {
                InlineNotice(problem.message, tone: .caution, actionTitle: "Choose the file", action: chooseFile)
            } else {
                InlineNotice(problem.message, tone: .caution)
            }
        }
        .background(SnapshotFrame(key: "linkProblem"))
    }
}

/// What the start page (and a failed link's page) does with dropped or chosen files and links.
@MainActor
enum RecreateDrop {
    static func take(_ urls: [URL], store: AppStore) -> Bool {
        if let file = urls.first(where: AppStore.isMovieFile) {
            Task { await store.createRecreateReference(from: file) }
            return true
        }
        if let link = urls.first(where: { !$0.isFileURL && RecreateLinks.platform($0.absoluteString) != nil }) {
            Task { await store.createRecreateReference(link: link.absoluteString) }
            return true
        }
        return false
    }

    static func imported(_ result: Result<URL, Error>, store: AppStore) {
        guard case .success(let url) = result else { return }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            await store.createRecreateReference(from: url)
        }
    }
}

/// A link reference whose download was blocked (`failed`, `errorCode: link_blocked`): the same words as the refusal and the
/// file drop right there.
struct RecreateLinkFailed: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var reference: RecreateReference
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("This link couldn’t be fetched").scaled(t.scale.title, t.roles.ink)
            Text(RecreateLinks.message(code: reference.errorCode ?? "link_blocked", message: reference.error))
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
            Button { importing = true } label: {
                DropZone(title: "Drop the saved video", hint: "Up to 60 s. It’s read like any dropped file.", buttonTitle: "Choose the file", targeted: targeted)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 640)
            .accessibilityLabel("Choose the file")
            if store.recreate.uploading {
                RProgress(value: store.uploadProgress ?? 0).frame(maxWidth: 640)
            }
            RButton("Back to references", kind: .plain) { store.leaveRecreateReference() }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in RecreateDrop.take(urls, store: store) } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie, .movie]) { result in
            RecreateDrop.imported(result, store: store)
        }
    }
}

// MARK: Analysing

/// While the reference is read: the steps as they finish ("Finding the cuts", "Reading the text"…) and the progress.
struct RecreateAnalysing: View {
    @Environment(\.theme) private var t
    var reference: RecreateReference
    /// The server isn't answering for now (it restarted): retrying quietly.
    var reconnecting = false
    /// Retrying gave up: plain words and Try again.
    var lost: String?
    var retry: () -> Void = {}

    var body: some View {
        let current = RecreateText.analysisStep(phase: reference.phase, state: reference.state)
        VStack(alignment: .leading, spacing: Space.s5) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Reading the reference").scaled(t.scale.title, t.roles.ink)
                Text("About a minute. You can leave this page; it carries on.").scaled(t.scale.body, t.roles.ink2)
            }
            if let lost {
                InlineNotice(lost, tone: .caution, actionTitle: "Try again", action: retry).frame(maxWidth: 520)
            } else if reconnecting {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Reconnecting…").scaled(t.scale.caption, t.roles.ink2)
                }
                .accessibilityElement(children: .combine)
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
        // The picture is an overlay, so it fills the frame it's given and never sizes the view: as a ZStack child, a
        // `.fill` image made the stack as big as the picture's aspect needed, and the lanes' shot tiles drew over the
        // player and each other (owner test 2026-11-08).
        placeholder
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
            .clipped()
        .task(id: link) {
            // Review mode's lanes check draws real portrait stills from local files (SnapshotRunner.recreateLanesShots).
            if SnapshotRunner.probing, let link, link.hasPrefix("file://"), let u = URL(string: link) {
                image = NSImage(contentsOf: u)
                return
            }
            image = await RecreateMediaLoader.image(store.recreateMedia(link))
        }
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
            Text(yours && rs.built?.cutOnly == true ? "Preview of the cut" : label).scaled(t.scale.label, t.roles.ink).lineLimit(1)
            ZStack {
                t.editViewer
                ZStack {
                    if yours, let b = rs.built, b.phase == .ready {
                        // The built edit itself, drawn by the editor's engine (ramps, camera keys, text, the Look).
                        RecreateVideoSurface(player: b.player)
                            .background(SnapshotFrame(key: "yours"))
                    } else if let player, !yours {
                        RecreateVideoSurface(player: player)
                    } else {
                        frame
                        if !yours || store.isDemo { overlayText }
                        if yours && rs.loadingBuilt {
                            VStack(spacing: Space.s2) {
                                ProgressView().controlSize(.small)
                                Text("Getting your edit ready to play").scaled(t.scale.caption, .white).multilineTextAlignment(.center)
                            }
                            .padding(Space.s3)
                        }
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
            if yours {
                if on { rs.built?.play(from: rs.time) } else { rs.built?.pause() }
                return
            }
            guard let player else { return }
            if on { player.play() } else { player.pause() }
        }
        .onChange(of: rs.time) { old, time in
            // Playing, the clock loops back to the start at the end: both players start again with it.
            if rs.playing {
                guard time < old - 0.5 else { return }
                if yours { rs.built?.play(from: time) } else if let player {
                    player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                }
                return
            }
            if yours { rs.built?.seek(time); return }
            guard let player else { return }
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private var aspectRatio: CGFloat {
        if yours, let b = store.recreate.built, b.phase == .ready { return b.aspect }
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
