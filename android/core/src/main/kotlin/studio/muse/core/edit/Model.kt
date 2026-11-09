package studio.muse.core.edit

/*
 * Editor v2: the multitrack edit project (plans/video-editor.md "Editor v2"). A Kotlin port of the TypeScript reference
 * server/api/src/editor/model.ts: the same data, the same JSON field names (EditJson), and the same answers from every
 * function (checked against the shared fixtures in src/test/resources/editor). Pure and immutable: no Android types.
 *
 * Optional fields of the contract are nullable and default to null (null = absent in JSON); required ones are not.
 * Enums carry their exact JSON spelling in [Wire.wire]; an unknown spelling is an error when parsing.
 */

/** An enum with a JSON spelling. */
interface Wire { val wire: String }

inline fun <reified E> wireOf(s: String): E? where E : Enum<E>, E : Wire = enumValues<E>().firstOrNull { it.wire == s }

enum class Ease(override val wire: String) : Wire { LINEAR("linear"), EASE_IN("easeIn"), EASE_OUT("easeOut"), EASE_IN_OUT("easeInOut"), HOLD("hold") }

/** Keyframeable properties. Volume only on clips with sound; the rest on visual items. */
enum class KfProp(override val wire: String) : Wire {
    X("x"), Y("y"), SCALE("scale"), ROTATION("rotation"), OPACITY("opacity"), VOLUME("volume"),
    /** Colour keyframes (M): replace the adjust field's static value over time ([adjustAt]); video clips and images. */
    EXPOSURE("exposure"), CONTRAST("contrast"), SATURATION("saturation"), TEMPERATURE("temperature"), TINT("tint"),
    /** Mask keyframes (M): the mask's fields over time ([maskAt]); only on items with a mask. */
    MASK_X("maskX"), MASK_Y("maskY"), MASK_WIDTH("maskWidth"), MASK_HEIGHT("maskHeight"), MASK_ROTATION("maskRotation"), MASK_FEATHER("maskFeather"),
    /** Look keyframes (M): the finishing effects' amounts over time ([lookAt]). */
    VIGNETTE("vignette"), GRAIN("grain"), LEAK("leak");

    companion object {
        val COLOR = listOf(EXPOSURE, CONTRAST, SATURATION, TEMPERATURE, TINT)
        val MASK = listOf(MASK_X, MASK_Y, MASK_WIDTH, MASK_HEIGHT, MASK_ROTATION, MASK_FEATHER)
        val LOOK = listOf(VIGNETTE, GRAIN, LEAK)
    }
}

enum class TransitionKind(override val wire: String) : Wire {
    FADE("fade"), BLACK("black"), WHITE("white"), SLIDE_LEFT("slideLeft"), SLIDE_RIGHT("slideRight"), SLIDE_UP("slideUp"), SLIDE_DOWN("slideDown"), ZOOM("zoom"),
    /** Edit suite: cubic push with motion blur. */ WHIP("whip"),
    /** Edit suite: rotate 180° and scale through a hard switch at the middle. */ SPIN("spin"),
    /** Edit suite: hard switch with jitter and an RGB split. */ GLITCH("glitch"),
}

/** Speed-curve presets (Edit suite, EM4). */
enum class SpeedPreset(override val wire: String) : Wire { MONTAGE("montage"), HERO("hero"), BULLET("bullet"), FLASH_IN("flashIn"), FLASH_OUT("flashOut"), CUSTOM("custom") }

/** A point of a speed curve: [x] 0–1 of the clip's kept source, [speed] 0.1–10. */
data class SpeedPoint(val x: Double, val speed: Double)

/** A speed curve over the clip's source (points 2–16, x from 0 to 1, rising). */
data class SpeedCurve(val preset: SpeedPreset, val points: List<SpeedPoint>)

enum class MaskShape(override val wire: String) : Wire { LINEAR("linear"), MIRROR("mirror"), CIRCLE("circle"), RECT("rect"), HEART("heart"), STAR("star") }

