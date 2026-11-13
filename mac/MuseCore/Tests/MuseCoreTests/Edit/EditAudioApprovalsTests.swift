import XCTest
@testable import MuseCore

/// Owner issues of 2026-11-12: a song that is raw ADTS AAC named .mp4 (ci_f99f93616ece), upload_local_file refusing sound
/// (ci_de89873ab1de), and paid-helper approvals of another edit that never showed (ci_e546642a4026).
final class EditAudioApprovalsTests: XCTestCase {
    typealias S = MediaSniff

    private func bytes(_ b: [UInt8], pad: Int = 64) -> Data { Data(b + [UInt8](repeating: 0, count: max(0, pad - b.count))) }
    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func iso(_ brand: String) -> Data { bytes([0, 0, 0, 0x20] + ascii("ftyp") + ascii(brand)) }

    // MARK: What a file is (ci_f99f93616ece)

    func testFormatFromTheBytesNotTheName() {
        XCTAssertEqual(S.format(bytes([0xFF, 0xF1, 0x50, 0x80])), .adts, "MPEG-4 AAC ADTS")
        XCTAssertEqual(S.format(bytes([0xFF, 0xF9, 0x50, 0x80])), .adts, "MPEG-2 AAC ADTS")
        XCTAssertEqual(S.format(bytes([0xFF, 0xFB, 0x90, 0x64])), .mp3, "MPEG-1 layer III frame")
        XCTAssertEqual(S.format(bytes(ascii("ID3") + [4, 0])), .mp3)
        XCTAssertEqual(S.format(bytes(ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE"))), .wav)
        XCTAssertEqual(S.format(bytes(ascii("RIFF") + [0, 0, 0, 0] + ascii("WEBP"))), .webp)
        XCTAssertEqual(S.format(bytes(ascii("FORM") + [0, 0, 0, 0] + ascii("AIFF"))), .aiff)
        XCTAssertEqual(S.format(bytes(ascii("fLaC"))), .flac)
        XCTAssertEqual(S.format(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), .png)
        XCTAssertEqual(S.format(bytes([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(S.format(iso("isom")), .isoMedia(brand: "isom"))
        XCTAssertEqual(S.format(iso("M4A ")), .isoMedia(brand: "M4A "))
        XCTAssertEqual(S.format(Data(ascii("hello, a text file"))), .unknown)
        XCTAssertEqual(S.format(Data()), .unknown)
    }

    func testRawAACNamedMp4IsASongAndIsReadThroughAnAacCopy() throws {
        let v = try XCTUnwrap(S.verdict(S.format(bytes([0xFF, 0xF1, 0x50, 0x80])), fileExtension: "mp4"))
        XCTAssertEqual(v, S.Verdict(.audio, "audio/aac", "aac"))
        XCTAssertTrue(S.needsRename(fileExtension: "mp4", v), "AVFoundation won't open raw AAC named .mp4")
        XCTAssertFalse(S.needsRename(fileExtension: "AAC", v))
    }

    func testAnMp4WithSoundOnlyIsAudioAndWithAPictureIsVideo() {
        let f = S.format(iso("isom"))
        XCTAssertEqual(S.verdict(f, fileExtension: "mp4", hasVideo: false, hasAudio: true), S.Verdict(.audio, "audio/mp4", "m4a"))
        XCTAssertEqual(S.verdict(f, fileExtension: "mp4", hasVideo: true, hasAudio: true), S.Verdict(.video, "video/mp4", "mp4"))
        XCTAssertEqual(S.verdict(S.format(iso("qt  ")), fileExtension: "mov", hasVideo: true, hasAudio: false), S.Verdict(.video, "video/quicktime", "mov"))
        XCTAssertNil(S.verdict(f, fileExtension: "mp4", hasVideo: false, hasAudio: false), "no video and no sound: unusable")
        XCTAssertEqual(S.verdict(S.format(iso("M4A ")), fileExtension: "mp4"), S.Verdict(.audio, "audio/mp4", "m4a"), "tracks unread: the brand's word")
        XCTAssertEqual(S.verdict(S.format(iso("heic")), fileExtension: "mp4"), S.Verdict(.picture, "image/heic", "heic"))
        // An M4A named .mp4 opens as it is (same container family).
        XCTAssertFalse(S.needsRename(fileExtension: "mp4", S.Verdict(.audio, "audio/mp4", "m4a")))
        XCTAssertTrue(S.needsRename(fileExtension: "mp4", S.Verdict(.audio, "audio/mpeg", "mp3")))
    }

    func testUnreadableFilesSayWhyInOnePlainLine() {
        XCTAssertNil(S.verdict(.unknown, fileExtension: "pdf"))
        XCTAssertNil(S.verdict(.unknown, fileExtension: "mp3"), "an .mp3 with no MPEG audio inside")
        XCTAssertEqual(S.verdict(.unknown, fileExtension: "mov"), S.Verdict(.video, "video/quicktime", "mov"))
        XCTAssertEqual(S.unreadable, "This file has no video or sound MUSE can read.")
        XCTAssertFalse(S.unreadable.contains("·"))
    }

    // MARK: upload_local_file takes sound (ci_de89873ab1de)

    func testUploadPolicyTakesSound() {
        for (f, mime) in [("a.mp3", "audio/mpeg"), ("a.M4A", "audio/mp4"), ("a.aac", "audio/aac"), ("a.wav", "audio/wav")] {
            let t = ClaudeFilePolicy.uploadType(f)
            XCTAssertEqual(t?.mime, mime, f)
            XCTAssertEqual(t?.kind, .audio, f)
            XCTAssertEqual(t?.resultKind, "audio", f)
        }
        XCTAssertEqual(ClaudeFilePolicy.uploadType("a.mp4")?.resultKind, "clip", "an .mp4 is a video by name")
        XCTAssertEqual(ClaudeFilePolicy.uploadType("a.png")?.resultKind, "image")
        XCTAssertNil(ClaudeFilePolicy.uploadType("a.flac"))
        XCTAssertEqual(ClaudeFilePolicy.uploadAudioMaxBytes, 200 * 1024 * 1024)
        XCTAssertTrue(ClaudeFilePolicy.uploadRefusal.contains("MP3, M4A, AAC, WAV, up to 200 MB"))
        // An audio-only .mp4 goes up as audio once its content is read.
        let sniffed = ClaudeFilePolicy.uploadType(sniffed: S.verdict(S.format(iso("isom")), fileExtension: "mp4", hasVideo: false, hasAudio: true))
        XCTAssertEqual(sniffed, ClaudeFilePolicy.UploadType(mime: "audio/mp4", kind: .audio))
        XCTAssertEqual(ClaudeFilePolicy.uploadType(sniffed: S.verdict(.adts, fileExtension: "mp4"))?.mime, "audio/aac")
        XCTAssertNil(ClaudeFilePolicy.uploadType(sniffed: nil))
        XCTAssertNil(ClaudeFilePolicy.uploadType(sniffed: S.Verdict(.picture, "image/png", "png")))
    }

    func testAUploadCardForSoundIsAskedNotRefused() {
        let ask = ClaudePermissionAsk(id: "p1", toolName: "Upload", input: .object(["file_path": .string("~/Music/song.m4a")]))
        guard case .ask = ClaudeFilePolicy.verdict(ask, mode: .ask, folders: [], cwd: "/Users/me", home: "/Users/me") else {
            return XCTFail("a sound must be asked about, not refused")
        }
    }

    // MARK: Approvals of every edit (ci_e546642a4026)

    private func session(_ id: String, take: String, _ pending: [EditPending]) throws -> EditSession {
        let json = """
        {"id":"\(id)","takeId":"\(take)","revision":1,"project":{},"status":"open","pending":[],"online":[],"requests":[]}
        """
        var s = try JSONDecoder().decode(EditSession.self, from: Data(json.utf8))
        s.pending = pending
        return s
    }

    func testEveryEditsWaitingHelpersAreListedOldestFirst() throws {
        var list = EditApprovalList()
        let a = EditPending(id: "pd_1", kind: "matte", label: "Remove background", estimateUsd: 0.4, createdAt: 20)
        let b = EditPending(id: "pd_2", kind: "captions", label: "Captions", estimateUsd: 0.05, createdAt: 10)
        let running = EditPending(id: "pd_3", kind: "denoise", label: "Clean up sound", estimateUsd: 0.1, status: "running", createdAt: 5)
        list.replace(sessions: [try session("es_open", take: "tk_a", [a]), try session("es_other", take: "tk_b", [b, running])])
        XCTAssertEqual(list.items.map(\.id), ["es_other/pd_2", "es_open/pd_1"], "waiting only, oldest first, from both edits")
        XCTAssertEqual(list.items.first?.takeId, "tk_b")
        XCTAssertEqual(list.items.last?.allowLabel, "Allow · $0.40")
    }

    func testLiveEventsAddUpdateAndRemove() throws {
        var list = EditApprovalList()
        list.replace(sessions: [try session("es_1", take: "tk_1", [])])
        let p = EditPending(id: "pd_9", kind: "cuts", label: "Cut silences", estimateUsd: 0.12, createdAt: 3)
        list.apply(sessionId: "es_2", takeId: "tk_2", p)
        XCTAssertEqual(list.items.map(\.id), ["es_2/pd_9"])
        var approved = p
        approved.status = "approved"
        list.apply(sessionId: "es_2", takeId: nil, approved)
        XCTAssertTrue(list.isEmpty, "answered on another device: gone here too")
        list.apply(sessionId: "es_2", takeId: nil, p)
        XCTAssertEqual(list.items.first?.takeId, "", "unknown edit until the next reload")
        list.remove("es_2/pd_9")
        XCTAssertEqual(list.count, 0)
    }

    func testTheCardNamesItsEdit() {
        XCTAssertEqual(EditApprovalList.editName(takeId: "tk_1", title: " Living room dance "), "Living room dance")
        XCTAssertEqual(EditApprovalList.editName(takeId: EditV2.blankSourceId, title: nil), "New project")
        XCTAssertEqual(EditApprovalList.editName(takeId: "tk_gone", title: nil), "an edit")
    }

    func testTheLiveStreamCarriesEditPendingEvents() throws {
        let json = #"{"type":"edit","sessionId":"es_7","op":"pending","pending":{"id":"pd_1","kind":"matte","label":"Remove background","estimateUsd":0.4,"status":"waiting","createdAt":1}}"#
        guard case .editPending(let sid, let p)? = ClaudeLiveEventFilter.parse(Data(json.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(sid, "es_7")
        XCTAssertEqual(p.label, "Remove background")
        XCTAssertNil(ClaudeLiveEventFilter.parse(Data(#"{"type":"edit","sessionId":"es_7","op":"patch","revision":2}"#.utf8)), "other edit events stay with the editor")
        XCTAssertNil(ClaudeLiveEventFilter.parse(Data(#"{"type":"jobs","op":"pending"}"#.utf8)))
    }

    func testTheDemoApiAnswersAHelperOfAnotherEditBySessionId() async throws {
        let api = FakeMuseAPI()
        let s1 = try await api.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId))
        let s2 = try await api.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId))
        _ = try await api.fakeClaudePending(sessionId: s2.id, kind: "matte", label: "Remove background", estimateUsd: 0.4)
        var list = EditApprovalList()
        list.replace(sessions: try await api.recentEditSessions(limit: 50))
        XCTAssertEqual(list.items.map(\.sessionId), [s2.id], "the other edit's helper, while \(s1.id) is the one open")
        let a = try XCTUnwrap(list.items.first)
        let answered = try await api.answerEditPending(sessionId: a.sessionId, pendingId: a.pending.id, approve: true)
        XCTAssertFalse(answered.isWaiting)
        list.replace(sessions: try await api.recentEditSessions(limit: 50))
        XCTAssertTrue(list.isEmpty)
    }
}
