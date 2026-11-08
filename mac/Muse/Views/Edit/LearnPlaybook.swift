import MuseCore
import SwiftUI

/// The Playbook (plans/learning-editor-ui.md §1, the owner-approved design): the rules Claude follows, in plain words.
/// Rules · Suggestions · History is a segmented control (no menus, so the CI click-through reaches every segment); "Add
/// rule" is the one filled button; the rule editor is a popover-style panel over the page, not a phone sheet.
struct LearnPlaybookView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let l = store.learn
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.s5)
                .padding(.bottom, Space.s7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if l.draft != nil {
                // A click outside the panel closes it, like a popover.
                Color.black.opacity(0.001)
                    .onTapGesture { store.cancelRule() }
                    .accessibilityHidden(true)
                LearnRuleEditor()
                    .padding(.top, 150)
                    .padding(.horizontal, Space.gutter)
                    .frame(maxWidth: 760 + 2 * Space.gutter, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .background(t.roles.canvas)
        .animation(.easeOut(duration: 0.2), value: l.draft != nil)
        .sheet(isPresented: Binding(get: { store.learn.deletingRule != nil }, set: { if !$0 { store.keepRule() } })) {
            LearnConfirm(title: "Delete this rule?", note: "Claude stops following it from the next edit.", action: "Delete rule",
                         keep: { store.keepRule() }, confirm: {
                             let id = store.learn.deletingRule
                             Task { await store.confirmDeleteRule(id) }
                         })
        }
    }

    private var header: some View {
        let l = store.learn
        let showAdd = !(l.rules?.isEmpty ?? true) || l.tab != .rules
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.s3) {
                SuiteIconButton(systemName: "caret-left", label: "Back to Edit") { store.closeLearn() }
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Playbook").scaled(t.scale.display, t.roles.ink).lineLimit(1).fitProbe("playbook title")
                        .accessibilityAddTraits(.isHeader)
                    Text("Claude reads these before every edit.").scaled(t.scale.caption, t.roles.ink2).lineLimit(1).fitProbe("playbook subtitle")
                }
                Spacer(minLength: Space.s4)
                if showAdd && l.rules != nil {
                    Button { store.startNewRule() } label: {
                        HStack(spacing: Space.s2) {
                            Ph("plus", 14)
                            Text("Add rule").fixedSize().fitProbe("Add rule")
                        }
                    }
                    .buttonStyle(RButtonStyle(kind: .action))
                    .disabled(l.full)
                    .help(l.full ? "The playbook holds 200 rules · delete some first" : "Add a rule Claude follows")
                    .accessibilityLabel("Add rule")
                }
            }
            if l.full {
                Text("The playbook holds 200 rules · delete some first").scaled(t.scale.caption, t.roles.ink2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, Space.s2)
            }
            RSeg([(PlaybookTab.rules, "Rules"), (.suggestions, "Suggestions"), (.history, "History")],
                 selection: Binding(get: { store.learn.tab }, set: { store.learn.tab = $0 }))
                .fixedSize()
                .padding(.top, Space.s5)
                .padding(.leading, 40)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Rules, suggestions or history")
        }
        .padding(.bottom, Space.s4)
    }

    @ViewBuilder private var content: some View {
        let l = store.learn
        Group {
            if let e = l.playbookError, l.rules == nil {
                LearnErrorLine(text: e) { Task { await store.loadPlaybook() } }
            } else if l.rules == nil {
                LearnSkeletonRows()
            } else {
                switch l.tab {
                case .rules: rules
                case .suggestions: suggestions
                case .history: history
                }
            }
        }
        .padding(.leading, 40)
    }

    // MARK: Rules

    @ViewBuilder private var rules: some View {
        let list = store.learn.rules ?? []
        if list.isEmpty {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("No rules yet. Claude suggests some from the changes you make to its edits, and you can add your own.")
                    .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                RButton("Add rule", kind: .action) { store.startNewRule() }
            }
            .padding(.top, Space.s4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(LearnFilter.grouped(list)) { g in
                    Text(LearnText.area(g.area)).scaled(t.scale.heading, t.roles.ink)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Space.s5)
                        .padding(.bottom, Space.s2)
                    ForEach(g.rules) { r in LearnRuleRow(rule: r) }
                }
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestions: some View {
        let lessons = store.learn.lessons ?? []
        if lessons.isEmpty {
            Text("No suggestions yet. They appear after you change or undo a few of Claude's edits.")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, Space.s4)
        } else {
            VStack(alignment: .leading, spacing: Space.s5) {
                ForEach(lessons) { l in
                    HStack(alignment: .top, spacing: Space.s4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LearnText.sentence(l)).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                            if let first = l.examples.first {
                                Text("\(first) · \(LearnText.relative(l.last, now: store.learn.now).lowercased())")
                                    .scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                            }
                            if l.examples.count > 1 {
                                Text(l.examples[1]).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                            }
                        }
                        Spacer(minLength: Space.s3)
                        Button("Make a rule") { store.startRule(from: l) }
                            .buttonStyle(RButtonStyle(kind: .plain, small: true))
                            .fixedSize()
                            .fitProbe("Make a rule")
                            .disabled(store.learn.full)
                            .accessibilityLabel("Make a rule: \(LearnText.sentence(l))")
                    }
                }
            }
            .padding(.top, Space.s5)
        }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        let list = store.learn.corrections ?? []
        if list.isEmpty {
            Text("Nothing yet. Your changes to Claude's edits show here.")
                .scaled(t.scale.body, t.roles.ink2)
                .padding(.top, Space.s4)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { c in
                    let take = store.correctionTake(c.takeId)
                    let row = HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.what).scaled(t.scale.body, t.roles.ink).lineLimit(2)
                            Text(LearnText.area(c.area)).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                        }
                        Spacer(minLength: Space.s3)
                        Text(LearnText.relative(c.createdAt, now: store.learn.now)).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                            .lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, Space.s2)
                    .contentShape(Rectangle())
                    if let take {
                        Button { store.openLearnTake(take.id) } label: { row }
                            .buttonStyle(.plain)
                            .help("Open this edit")
                            .accessibilityLabel("Open the edit: \(c.what)")
                    } else {
                        row.accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.top, Space.s4)
        }
    }
}

