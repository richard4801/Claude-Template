import SwiftUI
import MuseCore

/// Settings → Claude → Edit pipeline skill (owner): the how-to Claude reads at the start of every edit and improves after
/// it. Shows the version and its changelog, rolls back (Undo, or to any version: a new version, nothing is lost), and
/// answers the big changes that wait for the owner, each with what it changes before → after.
struct PipelineSkillSettingsSection: View {
    @Environment(\.theme) private var t
    @State private var state: PipelineSkillState?
    @State private var versions: [PipelineVersion] = []
    @State private var diffs: [Int: PipelineDiff] = [:]
    @State private var open: Int?
    @State private var showAll = false
    @State private var busy = false
    @State private var error: String?

    private var api: (any PipelineSkillAPI)? { ClaudeCodeService.shared.api as? any PipelineSkillAPI }

    var body: some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: Space.s2) {
            if let s = state {
                SettingRow("Edit pipeline skill", hint: "Version \(s.version). Claude reads it at the start of every edit and improves it after each one. Core \(s.coreChars) of \(s.coreBudget) characters, \(s.pages.filter { $0.status != "retired" }.count) techniques, \(s.houseStyle.count) house-style notes.") {
                    RButton("Undo last change", kind: .plain, small: true, off: busy || s.version <= 1) { run { _ = try await $0.pipelineUndo() } }
                        .help("Go back to the version before this one")
                        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline undo") } }
                }
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline heading") } }
                if !s.pending.isEmpty {
                    Text("Waiting for you").scaled(t.scale.body, r.ink).padding(.top, Space.s2)
                    ForEach(s.pending) { p in pendingRow(p) }
                }
                if !s.templateHints.isEmpty {
                    Text("Proven and repeatable: \(s.templateHints.map(\.title).joined(separator: ", ")). Ask Claude to save \(s.templateHints.count == 1 ? "it" : "them") as an Edit template.")
                        .scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, Space.s1)
                }
                Text("Changes").scaled(t.scale.body, r.ink).padding(.top, Space.s3)
                ForEach(showAll ? versions : Array(versions.prefix(8))) { v in versionRow(v, current: v.version == s.version) }
                if versions.count > 8 {
                    RButton(showAll ? "Show fewer" : "Show all \(versions.count) versions", kind: .plain, small: true) { showAll.toggle() }
                }
            } else if error == nil {
                SettingRow("Edit pipeline skill", hint: "Loading…")
            }
            if let error { Text(error).scaled(t.scale.caption, r.danger).fixedSize(horizontal: false, vertical: true) }
        }
        .task { await load() }
    }

    @ViewBuilder private func pendingRow(_ p: PipelineProposal) -> some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("\(p.why.prefix(1).uppercased() + p.why.dropFirst()). This \(p.reason).").scaled(t.scale.body, r.ink).fixedSize(horizontal: false, vertical: true)
            beforeAfter(before: p.before, after: p.after)
            HStack(spacing: Space.s2) {
                RButton("Approve", kind: .action, small: true, off: busy) { run { _ = try await $0.pipelineDecide(p.id, approve: true) } }
                    .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline approve") } }
                RButton("Decline", kind: .plain, small: true, off: busy) { run { _ = try await $0.pipelineDecide(p.id, approve: false) } }
                    .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline decline") } }
            }
        }
        .padding(.vertical, Space.s2)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline pending \(p.id)") } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change waiting for you: \(p.why)")
    }

    @ViewBuilder private func versionRow(_ v: PipelineVersion, current: Bool) -> some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(current ? "Version \(v.version), current" : "Version \(v.version)").scaled(t.scale.body, r.ink)
                Text(Date(timeIntervalSince1970: v.createdAt / 1000), style: .date).scaled(t.scale.caption, r.ink2)
                Spacer(minLength: Space.s3)
                RButton(open == v.version ? "Hide changes" : "Show changes", kind: .plain, small: true) { toggle(v.version) }
                if !current { RButton("Roll back to this", kind: .plain, small: true, off: busy) { run { _ = try await $0.pipelineRollback(to: v.version) } }
                    .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline rollback \(v.version)") } } }
            }
            ForEach(Array(v.changelog.prefix(4).enumerated()), id: \.offset) { _, c in
                Text("\(c.what) (\(c.why))").scaled(t.scale.caption, r.ink2).lineLimit(2)
            }
            if v.changelog.count > 4 { Text("and \(v.changelog.count - 4) more").scaled(t.scale.caption, r.ink2) }
            if open == v.version, let d = diffs[v.version] {
                ForEach(Array(d.changes.enumerated()), id: \.offset) { _, c in
                    Text(c.section == "core" ? "Core" : c.section == "page" ? "Technique \(c.name)" : "House style").scaled(t.scale.caption, r.ink).padding(.top, Space.s1)
                    beforeAfter(before: c.before, after: c.after)
                }
                if d.changes.isEmpty { Text("No content changed.").scaled(t.scale.caption, r.ink2) }
            }
        }
        .padding(.vertical, Space.s1)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pipeline version \(v.version)") } }
    }

    /// Before → after, plainly: the old words struck through, the new ones under them.
    @ViewBuilder private func beforeAfter(before: String, after: String) -> some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: 2) {
            if !before.isEmpty { Text(before).strikethrough().scaled(t.scale.caption, r.ink2).lineLimit(8).textSelection(.enabled) }
            Text(after.isEmpty ? "(removed)" : after).scaled(t.scale.caption, r.ink).lineLimit(8).textSelection(.enabled)
        }
        .padding(.leading, Space.s3)
    }

    private func toggle(_ v: Int) {
        if open == v { open = nil; return }
        open = v
        guard diffs[v] == nil, let api else { return }
        Task { if let d = try? await api.pipelineDiff(v) { diffs[v] = d } }
    }

    private func load() async {
        guard let api else { error = "Sign in to your MUSE server first."; return }
        do {
            let s = try await api.pipelineSkill()
            let v = try await api.pipelineVersions()
            state = s
            versions = v
            error = nil
        } catch {
            self.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    private func run(_ act: @escaping (any PipelineSkillAPI) async throws -> Void) {
        guard let api, !busy else { return }
        busy = true
        Task {
            do { try await act(api); diffs = [:]; await load() } catch { self.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription }
            busy = false
        }
    }
}
