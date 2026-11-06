import Foundation

/// Tool calls as human chips: "Trimmed 0:03–0:05", "Applied Look · Golden warmth", "Saved camera path", "Shot draft · $1.92".
/// Tools MUSE doesn't know get their name in words ("detect_scene_cuts" → "Detect scene cuts").
public enum ClaudeChipText {
    /// "mcp__muse__apply_edit_ops" → "apply_edit_ops"; "mcp__blender__get_scene_info" → "blender_get_scene_info".
    public static func shortName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__muse__") { return String(tool.dropFirst("mcp__muse__".count)) }
        if tool.hasPrefix("mcp__blender__") {
            let rest = String(tool.dropFirst("mcp__blender__".count))
            return rest.hasPrefix("blender_") ? rest : "blender_" + rest
        }
        if tool.hasPrefix("mcp__"), let r = tool.range(of: "__", range: tool.index(tool.startIndex, offsetBy: 5)..<tool.endIndex) {
            return String(tool[r.upperBound...])
        }
        return tool
    }

    /// "cut_silences" → "Cut silences".
    public static func words(_ tool: String) -> String {
        let s = shortName(tool).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let f = s.first else { return "Tool" }
        return f.uppercased() + s.dropFirst()
    }

    /// 3.2 → "0:03"; 75 → "1:15".
    public static func time(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "golden_warmth" / "golden-warmth" → "Golden warmth"; a human name stays as it is.
    public static func label(_ id: String) -> String {
        guard id.contains("_") || id.contains("-") || id == id.lowercased() else { return id }
        let s = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let f = s.first else { return id }
        return f.uppercased() + s.dropFirst()
    }

    /// The chip for a tool while it runs (input only) or when its result is in.
    public static func summary(tool: String, input: JSONValue?, result: String? = nil, isError: Bool = false) -> String {
        let base = describe(shortName(tool), input: object(input), result: result.flatMap(parseResult))
        return isError ? "\(base) · failed" : base
    }

    // MARK: Per tool

    private static func describe(_ name: String, input a: [String: JSONValue], result r: [String: JSONValue]?) -> String {
        switch name {
        // Camera
        case "set_camera_path": return "Saved camera path"
        case "create_shot_draft":
            if let usd = money(r) { return "Shot draft · $" + String(format: "%.2f", usd) }
            return "Shot draft"
        case "get_camera_session": return "Read the camera session"
        case "list_camera_sessions": return "Looked at camera sessions"
        case "create_camera_session": return a.jStr("title").map { "New camera session · \($0)" } ?? "New camera session"
        case "update_camera_session": return "Updated the session"
        case "post_camera_message": return "Left a note"
        case "list_characters": return "Looked at the cast"
        case "list_presets": return "Looked at camera presets"
        case "attach_guide_media": return a.jStr("kind").map { "Upload link · \(label($0))" } ?? "Upload link"
        case "confirm_guide_media": return "Guide ready"
        // Edit
        case "list_takes": return "Looked at takes"
        case "open_edit": return "Opened the edit"
        case "get_edit": return "Read the edit"
        case "list_looks": return "Looked at Looks"
        case "list_caption_styles": return "Looked at caption styles"
        case "apply_edit_ops":
            let ops = a.jArr("ops").compactMap { v -> [String: JSONValue]? in if case .object(let o) = v { return o }; return nil }
            guard let first = ops.first else { return "Edited" }
            let head = op(first)
            return ops.count > 1 ? "\(head) + \(ops.count - 1) more" : head
        case "auto_captions": return "Added captions"
        case "cut_silences": return "Cut silences"
        case "cut_fillers": return "Cut filler words"
        case "remove_background": return "Removed background"
        case "detect_beats": return "Found the beats"
        case "denoise": return "Cleaned up the audio"
        case "get_frame": return a.jNum("t").map { "Grabbed frame · \(time($0))" } ?? "Grabbed a frame"
        case "get_contact_sheet": return "Contact sheet"
        case "save_version": return a.jStr("name").map { "Saved version · \($0)" } ?? "Saved a version"
        case "export": return a.jStr("preset").map { "Export · \(label($0))" } ?? "Export"
        default:
            if name.hasPrefix("blender_") {
                return "Blender · " + words(String(name.dropFirst("blender_".count))).lowercased()
            }
            // A single op called as its own tool (trim, split, look…).
            if let o = opText(name, a) { return o }
            return words(name)
        }
    }

    /// One edit op (`op`, `type` or `kind` names it).
    static func op(_ o: [String: JSONValue]) -> String {
        let kind = o.jStr("op") ?? o.jStr("type") ?? o.jStr("kind") ?? ""
        return opText(kind, o) ?? (kind.isEmpty ? "Edited" : words(kind))
    }

    private static func range(_ o: [String: JSONValue]) -> String? {
        let pairs = [("inSec", "outSec"), ("startSec", "endSec"), ("from", "to"), ("start", "end"), ("fromSec", "toSec")]
        for (a, b) in pairs { if let x = o.jNum(a), let y = o.jNum(b) { return "\(time(x))–\(time(y))" } }
        return nil
    }

    private static func opText(_ kind: String, _ o: [String: JSONValue]) -> String? {
        switch kind.lowercased() {
        case "trim": return range(o).map { "Trimmed \($0)" } ?? "Trimmed"
        case "split": return (o.jNum("atSec") ?? o.jNum("t") ?? o.jNum("at")).map { "Split at \(time($0))" } ?? "Split"
        case "delete", "ripple", "ripple_delete": return range(o).map { "Cut \($0)" } ?? "Deleted a clip"
        case "move": return "Moved a clip"
        case "speed":
            if let s = o.jNum("speed") ?? o.jNum("rate") { return "Speed \(trim(s))×" }
            return "Changed speed"
        case "text", "add_text": return o.jStr("text").map { "Added text “\(short($0))”" } ?? "Added text"
        case "caption", "add_caption": return "Added a caption"
        case "hook", "add_hook": return o.jStr("text").map { "Hook “\(short($0))”" } ?? "Added a hook"
        case "caption_style": return (o.jStr("preset") ?? o.jStr("style")).map { "Caption style · \(label($0))" } ?? "Caption style"
        case "look", "apply_look":
            let name = o.jStr("name") ?? o.jStr("lookName") ?? o.jStr("look") ?? o.jStr("id") ?? o.jStr("lookId")
            var s = name.map { "Applied Look · \(label($0))" } ?? "Applied a Look"
            if let i = o.jNum("intensity") ?? o.jNum("amount") { s += " \(Int((i <= 1 ? i * 100 : i).rounded()))%" }
            return s
        case "adjust": return "Adjusted colour"
        case "transition": return (o.jStr("transition") ?? o.jStr("name") ?? o.jStr("style")).map { "Transition · \(label($0))" } ?? "Added a transition"
        case "mask": return "Added a mask"
        case "transform", "keyframe": return "Moved and scaled"
        case "volume", "audio_volume":
            if let v = o.jNum("volume") ?? o.jNum("level") { return "Volume \(Int((v * 100).rounded()))%" }
            return "Changed volume"
        case "duck", "audio_duck": return "Ducked the music"
        case "fade", "fades", "audio_fade", "audio_fades": return "Audio fades"
        case "voice_effect": return (o.jStr("effect") ?? o.jStr("preset")).map { "Voice · \(label($0))" } ?? "Voice effect"
        case "music", "music_track": return (o.jStr("title") ?? o.jStr("name")).map { "Music · \($0)" } ?? "Added music"
        case "ratio", "aspect": return (o.jStr("ratio") ?? o.jStr("aspect")).map { "Ratio \($0)" } ?? "Changed ratio"
        default: return nil
        }
    }

    // MARK: Helpers

    private static func object(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }

    /// Tool results are JSON text (MUSE's MCP server sends `JSON.stringify(data)`).
    private static func parseResult(_ s: String) -> [String: JSONValue]? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)), case .object(let o) = v else { return nil }
        return o
    }

    /// `estimate.usd` of a Shot draft (or of `{draft}` / `{shotDraft}`).
    private static func money(_ r: [String: JSONValue]?) -> Double? {
        guard let r else { return nil }
        if case .object(let e)? = r["estimate"], let usd = e.jNum("usd") { return usd }
        for k in ["shotDraft", "draft"] { if case .object(let d)? = r[k], let usd = money(d) { return usd } }
        return r.jNum("usd")
    }

    private static func trim(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : String(format: "%g", n) }
    private static func short(_ s: String) -> String { s.count > 28 ? String(s.prefix(27)) + "…" : s }
}
