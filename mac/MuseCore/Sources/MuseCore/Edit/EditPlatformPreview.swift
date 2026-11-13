import Foundation

// Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md). The platform views left the take
// viewer and came here, merged with Edit's safe-area guide:
// - View: Clean · TikTok · Reels · Shorts · Facebook (portrait, square, 4:5) or Clean · YouTube · Facebook (16:9). A platform
//   view draws that app's generic chrome over the edit; Clean draws nothing.
// - Safe area: a switch that works in every view. A platform view shows that app's red box; Clean shows the box that is
//   safe on every app; landscape views use their own boxes.
// - Remembered per project, falling back to this device's last choice.
// - The check that warns when captions or text sit outside the box (the app's warning line; the server runs the same
//   check for Claude: server/api/src/editor/safeArea.ts).

/// What Edit's preview shows.
public struct EditPreview: Codable, Hashable, Sendable {
    public var view: PreviewSkin
    public var safeArea: Bool

    public init(view: PreviewSkin = .clean, safeArea: Bool = true) {
        self.view = view
        self.safeArea = safeArea
    }

    /// The views for a canvas of this shape.
    public static func options(width: Int, height: Int) -> [PreviewSkin] {
        PreviewSkin.options(aspect: Double(width) / Double(max(1, height)))
    }

    /// The view this canvas can show: one the shape doesn't offer (TikTok on a 16:9 project) becomes Clean.
    public func resolved(width: Int, height: Int) -> EditPreview {
        EditPreview(view: Self.options(width: width, height: height).contains(view) ? view : .clean, safeArea: safeArea)
    }

    public static func isLandscape(width: Int, height: Int) -> Bool { PreviewSkin.isLandscape(Double(width) / Double(max(1, height))) }
}

// MARK: The red box

public enum EditSafeBox {
    /// Landscape: the classic title-safe margin in Clean.
    public static let titleSafe = SafeZone(top: 0.05, bottom: 0.05, left: 0.05, right: 0.05)

    /// The box for a view on a canvas of this shape (nil: the switch is off).
    public static func zone(_ p: EditPreview, width: Int, height: Int, layouts: PreviewLayouts = .defaults) -> SafeZone? {
        guard p.safeArea else { return nil }
        let v = p.resolved(width: width, height: height).view
        if EditPreview.isLandscape(width: width, height: height) {
            return v == .clean ? titleSafe : layouts.landscapeZone(v)
        }
        return v == .clean ? everyApp(layouts) : layouts.zone(v)
    }

    /// The box that is safe on every portrait app: the largest inset of each side.
    public static func everyApp(_ l: PreviewLayouts = .defaults) -> SafeZone {
        let zs = [PreviewSkin.tiktok, .reels, .shorts, .facebook].compactMap { l.zone($0) }
        return SafeZone(top: zs.map(\.top).max() ?? 0, bottom: zs.map(\.bottom).max() ?? 0,
                        left: zs.map(\.left).max() ?? 0, right: zs.map(\.right).max() ?? 0)
    }

    /// What the box is, for its tooltip and the warning line.
    public static func name(_ p: EditPreview, width: Int, height: Int) -> String {
        let v = p.resolved(width: width, height: height).view
        if v == .clean { return EditPreview.isLandscape(width: width, height: height) ? "the title-safe area" : "the area safe on every app" }
        return "\(v.label)'s safe area"
    }

    /// What the app's own chrome covers, for the warning line ("TikTok's caption and buttons").
    public static func covers(_ p: EditPreview, width: Int, height: Int) -> String {
        let v = p.resolved(width: width, height: height).view
        switch v {
        case .clean: return EditPreview.isLandscape(width: width, height: height) ? "the edge of some screens" : "some apps' captions and buttons"
        case .youtube: return "YouTube's title and controls"
        default: return EditPreview.isLandscape(width: width, height: height) ? "\(v.label)'s controls" : "\(v.label)'s caption and buttons"
        }
    }
}

// MARK: Captions and text outside the box

/// Captions or a text item outside the red box.
public struct SafeAreaIssue: Hashable, Sendable {
    public enum Kind: String, Sendable { case captions, text }
    public var kind: Kind
    /// The text item's id (nil for captions).
    public var itemId: String?
    public var startSec: Double
    public var endSec: Double
    /// Which edges cross the box: top, bottom, left, right.
    public var edges: [String]
}

