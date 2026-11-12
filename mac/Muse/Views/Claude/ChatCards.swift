import AVKit
import MuseCore
import SwiftUI

// The Claude panel's cards (owner's chosen chat reference, 2026-11-12; plans/design/claude-panel/panel-*.png): a plan
// checklist that ticks, a clip with its key moments (click to jump), "What I changed" with Undo per row, and an Approve
// card with price lines and a Total. Design rules (plans/design-direction.md): tone, not shadow; no box inside a card
// (the price table is rows); Approve is the panel's one filled button; ticked steps use `positive` (state); Phosphor only.

struct ChatCardView: View {
    @Environment(\.theme) private var t
    let card: ClaudeCard
    let messageId: String
    var resolve: (String) -> String

    var body: some View {
        Group {
            switch card {
            case .plan(_, let title, let steps): ChatPlanCard(title: title, steps: steps)
            case .media(let title, let summary, let video, let duration, let moments):
                ChatClipCard(title: title, summary: summary, url: resolve(video.url), duration: duration, moments: moments)
            case .changes(let title, let rows): ChatChangesCard(title: title, rows: rows, messageId: messageId)
            case .approve(let title, let subtitle, let lines, let total, let target, let yes, let no):
                ChatApproveCard(title: title, subtitle: subtitle, lines: lines, total: total, target: target, approveLabel: yes, declineLabel: no, messageId: messageId)
            case .unknown: EmptyView()
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field.opacity(t.isDark ? 0.55 : 0.6)))
    }
}

// MARK: Plan

struct ChatPlanCard: View {
    @Environment(\.theme) private var t
    let title: String
    let steps: [ClaudePlanStep]

    var body: some View {
        let r = t.roles
        let done = steps.filter(\.done).count
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(title).scaled(t.scale.label, r.ink).padding(.bottom, Space.s1).accessibilityAddTraits(.isHeader)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(s.done ? r.positive : r.ink2, lineWidth: 1.5)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(s.done ? r.positive : .clear))
                        if s.done { Ph("check", 10).foregroundStyle(r.canvas) }
                    }
                    .frame(width: 16, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(s.text).scaled(t.scale.caption, s.done ? r.ink2 : r.ink).fixedSize(horizontal: false, vertical: true)
                }
                .animation(.easeOut(duration: 0.12), value: s.done)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(s.text), \(s.done ? "done" : "to do")")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(done) of \(steps.count) done")
    }
}

// MARK: Clip analysis

struct ChatClipCard: View {
    @Environment(\.theme) private var t
    let title: String
    let summary: String?
    let url: String
    let duration: Double?
    let moments: [ClaudeMoment]
    @State private var player: AVPlayer?
    @State private var hover: Int?

    var body: some View {
        let r = t.roles
        HStack(alignment: .top, spacing: Space.s3) {
            ZStack(alignment: .bottomTrailing) {
                if let player { VideoPlayer(player: player) } else { r.field }
                if let duration {
                    Text(ClaudeCardText.clock(duration)).scaled(t.scale.micro, .white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 104, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
            .accessibilityLabel("The clip\(duration.map { ", \(ClaudeCardText.clock($0)) long" } ?? "")")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaled(t.scale.label, r.ink).accessibilityAddTraits(.isHeader)
                if let summary { Text(summary).scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true).padding(.bottom, Space.s1) }
                ForEach(Array(moments.enumerated()), id: \.offset) { i, m in
                    Button { seek(m.from) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                            Text(m.timecode).monospacedDigit().scaled(t.scale.micro, r.ink).frame(width: 66, alignment: .leading)
                            Text(m.label).scaled(t.scale.caption, r.ink).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(hover == i ? r.field : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, -6)
                    .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                    .help("Play from \(ClaudeCardText.clock(m.from))")
                    .accessibilityLabel("\(m.label), at \(m.timecode). Play from here")
                }
            }
        }
        .onAppear { if player == nil, let u = URL(string: url) { player = AVPlayer(url: u) } }
        .onDisappear { player?.pause() }
    }

    private func seek(_ s: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

// MARK: What I changed

struct ChatChangesCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    let title: String
    let rows: [ClaudeChangeRow]
    let messageId: String

    var body: some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: 0) {
            Text(title).scaled(t.scale.label, r.ink).padding(.bottom, Space.s1).accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: Space.s2) {
                    Text(row.what).scaled(t.scale.caption, r.ink2).lineLimit(1).fixedSize()
                    Ph("caret-right", 10).foregroundStyle(r.ink2)
                    Text(row.to).font(t.scale.caption.font.weight(.semibold)).foregroundStyle(row.undone ? r.ink2 : r.ink)
                        .strikethrough(row.undone).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Space.s2)
                    if row.undone {
                        Text("Undone").scaled(t.scale.micro, r.ink2)
                    } else if row.undoable {
                        Button { Task { await store.undoClaudeCardRow(messageId: messageId, row: i, label: row.what) } } label: {
                            HStack(spacing: 4) { Ph("arrow-counter-clockwise", 12); Text("Undo") }
                                .font(t.scale.micro.font).foregroundStyle(r.ink2).frame(minHeight: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.oneClaude.undoing.contains("\(messageId)#\(i)"))
                        .help("Put \(row.what.lowercased()) back as it was")
                        .accessibilityLabel("Undo \(row.what)")
                    }
                }
                .frame(minHeight: 30)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(ClaudeCardText.change(row))
            }
        }
    }
}