/** A mask on a video/image item: centre [x]/[y] and size in item fractions, [rotation] in degrees, soft edge [feather]. */
data class Mask(
    val shape: MaskShape,
    val x: Double? = null,
    val y: Double? = null,
    val width: Double? = null,
    val height: Double? = null,
    val rotation: Double? = null,
    val feather: Double? = null,
    val invert: Boolean? = null,
)

/** Voice processing on a clip with sound (Edit suite audio panel). */
enum class VoiceEffect(override val wire: String) : Wire { NONE("none"), WARM("warm"), RADIO("radio"), PHONE("phone"), DEEP("deep") }

enum class AnimKind(override val wire: String) : Wire {
    NONE("none"), FADE("fade"), POP("pop"), SLIDE_UP("slideUp"), SLIDE_DOWN("slideDown"), ZOOM("zoom"), TYPEWRITER("typewriter")
}

enum class Fit(override val wire: String) : Wire { COVER("cover"), CONTAIN("contain") }
enum class AssetKind(override val wire: String) : Wire { VIDEO("video"), IMAGE("image"), AUDIO("audio"), /** An imported .cube (Looks); always an upload. */ LUT("lut") }

enum class TrackKind(override val wire: String) : Wire {
    MAIN("main"), VIDEO("video"), IMAGE("image"), TEXT("text"), CAPTION("caption"), MUSIC("music"), VOICE("voice"), SFX("sfx");

    val isAudio: Boolean get() = this == MUSIC || this == VOICE || this == SFX
    /** Tracks whose items are [VideoClip]s. */
    val isVideo: Boolean get() = this == MAIN || this == VIDEO
}

enum class Font(override val wire: String) : Wire { SANS("sans"), SERIF("serif"), ROUNDED("rounded"), CONDENSED("condensed"), MONO("mono"), MARKER("marker") }
enum class Align(override val wire: String) : Wire { LEFT("left"), CENTER("center"), RIGHT("right") }

enum class CaptionPreset(override val wire: String) : Wire {
    PLAIN("plain"), HIGHLIGHT("highlight"), BOX("box"), KARAOKE("karaoke"), POP("pop"), SINGLE("single"),
    /** Edit suite: a marker stripe behind the active word. */ HIGHLIGHTER("highlighter"),
    /** Edit suite: glowing text. */ NEON("neon"),
}

enum class DuckUnder(override val wire: String) : Wire { VOICE("voice"), SPEECH("speech") }

data class Keyframe(val t: Double, val v: Double, val ease: Ease? = null)

/** Per-property keyframe lists, in JSON order. */
typealias Keyframes = Map<KfProp, List<Keyframe>>

/** [flipX] / [flipY] (wave 1, mirror): mirrored about the picture's centre, after the crop and before scale and rotation. */
data class Transform(val x: Double? = null, val y: Double? = null, val scale: Double? = null, val rotation: Double? = null, val flipX: Boolean? = null, val flipY: Boolean? = null)

/** Wave 1: how an overlay picture combines with the layers below ([blendPixel]). */
enum class BlendMode(override val wire: String) : Wire {
    NORMAL("normal"), MULTIPLY("multiply"), SCREEN("screen"), OVERLAY("overlay"), SOFT_LIGHT("softLight"), DARKEN("darken"), LIGHTEN("lighten"), ADD("add")
}
data class Crop(val left: Double? = null, val top: Double? = null, val right: Double? = null, val bottom: Double? = null)
data class Adjust(
    val exposure: Double? = null, val contrast: Double? = null, val saturation: Double? = null, val temperature: Double? = null,
    /** Edit suite: tone, applied after the colour matrix ([toneAdjust]). */
    val highlights: Double? = null, val shadows: Double? = null,
    /** Green (−1) ↔ magenta (+1), right after temperature in [colorMatrix]. */
    val tint: Double? = null,
)
data class FilterRef(val id: String, val amount: Double)
data class Chroma(val color: String, val similarity: Double? = null, val smoothness: Double? = null, val spill: Double? = null)
data class Transition(val kind: TransitionKind, val durationSec: Double)
data class Anim(val kind: AnimKind, val durationSec: Double)

