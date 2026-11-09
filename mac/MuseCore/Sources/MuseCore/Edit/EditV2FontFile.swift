import Foundation

// Own fonts (Swift port of server/api/src/editor/font.ts, WS8 6ccd9aa): an uploaded .ttf / .otf is checked and named from
// its `name` table. WOFF / WOFF2 and collections (.ttc) are refused.

extension EditV2 {
    public static let fontMaxBytes = 10 * 1024 * 1024

    /// The font's display name: full name (name ID 4), else family + subfamily (1 + 2), at most 80 characters; nil when
    /// `data` is not a TrueType or OpenType font.
    public static func fontName(_ data: Data) -> String? {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : 0 }
        guard b.count >= 12 else { return nil }
        let tag = u32(0)
        guard tag == 0x0001_0000 || tag == 0x7472_7565 || tag == 0x4F54_544F else { return nil }
        let n = u16(4)
        guard 12 + n * 16 <= b.count else { return nil }
        var nameOff = -1, nameLen = 0
        for i in 0..<n {
            let r = 12 + i * 16
            if b[r] == 0x6E, b[r + 1] == 0x61, b[r + 2] == 0x6D, b[r + 3] == 0x65 { nameOff = u32(r + 8); nameLen = u32(r + 12) }
        }
        var names: [Int: String] = [:]
        if nameOff >= 0, nameOff + 6 <= b.count, nameOff + nameLen <= b.count {
            let count = u16(nameOff + 2), strings = nameOff + u16(nameOff + 4)
            for i in 0..<count {
                let r = nameOff + 6 + i * 12
                if r + 12 > b.count { break }
                let platform = u16(r), id = u16(r + 6), len = u16(r + 8), off = strings + u16(r + 10)
                guard [1, 2, 4].contains(id), off + len <= b.count else { continue }
                // Windows / Unicode names are UTF-16BE; Mac Roman is read as Latin-1. Windows wins.
                let slice = Array(b[off..<(off + len)])
                let s: String
                switch platform {
                case 0, 3: s = String(decoding: stride(from: 0, to: slice.count - 1, by: 2).map { UInt16(slice[$0]) << 8 | UInt16(slice[$0 + 1]) }, as: UTF16.self)
                case 1: s = String(slice.map { Character(Unicode.Scalar($0)) })
                default: s = ""
                }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, names[id] == nil || platform == 3 { names[id] = t }
            }
        }
        let full = names[4] ?? [names[1], names[2]].compactMap { $0 }.joined(separator: " ")
        var clean = String.UnicodeScalarView()
        clean.append(contentsOf: (full.isEmpty ? "Font" : full).unicodeScalars.filter { $0.value >= 0x20 })
        return String(decoding: Array(String(clean).utf16.prefix(80)), as: UTF16.self)
    }
}
