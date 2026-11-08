import AppKit
import MuseCore
import SwiftUI

// Release 1 on the Recreate screens: the Cast step (who plays the lead), Claude's panel with Recreate's context and its
// confirmation for paid steps, and Export (the sound as a guide track, or silent).

// MARK: Cast

/// The Cast step at the top of the Recipe panel: the lead the new shots are made with, and the studio's cast to change it
/// (the same list the Suite's lead picker shows: real characters, not drafts). Changing it prices the shots again.
struct RecreateCastRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        let lead = store.recreateLead
        let cast = store.suiteCharacters
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                Text(rs.castOpen ? "Choose the lead" : "Lead").scaled(t.scale.label, t.roles.ink)
                Spacer(minLength: Space.s2)
                if rs.castOpen {
                    SuiteToolButton(title: "Done", plain: true) { rs.castOpen = false }
                        .accessibilityLabel("Done choosing the lead")
                        .background(SnapshotFrame(key: "cast"))
                }
            }
            // Chosen: one row. Choosing: only the list (the lead marked), never both.
            if !rs.castOpen {
                HStack(spacing: Space.s3) {
                    MuseImage(ref: lead?.cover)
                        .frame(width: 32, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lead?.name ?? "No model yet").scaled(t.scale.label, t.roles.ink).lineLimit(1).fitProbe("lead name")
                        Text(lead == nil ? "Make a model to cast in the new shots." : "The new shots are made with this model.")
                            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s2)
                    if !cast.isEmpty {
                        SuiteToolButton(title: "Change", plain: true) { rs.castOpen = true }
                            .accessibilityLabel("Change the lead")
                            .background(SnapshotFrame(key: "cast"))
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                VStack(spacing: 0) {
                    ForEach(cast) { m in
                        Button {
                            store.setRecreateLead(m)
                            rs.castOpen = false
                        } label: {
                            HStack(spacing: Space.s3) {
                                MuseImage(ref: m.cover).frame(width: 32, height: 40).clipped()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                                    Text("\(m.niche) · \(store.outfits(for: m).count) outfits").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if m.id == lead?.id { Ph("check", 16).foregroundStyle(t.roles.ink) }
                            }
                            .padding(.vertical, Space.s1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(m.id == lead?.id ? "\(m.name), the lead" : "Cast \(m.name) as the lead")
                    }
                }
            }
        }
    }
}

// MARK: Claude

/// Claude beside the Recreate screens (owner only): the editor's chat on the owner's Claude Code with MUSE's recreate tools.
/// It asks the server for a "recreate" thread on the reference and falls back to the edit session's thread on a server that
/// doesn't have that context yet. Every message names the reference and the edit session, so the tools act on them.
struct RecreateClaudePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    static let width: CGFloat = 340

    var body: some View {
        let rs = store.recreate
        let sid = rs.claudeSessionId
        VStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                ClaudeBadge()
                Text(rs.reference.map { "On \($0.name ?? "this reference")" } ?? "Recreate an edit")
                    .scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: Space.s2)
                SuiteIconButton(systemName: "xmark", label: "Hide Claude", size: 26) { rs.closeClaude() }
            }
            .padding(.horizontal, Space.s3)
            .frame(height: 44)
            SuiteRule()
            ClaudeChatView(contextKind: "recreate", contextId: rs.reference?.id ?? "start", title: "Claude", showsHeader: false,
                           placeholder: "Ask Claude about this edit…",
                           fallback: sid.map { (kind: "edit", id: $0) },
                           suggestions: RecreateClaude.suggestions(selectedShot: rs.reference?.isReady == true ? rs.selectedSlot : nil,
                                                                   weakestShot: rs.weakestSlot, hasRecipe: rs.reference?.isReady == true),
                           emptyHint: "Claude can read a video’s recipe, explain a shot, pick better takes and rebuild the edit. A new shot is only made after you confirm its price.",
                           wrapOutgoing: { [store] text in
                               RecreateClaude.message(text, reference: store.recreate.reference, sessionId: store.recreate.claudeSessionId)
                           },
                           unwrapShown: RecreateClaude.stripContext)
        }
        .background(t.chrome)
        .background(SnapshotFrame(key: "claude"))
    }
}

