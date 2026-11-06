import AppKit
import MuseCore
import SwiftUI

/// Photo templates (plans/templates.md): the library, the detail, using one as a Photo preset, and the template editor.
/// Layers and variation pools are only ever shown for templates the signed-in user owns; the server never sends them otherwise.
extension AppStore {
    // MARK: Library

    func loadTemplates() async {
        do {
            templates = try await api.listTemplates(TemplateQuery())
            listFreshness.mark("templates")
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            templates = [] // a server without templates yet (server/mock)
        } catch {
            return // offline: keep what we have
        }
        // A template that's gone (deleted, made private, another account) can't be a Photo preset any more.
        if let id = suite.photo.presetId, !templates.contains(where: { $0.id == id }) { suite.photo.presetId = nil }
    }

    func openTemplates() {
        go(.templates)
        Task { await loadTemplatesIfStale() }
    }

    /// The library appeared: refetch only when the list (kept current by `template` events) is over a minute old.
    func loadTemplatesIfStale() async {
        guard !listFreshness.isFresh("templates", maxAge: Self.listMaxAge) else { return }
        await loadTemplates()
    }

    /// The library's current tab, search and tag chip, applied locally (the same filter the server applies).
    var templateList: [MuseTemplate] { TemplateQuery(scope: templateScope, q: templateQuery, tag: templateTag).apply(templates) }
    var templateTags: [String] { TemplateEngine.allTags(templates) }

    func isMine(_ t: MuseTemplate) -> Bool { t.isOwner }

    /// "You" for my own templates, else the owner's name.
    func ownerLabel(_ t: MuseTemplate) -> String { t.isOwner ? "You" : (t.ownerName.isEmpty ? "Studio" : t.ownerName) }

    private func replaceTemplate(_ t: MuseTemplate) {
        if let i = templates.firstIndex(where: { $0.id == t.id }) { templates[i] = t } else { templates.insert(t, at: 0) }
        if templateDetail?.id == t.id {
            var d = t
            if d.recent == nil { d.recent = templateDetail?.recent }
            templateDetail = d
        }
    }

    // MARK: Detail

    func openTemplate(_ t: MuseTemplate) {
        openTemplateId = t.id
        templateDetail = t
        go(.template)
        perform { [self] in
            let d = try await api.template(id: t.id)
            if openTemplateId == d.id { templateDetail = d }
            replaceTemplate(d)
        }
    }

    func toggleFavourite(_ t: MuseTemplate) {
        let on = !t.favourite
        var optimistic = t
        optimistic.favourite = on
        replaceTemplate(optimistic)
        perform { [self] in
            do {
                replaceTemplate(try await api.setTemplateFavourite(id: t.id, on))
            } catch {
                replaceTemplate(t)
                throw error
            }
        }
    }

    func setVisibility(_ t: MuseTemplate, _ v: TemplateVisibility) {
        guard t.isOwner, t.visibility != v.rawValue else { return }
        perform { [self] in
            replaceTemplate(try await api.updateTemplate(id: t.id, TemplatePatch(visibility: v.rawValue)))
            showToast(v == .public ? "\(t.name) is public: everyone in the studio can use it" : "\(t.name) is private: only you can see it")
        }
    }

    func duplicateTemplate(_ t: MuseTemplate) {
        guard t.isOwner else { return }
        perform { [self] in
            let copy = try await api.duplicateTemplate(id: t.id)
            replaceTemplate(copy)
            showToast("Duplicated as \(copy.name)", action: "Open") { [weak self] in self?.openTemplate(copy) }
        }
    }

    func deleteTemplate(_ t: MuseTemplate) {
        guard t.isOwner else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(t.name)?"
        alert.informativeText = "Photos made with it stay in the Library. \(t.isPublic ? "No one in the studio will be able to use it any more." : "")"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { [self] in
            try await api.deleteTemplate(id: t.id)
            templates.removeAll { $0.id == t.id }
            if suite.photo.presetId == t.id { suite.photo.presetId = nil }
            if screen == .template { go(.templates) }
            showToast("Template deleted")
        }
    }

    // MARK: Using a template

    /// Use: the AI suite's Photo tool with this template as its preset (Photoshoot is now the Photo tool, workstream 3).
    func useTemplate(_ t: MuseTemplate) {
        openPhoto(preset: t.id)
    }

    // MARK: Creating and editing

    /// Save as template on a photo: the server's draft (exact layers, suggested pool, cover), editable before saving.
    func saveAsTemplate(_ take: Take) {
        perform { [self] in
            let d = try await api.templateDraft(fromShotId: take.id)
            withAnimation { templateForm = .from(draft: d) }
        }
    }

    /// Someone else's template made this photo, so its look can't be saved (the server answers template_hidden).
    func canSaveAsTemplate(_ take: Take) -> Bool {
        guard !take.isVideo else { return false }
        guard let tid = take.templateId else { return true }
        return templates.first { $0.id == tid }?.isOwner ?? false
    }

    /// From scratch (pro): the layer editor with an empty template.
    func newTemplate() {
        guard pro else {
            showToast("Turn on pro mode to build a template from scratch, or use Save as template on any photo", action: "Pro mode") { [weak self] in
                self?.pro = true
                self?.newTemplate()
            }
            return
        }
        var f = TemplateForm(name: "")
        f.suggestPool()
        withAnimation { templateForm = f }
    }

    func editTemplate(_ t: MuseTemplate) {
        guard t.isOwner else { return }
        withAnimation { templateForm = .edit(t) }
    }

    func closeTemplateForm() {
        withAnimation { templateForm = nil }
    }

    func saveTemplateForm() {
        guard let f = templateForm, f.canSave, !templateFormBusy else { return }
        templateFormBusy = true
        perform { [self] in
            defer { templateFormBusy = false }
            let t: MuseTemplate
            if let id = f.templateId {
                t = try await api.updateTemplate(id: id, f.patch)
                showToast("Template saved")
            } else {
                t = try await api.createTemplate(f.createRequest)
                showToast("Saved as template · \(t.isPublic ? "public" : "private")", action: "Open") { [weak self] in self?.openTemplate(t) }
            }
            replaceTemplate(t)
            withAnimation { templateForm = nil }
        }
    }
}