// MARK: Approve

struct ChatApproveCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    let title: String
    let subtitle: String?
    let lines: [ClaudePriceLine]
    let total: Double?
    let target: ClaudeApproveTarget
    let approveLabel: String
    let declineLabel: String
    let messageId: String

    var body: some View {
        let r = t.roles
        let state = store.oneClaude.answeredCards[messageId]
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaled(t.scale.label, r.ink).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true) }
            if !lines.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline) {
                            Text(l.label).scaled(t.scale.caption, r.ink2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.s2)
                            Text(ClaudeCardText.money(l.usd)).monospacedDigit().scaled(t.scale.caption, r.ink).fixedSize()
                        }
                    }
                    Rectangle().fill(r.hairline).frame(height: 1).padding(.vertical, Space.s1)
                    HStack {
                        Text("Total").font(t.scale.caption.font.weight(.semibold)).foregroundStyle(r.ink)
                        Spacer()
                        Text(ClaudeCardText.money(ClaudeCardText.total(lines, total))).monospacedDigit().font(t.scale.caption.font.weight(.semibold)).foregroundStyle(r.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.top, Space.s2)
            }
            if let state {
                Text(state).scaled(t.scale.caption, r.ink2).padding(.top, Space.s2)
            } else {
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: approveLabel, filled: true, disabled: store.oneClaude.answering.contains(messageId)) {
                        Task { await store.answerClaudeCard(messageId: messageId, target: target, approve: true) }
                    }
                    .frame(maxWidth: .infinity)
                    SuiteToolButton(title: declineLabel, disabled: store.oneClaude.answering.contains(messageId)) {
                        Task { await store.answerClaudeCard(messageId: messageId, target: target, approve: false) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, Space.s3)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Live activity strip

/// "Opening Swap… setting outfit…", a percentage and a bar while Claude operates the window or a job it started runs,
/// and "Esc to stop" (Esc stops the window calls; the job itself runs on).
struct ClaudeActivityStrip: View {
    @Environment(\.theme) private var t
    let activity: ClaudeActivity
    var onStop: () -> Void

    var body: some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.s2) {
                ClaudeOrbView(size: 18) // in place of a spinner
                Text(activity.line.isEmpty ? "Working…" : activity.line).scaled(t.scale.caption, r.ink).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Space.s2)
                if let p = activity.percent { Text(p).monospacedDigit().scaled(t.scale.micro, r.ink2) }
                if !activity.open.isEmpty {
                    Button(action: onStop) {
                        Text("Esc to stop").scaled(t.scale.micro, r.ink2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(r.hairline))
                    }
                    .buttonStyle(.plain)
                    .help("Stop Claude using the window (Esc)")
                    .accessibilityLabel("Stop Claude")
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(r.field)
                    Capsule().fill(r.accent).frame(width: g.size.width * CGFloat(activity.progress ?? 0))
                        .animation(.easeOut(duration: 0.2), value: activity.progress)
                }
            }
            .frame(height: 3)
            .opacity(activity.progress == nil ? 0 : 1)
        }
        .padding(.horizontal, Space.s4).padding(.top, Space.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.line)\(activity.percent.map { ", \($0)" } ?? "")")
    }
}
