import AVFoundation
import Foundation
import MuseCore

/// What a file on this Mac really is (owner issue ci_f99f93616ece, 2026-11-12): its first bytes (MuseCore MediaSniff), and
/// for an MP4/MOV container its tracks, decide video, picture or sound; never the name alone. A file whose name hides what
/// it is (raw AAC named .mp4) is read through a copy named right, because AVFoundation picks its reader by extension.
/// Used by Edit's Add (Uploads, Music, Record voice-over) and by Claude's upload_local_file.
enum EditMediaProbe {
    struct Probed {
        let verdict: MediaSniff.Verdict
        /// The file to read and upload (the original, or the renamed copy).
        let url: URL
        /// The name to show (the original file's, without extension).
        let name: String
    }

    /// Nil when MUSE can't use the file (MediaSniff.unreadable says why).
    static func probe(_ url: URL) async -> Probed? {
        let head: Data = {
            guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? h.close() }
            return (try? h.read(upToCount: MediaSniff.headerBytes)) ?? Data()
        }()
        let format = MediaSniff.format(head)
        var hasVideo: Bool?, hasAudio: Bool?
        // A container, or bytes that say nothing (then only real tracks make it usable, never the name).
        var readTracks = format == .unknown
        if case .isoMedia = format { readTracks = true }
        if readTracks {
            let asset = AVURLAsset(url: url)
            let v = try? await asset.loadTracks(withMediaType: .video)
            let a = try? await asset.loadTracks(withMediaType: .audio)
            if v != nil || a != nil {
                hasVideo = !(v ?? []).isEmpty
                hasAudio = !(a ?? []).isEmpty
            }
        }
        guard let verdict = MediaSniff.verdict(format, fileExtension: url.pathExtension, hasVideo: hasVideo, hasAudio: hasAudio) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard MediaSniff.needsRename(fileExtension: url.pathExtension, verdict) else { return Probed(verdict: verdict, url: url, name: name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muse-probe-\(UUID().uuidString)", isDirectory: true)
        let copy = dir.appendingPathComponent(name.isEmpty ? "file" : name).appendingPathExtension(verdict.ext)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do { try FileManager.default.linkItem(at: url, to: copy) } catch { try FileManager.default.copyItem(at: url, to: copy) }
        } catch {
            return nil
        }
        return Probed(verdict: verdict, url: copy, name: name)
    }
}