/// Claude asked for a paid step (`fill_slot` with confirm): nothing starts until the owner says yes here. Cancel tells
/// Claude not now.
struct RecreateClaudeAsk: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var pending: EditPending

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s2) {
                ClaudeBadge()
                Text("Claude is asking").scaled(t.scale.caption, t.roles.ink2)
            }
            Text("\(pending.label) for \(RecreateText.money(pending.estimateUsd))?").scaled(t.scale.title, t.roles.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("It’s charged to the studio like any new shot. Claude adds it to the edit when it’s ready, and you can undo it.")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Cancel") { store.answerRecreateClaude(approve: false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                SuiteToolButton(title: "Allow · \(RecreateText.money(pending.estimateUsd))", accent: true) { store.answerRecreateClaude(approve: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s5)
        .frame(width: 440, alignment: .leading)
        .background(t.roles.canvas)
    }
}

// MARK: Write the shot briefs (G8)

/// Under "Not described yet": the server writes every missing brief for its price (asked first), or says why it can't
/// (Settings → Claude, or ask Claude on this Mac for free). Hidden on servers without it.
struct RecreateBriefsButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        if let b = rs.briefs {
            VStack(alignment: .leading, spacing: Space.s1) {
                if rs.writingBriefs {
                    HStack(spacing: Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Writing the shot briefs").scaled(t.scale.caption, t.roles.ink2)
                    }
                } else if b.available {
                    SuiteToolButton(title: b.label, icon: "pencil-simple", plain: true) { store.requestRecreateBriefs() }
                        .accessibilityLabel(b.label)
                        .background(SnapshotFrame(key: "briefs"))
                } else if let reason = b.reason, !reason.isEmpty {
                    Text(reason).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                }
                if let e = rs.briefsError { Text(e).scaled(t.scale.caption, t.roles.caution).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// "Write the shot briefs?": the price before anything is charged.
struct RecreateBriefsConfirm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let b = store.recreate.briefs
        let n = b?.slots ?? 0
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Write the shot briefs?").scaled(t.scale.title, t.roles.ink).lineLimit(1).fitProbe("briefs title")
            Text("Claude reads the reference’s frames and describes \(n == 1 ? "the shot" : "the \(n) shots") without a brief: framing, angle, what happens and where. New shots are made from these. It’s charged to the studio\(b?.priceLine.map { ", \($0)" } ?? "").")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Cancel") { store.recreate.askBriefs = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                SuiteToolButton(title: "Write · \(RecreateText.money(b?.estimateUsd ?? 0))", accent: true) { store.confirmRecreateBriefs() }
                    .keyboardShortcut(.defaultAction)
                    .background(SnapshotFrame(key: "briefsConfirm"))
            }
        }
        .padding(Space.s5)
        .frame(width: 440, alignment: .leading)
        .background(t.roles.canvas)
    }
}

// MARK: How a shot is made (G2)

