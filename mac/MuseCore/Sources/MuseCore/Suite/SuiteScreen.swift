import Foundation

// Claude sees what is on screen (owner, 2026-11-11: "Claude still can't see clips added to swap or anywhere"). The shared
// draft the composer syncs to the server (SuiteClaudeBridge, PATCH /v1/suite/assist) carries `screen` next to the chips
// and rig: the request Generate would send right now (Swap's clip, Recast's cast, Extend's video, the slots' frames and
// references, a Directed camera with its Blender guides, the pinned model) and every input on screen in words, each with
// the id Claude watches or sees it by. Server: suite/screen.ts (requestOf takes the media from here). Pure, so it is tested.
public enum SuiteScreen {
    /// One input on screen, as the server's ScreenInputSchema names it.
    public struct Input: Hashable, Sendable {
        public var slot: String
        public var kind: String // video | image | audio
        public var label: String?
        public var role: String?
        public var clipId: String?
        public var uploadId: String?
        public var takeId: String?
        public var cameraSessionId: String?
        public var key: String?
        public var url: String?
        public var seconds: Double?
        public var state: String? // uploading | failed (nil = ready)

        public init(slot: String, kind: String, label: String? = nil, role: String? = nil, clipId: String? = nil, uploadId: String? = nil, takeId: String? = nil,
                    cameraSessionId: String? = nil, key: String? = nil, url: String? = nil, seconds: Double? = nil, state: String? = nil) {
            self.slot = slot; self.kind = kind; self.label = label; self.role = role; self.clipId = clipId; self.uploadId = uploadId; self.takeId = takeId
            self.cameraSessionId = cameraSessionId; self.key = key; self.url = url; self.seconds = seconds; self.state = state
        }

        var json: JSONValue {
            var o: [String: JSONValue] = ["slot": .string(String(slot.prefix(40))), "kind": .string(kind)]
            func put(_ k: String, _ v: String?, max: Int = 80) { if let v, !v.isEmpty { o[k] = .string(String(v.prefix(max))) } }
            put("label", label, max: 120); put("role", role, max: 20); put("clipId", clipId); put("uploadId", uploadId); put("takeId", takeId)
            put("cameraSessionId", cameraSessionId); put("key", key, max: 300); put("url", url, max: 2000); put("state", state, max: 20)
            if let s = seconds, s > 0, s.isFinite { o["seconds"] = .number(min(s, 3600)) }
            return .object(o)
        }
    }

    /// The filled slots, in the order the composer shows them ("start", "middle 1", "reference 2", "video 1", "audio").
    public static func inputs(_ slots: InputSlots) -> [Input] {
        let order = SlotKind.allCases
        let ids = slots.values.keys.sorted { a, b in
            let x = order.firstIndex(of: a.kind)!, y = order.firstIndex(of: b.kind)!
            return x == y ? a.index < b.index : x < y
        }
        return ids.compactMap { id -> Input? in
            guard let v = slots[id] else { return nil }
            let slot: String
            switch id.kind {
            case .start, .end, .audio: slot = id.kind.rawValue
            case .middle: slot = "middle \(id.index + 1)"
            case .image: slot = "reference \(id.index + 1)"
            case .video: slot = "video \(id.index + 1)"
            }
            let state = v.uploading ? "uploading" : v.error != nil ? "failed" : nil
            let name = (v.name as NSString).deletingPathExtension
            if id.kind.isImage {
                return Input(slot: slot, kind: "image", label: name.isEmpty ? nil : name, role: id.kind == .image ? v.role : nil, url: v.image?.url, state: state)
            }
            return Input(slot: slot, kind: id.kind == .audio ? "audio" : "video", label: name.isEmpty ? nil : name, role: id.kind == .video ? v.use : nil,
                         key: v.media?.key, url: v.media?.url, seconds: v.media?.seconds, state: state)
        }
    }

    /// Swap / Recast's source clip (uploaded or attached by link: both are a clip of the studio).
    public static func clip(_ c: Clip, slot: String) -> Input {
        Input(slot: slot, kind: "video", label: c.name, clipId: c.id, seconds: c.durationSec)
    }

    /// The Blender guide clip of a Directed camera (Rig → Movement → Directed), when it has one.
    public static func guide(_ camera: CameraSpec?) -> Input? {
        guard let cam = camera, cam.mode == "directed", case .object(let g)? = cam.guide else { return nil }
        var key: String?, url: String?, seconds: Double?, session: String?, use: String?
        if case .object(let v)? = g["video"] {
            if case .string(let k)? = v["key"] { key = k }
            if case .string(let u)? = v["url"] { url = u }
            if case .number(let s)? = v["seconds"] { seconds = s }
        }
        if case .string(let s)? = g["cameraSessionId"] { session = s }
        if case .string(let u)? = g["use"] { use = u }
        guard key != nil || url != nil || session != nil else { return nil }
        return Input(slot: "guide", kind: "video", label: "Blender guide", role: use ?? "blocking", cameraSessionId: session, key: key, url: url, seconds: seconds)
    }

    /// The draft's `screen`: the tool, the request Generate would send now (nil when it can't be built yet) and the inputs.
    /// `at` nil leaves the time out (to compare a screen with the one last sent).
    public static func json(tool: String, request: ShotRequest?, inputs: [Input], at: Date? = Date()) -> JSONValue {
        var o: [String: JSONValue] = ["tool": .string(tool), "inputs": .array(inputs.prefix(24).map(\.json))]
        if let at { o["at"] = .number((at.timeIntervalSince1970 * 1000).rounded()) }
        if var r = request {
            r.draft = nil // the draft itself is not repeated inside it
            if let j = JSONValue.encoding(r) { o["request"] = j }
        }
        return .object(o)
    }
}
