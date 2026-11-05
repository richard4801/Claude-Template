import Foundation

// The shared preset tables (server/api/src/editor/presets.ts): filters, caption styles and hook templates. The fixture
// presets.json is the reference's copy; EditV2PresetTests checks these tables equal it.

extension EditV2 {
    public struct HookTemplate: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var text: String
        public var durationSec: Double
        public var style: TextStyle
        public var transform: Transform
        public var animIn: Anim
        public var animOut: Anim?

        public init(id: String, label: String, text: String, durationSec: Double, style: TextStyle, transform: Transform, animIn: Anim, animOut: Anim? = nil) {
            self.id = id; self.label = label; self.text = text; self.durationSec = durationSec; self.style = style; self.transform = transform
            self.animIn = animIn; self.animOut = animOut
        }

        /// A text item made from this template (`template` records the id).
        public func item(id: String, startSec: Double, text: String? = nil) -> TextItem {
            TextItem(id: id, startSec: startSec, durationSec: durationSec, text: text ?? self.text, style: style, transform: transform,
                     animIn: animIn, animOut: animOut, template: self.id)
        }
    }

    public static let filters: [FilterPreset] = [
        FilterPreset(id: "none", label: "Original", adjust: Adjust()),
        FilterPreset(id: "warm", label: "Warm", adjust: Adjust(saturation: 0.1, temperature: 0.6)),
        FilterPreset(id: "cool", label: "Cool", adjust: Adjust(contrast: 0.05, temperature: -0.6)),
        FilterPreset(id: "vivid", label: "Vivid", adjust: Adjust(contrast: 0.15, saturation: 0.35)),
        FilterPreset(id: "mono", label: "Mono", adjust: Adjust(contrast: 0.1, saturation: -1)),
        FilterPreset(id: "fade", label: "Faded", adjust: Adjust(exposure: 0.05, contrast: -0.25, saturation: -0.2)),
        FilterPreset(id: "film", label: "Film", adjust: Adjust(contrast: 0.1, saturation: -0.15, temperature: 0.2), tint: Tint(color: "#F2C48D", strength: 0.08)),
        FilterPreset(id: "moody", label: "Moody", adjust: Adjust(exposure: -0.2, contrast: 0.2, saturation: -0.3, temperature: -0.25)),
        FilterPreset(id: "golden", label: "Golden hour", adjust: Adjust(exposure: 0.05, saturation: 0.15, temperature: 0.8), tint: Tint(color: "#FFB347", strength: 0.1)),
        FilterPreset(id: "pastel", label: "Pastel", adjust: Adjust(exposure: 0.15, contrast: -0.2, saturation: -0.1), tint: Tint(color: "#FADADD", strength: 0.08)),
        FilterPreset(id: "noir", label: "Noir", adjust: Adjust(exposure: -0.1, contrast: 0.45, saturation: -1)),
        FilterPreset(id: "punch", label: "Punch", adjust: Adjust(exposure: 0.05, contrast: 0.3, saturation: 0.25)),
    ]

    /// The reference's `base()` text style with changes.
    private static func base(_ change: (inout TextStyle) -> Void = { _ in }) -> TextStyle {
        var s = TextStyle(font: .sans, weight: 900, sizePct: 0.045, color: "#FFFFFF", align: .center, maxWidthPct: 0.85, lineHeight: 1.15)
        change(&s)
        return s
    }

    /// Default style per caption preset (a caption track starts from these).
    public static let captionStyles: [CaptionPreset: CaptionStyle] = [
        .plain: CaptionStyle(base { $0.weight = 700; $0.sizePct = 0.035; $0.shadow = Shadow(color: "#000000", opacity: 0.6, blurPct: 0.15, dyPct: 0.04) },
                             preset: .plain, highlightColor: "#FFFFFF", y: 0.8, wordsPerPage: 6, maxLines: 2),
        .highlight: CaptionStyle(base { $0.stroke = Stroke(color: "#000000", widthPct: 0.12) }, preset: .highlight, highlightColor: "#FFE600", y: 0.72,
                                 wordsPerPage: 3, maxLines: 2),
        .box: CaptionStyle(base { $0.weight = 700; $0.sizePct = 0.042 }, preset: .box, highlightColor: "#7C3AED", y: 0.72, wordsPerPage: 3, maxLines: 2),
        .karaoke: CaptionStyle(base { $0.stroke = Stroke(color: "#000000", widthPct: 0.1) }, preset: .karaoke, highlightColor: "#22D3EE", y: 0.72,
                               wordsPerPage: 4, maxLines: 2),
        .pop: CaptionStyle(base { $0.sizePct = 0.05; $0.uppercase = true; $0.stroke = Stroke(color: "#000000", widthPct: 0.14) }, preset: .pop,
                           highlightColor: "#FFE600", y: 0.7, wordsPerPage: 2, maxLines: 1),
        .single: CaptionStyle(base { $0.sizePct = 0.065; $0.uppercase = true; $0.stroke = Stroke(color: "#000000", widthPct: 0.14) }, preset: .single,
                              highlightColor: "#FFFFFF", y: 0.6, wordsPerPage: 1, maxLines: 1),
        // Edit suite: a marker stripe behind the active word; a neon glow.
        .highlighter: CaptionStyle(base { $0.weight = 900; $0.sizePct = 0.045; $0.uppercase = true; $0.color = "#FFFFFF"; $0.stroke = Stroke(color: "#000000", widthPct: 0.08) },
                                   preset: .highlighter, highlightColor: "#22C55E", y: 0.72, wordsPerPage: 3, maxLines: 2),
        .neon: CaptionStyle(base { $0.weight = 900; $0.sizePct = 0.045; $0.uppercase = true; $0.color = "#FFD1E8"; $0.shadow = Shadow(color: "#FF2D87", opacity: 0.9, blurPct: 0.5, dyPct: 0) },
                            preset: .neon, highlightColor: "#FF2D87", y: 0.72, wordsPerPage: 3, maxLines: 2),
    ]


    public static func captionStyle(_ p: CaptionPreset) -> CaptionStyle { captionStyles[p]! }

    /// Ready hook/text templates: choosing one copies style, position and animations into a TextItem.
    public static let hooks: [HookTemplate] = [
        HookTemplate(id: "hook-bold", label: "Bold hook", text: "Wait for it…", durationSec: 3,
                     style: base { $0.sizePct = 0.06; $0.stroke = Stroke(color: "#000000", widthPct: 0.14) },
                     transform: Transform(x: 0.5, y: 0.2), animIn: Anim(kind: .pop, durationSec: 0.35)),
        HookTemplate(id: "hook-box", label: "Boxed", text: "POV: you finally tried it", durationSec: 3,
                     style: base { $0.weight = 700; $0.sizePct = 0.04; $0.color = "#111111"; $0.background = TextBackground(color: "#FFFFFF", opacity: 1, paddingPct: 0.35, radiusPct: 0.25) },
                     transform: Transform(x: 0.5, y: 0.18), animIn: Anim(kind: .slideUp, durationSec: 0.3)),
        HookTemplate(id: "hook-question", label: "Question", text: "Would you try this?", durationSec: 3,
                     style: base { $0.sizePct = 0.05; $0.color = "#FFE600"; $0.stroke = Stroke(color: "#000000", widthPct: 0.12) },
                     transform: Transform(x: 0.5, y: 0.25), animIn: Anim(kind: .zoom, durationSec: 0.4)),
        HookTemplate(id: "hook-typewriter", label: "Typewriter", text: "Things nobody tells you about…", durationSec: 4,
                     style: base { $0.font = .mono; $0.weight = 700; $0.sizePct = 0.035; $0.align = .left; $0.background = TextBackground(color: "#000000", opacity: 0.6, paddingPct: 0.3, radiusPct: 0.1) },
                     transform: Transform(x: 0.5, y: 0.2), animIn: Anim(kind: .typewriter, durationSec: 1.5)),
        HookTemplate(id: "hook-list", label: "Top 3", text: "3 things I wish I knew", durationSec: 3,
                     style: base { $0.font = .condensed; $0.sizePct = 0.06; $0.uppercase = true; $0.stroke = Stroke(color: "#000000", widthPct: 0.1) },
                     transform: Transform(x: 0.5, y: 0.15), animIn: Anim(kind: .slideDown, durationSec: 0.3)),
        HookTemplate(id: "hook-marker", label: "Marker", text: "honestly obsessed", durationSec: 3,
                     style: base { $0.font = .marker; $0.weight = 400; $0.sizePct = 0.06; $0.color = "#FF4D8D" },
                     transform: Transform(x: 0.5, y: 0.3, rotation: -6), animIn: Anim(kind: .pop, durationSec: 0.3)),
        HookTemplate(id: "hook-before", label: "Before / after", text: "BEFORE", durationSec: 2,
                     style: base { $0.font = .condensed; $0.sizePct = 0.07; $0.background = TextBackground(color: "#EF4444", opacity: 1, paddingPct: 0.25, radiusPct: 0.15) },
                     transform: Transform(x: 0.5, y: 0.12), animIn: Anim(kind: .fade, durationSec: 0.2)),
        HookTemplate(id: "hook-serif", label: "Elegant", text: "a little routine", durationSec: 3,
                     style: base { $0.font = .serif; $0.weight = 400; $0.sizePct = 0.05; $0.shadow = Shadow(color: "#000000", opacity: 0.5, blurPct: 0.2, dyPct: 0.03) },
                     transform: Transform(x: 0.5, y: 0.5), animIn: Anim(kind: .fade, durationSec: 0.6), animOut: Anim(kind: .fade, durationSec: 0.4)),
        HookTemplate(id: "hook-stop", label: "Stop scrolling", text: "STOP SCROLLING", durationSec: 2,
                     style: base { $0.sizePct = 0.07; $0.color = "#FFFFFF"; $0.stroke = Stroke(color: "#EF4444", widthPct: 0.16) },
                     transform: Transform(x: 0.5, y: 0.45), animIn: Anim(kind: .zoom, durationSec: 0.25)),
        HookTemplate(id: "hook-caption", label: "Lower third", text: "Day 1 of trying this", durationSec: 3,
                     style: base { $0.weight = 700; $0.sizePct = 0.035; $0.align = .left; $0.background = TextBackground(color: "#111111", opacity: 0.8, paddingPct: 0.3, radiusPct: 0.2) },
                     transform: Transform(x: 0.4, y: 0.85), animIn: Anim(kind: .slideUp, durationSec: 0.3), animOut: Anim(kind: .fade, durationSec: 0.3)),
    ]
}
