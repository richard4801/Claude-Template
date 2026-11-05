package studio.muse.core.edit

/**
 * The shared editor presets (server/api/src/editor/presets.ts): filters, caption styles and hook-text templates. The
 * same tables as the server's, checked against the fixture presets.json.
 */
data class HookTemplate(
    val id: String,
    val label: String,
    val text: String,
    val durationSec: Double,
    val style: TextStyle,
    val transform: Transform,
    val animIn: Anim,
    val animOut: Anim? = null,
) {
    /** A text item made from this template (the template's style, position and animations; `template` = its id). */
    fun toItem(id: String, startSec: Double, text: String = this.text) =
        TextItem(id, startSec, durationSec, text, style, transform = transform, animIn = animIn, animOut = animOut, template = this.id)
}

object Presets {
    val FILTERS: List<FilterPreset> = listOf(
        FilterPreset("none", "Original", Adjust()),
        FilterPreset("warm", "Warm", Adjust(temperature = 0.6, saturation = 0.1)),
        FilterPreset("cool", "Cool", Adjust(temperature = -0.6, contrast = 0.05)),
        FilterPreset("vivid", "Vivid", Adjust(saturation = 0.35, contrast = 0.15)),
        FilterPreset("mono", "Mono", Adjust(saturation = -1.0, contrast = 0.1)),
        FilterPreset("fade", "Faded", Adjust(contrast = -0.25, saturation = -0.2, exposure = 0.05)),
        FilterPreset("film", "Film", Adjust(contrast = 0.1, saturation = -0.15, temperature = 0.2), Tint("#F2C48D", 0.08)),
        FilterPreset("moody", "Moody", Adjust(exposure = -0.2, contrast = 0.2, saturation = -0.3, temperature = -0.25)),
        FilterPreset("golden", "Golden hour", Adjust(exposure = 0.05, temperature = 0.8, saturation = 0.15), Tint("#FFB347", 0.1)),
        FilterPreset("pastel", "Pastel", Adjust(exposure = 0.15, contrast = -0.2, saturation = -0.1), Tint("#FADADD", 0.08)),
        FilterPreset("noir", "Noir", Adjust(saturation = -1.0, contrast = 0.45, exposure = -0.1)),
        FilterPreset("punch", "Punch", Adjust(contrast = 0.3, saturation = 0.25, exposure = 0.05)),
    )

    private fun base(
        font: Font = Font.SANS, weight: Int = 900, sizePct: Double = 0.045, color: String = "#FFFFFF", align: Align = Align.CENTER,
        uppercase: Boolean? = null, stroke: Stroke? = null, shadow: Shadow? = null, background: TextBackground? = null,
    ) = TextStyle(font, weight, sizePct, color, align, maxWidthPct = 0.85, lineHeight = 1.15, uppercase = uppercase, stroke = stroke, shadow = shadow, background = background)

    private val BLACK_STROKE_12 = Stroke("#000000", 0.12)
    private val BLACK_STROKE_14 = Stroke("#000000", 0.14)

    /** Default style per caption preset (a new caption track starts from these). */
    val CAPTION_STYLES: Map<CaptionPreset, CaptionStyle> = linkedMapOf(
        CaptionPreset.PLAIN to CaptionStyle(base(weight = 700, sizePct = 0.035, shadow = Shadow("#000000", 0.6, 0.15, 0.04)), CaptionPreset.PLAIN, "#FFFFFF", 0.8, 6, 2),
        CaptionPreset.HIGHLIGHT to CaptionStyle(base(stroke = BLACK_STROKE_12), CaptionPreset.HIGHLIGHT, "#FFE600", 0.72, 3, 2),
        CaptionPreset.BOX to CaptionStyle(base(weight = 700, sizePct = 0.042), CaptionPreset.BOX, "#7C3AED", 0.72, 3, 2),
        CaptionPreset.KARAOKE to CaptionStyle(base(stroke = Stroke("#000000", 0.1)), CaptionPreset.KARAOKE, "#22D3EE", 0.72, 4, 2),
        CaptionPreset.POP to CaptionStyle(base(sizePct = 0.05, uppercase = true, stroke = BLACK_STROKE_14), CaptionPreset.POP, "#FFE600", 0.7, 2, 1),
        CaptionPreset.SINGLE to CaptionStyle(base(sizePct = 0.065, uppercase = true, stroke = BLACK_STROKE_14), CaptionPreset.SINGLE, "#FFFFFF", 0.6, 1, 1),
        /** Active word gets a marker stripe (highlightColor, lower 45 % of the line) behind it. */
        CaptionPreset.HIGHLIGHTER to CaptionStyle(base(uppercase = true, stroke = Stroke("#000000", 0.08)), CaptionPreset.HIGHLIGHTER, "#22C55E", 0.72, 3, 2),
        /** Text glows in highlightColor (shadow blur, no offset); the active word is pure highlightColor. */
        CaptionPreset.NEON to CaptionStyle(base(uppercase = true, color = "#FFD1E8", shadow = Shadow("#FF2D87", 0.9, 0.5, 0.0)), CaptionPreset.NEON, "#FF2D87", 0.72, 3, 2),
    )

