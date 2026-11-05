import Foundation

// Silence, filler-word and repeated-word cuts from word timestamps: a port of server/api/src/editor/cuts.ts. Times are
// SOURCE seconds of the transcribed media; the result goes to EditV2.applyCuts.

extension EditV2 {
    public struct Word: Codable, Hashable, Sendable {
        public var text: String
        public var startSec: Double
        public var endSec: Double
        public var score: Double?
        public init(text: String, startSec: Double, endSec: Double, score: Double? = nil) {
            self.text = text; self.startSec = startSec; self.endSec = endSec; self.score = score
        }
    }

    public enum CutReason: String, Codable, Hashable, Sendable { case silence, filler, `repeat` }

    public struct Cut: Codable, Hashable, Sendable {
        public var startSec: Double
        public var endSec: Double
        public var reason: CutReason
        public var text: String?
        public init(startSec: Double, endSec: Double, reason: CutReason, text: String? = nil) {
            self.startSec = startSec; self.endSec = endSec; self.reason = reason; self.text = text
        }
        public var range: SecRange { SecRange(startSec: startSec, endSec: endSec) }
    }

    public struct CutOptions: Codable, Hashable, Sendable {
        public var minSilenceSec: Double?
        public var keepPadSec: Double?
        public var fillers: Bool?
        public var repeats: Bool?
        public var extraFillers: [String]?
        public init(minSilenceSec: Double? = nil, keepPadSec: Double? = nil, fillers: Bool? = nil, repeats: Bool? = nil, extraFillers: [String]? = nil) {
            self.minSilenceSec = minSilenceSec; self.keepPadSec = keepPadSec; self.fillers = fillers; self.repeats = repeats; self.extraFillers = extraFillers
        }
    }

    public struct CutSuggestion: Codable, Hashable, Sendable {
        public var cuts: [Cut]
        public var savedSec: Double
    }

    public static let fillerWords = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "mhm"]
    public static let cutDefaults = CutOptions(minSilenceSec: 0.7, keepPadSec: 0.12, fillers: true, repeats: false)

    /// Lower case, letters, digits and apostrophes only.
    public static func normWord(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.lowercased().unicodeScalars {
            if u == "'" { out.append(u); continue }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                out.append(u)
            default: break
            }
        }
        return String(out)
    }

    public static func suggestCuts(_ words: [Word], durationSec: Double, options o: CutOptions = CutOptions()) -> CutSuggestion {
        let minSil = o.minSilenceSec ?? 0.7, pad = o.keepPadSec ?? 0.12
        let fillers = Set((fillerWords + (o.extraFillers ?? []).map(normWord)).filter { !$0.isEmpty })
        let ws = stableSorted(words) { $0.startSec < $1.startSec }
        var raw: [Cut] = []
        guard let first = ws.first, let last = ws.last else { return CutSuggestion(cuts: [], savedSec: 0) }
        func silence(_ a: Double, _ b: Double) {
            let s = a + pad, e = b - pad
            if b - a >= minSil && e - s >= 0.1 { raw.append(Cut(startSec: s, endSec: e, reason: .silence)) }
        }
        // Leading and trailing silence keep no pad on the outer side.
        if first.startSec >= minSil && first.startSec - pad >= 0.1 { raw.append(Cut(startSec: 0, endSec: first.startSec - pad, reason: .silence)) }
        for i in 1..<ws.count { silence(ws[i - 1].endSec, ws[i].startSec) }
        if durationSec - last.endSec >= minSil && durationSec - (last.endSec + pad) >= 0.1 {
            raw.append(Cut(startSec: last.endSec + pad, endSec: durationSec, reason: .silence))
        }
        for (i, w) in ws.enumerated() {
            let n = normWord(w.text)
            if (o.fillers ?? true) && fillers.contains(n) { raw.append(Cut(startSec: w.startSec, endSec: w.endSec, reason: .filler, text: w.text)) }
            if (o.repeats ?? false), i + 1 < ws.count, !n.isEmpty {
                let next = ws[i + 1]
                if normWord(next.text) == n && next.startSec - w.endSec < 1 { raw.append(Cut(startSec: w.startSec, endSec: next.startSec, reason: .`repeat`, text: w.text)) }
            }
        }
        raw = stableSorted(raw) { $0.startSec < $1.startSec || ($0.startSec == $1.startSec && $0.endSec < $1.endSec) }
        var out: [Cut] = []
        for c in raw {
            if let prev = out.last, c.startSec <= prev.endSec + 1e-9 {
                out[out.count - 1].endSec = max(prev.endSec, c.endSec)
                if let t = c.text, !t.isEmpty, prev.text?.isEmpty ?? true { out[out.count - 1].text = t }
                continue
            }
            out.append(c)
        }
        let cuts = out.map { c -> Cut in
            var d = c
            d.startSec = r3(max(0, c.startSec))
            d.endSec = r3(min(durationSec, c.endSec))
            return d
        }.filter { $0.endSec - $0.startSec >= 0.05 }
        return CutSuggestion(cuts: cuts, savedSec: r3(cuts.reduce(0) { $0 + $1.endSec - $1.startSec }))
    }
}
