import XCTest
@testable import MuseCore

/// Contract test for edited versions (plans/api.md "Video editor") against a LOCAL server/api: the presigned upload of the
/// edited file and its thumbnail, POST /v1/takes/{id}/versions with the edit list exactly as the Mac encodes it, the
/// returned take, GET …/versions and the server's refusals. Skipped unless MUSE_API_URL points at a local server.
final class VideoEditApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("VideoEditApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func owner() async throws -> HTTPMuseAPI {
        let api = HTTPMuseAPI(baseURL: base)
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        return api
    }

    private func tempVideo() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muse-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("edit.mp4")
        try Data("edited mp4 bytes from the Mac contract test".utf8).write(to: file)
        return (dir, file)
    }

    /// The server checks the body and the edit list (strict: no unknown keys) before it looks at the take, so a take with
    /// no video answering "Edit works on a video take" proves the Mac's request is accepted as sent. (The local test server's
    /// simulated renders have no video file.)
    func testRequestShapeAndRefusals() async throws {
        let api = try await owner()
        let takes = try await api.listTakes()
        let noVideo = try XCTUnwrap(takes.first { $0.videoUrl == nil }, "a seeded take")
        let (dir, file) = try tempVideo()
        defer { try? FileManager.default.removeItem(at: dir) }
        var edits = EditList(sourceTakeId: noVideo.id, sourceDurationSec: 6, mute: true)
        XCTAssertTrue(edits.split(at: 2, fps: 30))
        edits.setSpeed(0.75, segment: edits.segments[1].id)
        edits.setMuted(true, segment: edits.segments[0].id)
        let video = EditedVideo(file: file, thumbJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0]), durationSec: edits.duration, width: 1440, height: 2560, fps: 29.97)
        let up = try await api.uploadEditedVideo(video, progress: nil)
        XCTAssertFalse(up.uploadId.isEmpty)
        XCTAssertNotNil(up.thumbUploadId)

        func code(_ id: String, _ r: TakeVersionRequest) async -> (String, String)? {
            do { _ = try await api.createTakeVersion(takeId: id, r); return nil } catch let e as ApiError { return (e.code, e.message) } catch { return ("?", "\(error)") }
        }
        let shape = await code(noVideo.id, .make(up, video: video, edits: edits))
        XCTAssertEqual(shape?.0, "bad_request")
        XCTAssertEqual(shape?.1, "Edit works on a video take", "body and edit list passed the server's checks")

        var badLength = TakeVersionRequest.make(up, video: video, edits: edits)
        badLength.durationSec = edits.duration + 3
        let length = await code(noVideo.id, badLength)
        XCTAssertEqual(length?.0, "bad_request")
        XCTAssertTrue(length?.1.hasPrefix("durationSec") ?? false, length?.1 ?? "")

        var bad = edits
        bad.segments[1].speed = 3
        let speed = await code(noVideo.id, .make(up, video: video, edits: bad))
        XCTAssertEqual(speed?.0, "bad_request")

        var plain = video
        plain.durationSec = 6
        let missing = await code("take_nope", .make(up, video: plain, edits: EditList(sourceTakeId: "take_nope", sourceDurationSec: 6)))
        XCTAssertEqual(missing?.0, "not_found")

        let versions = try await api.takeVersions(takeId: noVideo.id)
        XCTAssertTrue(versions.isEmpty)
    }

    /// The whole flow on a take with a video, when the server has one (a real render).
    func testSaveAnEditedVersion() async throws {
        let api = try await owner()
        guard let src = try await api.listTakes().first(where: { $0.kind == "take" && $0.videoUrl != nil }) else {
            throw XCTSkip("no video take on this server")
        }
        let dur = src.durationSec ?? 5
        var edits = EditList(sourceTakeId: src.id, sourceDurationSec: dur)
        XCTAssertTrue(edits.split(at: dur / 2, fps: 30))
        edits.setSpeed(2, segment: edits.segments[1].id)
        edits.setMuted(true, segment: edits.segments[0].id)
        XCTAssertNil(edits.problem)

        let (dir, file) = try tempVideo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = EditedVideo(file: file, thumbJPEG: Data([0xFF, 0xD8, 0xFF, 0xE0]), durationSec: edits.duration + 0.02, width: 768, height: 1344, fps: 30)

        let up = try await api.uploadEditedVideo(video, progress: nil)
        XCTAssertNotNil(up.thumbUploadId)
        let take = try await api.createTakeVersion(takeId: src.id, .make(up, video: video, edits: edits))
        XCTAssertEqual(take.kind, "edit")
        XCTAssertTrue(take.isEdit && take.isVideo)
        XCTAssertEqual(take.parentTakeId, src.id)
        XCTAssertEqual(take.label, "Edited")
        XCTAssertEqual(take.cost, 0)
        XCTAssertEqual(take.status, "test")
        XCTAssertEqual(take.title, src.title)
        XCTAssertEqual(take.width, 768)
        XCTAssertEqual(take.fps, 30)
        XCTAssertEqual(take.edits, edits, "the edit list comes back as sent")
        XCTAssertTrue(take.videoUrl?.hasPrefix("http") ?? false, take.videoUrl ?? "no videoUrl")
        XCTAssertTrue(take.editorStart { $0 == src.id }?.list != nil, "re-opens on its source")

        let versions = try await api.takeVersions(takeId: src.id)
        XCTAssertEqual(versions.first?.id, take.id)
        let all = try await api.listTakes()
        XCTAssertTrue(all.contains { $0.id == src.id }, "the original is kept")

        // The same upload can't make a second version; the edit list must name the take in the URL.
        do {
            _ = try await api.createTakeVersion(takeId: src.id, .make(up, video: video, edits: edits))
            XCTFail("expected upload_used")
        } catch let e as ApiError { XCTAssertEqual(e.code, "upload_used", e.message) }
        let up2 = try await api.uploadEditedVideo(EditedVideo(file: file, thumbJPEG: nil, durationSec: video.durationSec, width: 768, height: 1344, fps: 30), progress: nil)
        var wrong = TakeVersionRequest.make(up2, video: video, edits: edits)
        wrong.edits.sourceTakeId = "take_other"
        do {
            _ = try await api.createTakeVersion(takeId: src.id, wrong)
            XCTFail("expected bad_request")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request", e.message) }
        var badLength = TakeVersionRequest.make(up2, video: video, edits: edits)
        badLength.durationSec = edits.duration + 3
        do {
            _ = try await api.createTakeVersion(takeId: src.id, badLength)
            XCTFail("expected bad_request")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request", e.message) }

        // An edited version can itself be the source (when its own source is gone, apps open it on its own video).
        let again = try await api.createTakeVersion(takeId: take.id, .make(up2, video: EditedVideo(file: file, thumbJPEG: nil, durationSec: 1, width: 768, height: 1344, fps: 30),
                                                                              edits: EditList(sourceTakeId: take.id, sourceDurationSec: edits.duration, segments: [EditSegment(inSec: 0, outSec: 1)])))
        XCTAssertEqual(again.parentTakeId, take.id)
    }
}
