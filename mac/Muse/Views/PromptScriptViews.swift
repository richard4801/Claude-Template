import MuseCore
import SwiftUI

// Settings → Prompts → Scripts (owner only; prompt scripts, workstream 4). A script puts the prompt library's blocks together:
// typed inputs → rules → blocks. The owner switches rules on and off, edits them in a structured form, reorders them within a
// place and watches a live preview. Locked rules (who she is, what is kept, the user's own words …) only take text edits.

/// The scripts, grouped like the blocks.
struct ScriptsList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Muted("A script decides which blocks go into a prompt, from facts about the job (is the performer speaking? are presets on?). Edit its rules here and the blocks' wording under Blocks. A saved edit is used for every new prompt in your studio.")
            if let err = store.scriptListError, store.scriptList == nil {
                Note(icon: "exclamationmark.triangle", warn: true, err)
                MButton("Try again", size: .small) { Task { await store.loadScripts() } }
            } else if let list = store.scriptList {
                ForEach(list.sections, id: \.group.id) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Lbl(section.group.label)
                        ListBox {
                            ForEach(Array(section.scripts.enumerated()), id: \.element.id) { i, s in
                                ScriptRow(script: s, last: i == section.scripts.count - 1) { store.openScript(s.id) }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Muted("Loading scripts…")
                }
            }
        }
        .task { if store.scriptList == nil { await store.loadScripts() } }
    }
}

