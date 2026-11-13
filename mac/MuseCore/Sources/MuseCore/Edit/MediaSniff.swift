import Foundation

// What a file really is, from its first bytes, not its name (owner issue ci_f99f93616ece, 2026-11-12: a song that was raw
// ADTS AAC, sound only, named .mp4, was read as a video and Edit said only "Couldn't add that file"). Used by Edit's Add
// (Uploads, Music) and by upload_local_file. An MP4 container needs its tracks to decide: the app reads them
// (AVFoundation) and passes `hasVideo` / `hasAudio`.

public enum MediaSniff {
    /// Enough of the file's start for every check here.
    public static let headerBytes = 64

    public enum Format: Equatable, Sendable {
        case adts, mp3, wav, aiff, flac
        /// ISO base media (MP4, M4A, MOV, HEIC): the `ftyp` brand decides pictures; tracks decide video vs sound.
        case isoMedia(brand: String)
        case png, jpeg, webp
        case unknown
    }

    /// The format of a file from its first bytes.
    public static func format(_ data: Data) -> Format {
        let b = [UInt8](data.prefix(headerBytes))
        func ascii(_ at: Int, _ n: Int) -> String? {
            guard b.count >= at + n else { return nil }
            return String(bytes: b[at..<at + n], encoding: .ascii)
        }
        if b.count >= 8, ascii(4, 4) == "ftyp" { return .isoMedia(brand: ascii(8, 4) ?? "") }
        // An older QuickTime file starts with another top-level atom (no ftyp): a container whose tracks decide.
        if b.count >= 8, let atom = ascii(4, 4), quickTimeAtoms.contains(atom) { return .isoMedia(brand: "qt  ") }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" { return .wav }
        if ascii(0, 4) == "RIFF", ascii(8, 4) == "WEBP" { return .webp }
        if ascii(0, 4) == "FORM", let t = ascii(8, 4), t == "AIFF" || t == "AIFC" { return .aiff }
        if ascii(0, 4) == "fLaC" { return .flac }
        if ascii(0, 3) == "ID3" { return .mp3 }
        if b.count >= 2, b[0] == 0xFF {
            // ADTS (AAC): 12-bit sync 0xFFF, layer 00. MPEG audio (MP3): 11-bit sync, layer not 00.
            if b[1] & 0xF6 == 0xF0 { return .adts }
            if b[1] & 0xE0 == 0xE0, (b[1] >> 1) & 0x3 != 0 { return .mp3 }
        }
        return .unknown
    }

    /// What MUSE does with a file: its kind, the content type it is uploaded as and the extension it must carry on this
    /// Mac (AVFoundation reads by extension).
    public struct Verdict: Equatable, Sendable {
        public var kind: EditSuite.UploadKind
        public var contentType: String
        public var ext: String
        public init(_ kind: EditSuite.UploadKind, _ contentType: String, _ ext: String) {
            self.kind = kind; self.contentType = contentType; self.ext = ext
        }
    }

    /// The one line when a file can't be used.
    public static let unreadable = "This file has no video or sound MUSE can read."

    private static let quickTimeAtoms: Set<String> = ["moov", "mdat", "wide", "free", "skip", "pnot"]
    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
    private static let audioBrands: Set<String> = ["M4A ", "M4B ", "M4P "]

    /// The verdict, from the format and (for an MP4 container) its tracks; nil when MUSE can't use the file. A name alone
    /// never makes a file usable (bundle-10 run 617: a text file named .mp4 was taken): bytes that say nothing need real
    /// tracks read by the app.
    public static func verdict(_ f: Format, fileExtension: String, hasVideo: Bool? = nil, hasAudio: Bool? = nil) -> Verdict? {
        switch f {
        case .adts: return Verdict(.audio, "audio/aac", "aac")
        case .mp3: return Verdict(.audio, "audio/mpeg", "mp3")
        case .wav: return Verdict(.audio, "audio/wav", "wav")
        case .aiff: return Verdict(.audio, "audio/aiff", "aiff")
        case .flac: return Verdict(.audio, "audio/flac", "flac")
        case .png: return Verdict(.picture, "image/png", "png")
        case .jpeg: return Verdict(.picture, "image/jpeg", "jpg")
        case .webp: return Verdict(.picture, "image/webp", "webp")
        case .isoMedia(let brand):
            if heicBrands.contains(brand) { return Verdict(.picture, "image/heic", "heic") }
            let mov = brand == "qt  "
            if hasVideo == true { return Verdict(.video, mov ? "video/quicktime" : "video/mp4", mov ? "mov" : "mp4") }
            if hasAudio == true { return Verdict(.audio, "audio/mp4", "m4a") }
            if hasVideo == false && hasAudio == false { return nil }
            // Tracks not read: the brand's word.
            return audioBrands.contains(brand) ? Verdict(.audio, "audio/mp4", "m4a") : Verdict(.video, mov ? "video/quicktime" : "video/mp4", mov ? "mov" : "mp4")
        case .unknown:
            // Every format MUSE takes has magic bytes; a file without them is used only when the app read real tracks.
            let mov = fileExtension.lowercased() == "mov"
            if hasVideo == true { return Verdict(.video, mov ? "video/quicktime" : "video/mp4", mov ? "mov" : "mp4") }
            if hasAudio == true { return Verdict(.audio, "audio/mp4", "m4a") }
            return nil
        }
    }

    /// True when the file must be read through a copy named with the verdict's extension (AVFoundation picks its reader
    /// from the name: raw AAC named .mp4 won't open, an M4A named .mp4 will).
    public static func needsRename(fileExtension: String, _ v: Verdict) -> Bool {
        let e = fileExtension.lowercased()
        let families: [Set<String>] = [["jpg", "jpeg"], ["mp4", "m4v", "m4a", "mov"], ["aif", "aiff", "aifc"], ["heic", "heif"]]
        if e == v.ext { return false }
        return !families.contains { $0.contains(e) && $0.contains(v.ext) }
    }
}