/// "Swap into the reference shot" (the default: the lead goes into the reference's own shot, which keeps its camera, speed
/// and look) or "Generate a new shot"; with a swap, "Keep the reference's setting" on or off. Changing either prices the
/// shot again; nothing is held.
struct RecreateMethodPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var slotId: String
    var onChange: () -> Void = {}

    var body: some View {
        let rs = store.recreate
        let info = rs.estimateInfo[slotId]
        let picked = rs.methods[slotId] ?? info?.method ?? "swap"
        VStack(alignment: .leading, spacing: Space.s1) {
            option("swap", "Swap into the reference shot", "Keeps its camera, speed and look", on: picked == "swap")
            option("generate", "Generate a new shot", "From this shot’s brief", on: picked == "generate")
            if picked == "swap" {
                Toggle(isOn: Binding(get: { !rs.ownSetting.contains(slotId) }, set: { store.setRecreateKeepSetting(slotId, $0); onChange() })) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rs.ownSetting.contains(slotId) ? "Use your own setting" : "Keep the reference’s setting")
                            .scaled(t.scale.caption, t.roles.ink).lineLimit(1).fitProbe("swap setting")
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Keep the reference’s setting")
                .padding(.top, Space.s1)
            }
            if let note = info?.swapUnavailable, !note.isEmpty {
                Text(note).scaled(t.scale.caption, t.roles.caution).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func option(_ method: String, _ title: String, _ hint: String, on: Bool) -> some View {
        Button {
            guard !on else { return }
            store.setRecreateMethod(slotId, method)
            onChange()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                ZStack {
                    Circle().strokeBorder(on ? t.roles.ink : t.roles.ink2, lineWidth: 1.5).frame(width: 14, height: 14)
                    if on { Circle().fill(t.roles.ink).frame(width: 7, height: 7) }
                }
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).scaled(t.scale.caption, t.roles.ink).lineLimit(1).fitProbe("method \(method)")
                    Text(hint).scaled(t.scale.micro, t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Fix shot N

/// Compare → "Fix shot N": swap the shot in the built edit for one of your takes, or make it again (priced, then confirmed:
/// nothing is spent before "Generate · $x"). The shot's timing, transition, ramp, camera and look stay; it's one undoable
/// change in the edit.
struct RecreateFixSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        let slot = rs.fixSlot ?? ""
        let name = rs.shotName(slot)
        let busy = rs.fixBusy != nil
        VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Fix \(name.lowercased())").scaled(t.scale.title, t.roles.ink).lineLimit(1).fitProbe("fix title")
                Text(rs.score(slot).map { "It matches the reference \(RecreateText.percent($0)). Its timing, transition, speed, camera and look stay." }
                     ?? "Its timing, transition, speed, camera and look stay.")
                    .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Use one of my takes").scaled(t.scale.label, t.roles.ink)
                let choices = store.recreateTakeChoices
                if choices.isEmpty {
                    Text("No video takes yet. Make one in the Video suite, or regenerate this shot.")
                        .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s3) {
                            ForEach(choices) { tk in
                                Button { Task { await store.replaceRecreateSlot(slot, take: tk.id) } } label: {
                                    VStack(alignment: .leading, spacing: Space.s1) {
                                        MuseImage(ref: tk.thumb, symbol: "film")
                                            .frame(width: 72, height: 128)
                                            .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                                        Text(tk.caption).scaled(t.scale.caption, t.roles.ink).lineLimit(1).frame(width: 72, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .accessibilityLabel("Use \(tk.caption) for \(name.lowercased())")
                            }
                        }
                    }
                    .frame(height: 152)
                }
            }
            SuiteRule()
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Regenerate this shot").scaled(t.scale.label, t.roles.ink)
                Text("Made with \(store.recreateLead?.shortName ?? "your model"), charged to the studio once you confirm the price.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                RecreateMethodPicker(slotId: slot) { store.recreate.fixEstimate = nil }
                if let note = rs.fixSwapNote, !note.isEmpty {
                    Text(note).scaled(t.scale.caption, t.roles.caution).fixedSize(horizontal: false, vertical: true)
                }
                if let e = rs.fixEstimate {
                    HStack(spacing: Space.s3) {
                        Text(e.priceLine).scaled(t.scale.label, t.roles.ink).monospacedDigit().lineLimit(1).fitProbe("fix price")
                        Spacer(minLength: 0)
                        SuiteToolButton(title: e.buttonLabel.isEmpty ? "Generate · \(RecreateText.money(e.estimate))" : e.buttonLabel, accent: true, disabled: busy) {
                            store.confirmRecreateFix()
                        }
                        .accessibilityLabel("Make the new shot for \(RecreateText.money(e.estimate))")
                    }
                } else {
                    SuiteToolButton(title: "Price a new shot", disabled: busy) { Task { await store.priceRecreateFix() } }
                        .accessibilityLabel("Price a new shot")
                        .background(SnapshotFrame(key: "fixPrice"))
                }
            }
            if let b = rs.fixBusy {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(b).scaled(t.scale.caption, t.roles.ink2)
                }
            }
            if let e = rs.fixError {
                if rs.fixNeedsRebuild {
                    InlineNotice(e, tone: .caution, actionTitle: "Rebuild the edit") { store.rebuildRecreateFromFix() }
                } else {
                    InlineNotice(e, tone: .caution)
                }
            }
            HStack {
                Spacer(minLength: 0)
                SuiteToolButton(title: "Close") { store.closeRecreateFix() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
        }
        .padding(Space.s5)
        .frame(width: 500, alignment: .leading)
        .background(t.roles.canvas)
    }
}

// MARK: Export

/// Export after Build (plans/recreate-edit.md step 7): the built edit with the reference's sound as a guide track, or
/// silent and timed for the sound, plus the reminder to post with the platform's "Use this sound". Rendered on this Mac
/// with the editor's engine; nothing is uploaded or charged.
struct RecreateExportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        let hasSound = store.recreateHasReferenceSound
        let busy = rs.exportProgress != nil
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Export the edit").scaled(t.scale.title, t.roles.ink).lineLimit(1).fitProbe("export title")
            Text("Made on this Mac from the built edit. Nothing is uploaded or charged.")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Sound").scaled(t.scale.label, t.roles.ink)
                EditSeg(options: RecreateExport.Sound.allCases.map { ($0, $0.label) }, selection: rs.exportSound) { s in
                    if s == .guide && !hasSound { return }
                    rs.exportSound = s
                }
                .fixedSize()
                .disabled(busy)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Sound")
                Text(hasSound ? rs.exportSound.hint : "The reference’s sound isn’t on this Mac, so the export is silent. The cuts are timed for the sound.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            reminder
                .background(SnapshotFrame(key: "reminder"))
            if let p = rs.exportProgress {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Making the video on this Mac").scaled(t.scale.label, t.roles.ink)
                    RProgress(value: p)
                }
            }
            if let e = rs.exportError { InlineNotice(e, tone: .danger) }
            if let f = rs.exportedFile {
                InlineNotice("Exported \(f.lastPathComponent)", tone: .neutral, actionTitle: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([f])
                }
            }
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                if rs.exportedFile != nil && !busy {
                    SuiteToolButton(title: "Done", accent: true) { rs.exportOpen = false }
                        .keyboardShortcut(.defaultAction)
                } else {
                    SuiteToolButton(title: "Cancel") {
                        if busy { store.cancelRecreateExport() } else { rs.exportOpen = false }
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                    SuiteToolButton(title: "Export", accent: !busy, disabled: busy) { chooseFile() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Export the video")
                        .background(SnapshotFrame(key: "exportGo"))
                }
            }
        }
        .padding(Space.s5)
        .frame(width: 480, alignment: .leading)
        .background(t.roles.canvas)
    }

    /// "Post with the original sound": the server's steps for this reference's platform, or the plain reminder.
    private var reminder: some View {
        let lines = RecreateExport.reminderLines(store.recreate.useThisSound, reference: store.recreate.reference)
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text(lines.title).scaled(t.scale.label, t.roles.ink)
            if lines.steps.count == 1 {
                Text(lines.steps[0]).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(lines.steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                        Text("\(i + 1).").scaled(t.scale.caption, t.roles.ink2).monospacedDigit()
                        Text(s).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let n = lines.note, !n.isEmpty {
                Text(n).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
        .accessibilityElement(children: .combine)
    }

    private func chooseFile() {
        let rs = store.recreate
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = RecreateExport.fileName(rs.reference?.name, sound: rs.exportSound)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportRecreate(to: url)
    }
}
