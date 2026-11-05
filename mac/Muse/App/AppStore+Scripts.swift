import MuseCore
import SwiftUI

// Prompt scripts (workstream 4; plans/prompt-scripts.md, plans/api.md "Prompt scripts"): the owner's Settings → Prompts →
// Scripts screens, and the video studio's "Performer is speaking" switch (the only member-facing part).

/// Settings → Prompts: the library's blocks, or the scripts that put them together.
enum PromptsTab: Hashable {
    case blocks, scripts
}

extension AppStore {
    // MARK: "Performer is speaking"

    /// `clip`'s didSet: another clip resets the switch to its detection; a late detection for the same clip sets it unless flipped.
    func clipChangedForSpeaking(from old: Clip?) {
        let other = old?.id != clip?.id
        speaking = PerformerSpeaking.after(old, clip, current: speaking, touched: speakingTouched)
        if other { speakingTouched = false }
    }

    func setSpeaking(_ on: Bool) {
        speaking = on
        speakingTouched = true
    }

    // MARK: Scripts list

    func loadScripts() async {
        guard isOwner else { return }
        do {
            scriptList = try await api.promptScripts()
            scriptListError = nil
            if let id = scriptOpenId, let v = scriptList?.script(id), scriptDraft == scriptDraftBase {
                scriptDraft = v.rules
                scriptDraftBase = v.rules
            }
        } catch let e as ApiError {
            scriptListError = e.code == "not_found" || e.code == "http_404" ? "This server doesn't have prompt scripts yet." : e.friendlyMessage
        } catch {
            scriptListError = error.localizedDescription
        }
    }

    var currentScript: ScriptView? { scriptOpenId.flatMap { scriptList?.script($0) } }
    var scriptDirty: Bool { currentScript.map { $0.rules != scriptDraft } ?? false }
    var scriptOps: [CondOpInfo] { scriptList?.ops ?? CondOpInfo.defaults }

    func openScript(_ id: String) {
        guard let v = scriptList?.script(id) else { return }
        scriptOpenId = id
        scriptDraft = v.rules
        scriptDraftBase = v.rules
        scriptInputs = v.sampleInputs
        scriptPreview = nil
        scriptError = nil
        scriptEditingRule = nil
    }

    func closeScript() {
        scriptOpenId = nil
        scriptPreview = nil
        scriptError = nil
        scriptEditingRule = nil
    }

    /// A block's name in sentences and menus: the library entry's title (its key until the library is loaded).
    func blockTitle(_ key: String) -> String { ScriptText.blockTitle(key, library: promptLibrary) }

    // MARK: Editing the draft

    func setRuleOn(_ id: String, _ on: Bool) {
        guard let i = scriptDraft.firstIndex(where: { $0.id == id }), !scriptDraft[i].isLocked else { return }
        scriptDraft[i].isOn = on
        scriptError = nil
    }

    func editRule(_ id: String) {
        scriptEditingRule = scriptDraft.first { $0.id == id }
    }

    func addRule() {
        guard let s = currentScript else { return }
        scriptEditingRule = s.newRule(existing: scriptDraft)
    }

    /// The sheet's Done: replace the rule, or add a new one after the last rule of its place.
    func commitRule(_ r: ScriptRule) {
        if let i = scriptDraft.firstIndex(where: { $0.id == r.id }) {
            if scriptDraft[i].target != r.target {
                scriptDraft.remove(at: i)
                insertRule(r)
            } else {
                scriptDraft[i] = r
            }
        } else {
            insertRule(r)
        }
        scriptEditingRule = nil
        scriptError = nil
    }

    private func insertRule(_ r: ScriptRule) {
        if let last = scriptDraft.lastIndex(where: { $0.target == r.target }) { scriptDraft.insert(r, at: last + 1) } else { scriptDraft.append(r) }
    }

    func deleteRule(_ id: String) {
        guard let s = currentScript, let r = scriptDraft.first(where: { $0.id == id }), s.isAdded(r) else { return }
        scriptDraft.removeAll { $0.id == id }
        if scriptEditingRule?.id == id { scriptEditingRule = nil }
        scriptError = nil
    }

    func moveRule(_ id: String, up: Bool) {
        ScriptText.move(&scriptDraft, id: id, up: up)
        scriptError = nil
    }

    func undoScriptChanges() {
        scriptDraft = scriptDraftBase
        scriptError = nil
    }

    // MARK: Save, reset, preview

    func saveScript() {
        guard let id = scriptOpenId, !scriptSaving else { return }
        scriptSaving = true
        let rules = scriptDraft
        Task { [weak self] in
            guard let self else { return }
            defer { self.scriptSaving = false }
            do {
                let v = try await self.api.savePromptScript(id: id, rules: rules)
                self.scriptList?.apply(v)
                if self.scriptOpenId == id {
                    self.scriptDraft = v.rules
                    self.scriptDraftBase = v.rules
                }
                self.scriptError = nil
                self.promptsVersion += 1
                self.showToast(v.overridden ? "Saved · used for every new prompt" : "Saved · back on the default rules")
            } catch let e as ApiError where e.code == "script_invalid" {
                self.scriptError = e.message
            } catch let e as ApiError {
                self.handle(e)
            } catch {
                self.showToast(error.localizedDescription)
            }
        }
    }

    func resetScript() {
        guard let id = scriptOpenId else { return }
        perform { [self] in
            let v = try await api.resetPromptScript(id: id)
            scriptList?.apply(v)
            if scriptOpenId == id {
                scriptDraft = v.rules
                scriptDraftBase = v.rules
            }
            scriptError = nil
            promptsVersion += 1
            showToast("Back on the default rules")
        }
    }

    /// What the preview depends on, for the view's debounce (`.task(id:)`).
    var scriptPreviewKey: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let rules = (try? enc.encode(scriptDraft)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let inputs = (try? enc.encode(scriptInputs)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(scriptOpenId ?? "")|\(rules)|\(inputs)"
    }

    /// The live preview (debounced by the view): POST /v1/prompt-scripts/preview with the edited inputs and the unsaved rules.
    func refreshScriptPreview() async {
        guard let id = scriptOpenId else { return }
        let key = scriptPreviewKey
        let req = ScriptPreviewRequest(id: id, inputs: scriptInputs, rules: scriptDirty ? scriptDraft : nil)
        do {
            let p = try await api.previewPromptScript(req)
            guard !Task.isCancelled, scriptPreviewKey == key else { return }
            scriptPreview = p
            if scriptError != nil && scriptDirty { scriptError = nil }
        } catch let e as ApiError where e.code == "script_invalid" {
            guard !Task.isCancelled, scriptOpenId == id else { return }
            scriptError = e.message
        } catch {}
    }

    /// A `promptScript` event: another device saved or reset a script. An open screen with no unsaved edits follows it.
    func promptScriptChanged(_ v: ScriptView) {
        promptsVersion += 1
        guard scriptOpenId == v.id else { return }
        if scriptDraft == scriptDraftBase { scriptDraft = v.rules }
        scriptDraftBase = v.rules
    }

    /// Signing out or switching servers.
    func resetPromptScripts() {
        scriptList = nil
        scriptListError = nil
        closeScript()
        promptsTab = .blocks
    }
}