    /** The names the Edit suite shows (design E1/E3, EM2), in its order; `highlight` and `single` stay for older projects. */
    val CAPTION_STYLE_LABELS: List<Pair<CaptionPreset, String>> = listOf(
        CaptionPreset.POP to "Word pop", CaptionPreset.KARAOKE to "Karaoke", CaptionPreset.BOX to "Bold box", CaptionPreset.PLAIN to "Minimal",
        CaptionPreset.HIGHLIGHTER to "Highlighter", CaptionPreset.NEON to "Neon", CaptionPreset.HIGHLIGHT to "Highlight", CaptionPreset.SINGLE to "One word",
    )

    /** Transition names in the Edit suite (design E2): "cut" = no transition. */
    val TRANSITION_LABELS: List<Pair<String, String>> = listOf(
        "cut" to "Cut", "fade" to "X-fade", "zoom" to "Zoom", "whip" to "Whip", "slideLeft" to "Slide", "white" to "Flash",
        "glitch" to "Glitch", "spin" to "Spin", "black" to "Dip to black",
    )

    /** The transition a label row means (null = Cut). */
    fun transitionOf(wire: String): TransitionKind? = if (wire == "cut") null else wireOf<TransitionKind>(wire)

    /** Ready hook/text templates: choosing one copies style, position and animations into a TextItem. */
    val HOOKS: List<HookTemplate> = listOf(
        HookTemplate("hook-bold", "Bold hook", "Wait for it…", 3.0, base(sizePct = 0.06, stroke = BLACK_STROKE_14), Transform(x = 0.5, y = 0.2), Anim(AnimKind.POP, 0.35)),
        HookTemplate("hook-box", "Boxed", "POV: you finally tried it", 3.0,
            base(weight = 700, sizePct = 0.04, color = "#111111", background = TextBackground("#FFFFFF", 1.0, 0.35, 0.25)), Transform(x = 0.5, y = 0.18), Anim(AnimKind.SLIDE_UP, 0.3)),
        HookTemplate("hook-question", "Question", "Would you try this?", 3.0,
            base(sizePct = 0.05, color = "#FFE600", stroke = BLACK_STROKE_12), Transform(x = 0.5, y = 0.25), Anim(AnimKind.ZOOM, 0.4)),
        HookTemplate("hook-typewriter", "Typewriter", "Things nobody tells you about…", 4.0,
            base(font = Font.MONO, weight = 700, sizePct = 0.035, align = Align.LEFT, background = TextBackground("#000000", 0.6, 0.3, 0.1)),
            Transform(x = 0.5, y = 0.2), Anim(AnimKind.TYPEWRITER, 1.5)),
        HookTemplate("hook-list", "Top 3", "3 things I wish I knew", 3.0,
            base(font = Font.CONDENSED, sizePct = 0.06, uppercase = true, stroke = Stroke("#000000", 0.1)), Transform(x = 0.5, y = 0.15), Anim(AnimKind.SLIDE_DOWN, 0.3)),
        HookTemplate("hook-marker", "Marker", "honestly obsessed", 3.0,
            base(font = Font.MARKER, weight = 400, sizePct = 0.06, color = "#FF4D8D"), Transform(x = 0.5, y = 0.3, rotation = -6.0), Anim(AnimKind.POP, 0.3)),
        HookTemplate("hook-before", "Before / after", "BEFORE", 2.0,
            base(font = Font.CONDENSED, sizePct = 0.07, background = TextBackground("#EF4444", 1.0, 0.25, 0.15)), Transform(x = 0.5, y = 0.12), Anim(AnimKind.FADE, 0.2)),
        HookTemplate("hook-serif", "Elegant", "a little routine", 3.0,
            base(font = Font.SERIF, weight = 400, sizePct = 0.05, shadow = Shadow("#000000", 0.5, 0.2, 0.03)), Transform(x = 0.5, y = 0.5),
            Anim(AnimKind.FADE, 0.6), Anim(AnimKind.FADE, 0.4)),
        HookTemplate("hook-stop", "Stop scrolling", "STOP SCROLLING", 2.0,
            base(sizePct = 0.07, color = "#FFFFFF", stroke = Stroke("#EF4444", 0.16)), Transform(x = 0.5, y = 0.45), Anim(AnimKind.ZOOM, 0.25)),
        HookTemplate("hook-caption", "Lower third", "Day 1 of trying this", 3.0,
            base(weight = 700, sizePct = 0.035, align = Align.LEFT, background = TextBackground("#111111", 0.8, 0.3, 0.2)), Transform(x = 0.4, y = 0.85),
            Anim(AnimKind.SLIDE_UP, 0.3), Anim(AnimKind.FADE, 0.3)),
    )

    fun filter(id: String): FilterPreset? = FILTERS.firstOrNull { it.id == id }
    fun hook(id: String): HookTemplate? = HOOKS.firstOrNull { it.id == id }
}
