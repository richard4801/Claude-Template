package studio.muse.core.edit

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/*
 * Style kits (plans/edit-parity.md, M "Save your own edit as a template / style kit"): an edit's look, colour,
 * transition, caption and text styles and canvas background, saved by name (/v1/editor/kits) and applied to another
 * edit. Ports of server/api/src/editor/kit.ts (kitOf, applyKit, validateKit), checked against functions.json → kits.
 */

data class StyleKit(
    val look: Look? = null, val filter: FilterRef? = null, val adjust: Adjust? = null,
    val transition: Transition? = null,
    val captionStyle: CaptionStyle? = null, val textStyle: TextStyle? = null,
    val background: String? = null, val fill: CanvasFill? = null,
) {
    val isEmpty: Boolean get() = this == StyleKit()
}

private val KIT_KEYS = setOf("version", "look", "filter", "adjust", "transition", "captionStyle", "textStyle", "background", "fill")
private fun portableLut(lut: String?) = lut == null || lut.startsWith("pack:") || lut.startsWith("palette:")

/**
 * The style of [p] as a kit: the first main clip's look (a LUT only when it's a pack or palette look), filter and adjust;
 * the first transition; the caption style; the first text item's style; the canvas background and fill.
 */
fun kitOf(p: EditProject): StyleKit {
    val c = p.mainClips.firstOrNull()
    val look = c?.look?.let { l -> if (portableLut(l.lut)) l else l.copy(lut = null, strength = null) }?.takeIf { it != Look() }
    return StyleKit(
        look = look, filter = c?.filter, adjust = c?.adjust?.takeIf { it != Adjust() },
        transition = p.mainClips.firstOrNull { it.transitionIn != null }?.transitionIn,
        captionStyle = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION && it.caption != null }?.caption?.style,
        textStyle = (p.tracks.firstOrNull { it.kind == TrackKind.TEXT && it.items.isNotEmpty() }?.items?.first() as? TextItem)?.style,
        background = p.canvas.background, fill = p.canvas.fill,
    )
}

/**
 * [kit] applied to [p]: every main clip takes its look, filter and adjust (keyframes stay); every cut its transition,
 * at most half of each clip beside it (cuts too short for 0.1 s stay as they are); the caption track and every text item
 * its styles; the canvas its background and fill. What the kit leaves out stays.
 */
fun applyKit(p: EditProject, kit: StyleKit): EditProject {
    var main = p.mainClips.map { c ->
        c.copy(look = kit.look ?: c.look, filter = kit.filter ?: c.filter, adjust = kit.adjust ?: c.adjust)
    }
    kit.transition?.let { tr ->
        main = main.mapIndexed { i, c ->
            if (i == 0) c else {
                val d = kotlin.math.floor(minOf(tr.durationSec, clipLength(c) / 2, clipLength(main[i - 1]) / 2) * 1000) / 1000
                if (d >= EditLimits.MIN_TRANSITION_SEC) c.copy(transitionIn = Transition(tr.kind, d)) else c
            }
        }
    }
    val tracks = p.tracks.map { t ->
        when {
            t.kind == TrackKind.MAIN -> t.copy(items = main)
            t.kind == TrackKind.CAPTION && t.caption != null && kit.captionStyle != null -> t.copy(caption = t.caption.copy(style = kit.captionStyle))
            t.kind == TrackKind.TEXT && kit.textStyle != null -> t.copy(items = t.items.map { (it as? TextItem)?.copy(style = kit.textStyle) ?: it })
            else -> t
        }
    }
    return p.copy(tracks = tracks, canvas = p.canvas.copy(background = kit.background ?: p.canvas.background, fill = kit.fill ?: p.canvas.fill))
}

