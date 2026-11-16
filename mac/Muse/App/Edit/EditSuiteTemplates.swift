import Foundation
import MuseCore

// Edit templates on the Mac (plans/edit-templates.md §5, mockups 1, 2 and 4): the library in the media panel's Templates
// tab (caption styles kept as its section), a picked template previewed on the real edit (the server's dry run, nothing
// saved), its settings in the inspector, Apply as one change the edit session sends back, Save as template from the
// selection, and "Ask Claude to make it for this cut" for the pack's templates that aren't ready. Owner only (decision 3):
// templates need the live edit session; members keep the caption styles.

/// What the Templates panel shows and holds.
struct EditTemplatePanel: Equatable {
    enum Load: Equatable { case idle, loading, loaded, failed(String) }
    var load: Load = .idle
    var library = EditTemplateLibrary()
    var filter: EditTemplateLibrary.Filter = .all
    var query = ""
    /// The picked template's id; its settings; what the preview shows it on.
    var picked: String?
    var params: [String: JSONValue] = [:]
    /// The template id the player previews now (nil: not previewing).
    var previewOf: String?
    var previewing = false
    var priceUsd: Double?
    var notes: [String] = []
    var applying = false
    /// The Save as template sheet.
    var saving = false

    func template(_ id: String?) -> EditTemplate? { id.flatMap { i in library.templates.first { $0.id == i } } }
    var pickedTemplate: EditTemplate? { template(picked) }
}

extension EditSuiteSession {
    private static let fakeTemplates = FakeEditTemplateAPI()
    /// A server: the same HTTPMuseAPI as the rest of the app. Demo mode: the fake.
    var templateAPI: any EditTemplateAPI {
        if let http = api as? HTTPMuseAPI { return http }
        return Self.fakeTemplates
    }
    /// Templates apply through the live edit session (the owner's).
    var templatesAvailable: Bool { isOwner }

    private func line(_ error: Error, _ fallback: String) -> String {
        if let e = error as? ApiError, e.code != "offline" { return e.message }
        return fallback
    }

    // MARK: Library

    func loadTemplates(force: Bool = false) async {
        guard templatesAvailable else { return }
        if !force, templates.load == .loaded || templates.load == .loading { return }
        templates.load = .loading
        do {
            templates.library = try await templateAPI.editTemplates()
            templates.load = .loaded
        } catch {
            templates.load = .failed(line(error, "Templates didn't load"))
        }
    }

    /// Picks a tile: its settings at their defaults, then the preview on the real edit.
    func pickTemplate(_ t: EditTemplate) {
        templates.picked = t.id
        templates.params = Dictionary(uniqueKeysWithValues: t.params.compactMap { p in p.defaultValue.map { (p.key, $0) } })
        templates.notes = []
        templates.priceUsd = nil
        Task { await previewTemplate() }
    }

    func closeTemplate() {
        templates.picked = nil
        templates.notes = []
        templates.priceUsd = nil
        templates.previewOf = nil
        setTemplatePreview(nil)
    }

    func setTemplateParam(_ key: String, _ v: JSONValue) {
        templates.params[key] = v
        Task { await previewTemplate() }
    }

    /// Where the picked template goes now (the selection, else the playhead), for the "Applies to" row and the button.
    var templateTarget: (target: EditTemplateTarget, title: String, detail: String)? {
        guard let t = templates.pickedTemplate else { return nil }
        return EditTemplateTarget.current(for: t, project: project, selection: state.selection, playhead: playhead)
    }

    // MARK: Preview and apply