data class Asset(
    val id: String,
    val kind: AssetKind,
    val take: String? = null,
    val upload: String? = null,
    val library: String? = null,
    val durationSec: Double? = null,
    val width: Int? = null,
    val height: Int? = null,
    val hasAudio: Boolean? = null,
    /** A hint, never trusted. */
    val url: String? = null,
)

/** Anything on a track. Which class an item is follows from its track's kind. */
sealed interface Item { val id: String }

/** Items that draw a picture (video clips and images). */
sealed interface Visual : Item {
    val fit: Fit?
    val transform: Transform?
    val crop: Crop?
    val opacity: Double?
    val keyframes: Keyframes?
    val filter: FilterRef?
    val adjust: Adjust?
    /** The filter stack (plans/video-editor.md "Looks"), additive to [filter]/[adjust]. */
    val look: Look?
    /** Edit suite: a shape mask multiplied into the item's alpha (after chroma key). */
    val mask: Mask?
}

/** Items with source in/out times and a sound (video clips and audio clips). */
sealed interface MediaClip : Item {
    val asset: String
    val inSec: Double
    val outSec: Double
    /** Null = 1 (only audio clips may leave it out). */
    val speedOrNull: Double?
    val volume: Double?
    val muted: Boolean?
    val fadeInSec: Double?
    val fadeOutSec: Double?
    val keyframes: Keyframes?
}

data class VideoClip(
    override val id: String,
    override val asset: String,
    override val inSec: Double,
    override val outSec: Double,
    val speed: Double = 1.0,
    /** Edit suite: a speed curve (used for timing instead of [speed]). */
    val speedCurve: SpeedCurve? = null,
    /** Not on the main track. */
    val startSec: Double? = null,
    override val volume: Double? = null,
    override val muted: Boolean? = null,
    override val fadeInSec: Double? = null,
    override val fadeOutSec: Double? = null,
    /** Use this asset's sound (e.g. a cleaned voice) at the same source times. */
    val audioAsset: String? = null,
    override val fit: Fit? = null,
    override val transform: Transform? = null,
    override val crop: Crop? = null,
    override val opacity: Double? = null,
    override val keyframes: Keyframes? = null,
    override val filter: FilterRef? = null,
    override val adjust: Adjust? = null,
    override val look: Look? = null,
    override val mask: Mask? = null,
    val chroma: Chroma? = null,
    /**
     * Background removal's result (workstream 1, plans/api.md "VideoClip.alphaMatte"): a video asset aligned with this
     * clip's source whose luma is the clip's alpha (white = opaque; [AlphaMatte.invert] flips it). Applied before the look,
     * mask and transform. Replaces the older green composite + [chroma].
     */
    val alphaMatte: AlphaMatte? = null,
    /** Main track, clip ≥ 2. */
    val transitionIn: Transition? = null,
    val voiceEffect: VoiceEffect? = null,
    val enhance: Boolean? = null,
    /** Wave 1, freeze frame: shows the single source frame at [inSec] for this many seconds, silent ([clipLength] = holdSec). */
    val holdSec: Double? = null,
    /** Wave 1: overlay (video) tracks only. */
    val blend: BlendMode? = null,
    /** In / out animation (as images; no typewriter), main or overlay: [animState] over [clipLength]. */
    val animIn: Anim? = null,
    val animOut: Anim? = null,
) : Visual, MediaClip {
    override val speedOrNull: Double get() = speed
}