private val PROBE: EditProject by lazy {
    EditProject(
        sourceTakeId = "kit", canvas = Canvas(1080, 1920, 30.0),
        assets = listOf(Asset("v", AssetKind.VIDEO, take = "kit", durationSec = 10.0, width = 1080, height = 1920, hasAudio = true)),
        tracks = listOf(
            Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "v", 0.0, 4.0, 1.0), VideoClip("c2", "v", 4.0, 8.0, 1.0))),
            Track("txt", TrackKind.TEXT, items = listOf(TextItem("t1", 0.0, 2.0, "Kit", Presets.HOOKS[0].style))),
            Track("cap", TrackKind.CAPTION, caption = CaptionTrack("v", listOf(CaptionWord("kit", 0.0, 0.5)), Presets.CAPTION_STYLES.getValue(CaptionPreset.POP))),
        ),
    )
}

private val FIELD_MAP = listOf(
    Regex("^edits\\.tracks\\.0\\.items\\.\\d+\\.transitionIn") to "kit.transition",
    Regex("^edits\\.tracks\\.0\\.items\\.\\d+\\.(look|filter|adjust)") to "kit.$1",
    Regex("^edits\\.tracks\\.1\\.items\\.0\\.style") to "kit.textStyle",
    Regex("^edits\\.tracks\\.2\\.caption\\.style") to "kit.captionStyle",
    Regex("^edits\\.canvas\\.(background|fill)") to "kit.$1",
)

/**
 * A kit from its JSON, checked (throws [EditProblem] with a `kit.…` field): an object of the known keys at version 1, a
 * transition of a known kind at 0.1–2 s, a pack or palette look only, and every part valid where it lands (the edit
 * rules, on a small probe edit).
 */
fun parseKit(el: JsonElement, presets: List<FilterPreset> = Presets.FILTERS, lookIds: Set<String> = LookPack.IDS, paletteIds: Set<String> = emptySet()): StyleKit {
    val o = el as? JsonObject ?: throw EditProblem("kit", "must be an object")
    for (k in o.keys) if (k !in KIT_KEYS) throw EditProblem("kit.$k", "is not part of a style kit")
    val v = o["version"]
    if (v == null || (v as? kotlinx.serialization.json.JsonPrimitive)?.content != "1") throw EditProblem("kit.version", "must be 1")
    val kit = EditJson.kitOf(Obj(o, "kit"))
    kit.transition?.let { tr ->
        if (tr.durationSec < EditLimits.MIN_TRANSITION_SEC || tr.durationSec > EditLimits.MAX_TRANSITION_SEC)
            throw EditProblem("kit.transition.durationSec", "must be a number from ${EditLimits.MIN_TRANSITION_SEC} to ${EditLimits.MAX_TRANSITION_SEC}")
    }
    if (!portableLut(kit.look?.lut)) throw EditProblem("kit.look.lut", "a kit can only carry a pack or palette look")
    problemOf(applyKit(PROBE, kit), presets, lookIds, paletteIds)?.let { e ->
        val m = FIELD_MAP.firstOrNull { it.first.containsMatchIn(e.field) }
        throw EditProblem(m?.let { (re, to) -> re.replace(e.field, to) } ?: "kit", e.reason)
    }
    return kit
}

/** The kit as the contract's JSON. */
fun encodeKit(k: StyleKit): JsonObject = buildJsonObject {
    put("version", 1)
    k.look?.let { put("look", EditJson.encodeLook(it)) }
    k.filter?.let { f -> put("filter", buildJsonObject { put("id", f.id); put("amount", EditJson.number(f.amount)) }) }
    k.adjust?.let { put("adjust", EditJson.encodeAdjust(it)) }
    k.transition?.let { tr -> put("transition", buildJsonObject { put("kind", tr.kind.wire); put("durationSec", EditJson.number(tr.durationSec)) }) }
    k.captionStyle?.let { put("captionStyle", EditJson.encodeCaptionStyle(it)) }
    k.textStyle?.let { put("textStyle", EditJson.encodeTextStyle(it)) }
    k.background?.let { put("background", it) }
    k.fill?.let { put("fill", it.wire) }
}