/// An approximate box for a block of text (fractions of the canvas): the same estimate the server uses.
public struct TextBox: Hashable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public var left: Double { x - w / 2 }
    public var right: Double { x + w / 2 }
    public var top: Double { y - h / 2 }
    public var bottom: Double { y + h / 2 }

    /// A block of `text` at centre (x, y): its size from the font size (of the canvas height), the wrap width and the
    /// lines. Average glyph width ≈ 0.55 em (0.62 uppercase); good enough for a warning, not for layout.
    public static func estimate(text: String, x: Double, y: Double, sizePct: Double, maxWidthPct: Double?, lineHeight: Double?,
                                uppercase: Bool, maxLines: Int?, canvasAspect: Double) -> TextBox {
        let em = sizePct / max(0.1, canvasAspect)          // font size as a fraction of the canvas WIDTH
        let glyph = em * (uppercase ? 0.62 : 0.55)
        let wrap = maxWidthPct ?? 0.85
        var lines = 0
        var widest = 0.0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let w = Double(raw.count) * glyph
            let n = max(1, Int((w / max(0.01, wrap)).rounded(.up)))
            lines += n
            widest = max(widest, min(w, wrap))
        }
        if let m = maxLines { lines = min(lines, max(1, m)) }
        let h = Double(max(1, lines)) * sizePct * (lineHeight ?? 1.15)
        return TextBox(x: x, y: y, w: widest, h: h)
    }

    /// The edges outside the zone (a 0.5 % tolerance).
    public func edges(outside z: SafeZone) -> [String] {
        let r = z.safeRect, tol = 0.005
        var e: [String] = []
        if top < r.y - tol { e.append("top") }
        if bottom > r.y + r.h + tol { e.append("bottom") }
        if left < r.x - tol { e.append("left") }
        if right > r.x + r.w + tol { e.append("right") }
        return e
    }
}

public enum EditSafeCheck {
    public typealias E = EditV2

    /// Captions (each caption page) and text items (at rest: their own position, without animation, pins or keyframes)
    /// outside the zone. Captions come back as one issue covering every page that crosses the box.
    public static func issues(_ p: E.Project, zone: SafeZone) -> [SafeAreaIssue] {
        let aspect = Double(p.canvas.width) / Double(max(1, p.canvas.height))
        var out: [SafeAreaIssue] = []
        if let ct = p.captionTrack, !(p.tracks.first { $0.kind == .caption }?.hidden ?? false) {
            let s = ct.style
            var from: Double?, to = 0.0
            var edges = Set<String>()
            for page in E.captionPages(p) {
                let text = E.captionText(page.words.map(\.text), ct.language)
                let b = TextBox.estimate(text: text, x: 0.5, y: s.y ?? 0.72, sizePct: s.sizePct, maxWidthPct: s.maxWidthPct, lineHeight: s.lineHeight,
                                         uppercase: s.uppercase ?? false, maxLines: s.maxLines.map { Int($0) } ?? 2, canvasAspect: aspect)
                let e = b.edges(outside: zone)
                guard !e.isEmpty else { continue }
                if from == nil { from = page.startSec }
                to = max(to, page.endSec)
                edges.formUnion(e)
            }
            if let f = from { out.append(SafeAreaIssue(kind: .captions, itemId: nil, startSec: f, endSec: to, edges: order(edges))) }
        }
        for t in p.tracks where t.kind == .text && t.hidden != true {
            for case .text(let it) in t.items {
                let b = box(it, aspect: aspect)
                let e = b.edges(outside: zone)
                if !e.isEmpty { out.append(SafeAreaIssue(kind: .text, itemId: it.id, startSec: it.startSec, endSec: it.startSec + it.durationSec, edges: e)) }
            }
        }
        return out
    }

    public static func box(_ it: E.TextItem, aspect: Double) -> TextBox {
        let sc = it.transform?.scale ?? 1
        return TextBox.estimate(text: it.text, x: it.transform?.x ?? 0.5, y: it.transform?.y ?? 0.5, sizePct: it.style.sizePct * sc,
                                maxWidthPct: it.style.maxWidthPct.map { $0 * sc }, lineHeight: it.style.lineHeight,
                                uppercase: it.style.uppercase ?? false, maxLines: nil, canvasAspect: aspect)
    }

    private static func order(_ s: Set<String>) -> [String] { ["top", "bottom", "left", "right"].filter(s.contains) }

