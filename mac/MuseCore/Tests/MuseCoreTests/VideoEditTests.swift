import XCTest
@testable import MuseCore

/// The video editor's edit list (plans/video-editor.md): duration math, split / delete / trim / speed / mute, undo / redo,
/// the server's rules, the wire format, and the demo backend's edited versions.
final class VideoEditTests: XCTestCase {
    private func list(_ dur: Double = 10) -> EditList { EditList(sourceTakeId: "tk1", sourceDurationSec: dur) }
    private func seg(_ a: Double, _ b: Double, _ s: Double = 1, muted: Bool = false) -> EditSegment { EditSegment(inSec: a, outSec: b, speed: s, muted: muted) }

    // MARK: Duration math

    func testContractExamples() {
        // A plain trim, cutting out 3–4 s, and a slow-motion middle (2 + 4 + 6 = 12 s).
        XCTAssertEqual(EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0.5, 9.8)]).duration, 9.3, accuracy: 1e-9)
        XCTAssertEqual(EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0, 3), seg(4, 10)]).duration, 9, accuracy: 1e-9)
        let slow = EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0, 2), seg(2, 4, 0.5), seg(4, 10)])
        XCTAssertEqual(slow.duration, 12, accuracy: 1e-9)
        XCTAssertEqual(slow.outputStarts, [0, 2, 6])
    }

    func testEverySpeed() {
        for (s, d) in [(0.5, 8.0), (0.75, 16.0 / 3), (1, 4), (1.25, 3.2), (1.5, 8.0 / 3), (2, 2)] {
            XCTAssertEqual(seg(1, 5, s).outputLength, d, accuracy: 1e-9, "\(s)×")
        }
    }

    func testTimeMapping() {
        let l = EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0, 2), seg(2, 4, 0.5), seg(6, 10, 2)])
        // 0–2 plays 0–2; 2–6 plays 2–4 slowly; 6–8 plays 6–10 fast.
        XCTAssertEqual(l.duration, 8, accuracy: 1e-9)
        XCTAssertEqual(l.segmentIndex(at: 0), 0)
        XCTAssertEqual(l.segmentIndex(at: 2), 1)
        XCTAssertEqual(l.segmentIndex(at: 7), 2)
        XCTAssertEqual(l.segmentIndex(at: 99), 2)
        XCTAssertEqual(l.sourceTime(at: 1)!, 1, accuracy: 1e-9)
        XCTAssertEqual(l.sourceTime(at: 4)!, 3, accuracy: 1e-9)
        XCTAssertEqual(l.sourceTime(at: 7)!, 8, accuracy: 1e-9)
        XCTAssertEqual(l.outputTime(segment: 1, source: 3), 4, accuracy: 1e-9)
        XCTAssertEqual(l.outputTime(segment: 2, source: 8), 7, accuracy: 1e-9)
        XCTAssertEqual(l.trimIn, 0)
        XCTAssertEqual(l.trimOut, 10)
        XCTAssertNil(EditList(sourceTakeId: "t", sourceDurationSec: 1, segments: []).segmentIndex(at: 0))
    }

    func testUneditedAndSilence() {
        var l = list()
        XCTAssertTrue(l.isUnedited)
        l.setMuted(true)
        XCTAssertFalse(l.isUnedited)
        XCTAssertTrue(l.isSilent(0))
        l.setMuted(false)
        l.split(at: 5)
        XCTAssertFalse(l.isUnedited)
        l.setMuted(true, segment: l.segments[1].id)
        XCTAssertFalse(l.isSilent(0))
        XCTAssertTrue(l.isSilent(1))
    }

    // MARK: Operations

    func testSplitKeepsSpeedAndMuteAndRefusesNearEdges() {
        var l = EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0, 10, 2, muted: true)])
        XCTAssertFalse(l.split(at: 0.04), "0.08 s of source from the edge")
        XCTAssertFalse(l.split(at: 4.97))
        XCTAssertTrue(l.split(at: 2))
        XCTAssertEqual(l.segments.count, 2)
        XCTAssertEqual(l.segments[0].outSec, 4, accuracy: 1e-9)
        XCTAssertEqual(l.segments[1].inSec, 4, accuracy: 1e-9)
        XCTAssertEqual(l.segments.map(\.speed), [2, 2])
        XCTAssertEqual(l.segments.map(\.muted), [true, true])
        XCTAssertNotEqual(l.segments[0].id, l.segments[1].id)
        XCTAssertEqual(l.duration, 5, accuracy: 1e-9, "a split doesn't change the length")
    }

    func testSplitSnapsToFrames() {
        var l = list()
        XCTAssertTrue(l.split(at: 3.3333, fps: 30))
        XCTAssertEqual(l.segments[0].outSec, 100.0 / 30, accuracy: 1e-9)
    }

    func testSplitStopsAtFiftySegments() {
        var l = EditList(sourceTakeId: "t", sourceDurationSec: 100)
        for i in 1..<EditList.maxSegments { XCTAssertTrue(l.split(at: Double(i))) }
        XCTAssertEqual(l.segments.count, 50)
        XCTAssertFalse(l.split(at: 99.5))
        XCTAssertNil(l.problem)
    }

    func testDeleteCutsOutAMiddlePartButNotTheLast() {
        var l = list()
        l.split(at: 3)
        l.split(at: 4)
        XCTAssertEqual(l.segments.count, 3)
        XCTAssertTrue(l.delete(l.segments[1].id))
        XCTAssertEqual(l.segments.map(\.inSec), [0, 4])
        XCTAssertEqual(l.duration, 9, accuracy: 1e-9)
        XCTAssertTrue(l.delete(l.segments[0].id))
        XCTAssertFalse(l.delete(l.segments[0].id), "the last segment stays")
        XCTAssertFalse(l.delete("nope"))
    }

    func testTrimClampsToSourceNeighboursAndMinimum() {
        var l = list()
        let id = l.segments[0].id
        XCTAssertFalse(l.trimIn(id, to: -1), "already at 0")
        XCTAssertTrue(l.trimIn(id, to: 1))
        XCTAssertTrue(l.trimIn(id, to: -3))
        XCTAssertEqual(l.segments[0].inSec, 0)
        XCTAssertTrue(l.trimIn(id, to: 0.5))
        XCTAssertTrue(l.trimOut(id, to: 9.8))
        XCTAssertEqual(l.duration, 9.3, accuracy: 1e-9)
        XCTAssertTrue(l.trimOut(id, to: 50))
        XCTAssertEqual(l.trimOut, 10)
        XCTAssertTrue(l.trimIn(id, to: 9.99))
        XCTAssertEqual(l.segments[0].inSec, 9.9, accuracy: 1e-9, "keeps 0.1 s")

        // Neighbours: a segment can't grow over the one before or after it.
        var m = list()
        m.split(at: 5)
        m.delete(m.segments[1].id)
        m.segments.append(seg(6, 10))
        XCTAssertNil(m.problem)
        XCTAssertTrue(m.trimOut(m.segments[0].id, to: 8))
        XCTAssertEqual(m.segments[0].outSec, 6, accuracy: 1e-9)
        XCTAssertTrue(m.trimIn(m.segments[1].id, to: 7))
        XCTAssertTrue(m.trimIn(m.segments[1].id, to: 2))
        XCTAssertEqual(m.segments[1].inSec, 6, accuracy: 1e-9)
        XCTAssertNil(m.problem)
    }

    func testTrimSnapsToFrames() {
        var l = list()
        XCTAssertTrue(l.trimIn(l.segments[0].id, to: 0.51, fps: 24))
        XCTAssertEqual(l.segments[0].inSec, 12.0 / 24, accuracy: 1e-9)
    }

    func testSpeedForOneOrAll() {
        var l = list()
        l.split(at: 5)
        XCTAssertTrue(l.setSpeed(2, segment: l.segments[1].id))
        XCTAssertEqual(l.segments.map(\.speed), [1, 2])
        XCTAssertEqual(l.duration, 7.5, accuracy: 1e-9)
        XCTAssertFalse(l.setSpeed(3), "only the six speeds")
        XCTAssertFalse(l.setSpeed(2, segment: l.segments[1].id), "no change")
        XCTAssertTrue(l.setSpeed(0.5))
        XCTAssertEqual(l.segments.map(\.speed), [0.5, 0.5])
        XCTAssertEqual(l.duration, 20, accuracy: 1e-9)
    }

    // MARK: History

    func testUndoRedoReset() {
        var h = EditHistory(list())
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.apply { $0.split(at: 4) })
        XCTAssertFalse(h.apply { $0.split(at: 4) }, "same place again: nothing to record")
        let id = h.current.segments[0].id
        XCTAssertTrue(h.apply { $0.delete(id) })
        XCTAssertEqual(h.current.duration, 6, accuracy: 1e-9)
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.current.segments.count, 2)
        XCTAssertTrue(h.redo())
        XCTAssertEqual(h.current.segments.count, 1)
        XCTAssertFalse(h.redo())
        XCTAssertTrue(h.reset())
        XCTAssertTrue(h.current.isUnedited)
        XCTAssertTrue(h.undo(), "Reset can be undone")
        XCTAssertEqual(h.current.duration, 6, accuracy: 1e-9)
        h.apply { $0.setMuted(true) }
        XCTAssertFalse(h.canRedo, "a new change clears redo")
    }

    func testDragIsOneUndoStep() {
        var h = EditHistory(list())
        let id = h.current.segments[0].id
        h.begin()
        for v in [0.2, 0.4, 0.6] {
            var l = h.current
            l.trimIn(id, to: v)
            h.update(l)
        }
        h.end()
        XCTAssertEqual(h.undoCount, 1)
        h.undo()
        XCTAssertTrue(h.current.isUnedited)
        // A drag that ends where it started leaves no step.
        h.begin()
        h.end()
        XCTAssertEqual(h.undoCount, 0)
    }

    func testHistoryKeepsAHundredSteps() {
        var h = EditHistory(EditList(sourceTakeId: "t", sourceDurationSec: 1000))
        for i in 0..<130 { h.apply { $0.setMuted(i % 2 == 0) } }
        XCTAssertEqual(h.undoCount, EditHistory.maxSteps)
    }

    // MARK: Rules

    func testProblems() {
        XCTAssertNil(list().problem)
        var l = list()
        l.segments = []
        XCTAssertNotNil(l.problem)
        l = EditList(sourceTakeId: "t", sourceDurationSec: 10, segments: [seg(0, 10.04)])
        XCTAssertNil(l.problem, "0.05 s of slack past the end")
        l.segments = [seg(0, 10.2)]
        XCTAssertNotNil(l.problem)
        l.segments = [seg(0, 5), seg(4, 8)]
        XCTAssertNotNil(l.problem, "overlap")
        l.segments = [seg(5, 8), seg(0, 4)]
        XCTAssertNotNil(l.problem, "not in source order")
        l.segments = [seg(0, 0.05)]
        XCTAssertNotNil(l.problem, "under 0.1 s")
        l.segments = [seg(0, 0.4)]
        XCTAssertNotNil(l.problem, "output under 0.5 s")
        l.segments = [seg(0, 5, 3)]
        XCTAssertNotNil(l.problem, "speed")
        l = EditList(sourceTakeId: "t", sourceDurationSec: 700)
        l.setSpeed(0.5)
        XCTAssertNotNil(l.problem, "over 600 s")
        l.version = 2
        XCTAssertNotNil(EditList(sourceTakeId: "t", sourceDurationSec: 5, segments: nil).with { $0.version = 2 }.problem)
    }

    func testExportedLengthTolerance() {
        let short = EditList(sourceTakeId: "t", sourceDurationSec: 4)
        XCTAssertTrue(short.accepts(durationSec: 4.49))
        XCTAssertFalse(short.accepts(durationSec: 4.6))
        let long = EditList(sourceTakeId: "t", sourceDurationSec: 100)
        XCTAssertTrue(long.accepts(durationSec: 104.9), "5 %")
        XCTAssertFalse(long.accepts(durationSec: 106))
    }

    func testFittedToTheRealLength() {
        let l = EditList(sourceTakeId: "t", sourceDurationSec: 6, segments: [seg(0, 2), seg(3, 6, 1.5)], mute: true)
        let f = l.fitted(to: 5.9)
        XCTAssertEqual(f.sourceDurationSec, 5.9)
        XCTAssertEqual(f.segments.last?.outSec, 5.9)
        XCTAssertTrue(f.mute)
        XCTAssertNil(f.problem)
        let gone = l.fitted(to: 1, sourceTakeId: "other")
        XCTAssertEqual(gone.segments.count, 1)
        XCTAssertEqual(gone.segments[0].outSec, 1)
        XCTAssertEqual(gone.sourceTakeId, "other")
    }

    func testLabels() {
        XCTAssertEqual(EditList.clock(3.4), "0:03.40")
        XCTAssertEqual(EditList.clock(68.256), "1:08.26")
        XCTAssertEqual(EditList.clock(-1), "0:00.00")
        XCTAssertEqual(EditList.speeds.map(EditList.speedLabel), ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"])
    }

    // MARK: Wire format

    func testEditListJSON() throws {
        var l = EditList(sourceTakeId: "tk_9", sourceDurationSec: 10, segments: [seg(0, 2), seg(2, 4, 0.5, muted: true)])
        l.mute = false
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as! [String: Any]
        XCTAssertEqual(o["version"] as? Int, 1)
        XCTAssertEqual(o["sourceTakeId"] as? String, "tk_9")
        XCTAssertEqual(o["sourceDurationSec"] as? Double, 10)
        XCTAssertEqual(o["mute"] as? Bool, false)
        let segs = o["segments"] as! [[String: Any]]
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(Set(segs[0].keys), ["inSec", "outSec", "speed"], "no local id, muted only when on")
        XCTAssertEqual(segs[1]["speed"] as? Double, 0.5)
        XCTAssertEqual(segs[1]["muted"] as? Bool, true)
        XCTAssertLessThan(try JSONEncoder().encode(l).count, EditList.maxJSONBytes)
    }

    func testVersionRequestJSON() throws {
        let edits = EditList(sourceTakeId: "tk1", sourceDurationSec: 10, segments: [seg(0.5, 9.8)])
        let video = EditedVideo(file: URL(fileURLWithPath: "/tmp/x.mp4"), thumbJPEG: nil, durationSec: 9.30012, width: 1440, height: 2560, fps: 29.97)
        let req = TakeVersionRequest.make(EditedUpload(uploadId: "up_1", thumbUploadId: "up_2"), video: video, edits: edits)
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(o["uploadId"] as? String, "up_1")
        XCTAssertEqual(o["thumbUploadId"] as? String, "up_2")
        XCTAssertNil(o["thumb"])
        XCTAssertEqual(o["durationSec"] as? Double, 9.3)
        XCTAssertEqual(o["width"] as? Int, 1440)
        XCTAssertEqual(o["height"] as? Int, 2560)
        XCTAssertEqual(o["fps"] as? Double, 29.97)
        XCTAssertEqual((o["edits"] as? [String: Any])?["sourceTakeId"] as? String, "tk1")
    }

    func testEditTakeDecodes() throws {
        let json = """
        {"id":"tk_e","kind":"edit","jobId":null,"index":1,"of":1,"title":"Living-room dance","label":"Edited","engineLabel":"HD · 2K",
         "cost":0,"seed":7,"status":"test","thumb":{"url":"/files/t.jpg"},"prompt":"p","createdAt":5,
         "videoUrl":"https://x/e.mp4","durationSec":9.3,"width":1440,"height":2560,"fps":30,"parentTakeId":"tk1",
         "edits":{"version":1,"sourceTakeId":"tk1","sourceDurationSec":10,"segments":[{"inSec":0.5,"outSec":9.8,"speed":1}],"mute":true}}
        """
        let t = try JSONDecoder().decode(Take.self, from: Data(json.utf8))
        XCTAssertTrue(t.isEdit)
        XCTAssertTrue(t.isVideo)
        XCTAssertFalse(t.canUpscale, "Upscale is for renders")
        XCTAssertEqual(t.parentTakeId, "tk1")
        XCTAssertEqual(t.fps, 30)
        XCTAssertEqual(t.edits?.segments.first?.inSec, 0.5)
        XCTAssertEqual(t.edits?.segments.first?.muted, false)
        XCTAssertEqual(t.edits?.mute, true)
        XCTAssertEqual(t.caption, "Living-room dance · Edited")
        // Re-opens on its source while that exists, else on its own video.
        XCTAssertEqual(t.editorStart { $0 == "tk1" }?.sourceTakeId, "tk1")
        XCTAssertNotNil(t.editorStart { $0 == "tk1" }?.list)
        XCTAssertEqual(t.editorStart { _ in false }?.sourceTakeId, "tk_e")
        XCTAssertNil(t.editorStart { _ in false }?.list)

        // Older takes without the new fields still decode; photos have no editor.
        let old = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"a","kind":"take","videoUrl":"https://x/a.mp4"}"#.utf8))
        XCTAssertNil(old.parentTakeId)
        XCTAssertNil(old.edits)
        XCTAssertEqual(old.editorStart { _ in true }?.sourceTakeId, "a")
        let shot = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"b","kind":"shot"}"#.utf8))
        XCTAssertNil(shot.editorStart { _ in true })
    }

    // MARK: Requests (HTTP)

    func testVersionPaths() {
        let api = HTTPMuseAPI(baseURL: URL(string: "https://muse.example/")!)
        XCTAssertEqual(api.request("POST", "v1/takes/\(HTTPMuseAPI.pathKey("tk 1"))/versions", body: Data("{}".utf8)).url?.absoluteString,
                       "https://muse.example/v1/takes/tk%201/versions")
        let r = api.request("GET", "v1/takes/tk1/versions")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.path, "/v1/takes/tk1/versions")
    }

    // MARK: Demo backend

    private func demoVideo(_ dir: URL) throws -> URL {
        let f = dir.appendingPathComponent("edit.mp4")
        try Data("not really a video".utf8).write(to: f)
        return f
    }

    func testDemoBackendSavesAVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muse-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let api = FakeMuseAPI(speed: 0, storeDir: dir)
        let src = try await api.listTakes().first { $0.isVideo }!
        let edits = EditList(sourceTakeId: src.id, sourceDurationSec: 6, segments: [seg(0.5, 3), seg(4, 6, 2)])
        let video = EditedVideo(file: try demoVideo(dir), thumbJPEG: Data([0xFF, 0xD8, 0xFF]), durationSec: edits.duration, width: 1440, height: 2560, fps: 30)
        let up = try await api.uploadEditedVideo(video, progress: nil)
        XCTAssertNotNil(up.thumbUploadId)
        let events = api.events()
        let take = try await api.createTakeVersion(takeId: src.id, .make(up, video: video, edits: edits))
        XCTAssertEqual(take.kind, "edit")
        XCTAssertEqual(take.label, "Edited")
        XCTAssertEqual(take.cost, 0)
        XCTAssertEqual(take.status, "test")
        XCTAssertEqual(take.parentTakeId, src.id)
        XCTAssertEqual(take.title, src.title)
        XCTAssertEqual(take.edits, edits)
        XCTAssertEqual(take.width, 1440)
        XCTAssertNotNil(take.videoUrl)
        XCTAssertNotEqual(take.thumb, src.thumb)
        let versions = try await api.takeVersions(takeId: src.id)
        XCTAssertEqual(versions.map(\.id), [take.id])
        let all = try await api.listTakes()
        XCTAssertTrue(all.contains { $0.id == src.id }, "the original is kept")
        var it = events.makeAsyncIterator()
        let e = await it.next()
        XCTAssertEqual(e?.type, "take")
        XCTAssertEqual(e?.take?.id, take.id)

        // The same upload can't be saved twice.
        do {
            _ = try await api.createTakeVersion(takeId: src.id, .make(up, video: video, edits: edits))
            XCTFail("upload_used")
        } catch let e as ApiError { XCTAssertEqual(e.code, "upload_used") }
    }

    func testDemoBackendRejectsWhatTheServerRejects() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muse-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let api = FakeMuseAPI(speed: 0, storeDir: dir)
        let takes = try await api.listTakes()
        let src = takes.first { $0.isVideo }!
        let edits = EditList(sourceTakeId: src.id, sourceDurationSec: 6)
        let video = EditedVideo(file: try demoVideo(dir), thumbJPEG: nil, durationSec: 6, width: 768, height: 1344, fps: 30)
        let up = try await api.uploadEditedVideo(video, progress: nil)

        func code(_ takeId: String, _ r: TakeVersionRequest) async -> String? {
            do { _ = try await api.createTakeVersion(takeId: takeId, r); return nil } catch let e as ApiError { return e.code } catch { return "?" }
        }
        var wrongSource = TakeVersionRequest.make(up, video: video, edits: edits)
        wrongSource.edits.sourceTakeId = "other"
        let c1 = await code(src.id, wrongSource)
        XCTAssertEqual(c1, "bad_request")
        var badLength = TakeVersionRequest.make(up, video: video, edits: edits)
        badLength.durationSec = 3
        let c2 = await code(src.id, badLength)
        XCTAssertEqual(c2, "bad_request")
        var missing = TakeVersionRequest.make(up, video: video, edits: edits)
        missing.uploadId = "up_nope"
        let c3 = await code(src.id, missing)
        XCTAssertEqual(c3, "upload_missing")
        let c4 = await code("tk_nope", .make(up, video: video, edits: EditList(sourceTakeId: "tk_nope", sourceDurationSec: 6)))
        XCTAssertEqual(c4, "not_found")
        if let photo = takes.first(where: { !$0.isVideo }) {
            let c5 = await code(photo.id, .make(up, video: video, edits: EditList(sourceTakeId: photo.id, sourceDurationSec: 6)))
            XCTAssertEqual(c5, "bad_request")
        }
        let ok = await code(src.id, .make(up, video: video, edits: edits))
        XCTAssertNil(ok)
    }
}

private extension EditList {
    func with(_ f: (inout EditList) -> Void) -> EditList {
        var c = self
        f(&c)
        return c
    }
}