    /// The server's dry run on the live edit, applied to a copy the player shows. Nothing is saved.
    func previewTemplate() async {
        guard let t = templates.pickedTemplate, t.isReady, let sync = live, let target = templateTarget else { setTemplatePreview(nil); return }
        templates.previewing = true
        defer { templates.previewing = false }
        await pushLive() // the dry run works on the server's copy: send this Mac's change first
        let asked = templates.params
        do {
            let r = try await templateAPI.applyEditTemplate(t.id, EditTemplateApplyRequest(sessionId: sync.sessionId, target: target.target, params: asked, dryRun: true, device: device))
            guard templates.picked == t.id, templates.params == asked else { return } // picked again meanwhile
            templates.priceUsd = r.priceUsd
            templates.notes = r.notes
            let shown = try JSONPatch.apply(project, r.patch)
            templates.previewOf = t.id
            setTemplatePreview(shown)
        } catch {
            templates.previewOf = nil
            setTemplatePreview(nil)
            lastError = line(error, "Couldn't preview \(t.name)")
        }
    }

    /// Applies the picked template (to the current target, or `every`) as one change; a paid cut-out asks the owner next.
    func applyTemplate(every: EditTemplateTarget? = nil) async {
        guard let t = templates.pickedTemplate, t.isReady, let sync = live, let target = every ?? templateTarget?.target else { return }
        templates.applying = true
        defer { templates.applying = false }
        await pushLive()
        do {
            // The price is on the button the owner pressed: that press is the confirmation.
            let r = try await templateAPI.applyEditTemplate(t.id, EditTemplateApplyRequest(sessionId: sync.sessionId, target: target, params: templates.params, confirm: t.paid, device: device))
            templates.previewOf = nil
            setTemplatePreview(nil)
            if let u = try await sync.refresh() { await handleLive(u) }
            notice = r.waitingForOwner > 0 ? "Applied \(t.name) · approve the cut-out to finish it" : "Applied \(t.name)"
            templates.notes = r.notes
        } catch {
            lastError = line(error, "Couldn't apply \(t.name)")
        }
        mirrorLive()
    }

    // MARK: Save as template

    /// What Save as template would keep: the selected item (and the cut before it when it's a main clip and `cut`).
    var canSaveTemplate: Bool { templatesAvailable && live != nil && state.selection != nil }

    func saveTemplate(name: String, kind: String, cut: Bool) async -> Bool {
        guard let sync = live, let sel = state.selection else { return false }
        await pushLive()
        var cutAt: Double?
        if cut, let i = project.mainClips.firstIndex(where: { $0.id == sel }), i > 0 {
            let s = EditV2.timeline(project)[i]
            cutAt = s.startSec + s.transitionSec / 2
        }
        do {
            let r = try await templateAPI.saveEditTemplate(EditTemplateSaveRequest(name: name, kind: kind, target: cutAt == nil ? "clip" : "cut", sessionId: sync.sessionId, itemIds: [sel], cutAt: cutAt))
            notice = r.saved
            await loadTemplates(force: true)
            return true
        } catch {
            lastError = line(error, "Couldn't save the template")
            return false
        }
    }

    func deleteTemplate(_ t: EditTemplate) async {
        do {
            try await templateAPI.deleteEditTemplate(t.id)
            if templates.picked == t.id { closeTemplate() }
            templates.library.templates.removeAll { $0.id == t.id }
            notice = "Deleted \(t.name)"
        } catch {
            lastError = line(error, "Couldn't delete \(t.name)")
        }
    }

    // MARK: Not ready: Claude makes it

    /// "Ask Claude to make it for this cut": the Claude panel opens with a request naming the template, the cut and the two
    /// shots. Claude reads the pack's script (template_pack_read), adapts it to these shots and adds the result as an overlay.
    func askClaudeToMake(_ t: EditTemplate) {
        let place: String
        if let tg = EditTemplateTarget.current(for: t, project: project, selection: state.selection, playhead: playhead) {
            place = "\(tg.title.prefix(1).lowercased() + tg.title.dropFirst()) (\(tg.detail.prefix(1).lowercased() + tg.detail.dropFirst()))"
        } else {
            place = "this edit"
        }
        claudeAsk = "Make the \(t.name) template (\(t.id), icon-storyboard pack) for \(place). Read its script with template_pack_read, adapt it to these shots, and add the result as an overlay."
    }
}
