import AppKit
import MuseCore
import Observation
import SwiftUI

/// "Import a video from a link" (owner-approved 2026-11-08): one sheet shared by Swap's source, the Library and Edit's
/// media bin. The link is fetched on this Mac with Recreate's pinned yt-dlp and Strict link rules (DeviceLinkFetcher),
/// uploaded and kept as an imported clip; when the Mac can't fetch it, the server tries. Stop cancels at any point.
@Observable @MainActor
final class LinkImportState {
    var open = false
    var purpose: LinkImportPurpose = .library
    var text = ""
    var fetching = false
    /// "Checking the link…", "Downloading on this Mac… 40%", "Uploading the video… 80%".
    var status: String?
    var progress: Double?
    /// A refusal with Recreate's words (private, too long, not a supported site…); offers a file instead.
    var problem: RecreateLinkProblem?
    /// Anything else, in plain words.
    var error: String?
    var settings: RecreateLinkSettings?
    @ObservationIgnored var task: Task<Void, Never>?
}

extension AppStore {
    var linkImportAPI: (any LinkImportAPI)? { api as? any LinkImportAPI }

    /// Opens the sheet for this purpose, the field filled from the clipboard when it holds a link (⌘V's job, done for you).
    func openLinkImport(_ purpose: LinkImportPurpose, link: String? = nil) {
        let s = linkImport
        guard !s.fetching else { s.open = true; return }
        s.purpose = purpose
        s.problem = nil
        s.error = nil
        s.status = nil
        s.progress = nil
        let clip = NSPasteboard.general.string(forType: .string).flatMap { LinkImport.link($0, strict: false) }
        s.text = link ?? clip ?? ""
        withAnimation(.easeOut(duration: 0.15)) { s.open = true }
        Task { if let v = try? await linkImportAPI?.linkImportSettings() { linkImport.settings = v } }
        if let link, !link.isEmpty { startLinkImport() }
    }

    func closeLinkImport() {
        stopLinkImport()
        withAnimation(.easeOut(duration: 0.15)) { linkImport.open = false }
    }

    /// Stop: the fetch or upload is cancelled; nothing is kept.
    func stopLinkImport() { linkImport.task?.cancel() }

    func startLinkImport() {
        let s = linkImport
        guard !s.fetching else { return }
        let strict = s.settings?.strictLinks ?? true
        guard let link = LinkImport.link(s.text, strict: strict) else {
            s.problem = RecreateLinkProblem(code: "link_unsupported", message: RecreateLinks.message(code: "link_unsupported", message: nil))
            return
        }
        s.problem = nil
        s.error = nil
        s.fetching = true
        s.status = "Checking the link…"
        s.progress = nil
        let task = Task { await runLinkImport(link) }
        s.task = task
        Task {
            await task.value
            s.task = nil
            s.fetching = false
            s.status = nil
            s.progress = nil
        }
    }

    private func runLinkImport(_ raw: String) async {
        guard let api = linkImportAPI else {
            linkImport.error = "This server can't import from links yet. Save the video and choose the file instead."
            return
        }
        let settings = linkImport.settings ?? (try? await api.linkImportSettings()) ?? RecreateLinkSettings()
        var link = raw
        var platform: String?
        // The server's verdict first. A server without the check: this Mac's own strict rules.
        do {
            let c = try await api.checkImportLink(raw)
            if Task.isCancelled { return }
            if let p = c.problem { linkImport.problem = p; return }
            if let u = c.url, !u.isEmpty { link = u }
            platform = c.platform
        } catch {
            if Task.isCancelled { return }
            if let p = RecreateLinkProblem(error) { linkImport.problem = p; return }
        }
        var result: LinkImportResult?
        if api is HTTPMuseAPI {
            linkImport.status = RecreateDeviceFetch.statusLine(fetched: nil)
            let fetched = await DeviceLinkFetcher.shared.fetch(link, platform: platform, settings: settings) { v in
                Task { @MainActor [weak self] in
                    guard let self, self.linkImport.fetching, self.linkImport.task?.isCancelled == false else { return }
                    self.linkImport.progress = v
                    self.linkImport.status = RecreateDeviceFetch.statusLine(fetched: v)
                }
            }
            if Task.isCancelled {
                if case .success(let f) = fetched { try? FileManager.default.removeItem(at: f.file.deletingLastPathComponent()) }
                return
            }
            switch fetched {
            case .failure(.refused(let p)):
                linkImport.problem = p
                return
            case .failure(.unavailable(let why)):
                NSLog("[import] this Mac couldn't fetch it (%@): the server tries", why)
            case .success(let f):
                defer { try? FileManager.default.removeItem(at: f.file.deletingLastPathComponent()) }
                linkImport.status = "Uploading the video…"
                linkImport.progress = 0
                do {
                    result = try await api.importVideo(file: f.file, contentType: RecreateDeviceFetch.contentType(f.file), sourceUrl: raw,
                                                       name: LinkImport.name(title: f.title, platform: platform)) { v in
                        Task { @MainActor [weak self] in
                            guard let self, self.linkImport.fetching else { return }
                            self.linkImport.progress = v
                            self.linkImport.status = "Uploading the video… \(Int((v * 100).rounded()))%"
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    showImportError(error)
                    return
                }
            }
        }
        if result == nil {
            // The server fetches it (demo mode: its instant fake).
            linkImport.status = "Fetching on the MUSE server…"
            linkImport.progress = nil
            do {
                result = try await api.importLink(link, name: LinkImport.name(title: nil, platform: platform))
            } catch {
                if Task.isCancelled { return }
                showImportError(error)
                return
            }
        }
        if Task.isCancelled { return }
        if let result { finishLinkImport(result) }
    }

    private func showImportError(_ error: Error) {
        if let p = RecreateLinkProblem(error) {
            linkImport.problem = p
        } else {
            linkImport.error = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    /// What the import is for: Swap's source (selected), or the Library and Edit's Uploads.
    private func finishLinkImport(_ r: LinkImportResult) {
        let purpose = linkImport.purpose
        withAnimation(.easeOut(duration: 0.15)) { linkImport.open = false }
        linkImport.text = ""
        if let take = r.take, !takes.contains(where: { $0.id == take.id }) { takes.insert(take, at: 0) }
        switch purpose {
        case .swap:
            if let c = r.clip {
                clip = c
                clipFile = nil
                clipThumb = c.thumb
                openTool(.swap)
                showToast("Imported \(c.name). It's the clip to swap into now.")
            } else {
                showToast("Imported. Choose it as the clip in Swap.")
            }
        case .library:
            showToast(r.clip.map { "Imported \($0.name)" } ?? "Imported", action: "Use in Swap") { [weak self] in
                guard let self, let c = r.clip else { return }
                self.clip = c
                self.openTool(.swap)
            }
            Task { await forceReload() }
        case .edit:
            showToast(r.clip.map { "Imported \($0.name). It's in Uploads." } ?? "Imported. It's in Uploads.")
            Task { await forceReload() }
        }
    }

    /// A link dropped or pasted where a clip goes: imported for that purpose.
    func importDroppedLink(_ url: URL, for purpose: LinkImportPurpose) -> Bool {
        guard !url.isFileURL, let s = url.scheme?.lowercased(), s == "https" || s == "http" else { return false }
        openLinkImport(purpose, link: url.absoluteString)
        return true
    }
}