/// A rule: the text (three lines at most, the whole rule in the tooltip), who wrote it and its evidence, then Edit and
/// Delete on hover or keyboard focus, and the pin. No row menu.
struct LearnRuleRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var rule: LearnRule
    @State private var hover = false
    @FocusState private var focus: String?

    var body: some View {
        let r = t.roles
        let shown = hover || focus != nil
        HStack(alignment: .top, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.text).scaled(t.scale.body, r.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(rule.text)
                Text(LearnText.byline(rule)).scaled(t.scale.caption, r.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                SuiteIconButton(systemName: "pencil-simple", label: "Edit rule", size: 30) { store.startEditing(rule) }
                    .focused($focus, equals: "edit")
                    .opacity(shown ? 1 : 0)
                SuiteIconButton(systemName: "trash", label: "Delete rule", size: 30) { store.askDeleteRule(rule.id) }
                    .focused($focus, equals: "delete")
                    .opacity(shown ? 1 : 0)
                Button { Task { await store.togglePin(rule) } } label: {
                    Ph("push-pin", 15)
                        .foregroundStyle(rule.pinned ? r.selection : r.ink2)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focus, equals: "pin")
                .help(rule.pinned ? "Unpin rule" : "Pin rule")
                .accessibilityLabel(rule.pinned ? "Unpin rule" : "Pin rule")
                .accessibilityAddTraits(rule.pinned ? .isSelected : [])
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2 + 2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(shown ? (t.isDark ? r.field : r.raised) : .clear))
        .padding(.horizontal, -Space.s3)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: shown)
    }
}

/// The rule editor: the text (a counter from 250 characters), the area, the evidence, "Add a note", then Save rule and
/// Cancel, and a quiet red "Delete rule" when editing. A panel floating over the page (the one `float` shadow).
struct LearnRuleEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @FocusState private var textFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
        ViewThatFits(in: .vertical) {
            fields
            ScrollView(.vertical) { fields }
        }
        .frame(width: 540)
        .background(shape.fill(t.roles.raised))
        .clipShape(shape)
        .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: t.isDark ? 1 : 0))
        .museFloat(t)
        .onAppear { textFocused = true }
    }

    private var fields: some View {
        let d = store.learn.draft ?? RuleDraft()
        let r = t.roles
        let binding = Binding(get: { store.learn.draft?.text ?? "" }, set: { store.learn.draft?.text = String($0.prefix(Learn.maxRuleChars)) })
        return VStack(alignment: .leading, spacing: Space.s4) {
            Text(d.isNew ? "New rule" : "Edit rule").scaled(t.scale.title, r.ink).lineLimit(1).fitProbe("rule editor title")
            VStack(alignment: .trailing, spacing: Space.s1) {
                ZStack(alignment: .topLeading) {
                    if d.text.isEmpty {
                        Text(d.evidence.isEmpty ? "Say what Claude should do" : "Say what Claude should do instead")
                            .font(t.scale.body.font).foregroundStyle(r.ink2)
                            .padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: binding)
                        .font(t.scale.body.font)
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .frame(height: 4 * 21)
                        .accessibilityLabel("Rule")
                }
                .roleField(focused: textFocused, multiline: true)
                if let c = LearnText.counter(d.text) {
                    Text(c).monospacedDigit().scaled(t.scale.caption, d.text.count >= Learn.maxRuleChars ? r.caution : r.ink2)
                        .fixedSize().fitProbe("rule counter")
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Area").scaled(t.scale.label, r.ink)
                LearnAreaSeg(selection: d.area) { store.learn.draft?.area = $0 }
            }
            if !d.evidence.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Evidence").scaled(t.scale.label, r.ink)
                    VStack(alignment: .leading, spacing: Space.s1) {
                        ForEach(Array(d.evidence.prefix(6).enumerated()), id: \.offset) { _, e in evidenceLine(e) }
                        if d.evidence.count > 6 {
                            Text("and \(d.evidence.count - 6) more").scaled(t.scale.caption, r.ink2)
                        }
                    }
                }
            }
            if d.noting {
                RTextField(placeholder: "Why this rule", text: Binding(get: { store.learn.draft?.note ?? "" },
                                                                       set: { store.learn.draft?.note = String($0.prefix(200)) }))
                    .accessibilityLabel("Note")
            } else {
                Button { store.learn.draft?.noting = true } label: {
                    HStack(spacing: Space.s2) { Ph("plus", 13); Text("Add a note").fixedSize().fitProbe("Add a note") }
                }
                .buttonStyle(RButtonStyle(kind: .plain, small: true))
                .padding(.leading, -Space.s2)
                .accessibilityLabel("Add a note")
            }
            HStack(spacing: Space.s3) {
                if !d.isNew, let id = d.id {
                    Button("Delete rule") { store.askDeleteRule(id) }
                        .buttonStyle(RButtonStyle(kind: .danger, small: true))
                        .fixedSize()
                        .fitProbe("Delete rule")
                        .padding(.leading, -Space.s2)
                }
                Spacer(minLength: Space.s2)
                Button("Cancel") { store.cancelRule() }
                    .buttonStyle(RButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .fitProbe("Cancel")
                Button("Save rule") { Task { await store.saveRule() } }
                    .buttonStyle(RButtonStyle(kind: .action))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.learn.saving)
                    .fixedSize()
                    .fitProbe("Save rule")
            }
        }
        .padding(Space.s5)
    }

    @ViewBuilder private func evidenceLine(_ e: LearnEvidence) -> some View {
        let line = Text(LearnText.evidence(e, now: store.learn.now)).scaled(t.scale.caption, t.roles.ink2).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        if let take = store.evidenceTake(e) {
            Button { store.cancelRule(); store.openLearnTake(take.id) } label: { line }
                .buttonStyle(.plain)
                .help("Open this edit")
        } else {
            line
        }
    }
}