struct ScriptRow: View {
    @Environment(\.theme) private var t
    var script: ScriptView
    var last: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(script.title).font(t.body(14, .semibold)).foregroundStyle(t.ink)
                            if script.overridden { Pill("Edited", .acc) }
                        }
                        if !script.description.isEmpty {
                            Text(script.description).font(t.body(12)).foregroundStyle(t.muted).lineLimit(2).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(hover ? t.surface2.opacity(0.6) : .clear)
                if !last { Rectangle().fill(t.line).frame(height: t.lineWidth).padding(.leading, 16) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One script: inputs, rules by place, blocks, the live preview, Save and Reset.
struct ScriptScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        if let s = store.currentScript {
            VStack(alignment: .leading, spacing: 16) {
                LinkText("← All scripts") { store.closeScript() }
                HStack(spacing: 10) {
                    H2(s.title)
                    if s.overridden { Pill("Edited", .acc) }
                }
                if !s.description.isEmpty { Muted(s.description) }
                if s.stale {
                    Note(icon: "exclamationmark.triangle", warn: true, "Your saved rules no longer fit this script, so it is back on the default rules.")
                }
                inputs(s)
                rules(s)
                blocks(s)
                ScriptPreviewPane(script: s)
                if let err = store.scriptError {
                    Note(icon: "exclamationmark.triangle", warn: true, err)
                }
                HStack(spacing: 10) {
                    MButton(store.scriptSaving ? "Saving…" : "Save", kind: .primary, off: !store.scriptDirty || store.scriptSaving) { store.saveScript() }
                    if store.scriptDirty { MButton("Undo changes") { store.undoScriptChanges() } }
                    Spacer()
                    if s.overridden {
                        MButton("Reset to default", icon: "arrow.uturn.backward") { confirmReset = true }
                    }
                }
                if let by = s.updatedBy, s.overridden {
                    Muted("Last saved by \(by)\(s.updatedAt.map { " · " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "")")
                }
            }
            // Live preview, debounced: POST /v1/prompt-scripts/preview with the inputs and the unsaved rules.
            .task(id: store.scriptPreviewKey) {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await store.refreshScriptPreview()
            }
            .confirmationDialog("Reset “\(s.title)” to its default rules?", isPresented: $confirmReset) {
                Button("Reset to default", role: .destructive) { store.resetScript() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every new prompt in your studio goes back to MUSE's default rules. Block texts are not changed.")
            }
            .sheet(item: $store.scriptEditingRule) { r in
                RuleEditorSheet(script: s, rule: r)
                    .environment(store)
                    .environment(\.theme, t)
            }
        }
    }

    @ViewBuilder private func inputs(_ s: ScriptView) -> some View {
        if !s.inputs.isEmpty {
            Field("Inputs") {
                ListBox {
                    ForEach(Array(s.inputs.enumerated()), id: \.element.id) { i, input in
                        ListRow(title: "\(input.label) · \(input.typeLabel)", hint: input.description.isEmpty ? nil : input.description, last: i == s.inputs.count - 1) {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func rules(_ s: ScriptView) -> some View {
        let lib = store.promptLibrary
        let ops = store.scriptOps
        Field("Rules") {
            VStack(alignment: .leading, spacing: 12) {
                Muted("Each place uses the first rule that applies (a repeating or combined place uses every one). Click a rule to change it.")
                ForEach(s.places(store.scriptDraft)) { place in
                    VStack(alignment: .leading, spacing: 6) {
                        Lbl(place.target.label)
                        ListBox {
                            ForEach(Array(place.rules.enumerated()), id: \.element.id) { i, r in
                                RuleRow(script: s, rule: r, sentence: ScriptText.sentence(r, script: s, ops: ops) { ScriptText.blockTitle($0, library: lib) },
                                        last: i == place.rules.count - 1)
                            }
                        }
                    }
                }
                MButton("Add a rule", icon: "plus", size: .small) { store.addRule() }
            }
        }
    }

    @ViewBuilder private func blocks(_ s: ScriptView) -> some View {
        let lib = store.promptLibrary
        Field("Blocks") {
            ListBox {
                ForEach(Array(s.blocks.enumerated()), id: \.element) { i, key in
                    let entry = lib?.entry(key)
                    Button {
                        store.openPrompt(key)
                    } label: {
                        ListRow(title: entry?.title ?? key, hint: key, last: i == s.blocks.count - 1) {
                            HStack(spacing: 8) {
                                if entry?.overridden == true { Pill("Edited", .acc) }
                                if entry != nil { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.muted) }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(entry == nil)
                }
            }
        }
    }
}

/// A rule as a sentence: a lock for locked rules, an on/off switch for the others. Click: edit it (a locked one opens its block).
struct RuleRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var script: ScriptView
    var rule: ScriptRule
    var sentence: String
    var last: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                if rule.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(t.muted).help("Locked: only its block's text can be changed")
                }
                Button {
                    if rule.isLocked { store.openPrompt(rule.block) } else { store.editRule(rule.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(rule.label).font(t.body(14, .semibold)).foregroundStyle(rule.isOn ? t.ink : t.muted)
                            if rule.isOptional == true { Pill("Presets") }
                            if script.isAdded(rule) { Pill("Added") }
                            if !rule.isOn { Pill("Off", .warn) }
                        }
                        Text(sentence).font(t.body(12.5)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !rule.isLocked {
                    MToggle(isOn: Binding(get: { rule.isOn }, set: { store.setRuleOn(rule.id, $0) }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(hover ? t.surface2.opacity(0.6) : .clear)
            if !last { Rectangle().fill(t.line).frame(height: t.lineWidth).padding(.leading, 16) }
        }
        .onHover { hover = $0 }
    }
}

/// The preview: a control per input (pre-filled with its sample), the assembled prompt and the rules that fired.
struct ScriptPreviewPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var script: ScriptView

    var body: some View {
        Field("Preview") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(script.inputs) { input in
                    HStack(spacing: 12) {
                        Text(input.label).font(t.body(13)).foregroundStyle(t.ink)
                        Spacer(minLength: 8)
                        control(input)
                    }
                }
                Rectangle().fill(t.line).frame(height: t.lineWidth)
                if let p = store.scriptPreview {
                    Text(p.text.isEmpty ? "(empty)" : p.text)
                        .font(t.mono(11.5)).foregroundStyle(t.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !p.fired.isEmpty {
                        Lbl("Rules used")
                        FlowLayout {
                            ForEach(p.fired.indices, id: \.self) { i in
                                let id = p.fired[i]
                                Pill(store.scriptDraft.first { $0.id == id }?.label ?? id)
                            }
                        }
                    }
                } else {
                    Muted("Building the preview…")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
        }
    }

    private func value(_ name: String) -> JSONValue { store.scriptInputs[name] ?? .null }

    @ViewBuilder private func control(_ input: ScriptInputDef) -> some View {
        let name = input.name
        switch input.type {
        case "bool":
            MToggle(isOn: Binding(get: { value(name) == .bool(true) }, set: { store.scriptInputs[name] = .bool($0) }))
        case "enum":
            let current: String = {
                if case .string(let s) = value(name) { return input.optionLabel(s) }
                return "—"
            }()
            ScriptMenu(title: current, options: (input.options ?? []).map { ($0.id, $0.label) }) { store.scriptInputs[name] = .string($0) }
        case "number":
            TextField("0", text: Binding(get: { value(name).description }, set: { s in
                if let n = Double(s.trimmingCharacters(in: .whitespaces)) { store.scriptInputs[name] = .number(n) }
            }))
            .fieldChrome()
            .frame(width: 90)
        case "list":
            if let options = input.options, input.fields == nil {
                FlowLayout {
                    ForEach(options) { o in
                        Chip(o.label, on: listHas(name, o.id)) { toggle(name, o.id) }
                    }
                }
                .frame(maxWidth: 320)
            } else {
                Muted(listSummary(value(name)))
            }
        default:
            TextField("", text: Binding(get: {
                if case .string(let s) = value(name) { return s }
                return ""
            }, set: { store.scriptInputs[name] = .string($0) }))
            .fieldChrome()
            .frame(width: 220)
        }
    }

    private func listHas(_ name: String, _ id: String) -> Bool {
        if case .array(let a) = value(name) { return a.contains(.string(id)) }
        return false
    }

    private func toggle(_ name: String, _ id: String) {
        var a: [JSONValue] = []
        if case .array(let cur) = value(name) { a = cur }
        if let i = a.firstIndex(of: .string(id)) { a.remove(at: i) } else { a.append(.string(id)) }
        store.scriptInputs[name] = .array(a)
    }

    private func listSummary(_ v: JSONValue) -> String {
        if case .array(let a) = v { return a.count == 1 ? "Sample: 1 item" : "Sample: \(a.count) items" }
        return "Sample"
    }
}

/// A small menu button: the current choice as its title, one item per option.
struct ScriptMenu: View {
    @Environment(\.theme) private var t
    var title: String
    var options: [(String, String)]
    var onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { onPick(options[i].0) }
            }
        } label: {
            Text(title).font(t.body(13)).foregroundStyle(t.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
    }
}

/// The rule form: name, place, block, conditions (input → test → value), move, delete (added rules only).
struct RuleEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    let script: ScriptView
    @State private var rule: ScriptRule

    init(script: ScriptView, rule: ScriptRule) {
        self.script = script
        _rule = State(initialValue: rule)
    }

    private var isNew: Bool { !store.scriptDraft.contains { $0.id == rule.id } }

    var body: some View {
        let lib = store.promptLibrary
        let ops = store.scriptOps
        VStack(alignment: .leading, spacing: 14) {
            H2(isNew ? "New rule" : "Edit rule")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Field("Name") {
                        TextField("What this rule does", text: $rule.label).fieldChrome()
                    }
                    Field("Place") {
                        ScriptMenu(title: script.targetLabel(rule.target), options: script.targets.map { ($0.id, $0.label) }) { rule.target = $0 }
                    }
                    Field("Block") {
                        ScriptMenu(title: ScriptText.blockTitle(rule.block, library: lib),
                                   options: script.blocks.map { ($0, ScriptText.blockTitle($0, library: lib)) }) { rule.block = $0 }
                    }
                    Field("Conditions", trailing: rule.when.count < ScriptEngine.maxConditions ? "Add condition" : nil, trailingAction: { addCondition() }) {
                        if rule.when.isEmpty {
                            Muted("No conditions: the rule always applies.")
                        } else {
                            ForEach(Array(rule.when.enumerated()), id: \.offset) { i, c in
                                ConditionRow(script: script, target: rule.target, cond: c, ops: ops, onChange: { new in
                                    if i < rule.when.count { rule.when[i] = new }
                                }, onRemove: {
                                    if i < rule.when.count { rule.when.remove(at: i) }
                                })
                            }
                            Muted("All conditions must hold.")
                        }
                    }
                    Field("Reads") {
                        Text(ScriptText.sentence(rule, script: script, ops: ops) { ScriptText.blockTitle($0, library: lib) })
                            .font(t.body(12.5)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 460)
            HStack(spacing: 8) {
                if !isNew {
                    MButton("Move up", icon: "arrow.up", size: .small) { store.moveRule(rule.id, up: true) }
                    MButton("Move down", icon: "arrow.down", size: .small) { store.moveRule(rule.id, up: false) }
                    if script.isAdded(rule) {
                        MButton("Delete", icon: "trash", size: .small) { store.deleteRule(rule.id) }
                    }
                }
                Spacer()
                MButton("Cancel") { store.scriptEditingRule = nil }
                    .keyboardShortcut(.cancelAction)
                MButton("Done", kind: .primary, off: rule.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { store.commitRule(rule) }
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(t.surface)
    }

    private func addCondition() {
        guard rule.when.count < ScriptEngine.maxConditions, let first = script.conditionInputs(target: rule.target).first else { return }
        rule.when.append(ScriptText.newCondition(first.key, def: first.def, ops: store.scriptOps))
    }
}

/// One condition: input menu → test menu (only the tests for the input's type) → value control.
struct ConditionRow: View {
    @Environment(\.theme) private var t
    let script: ScriptView
    let target: String
    let cond: ScriptCond
    let ops: [CondOpInfo]
    let onChange: (ScriptCond) -> Void
    let onRemove: () -> Void

    var body: some View {
        let def = script.input(cond.input, target: target)
        let allowed = def.map { CondOpInfo.ops(for: $0.type, in: ops) } ?? []
        let opLabel = (ops.isEmpty ? CondOpInfo.defaults : ops).first { $0.id == cond.op }?.label ?? cond.op
        HStack(alignment: .center, spacing: 8) {
            ScriptMenu(title: def?.label ?? cond.input, options: script.conditionInputs(target: target).map { ($0.key, $0.def.label) }) { key in
                onChange(ScriptText.newCondition(key, def: script.input(key, target: target), ops: ops))
            }
            ScriptMenu(title: opLabel, options: allowed.map { ($0.id, $0.label) }) { op in
                var c = cond
                c.op = op
                c.value = ScriptText.defaultValue(op: op, def: def)
                onChange(c)
            }
            if cond.needsValue { valueControl(def) }
            Spacer(minLength: 0)
            Button { onRemove() } label: {
                Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(t.muted)
            }
            .buttonStyle(.plain)
            .help("Remove this condition")
            .accessibilityLabel("Remove this condition")
        }
    }

    private func set(_ v: JSONValue) {
        var c = cond
        c.value = v
        onChange(c)
    }

    @ViewBuilder private func valueControl(_ def: ScriptInputDef?) -> some View {
        let options = def?.options ?? []
        if cond.op == "in" || cond.op == "notIn" {
            FlowLayout {
                ForEach(options) { o in
                    Chip(o.label, on: picked(o.id)) { togglePick(o.id) }
                }
            }
            .frame(maxWidth: 280)
        } else if (cond.op == "has" || cond.op == "hasNot" || def?.type == "enum") && !options.isEmpty {
            let current: String = {
                if case .string(let s)? = cond.value { return def?.optionLabel(s) ?? s }
                return "—"
            }()
            ScriptMenu(title: current, options: options.map { ($0.id, $0.label) }) { set(.string($0)) }
        } else if def?.type == "bool" {
            ScriptMenu(title: cond.value == .bool(false) ? "no" : "yes", options: [("true", "yes"), ("false", "no")]) { set(.bool($0 == "true")) }
        } else if def?.type == "number" || cond.op == "atLeast" || cond.op == "atMost" {
            TextField("0", text: Binding(get: { cond.value?.description ?? "" }, set: { s in
                if let n = Double(s.trimmingCharacters(in: .whitespaces)) { set(.number(n)) }
            }))
            .fieldChrome()
            .frame(width: 80)
        } else {
            TextField("text", text: Binding(get: {
                if case .string(let s)? = cond.value { return s }
                return ""
            }, set: { set(.string($0)) }))
            .fieldChrome()
            .frame(width: 180)
        }
    }

    private func picked(_ id: String) -> Bool {
        if case .array(let a)? = cond.value { return a.contains(.string(id)) }
        return false
    }

    private func togglePick(_ id: String) {
        var a: [JSONValue] = []
        if case .array(let cur)? = cond.value { a = cur }
        if let i = a.firstIndex(of: .string(id)) { a.remove(at: i) } else { a.append(.string(id)) }
        set(.array(a))
    }
}
