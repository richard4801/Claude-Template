import Foundation

// The Claude panel's live context strip (owner, 2026-11-12: "the 'Claude sees' feature is basic"): under the header, a row
// of small thumbnails, each with a tiny label, of what Claude can see on this page right now: the source clip, her, the
// outfit, the background (a photo, or the words of a described one), references and frames, the Directed guide, the
// picked model. Read from the SAME `screen` the composer syncs to the server for Claude (SuiteScreen.json → suite/screen.ts),
// so the strip and Claude never disagree. Pure: the app passes lookups for names and pictures.

public struct ClaudeContextItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case clip, character, outfit, background, frame, reference, guide, audio, model, product, face }
    public var id: String
    public var kind: Kind
    /// The tiny label under the thumbnail ("Clip", "Her", "Outfit", "Ref 1").
    public var label: String
    /// What it is, for the tooltip and VoiceOver ("Beach walk.mp4", "Ava", "a grey hoodie").
    public var detail: String?
    public var image: ImageRef?
    /// A clip of the studio (the app shows its poster).
    public var clipId: String?
    public var isVideo: Bool
    /// A background described in words (no picture): the words.
    public var words: String?
}

public enum ClaudeContext {
    /// Names and pictures the strip needs, looked up by the app.
    public struct Lookups {
        public var character: (String) -> (name: String, image: ImageRef?)?
        public var outfit: (String) -> (name: String, image: ImageRef?)?
        public var clipPoster: (String) -> ImageRef?
        public var modelLabel: (String) -> String?
        public init(character: @escaping (String) -> (name: String, image: ImageRef?)? = { _ in nil },
                    outfit: @escaping (String) -> (name: String, image: ImageRef?)? = { _ in nil },
                    clipPoster: @escaping (String) -> ImageRef? = { _ in nil },
                    modelLabel: @escaping (String) -> String? = { _ in nil }) {
            self.character = character; self.outfit = outfit; self.clipPoster = clipPoster; self.modelLabel = modelLabel
        }
    }

    /// The strip's items for a `screen` (SuiteScreen.json), in the order Claude reads them: the source, her, the outfit,
    /// the background, frames and references, the guide, sound, then the model.
    public static func items(screen: JSONValue, lookups: Lookups = Lookups()) -> [ClaudeContextItem] {
        guard case .object(let s) = screen else { return [] }
        let request = obj(s["request"]), settings = obj(s["settings"])
        var out: [ClaudeContextItem] = []
        var refs = 0, frames = 0

        let inputs: [[String: JSONValue]] = { if case .array(let a)? = s["inputs"] { return a.compactMap(obj) }; return [] }()
        // Sources first (clip, extend's video), then her and the outfit, then everything else on screen.
        let sources = inputs.filter { isSource(str($0["slot"])) }
        for i in sources {
            let clip = str(i["clipId"])
            out.append(ClaudeContextItem(id: "in:\(str(i["slot"]) ?? "")", kind: .clip, label: "Clip", detail: str(i["label"]),
                                         image: clip.flatMap(lookups.clipPoster) ?? imageOf(i, video: true), clipId: clip, isVideo: true, words: nil))
        }
        if let m = str(request["modelId"]) {
            let c = lookups.character(m)
            out.append(ClaudeContextItem(id: "character:\(m)", kind: .character, label: "Her", detail: c?.name, image: c?.image, clipId: nil, isVideo: false, words: nil))
        }
        if let o = str(request["outfitId"]) {
            let x = lookups.outfit(o)
            out.append(ClaudeContextItem(id: "outfit:\(o)", kind: .outfit, label: "Outfit", detail: x?.name, image: x?.image, clipId: nil, isVideo: false, words: nil))
        }
        // New Swap's outfit in words.
        if let w = str(obj(obj(request["remix"])["outfit"])["words"]) {
            out.append(ClaudeContextItem(id: "outfit:words", kind: .outfit, label: "Outfit", detail: w, image: nil, clipId: nil, isVideo: false, words: w))
        }
        // The background: a picture on screen, or the words of a described one.
        let bgWords = str(obj(obj(request["remix"])["background"])["words"])
            ?? ((str(request["background"]) ?? str(settings["background"])) == "describe" ? (str(request["direction"]) ?? str(request["prompt"])) : nil)
        if let w = bgWords, !inputs.contains(where: { str($0["slot"])?.hasSuffix("background") == true }) {
            out.append(ClaudeContextItem(id: "background:words", kind: .background, label: "Background", detail: w, image: nil, clipId: nil, isVideo: false, words: w))
        }
        for i in inputs where !isSource(str(i["slot"])) {
            let slot = str(i["slot"]) ?? ""
            let kind = str(i["kind"]) ?? "image"
            let label: String, k: ClaudeContextItem.Kind
            if slot.hasSuffix("background") { label = "Background"; k = .background }
            else if slot.hasSuffix(".outfit") { label = "Product"; k = .product }
            else if slot.hasSuffix(".face") { label = "Face"; k = .face }
            else if slot == "guide" { label = "Guide"; k = .guide }
            else if slot == "start" { label = "Start"; k = .frame }
            else if slot == "end" { label = "End"; k = .frame }
            else if slot.hasPrefix("middle") { frames += 1; label = "Frame \(frames)"; k = .frame }
            else if kind == "audio" { label = "Sound"; k = .audio }
            else { refs += 1; label = str(i["role"]).map { cap($0) } ?? "Ref \(refs)"; k = .reference }
            out.append(ClaudeContextItem(id: "in:\(slot)", kind: k, label: label, detail: str(i["label"]), image: imageOf(i, video: kind == "video"),
                                         clipId: str(i["clipId"]), isVideo: kind == "video", words: nil))
        }
        // The picked model, by the label the server gives it (settings.modelLabel, the Model pill's words).
        if let e = str(request["engineModel"]) ?? str(settings["modelLabel"]) {
            let label = str(settings["modelLabel"]) ?? lookups.modelLabel(e) ?? e
            out.append(ClaudeContextItem(id: "model:\(e)", kind: .model, label: "Model", detail: label, image: nil, clipId: nil, isVideo: false, words: nil))
        }
        return out
    }

    private static func isSource(_ slot: String?) -> Bool {
        guard let s = slot else { return false }
        return s.hasSuffix(".clip") || s == "extend.video"
    }
    private static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }
    private static func str(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        return nil
    }
    private static func imageOf(_ i: [String: JSONValue], video: Bool) -> ImageRef? {
        guard !video, let u = str(i["url"]) else { return nil }
        return ImageRef(url: u)
    }
    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