data class ImageItem(
    override val id: String,
    val asset: String,
    val startSec: Double,
    val durationSec: Double,
    override val fit: Fit? = null,
    override val transform: Transform? = null,
    override val crop: Crop? = null,
    override val opacity: Double? = null,
    override val keyframes: Keyframes? = null,
    override val filter: FilterRef? = null,
    override val adjust: Adjust? = null,
    override val look: Look? = null,
    override val mask: Mask? = null,
    val animIn: Anim? = null,
    val animOut: Anim? = null,
    /** Wave 1: overlay blend mode. */
    val blend: BlendMode? = null,
) : Visual

data class Stroke(val color: String, val widthPct: Double)
data class Shadow(val color: String, val opacity: Double, val blurPct: Double, val dyPct: Double)
data class TextBackground(val color: String, val opacity: Double, val paddingPct: Double, val radiusPct: Double)

data class TextStyle(
    val font: Font,
    val weight: Int,
    val sizePct: Double,
    val color: String,
    val align: Align,
    val maxWidthPct: Double? = null,
    val lineHeight: Double? = null,
    val letterSpacing: Double? = null,
    val uppercase: Boolean? = null,
    val stroke: Stroke? = null,
    val shadow: Shadow? = null,
    val background: TextBackground? = null,
)

data class TextItem(
    override val id: String,
    val startSec: Double,
    val durationSec: Double,
    val text: String,
    val style: TextStyle,
    val transform: Transform? = null,
    val opacity: Double? = null,
    val keyframes: Keyframes? = null,
    val animIn: Anim? = null,
    val animOut: Anim? = null,
    val template: String? = null,
) : Item

data class AudioClip(
    override val id: String,
    override val asset: String,
    val startSec: Double,
    override val inSec: Double,
    override val outSec: Double,
    val speed: Double? = null,
    override val volume: Double? = null,
    override val muted: Boolean? = null,
    override val fadeInSec: Double? = null,
    override val fadeOutSec: Double? = null,
    override val keyframes: Keyframes? = null,
    /** Beat marks, source seconds. */
    val beats: List<Double>? = null,
    /** Strong (downbeat) marks, source seconds. */
    val strongBeats: List<Double>? = null,
    val voiceEffect: VoiceEffect? = null,
    val enhance: Boolean? = null,
) : MediaClip {
    override val speedOrNull: Double? get() = speed
}

/** A caption style: the [TextStyle] fields plus the caption ones (one flat JSON object). */
data class CaptionStyle(
    val text: TextStyle,
    val preset: CaptionPreset,
    val highlightColor: String,
    val y: Double? = null,
    val wordsPerPage: Int? = null,
    val maxLines: Int? = null,
)

data class CaptionWord(val text: String, val startSec: Double, val endSec: Double)
data class CaptionTrack(val asset: String, val words: List<CaptionWord>, val style: CaptionStyle)
data class Duck(
    val level: Double? = null, val fadeSec: Double? = null, val under: List<DuckUnder>,
    /** Edit suite: ramp down before speech / back up after it (else [fadeSec] for both). */
    val attackSec: Double? = null, val releaseSec: Double? = null,
)

data class Track(
    val id: String,
    val kind: TrackKind,
    val name: String? = null,
    val muted: Boolean? = null,
    val hidden: Boolean? = null,
    val volume: Double? = null,
    val items: List<Item> = emptyList(),
    val caption: CaptionTrack? = null,
    val duck: Duck? = null,
)

/** [fill] (wave 1): what shows where a contain-fitted main clip leaves the frame empty: the background colour, or a blur of the clip. */
enum class CanvasFill(override val wire: String) : Wire { COLOR("color"), BLUR("blur") }

data class Canvas(val width: Int, val height: Int, val fps: Double, val background: String? = null, val fill: CanvasFill? = null)

data class EditProject(
    val version: Int = 2,
    val sourceTakeId: String,
    val canvas: Canvas,
    val assets: List<Asset>,
    val tracks: List<Track>,
    val mute: Boolean? = null,
) {
    /** The main track (exactly one in a valid project; the first). */
    val main: Track get() = tracks.first { it.kind == TrackKind.MAIN }
    val mainClips: List<VideoClip> get() = main.items.map { it as VideoClip }
    fun asset(id: String): Asset? = assets.firstOrNull { it.id == id }
    fun track(id: String): Track? = tracks.firstOrNull { it.id == id }
}

