import AppKit
import AVFoundation
import MuseCore

/// Owner issues of 2026-11-12, checked in the real app (review mode, demo API); every failure is a FAIL line in
/// edit-check.txt, which fails Mac CI:
/// - ci_f99f93616ece: a song that is raw ADTS AAC named .mp4 (made with macOS's afconvert), and an M4A renamed .mp4, go
///   into Edit's Uploads as sound; a text file named .mp4 is refused with the one plain line.
/// - ci_de89873ab1de: upload_local_file's decision for those files (sound by content, at most 200 MB).
/// - ci_e546642a4026: a paid helper Claude asked for on ANOTHER edit session is listed for the Claude panel (named after
///   its edit) while a different edit is open, and Allow answers it on its own session.
extension SnapshotRunner {
    static func editAudioApprovalsCheck(_ store: AppStore, media: URL, note: (String) -> Void) async {
        note("START edit_audio_approvals")
        let dir = media.appendingPathComponent("audio-check", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wav = dir.appendingPathComponent("tone.wav"), adts = dir.appendingPathComponent("Night drive.mp4")
        let m4a = dir.appendingPathComponent("voice.m4a"), m4aAsMp4 = dir.appendingPathComponent("Voice note.mp4")
        let text = dir.appendingPathComponent("notes.mp4")
        do {
            try writeTone(m4a, seconds: 4, rate: 44_100, channels: 1)
            try FileManager.default.copyItem(at: m4a, to: m4aAsMp4)
            try Data("not a video".utf8).write(to: text)
            try writePCM(wav, seconds: 6)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "adts", "-d", "aac", wav.path, adts.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ApiError("edit_check", "afconvert \(p.terminationStatus)") }
        } catch {
            note("FAIL edit_audio_approvals: test files (\(error.localizedDescription))")
            return
        }
        // The file really is raw AAC: the check means nothing otherwise.
        let head = (try? FileHandle(forReadingFrom: adts)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 64) } ?? Data()
        if MediaSniff.format(head) != .adts { note("FAIL edit_audio_approvals: afconvert didn't write ADTS (\(MediaSniff.format(head)))") }

        // ci_de89873ab1de: what upload_local_file sends for each.
        for (url, mime) in [(adts, "audio/aac"), (m4aAsMp4, "audio/mp4")] {
            let t = ClaudeFilePolicy.uploadType(sniffed: await EditMediaProbe.probe(url)?.verdict)
            if t?.kind != .audio || t?.mime != mime { note("FAIL upload_local_file \(url.lastPathComponent): \(String(describing: t)), wanted audio \(mime)") }
        }
        if await EditMediaProbe.probe(text) != nil { note("FAIL upload_local_file notes.mp4: a text file was taken") }

        // ci_f99f93616ece: Edit's Add.
        guard let s = store.makeEditSuiteSession(takeId: "rx_full") else { note("FAIL edit_audio_approvals: no editor session"); return }
        await s.load()
        defer { s.close() }
        let before = Set(s.uploads.map(\.id))
        await s.addFiles([adts, m4aAsMp4])
        let added = s.uploads.filter { !before.contains($0.id) }
        if added.count != 2 || added.contains(where: { $0.kind != .audio }) {
            note("FAIL edit_add: \(added.map { "\($0.name) \($0.kind)" }) (\(s.lastError ?? "no error")), wanted 2 sounds")
        }
        if let song = added.first(where: { $0.name == "Night drive" }) {
            if (song.durationSec ?? 0) < 5 { note("FAIL edit_add: Night drive is \(song.durationSec ?? 0) s, wanted about 6") }
        } else {
            note("FAIL edit_add: Night drive (raw AAC named .mp4) isn't in Uploads")
        }
        s.lastError = nil
        await s.addFiles([text])
        if s.lastError != MediaSniff.unreadable { note("FAIL edit_add notes.mp4: said \(s.lastError ?? "nothing"), wanted \(MediaSniff.unreadable)") }
        if s.uploads.count != before.count + 2 { note("FAIL edit_add notes.mp4: something was added") }

        // ci_e546642a4026: a helper on another edit, while this one is open.
        guard let fake = store.api as? FakeMuseAPI else { note("FAIL edit_approvals: not the demo API"); return }
        do {
            let open = try await fake.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId))
            let other = try await fake.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId))
            let p = try await fake.fakeClaudePending(sessionId: other.id, kind: "matte", label: "Remove background", estimateUsd: 0.4)
            await store.loadEditApprovals()
            let mine = store.oneClaude.editApprovals.items.filter { $0.sessionId == other.id }
            guard let a = mine.first, mine.count == 1 else {
                note("FAIL edit_approvals: \(store.oneClaude.editApprovals.count) listed, none for the other edit (open: \(open.id))")
                return
            }
            if store.editApprovalName(a) != "New project" { note("FAIL edit_approvals: the card names \(store.editApprovalName(a))") }
            if a.allowLabel != "Allow · $0.40" { note("FAIL edit_approvals: button \(a.allowLabel)") }
            await store.answerEditApproval(a, approve: true)
            let after = try await fake.editSession(id: other.id)
            if after.pending.contains(where: { $0.id == p.id && $0.isWaiting }) { note("FAIL edit_approvals: Allow didn't answer it on its own session") }
            if store.oneClaude.editApprovals.items.contains(where: { $0.id == a.id }) { note("FAIL edit_approvals: still listed after Allow") }
            try? await fake.closeEditSession(id: open.id)
            try? await fake.closeEditSession(id: other.id)
        } catch {
            note("FAIL edit_approvals: \(error.localizedDescription)")
            return
        }
        note("DONE edit_audio_approvals (\(added.map(\.name).joined(separator: ", ")) as sound; another edit's helper allowed from the panel)")
    }

    /// A 16-bit PCM WAV of a tone (afconvert's input).
    private static func writePCM(_ url: URL, seconds: Double) throws {
        let rate = 44_100.0
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate)), let data = buf.floatChannelData else {
            throw ApiError("edit_check", "Couldn't make the test sound")
        }
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) { data[0][i] = Float(sin(2 * Double.pi * 330 * Double(i) / rate) * 0.6) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        try file.write(from: buf)
    }
}