    /// The warning line: "Captions sit under TikTok's caption and buttons (0:01–0:09)." nil when everything is inside.
    public static func line(_ issues: [SafeAreaIssue], covers: String) -> String? {
        guard let first = issues.first else { return nil }
        let range = { (i: SafeAreaIssue) in "\(Take.clock(i.startSec))–\(Take.clock(i.endSec))" }
        let caps = issues.first { $0.kind == .captions }
        let texts = issues.filter { $0.kind == .text }
        if let c = caps, texts.isEmpty { return "Captions sit under \(covers) (\(range(c)))." }
        if caps == nil, texts.count == 1 { return "A text sits under \(covers) (\(range(first)))." }
        if caps == nil { return "\(texts.count) texts sit under \(covers)." }
        return "Captions and \(texts.count == 1 ? "a text" : "\(texts.count) texts") sit under \(covers)."
    }

    /// "Move into the safe area": the caption position and wrap width, and each text item's position, moved just inside
    /// the box (nothing else changes). Returns nil when nothing needed moving.
    public static func fixed(_ p: E.Project, zone: SafeZone) -> E.Project? {
        let r = zone.safeRect
        let aspect = Double(p.canvas.width) / Double(max(1, p.canvas.height))
        var q = p
        var changed = false
        let found = issues(p, zone: zone)
        let margin = 0.01
        if found.contains(where: { $0.kind == .captions }), let ti = q.tracks.firstIndex(where: { $0.kind == .caption && $0.caption != nil }) {
            var ct = q.tracks[ti].caption!
            // Wrap no wider than the box allows around the centre line, then the tallest page inside the box vertically.
            let half = min(0.5 - r.x, r.x + r.w - 0.5) - margin
            if half > 0.1, (ct.style.maxWidthPct ?? 0.85) > 2 * half { ct.style.maxWidthPct = (2 * half * 100).rounded(.down) / 100 }
            var tallest = 0.0
            for page in E.captionPages(p) {
                let b = TextBox.estimate(text: E.captionText(page.words.map(\.text), ct.language), x: 0.5, y: 0.5, sizePct: ct.style.sizePct,
                                         maxWidthPct: ct.style.maxWidthPct, lineHeight: ct.style.lineHeight, uppercase: ct.style.uppercase ?? false,
                                         maxLines: ct.style.maxLines.map { Int($0) } ?? 2, canvasAspect: aspect)
                tallest = max(tallest, b.h)
            }
            ct.style.y = clampCentre(ct.style.y ?? 0.72, half: tallest / 2, lo: r.y + margin, hi: r.y + r.h - margin)
            q.tracks[ti].caption = ct
            changed = true
        }
        for ti in q.tracks.indices where q.tracks[ti].kind == .text {
            for ii in q.tracks[ti].items.indices {
                guard case .text(var it) = q.tracks[ti].items[ii], found.contains(where: { $0.itemId == it.id }) else { continue }
                // Wrap no wider than the box, then the block's centre inside it.
                let room = r.w - 2 * margin
                if box(it, aspect: aspect).w > room, room > 0.1 {
                    it.style.maxWidthPct = (room / (it.transform?.scale ?? 1) * 100).rounded(.down) / 100
                }
                let b = box(it, aspect: aspect)
                var tr = it.transform ?? E.Transform()
                tr.x = clampCentre(b.x, half: b.w / 2, lo: r.x + margin, hi: r.x + r.w - margin)
                tr.y = clampCentre(b.y, half: b.h / 2, lo: r.y + margin, hi: r.y + r.h - margin)
                it.transform = tr
                q.tracks[ti].items[ii] = .text(it)
                changed = true
            }
        }
        return changed ? q : nil
    }

    /// A centre kept so [c − half, c + half] sits inside [lo, hi] (centred when it can't fit), to 3 decimals.
    static func clampCentre(_ c: Double, half: Double, lo: Double, hi: Double) -> Double {
        let v = hi - lo < 2 * half ? (lo + hi) / 2 : min(max(c, lo + half), hi - half)
        return (v * 1000).rounded() / 1000
    }
}

// MARK: Remembered per project

/// Edit's preview choice per project (keyed by the project's source take), and this device's last choice for a new one.
public struct EditPreviewPrefs: Codable, Hashable, Sendable {
    public var last: EditPreview?
    public var byProject: [String: EditPreview] = [:]
    /// Oldest first, so the map stays small.
    public var order: [String] = []
    public static let kept = 200

    public init() {}

    public func choice(for project: String) -> EditPreview { byProject[project] ?? last ?? EditPreview() }

    public mutating func set(_ p: EditPreview, for project: String) {
        last = p
        byProject[project] = p
        order.removeAll { $0 == project }
        order.append(project)
        while order.count > Self.kept { byProject[order.removeFirst()] = nil }
    }
}
