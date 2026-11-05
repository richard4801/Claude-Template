import Foundation

/// A presigned upload in demo mode: the edited video's file, or a thumbnail.
public enum FakeEditUpload: Sendable {
    case video(URL)
    case image(URL)
}

// Video editor in demo mode (plans/api.md "Video editor: edited versions of a take"): the same rules as the server.
extension FakeMuseAPI {
    public func uploadEditedVideo(_ video: EditedVideo, progress: UploadProgress?) throws -> EditedUpload {
        progress?(0)
        let id = "up_" + shortId()
        editUploads[id] = .video(try keep(video.file, name: "edit_\(id).mp4"))
        var thumbId: String?
        if let jpeg = video.thumbJPEG {
            let tid = "up_" + shortId()
            let f = try scratch("thumb_\(tid).jpg")
            try jpeg.write(to: f)
            editUploads[tid] = .image(f)
            thumbId = tid
        }
        progress?(1)
        return EditedUpload(uploadId: id, thumbUploadId: thumbId)
    }

    public func createTakeVersion(takeId: String, _ req: TakeVersionRequest) throws -> Take {
        guard let src = takes.first(where: { $0.id == takeId }) else { throw ApiError("not_found", "Take not found") }
        guard src.isVideo else { throw ApiError("bad_request", "Edit works on a video take") }
        if let p = FakeMuseAPI.versionProblem(takeId: takeId, req) { throw ApiError("bad_request", p) }
        if usedUploads.contains(req.uploadId) { throw ApiError("upload_used", "This upload is already saved") }
        guard case .video(let file)? = editUploads[req.uploadId] else { throw ApiError("upload_missing", "The upload hasn't arrived") }
        var thumb = src.thumb
        if let tid = req.thumbUploadId {
            guard case .image(let f)? = editUploads[tid] else { throw ApiError("bad_request", "thumbUploadId: not an image upload") }
            thumb = ImageRef(url: f.absoluteString)
        } else if let t = req.thumb {
            thumb = t
        }
        var t = Take(id: "tk_" + shortId(), kind: "edit", jobId: src.jobId, title: src.title, label: "Edited", engineLabel: src.engineLabel,
                     cost: 0, seed: src.seed, status: "test", thumb: thumb, prompt: src.prompt, createdAt: nowMs())
        t.videoUrl = file.absoluteString
        t.durationSec = req.durationSec
        t.width = req.width
        t.height = req.height
        t.fps = req.fps
        t.parentTakeId = takeId
        t.edits = req.edits
        t.templateId = src.templateId
        t.templateName = src.templateName
        usedUploads.insert(req.uploadId)
        editUploads[req.uploadId] = nil
        takes.insert(t, at: 0)
        hub.emit(ApiEvent(type: "take", take: t))
        return t
    }

    public func takeVersions(takeId: String) throws -> [Take] {
        guard takes.contains(where: { $0.id == takeId }) else { throw ApiError("not_found", "Take not found") }
        return takes.filter { $0.parentTakeId == takeId }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The server's `bad_request` rules for POST /v1/takes/{id}/versions, with the field named.
    static func versionProblem(takeId: String, _ req: TakeVersionRequest) -> String? {
        let e = req.edits
        if e.sourceTakeId != takeId { return "edits.sourceTakeId: must be the take in the URL" }
        if let p = e.problem { return "edits: " + p }
        if !e.accepts(durationSec: req.durationSec) { return "durationSec: doesn't match the edit list" }
        if !(16...4096).contains(req.width) || !(16...4096).contains(req.height) { return "width/height: 16–4096" }
        if let f = req.fps, !(1...240).contains(f) { return "fps: 1–240" }
        return nil
    }

    private func scratch(_ name: String) throws -> URL {
        let dir = storeDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Copies the exported file somewhere it stays (the editor's own file is temporary).
    private func keep(_ file: URL, name: String) throws -> URL {
        let dst = try scratch(name)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: file, to: dst) } catch { throw ApiError("upload_failed", "Couldn't save the edit") }
        return dst
    }
}
