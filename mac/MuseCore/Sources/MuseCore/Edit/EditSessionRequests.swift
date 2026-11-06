import Foundation

// Edit sessions (workstream 3): what the Mac does with Claude's requests (plans/claude-editing.md A). Pure helpers so the
// rules are tested on Linux; the app renders, saves and exports.

extension EditSuite.ExportSettings {
    /// The export settings with the preset Claude chose (`export_video`: ratio, resolution, fps, codec, captions). The owner's
    /// disclosure switches (AI label, Content Credentials) are never taken from a preset: they stay as they are.
    public func applying(preset: [String: JSONValue]?) -> EditSuite.ExportSettings {
        var s = self
        guard let preset else { return s }
        if case .string(let r)? = preset["ratio"], let v = EditSuite.Ratio(rawValue: r) { s.ratio = v }
        if case .string(let r)? = preset["resolution"] {
            switch r.lowercased() {
            case "720p", "720": s.resolution = .p720
            case "1080p", "1080": s.resolution = .p1080
            case "4k", "2160p", "2160": s.resolution = .k4
            default: break
            }
        }
        if case .number(let f)? = preset["fps"], EditSuite.ExportSettings.frameRates.contains(Int(f)) { s.fps = Int(f) }
        if case .string(let c)? = preset["codec"], let v = EditSuite.Codec(rawValue: c.lowercased()) { s.codec = v }
        if case .string(let c)? = preset["captions"] {
            switch c.lowercased() {
            case "burn", "burnin", "burn_in": s.captions = .burnIn
            case "srt": s.captions = .srt
            default: break
            }
        }
        return s
    }
}

extension EditHistoryEntry {
    /// The toast when Claude's change lands: "Claude · Look · film-gold 70 %".
    public var claudeToast: String { "Claude · \(label)" }

    /// Who made it, for the history list ("Claude", "This Mac", "Phone"…). `device` is this app's device id.
    public func who(thisDevice device: String) -> String {
        if byClaude { return "Claude" }
        if author == "app:\(device)" { return "This Mac" }
        return "Another device"
    }
}

/// The exact-frame size Claude asked for: `width` (clamped 64…2160) and the canvas's shape.
public func editFrameSize(canvas: EditV2.Canvas, width: Int) -> (width: Int, height: Int) {
    let w = min(2160, max(64, width))
    let h = Int((Double(w) * Double(canvas.height) / Double(max(1, canvas.width))).rounded())
    return (w, max(1, h))
}

/// A stable id for this Mac in edit sessions ("mac-1a2b3c4d"), kept in `defaults`.
public func editSessionDeviceId(_ defaults: UserDefaults = .standard) -> String {
    let key = "muse.editSessions.device"
    if let d = defaults.string(forKey: key), !d.isEmpty { return d }
    let d = "mac-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
    defaults.set(d, forKey: key)
    return d
}