/// The eleven areas as one segmented control on three rows (a segmented control, not a menu: the click-through reaches each).
struct LearnAreaSeg: View {
    @Environment(\.theme) private var t
    var selection: String
    var onChange: (String) -> Void

    var body: some View {
        let r = t.roles
        let inner = RoundedRectangle(cornerRadius: max(0, t.radii.control - 2), style: .continuous)
        // Four to a row, so the longest name ("Transitions") never crowds its neighbour.
        let rows: [[String]] = stride(from: 0, to: Learn.areas.count, by: 4).map { Array(Learn.areas[$0..<min($0 + 4, Learn.areas.count)]) }
        VStack(spacing: 2) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 2) {
                    ForEach(rows[i], id: \.self) { a in
                        let on = a == selection
                        Button { onChange(a) } label: {
                            Text(LearnText.area(a)).font(t.scale.label.font).lineLimit(1).fixedSize()
                                .fitProbe("area \(a)")
                                .foregroundStyle(on ? r.ink : r.ink2)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(inner.fill(on ? (t.isDark ? r.hairline : r.raised) : .clear))
                                .overlay(inner.strokeBorder(r.selection, lineWidth: on && t.isD ? 2 : 0))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    ForEach(0..<(4 - rows[i].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 28) }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(r.field))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Area")
    }
}

/// A delete confirmation: names the action, says what stays, "Keep" or the red destructive button (the one fill here).
struct LearnConfirm: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    var title: String
    var note: String?
    var action: String
    var keep: () -> Void
    var confirm: () -> Void

    var body: some View {
        let r = t.roles
        let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).scaled(t.scale.title, r.ink).lineLimit(1).fitProbe(title)
            if let note { Text(note).scaled(t.scale.body, r.ink2).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: Space.s3) {
                Spacer(minLength: 0)
                Button("Keep") { keep(); dismiss() }
                    .buttonStyle(RButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button { confirm(); dismiss() } label: {
                    Text(action).font(t.scale.label.font).foregroundStyle(.white).lineLimit(1).fixedSize()
                        .padding(.horizontal, Space.s4).frame(height: 32)
                        .background(shape.fill(r.danger))
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action)
            }
            .padding(.top, Space.s2)
        }
        .padding(Space.s5)
        .frame(width: 400, alignment: .leading)
        .background(r.canvas)
    }
}

/// Loading: three rows of skeleton lines, shaped like rules.
struct LearnSkeletonRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            SkeletonBlock(width: 90, height: 14)
            ForEach(0..<3, id: \.self) { i in
                VStack(alignment: .leading, spacing: Space.s2) {
                    SkeletonBlock(width: CGFloat([420, 360, 300][i]), height: 12)
                    SkeletonBlock(width: CGFloat([110, 150, 90][i]), height: 10)
                }
            }
        }
        .padding(.top, Space.s5)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// An error in words, with "Try again".
struct LearnErrorLine: View {
    @Environment(\.theme) private var t
    var text: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(text).scaled(t.scale.body, t.roles.danger).fixedSize(horizontal: false, vertical: true)
            RButton("Try again", kind: .quiet, action: retry)
        }
        .padding(.top, Space.s4)
    }
}