/** The v1 edit list (plans/video-editor.md "Edit list"), as JSON sees it. */
data class V1Segment(val inSec: Double, val outSec: Double, val speed: Double, val muted: Boolean? = null)
data class EditListV1(val version: Int = 1, val sourceTakeId: String, val sourceDurationSec: Double, val segments: List<V1Segment>, val mute: Boolean)

/** A broken rule: the field path (e.g. `edits.tracks.0.items.1.startSec`) and what is wrong, like the server's bad_request. */
class EditProblem(val field: String, val reason: String) : IllegalArgumentException("$field: $reason")

object EditLimits {
    const val MAX_JSON_BYTES = 256 * 1024
    const val MAX_TRACKS = 16
    const val MAX_ITEMS_PER_TRACK = 300
    const val MAX_ITEMS = 600
    const val MAX_ASSETS = 60
    const val MAX_WORDS = 3000
    const val MAX_KEYFRAMES = 100
    const val MIN_CLIP_SOURCE_SEC = 0.1
    const val MIN_ITEM_SEC = 0.05
    const val MIN_OUTPUT_SEC = 0.5
    const val MAX_OUTPUT_SEC = 600.0
    const val MIN_SPEED = 0.1
    const val MAX_SPEED = 10.0
    const val END_SLACK_SEC = 0.05
    const val MIN_TRANSITION_SEC = 0.1
    const val MAX_TRANSITION_SEC = 2.0
    const val MAX_TEXT = 500
    const val OVERLAP_SLACK_SEC = 0.001
    val V1_SPEEDS = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)

    /** Caption paging constants (plans/video-editor.md "Text, hooks and captions"). */
    const val CAPTION_GAP_SEC = 0.6
    const val CAPTION_TAIL_SEC = 0.4
    const val SPEECH_JOIN_SEC = 0.4

    /** Source pieces a speed curve is rendered as. */
    const val CURVE_PIECES = 48
}

/** Speed-curve presets (x = position in the clip's kept source, speed ×). */
val SPEED_PRESETS: Map<SpeedPreset, List<SpeedPoint>> = linkedMapOf(
    SpeedPreset.MONTAGE to listOf(SpeedPoint(0.0, 1.0), SpeedPoint(0.2, 4.0), SpeedPoint(0.4, 0.5), SpeedPoint(0.6, 4.0), SpeedPoint(0.8, 0.5), SpeedPoint(1.0, 1.0)),
    SpeedPreset.HERO to listOf(SpeedPoint(0.0, 1.0), SpeedPoint(0.3, 1.0), SpeedPoint(0.42, 6.0), SpeedPoint(0.58, 6.0), SpeedPoint(0.7, 1.0), SpeedPoint(1.0, 1.0)),
    SpeedPreset.BULLET to listOf(SpeedPoint(0.0, 4.0), SpeedPoint(0.35, 4.0), SpeedPoint(0.45, 0.2), SpeedPoint(0.55, 0.2), SpeedPoint(0.65, 4.0), SpeedPoint(1.0, 4.0)),
    SpeedPreset.FLASH_IN to listOf(SpeedPoint(0.0, 6.0), SpeedPoint(0.4, 6.0), SpeedPoint(0.6, 1.0), SpeedPoint(1.0, 1.0)),
    SpeedPreset.FLASH_OUT to listOf(SpeedPoint(0.0, 1.0), SpeedPoint(0.4, 1.0), SpeedPoint(0.6, 6.0), SpeedPoint(1.0, 6.0)),
)

/** A clip's alpha from a matte video (plans/api.md "VideoClip.alphaMatte"). */
data class AlphaMatte(val asset: String, val invert: Boolean? = null)
