package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * The JSON form of an [EditProject] (the exact field names of plans/video-editor.md "Editor v2"). Parsing is strict
 * about shapes and kinds — a missing required field, a wrong type or an unknown kind/ease/keyframe property is an
 * [EditProblem] with the field path the server would name — and leaves the value rules (ranges, overlaps…) to
 * [validate]. Emitting omits absent optionals and writes whole numbers without a fraction, like JavaScript does.
 */
object EditJson {
    private val json = Json { prettyPrint = false }

    fun parse(text: String): EditProject {
        val el = try { json.parseToJsonElement(text) } catch (e: Exception) { throw EditProblem("edits", "is not valid JSON") }
        return parse(el)
    }

    fun parse(el: JsonElement): EditProject = project(Obj.of(el, "edits"))

    fun encode(p: EditProject): JsonObject = buildJsonObject {
        put("version", p.version)
        put("sourceTakeId", p.sourceTakeId)
        put("canvas", buildJsonObject {
            put("width", p.canvas.width); put("height", p.canvas.height); num("fps", p.canvas.fps); str("background", p.canvas.background); str("fill", p.canvas.fill?.wire)
        })
        put("assets", JsonArray(p.assets.map(::encodeAsset)))
        put("tracks", JsonArray(p.tracks.map(::encodeTrack)))
        bool("mute", p.mute)
    }

    fun stringify(p: EditProject): String = encode(p).toString()

    // ------------------------------------------------------------------ v1
    fun parseV1(el: JsonElement): EditListV1 {
        val o = Obj.of(el, "edits")
        return EditListV1(
            version = o.int("version"), sourceTakeId = o.str("sourceTakeId"), sourceDurationSec = o.num("sourceDurationSec"),
            segments = o.arr("segments").map { (e, f) -> Obj.of(e, f).let { s -> V1Segment(s.num("inSec"), s.num("outSec"), s.num("speed"), s.boolOrNull("muted")) } },
            mute = o.boolOrNull("mute") ?: false,
        )
    }

    fun encodeV1(v: EditListV1): JsonObject = buildJsonObject {
        put("version", v.version); put("sourceTakeId", v.sourceTakeId); num("sourceDurationSec", v.sourceDurationSec)
        put("segments", JsonArray(v.segments.map { s ->
            buildJsonObject { num("inSec", s.inSec); num("outSec", s.outSec); num("speed", s.speed); bool("muted", s.muted) }
        }))
        put("mute", v.mute)
    }

    // ------------------------------------------------------------------ parsing
    private fun project(o: Obj): EditProject {
        val cv = o.obj("canvas")
        return EditProject(
            version = o.int("version"),
            sourceTakeId = o.str("sourceTakeId"),
            canvas = Canvas(cv.int("width"), cv.int("height"), cv.num("fps"), cv.strOrNull("background"), cv.enumOrNull("fill", "must be color or blur")),
            assets = o.arr("assets").map { (e, f) -> asset(Obj.of(e, f)) },
            tracks = o.arr("tracks").map { (e, f) -> track(Obj.of(e, f)) },
            mute = o.boolOrNull("mute"),
        )
    }

    private fun asset(o: Obj) = Asset(
        id = o.str("id"), kind = o.enum("kind", "must be video, image, audio, lut or font"),
        take = o.strOrNull("take"), upload = o.strOrNull("upload"), library = o.strOrNull("library"),
        durationSec = o.numOrNull("durationSec"), width = o.intOrNull("width"), height = o.intOrNull("height"),
        hasAudio = o.boolOrNull("hasAudio"), url = o.strOrNull("url"), name = o.strOrNull("name"), reverseOf = o.strOrNull("reverseOf"),
        derivedFrom = o.objOrNull("derivedFrom")?.let { DerivedFrom(it.str("asset"), it.enum("op", "must be stabilize or slowmo"), it.numOrNull("startSec"), it.numOrNull("endSec"), it.intOrNull("factor")) },
    )

    private fun track(o: Obj): Track {
        val kind = o.enum<TrackKind>("kind", "unknown track kind")
        val items = o.arr("items")
        if (kind == TrackKind.CAPTION && items.isNotEmpty()) o.bad("items", "a caption track has no items")
        return Track(
            id = o.str("id"), kind = kind, name = o.strOrNull("name"), muted = o.boolOrNull("muted"), hidden = o.boolOrNull("hidden"),
            volume = o.numOrNull("volume"),
            items = items.map { (e, f) ->
                val io = Obj.of(e, f)
                when (kind) {
                    TrackKind.MAIN, TrackKind.VIDEO -> videoClip(io)
                    TrackKind.IMAGE -> imageItem(io)
                    TrackKind.TEXT -> textItem(io)
                    TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX -> audioClip(io)
                    TrackKind.ADJUST -> adjustItem(io)
                    TrackKind.CAPTION -> error("unreachable")
                }
            },
            caption = o.objOrNull("caption")?.let { c ->
                fun words(ws: List<Pair<JsonElement, String>>) = ws.map { (e, f) -> Obj.of(e, f).let { w -> CaptionWord(w.str("text"), w.num("startSec"), w.num("endSec")) } }
                CaptionTrack(c.str("asset"), words(c.arr("words")), captionStyle(c.obj("style")), c.strOrNull("language"),
                    c.objOrNull("original")?.let { o -> CaptionOriginal(o.strOrNull("language"), words(o.arr("words"))) })
            },
            duck = o.objOrNull("duck")?.let { d ->
                Duck(d.numOrNull("level"), d.numOrNull("fadeSec"), d.arr("under").map { (e, f) -> Obj.wire<DuckUnder>(e, f, "must list voice and/or speech") },
                    d.numOrNull("attackSec"), d.numOrNull("releaseSec"))
            },
        )
    }

    private fun videoClip(o: Obj) = VideoClip(
        id = o.str("id"), asset = o.str("asset"), inSec = o.num("inSec"), outSec = o.num("outSec"), speed = o.num("speed"),
        speedCurve = o.objOrNull("speedCurve")?.let(::speedCurveOf), startSec = o.numOrNull("startSec"), volume = o.numOrNull("volume"), muted = o.boolOrNull("muted"),
        fadeInSec = o.numOrNull("fadeInSec"), fadeOutSec = o.numOrNull("fadeOutSec"), audioAsset = o.strOrNull("audioAsset"),
        fit = o.enumOrNull("fit", "must be cover or contain"), transform = transform(o), crop = crop(o), opacity = o.numOrNull("opacity"),
        keyframes = keyframes(o), filter = filter(o), adjust = adjust(o), look = look(o), mask = mask(o),
        voiceEffect = o.enumOrNull("voiceEffect", "one of ${VoiceEffect.entries.joinToString(", ") { it.wire }}"), enhance = o.boolOrNull("enhance"),
        chroma = o.objOrNull("chroma")?.let { Chroma(it.str("color"), it.numOrNull("similarity"), it.numOrNull("smoothness"), it.numOrNull("spill")) },
        alphaMatte = o.objOrNull("alphaMatte")?.let { AlphaMatte(it.str("asset"), it.boolOrNull("invert")) },
        transitionIn = o.objOrNull("transitionIn")?.let { Transition(it.enum("kind", "unknown transition"), it.num("durationSec")) },
        holdSec = o.numOrNull("holdSec"), blend = o.enumOrNull("blend", "one of ${BlendMode.entries.joinToString(", ") { it.wire }}"),
        animIn = anim(o, "animIn"), animOut = anim(o, "animOut"), animLoop = loop(o),
    )

    private fun imageItem(o: Obj) = ImageItem(
        id = o.str("id"), asset = o.str("asset"), startSec = o.num("startSec"), durationSec = o.num("durationSec"),
        fit = o.enumOrNull("fit", "must be cover or contain"), transform = transform(o), crop = crop(o), opacity = o.numOrNull("opacity"),
        keyframes = keyframes(o), filter = filter(o), adjust = adjust(o), look = look(o), mask = mask(o), animIn = anim(o, "animIn"), animOut = anim(o, "animOut"), animLoop = loop(o),
        blend = o.enumOrNull("blend", "one of ${BlendMode.entries.joinToString(", ") { it.wire }}"),
        transitionIn = o.objOrNull("transitionIn")?.let { Transition(it.enum("kind", "unknown transition"), it.num("durationSec")) },
    )

    private fun textItem(o: Obj) = TextItem(
        id = o.str("id"), startSec = o.num("startSec"), durationSec = o.num("durationSec"), text = o.str("text"), style = textStyle(o.obj("style")),
        transform = transform(o), opacity = o.numOrNull("opacity"), keyframes = keyframes(o),
        animIn = anim(o, "animIn"), animOut = anim(o, "animOut"), template = o.strOrNull("template"), animLoop = loop(o),
    )

    private fun audioClip(o: Obj) = AudioClip(
        id = o.str("id"), asset = o.str("asset"), startSec = o.num("startSec"), inSec = o.num("inSec"), outSec = o.num("outSec"),
        speed = o.numOrNull("speed"), volume = o.numOrNull("volume"), muted = o.boolOrNull("muted"),
        fadeInSec = o.numOrNull("fadeInSec"), fadeOutSec = o.numOrNull("fadeOutSec"), keyframes = keyframes(o),
        beats = o.arrOrNull("beats")?.map { (e, f) -> Obj.number(e, f) },
        strongBeats = o.arrOrNull("strongBeats")?.map { (e, f) -> Obj.number(e, f) },
        voiceEffect = o.enumOrNull("voiceEffect", "one of ${VoiceEffect.entries.joinToString(", ") { it.wire }}"), enhance = o.boolOrNull("enhance"),
    )

    /** A speed curve; a point that isn't `[x, speed]` numbers is a problem here (ranges are [validate]'s). */
    private fun speedCurveOf(c: Obj) = SpeedCurve(
        preset = c.enum("preset", "unknown preset"),
        points = c.arr("points").map { (e, f) ->
            val pt = (e as? JsonArray)?.takeIf { it.size == 2 }?.map { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.doubleOrNull?.takeIf { d -> d.isFinite() } }
            if (pt == null || pt.any { it == null }) throw EditProblem(f, "must be [x 0–1, speed ${number(EditLimits.MIN_SPEED)}–${number(EditLimits.MAX_SPEED)}]")
            SpeedPoint(pt[0]!!, pt[1]!!)
        },
    )

    internal fun mask(o: Obj) = o.objOrNull("mask")?.let { m ->
        Mask(
            m.enum("shape", "one of ${MaskShape.entries.joinToString(", ") { it.wire }}"), m.numOrNull("x"), m.numOrNull("y"), m.numOrNull("width"), m.numOrNull("height"),
            m.numOrNull("rotation"), m.numOrNull("feather"), m.boolOrNull("invert"),
        )
    }

    private fun transform(o: Obj) = o.objOrNull("transform")?.let { Transform(it.numOrNull("x"), it.numOrNull("y"), it.numOrNull("scale"), it.numOrNull("rotation"), it.boolOrNull("flipX"), it.boolOrNull("flipY")) }
    private fun crop(o: Obj) = o.objOrNull("crop")?.let { Crop(it.numOrNull("left"), it.numOrNull("top"), it.numOrNull("right"), it.numOrNull("bottom")) }
    private fun adjust(o: Obj) = o.objOrNull("adjust")?.let(::adjustOf)
    private fun adjustOf(a: Obj) = Adjust(
        a.numOrNull("exposure"), a.numOrNull("contrast"), a.numOrNull("saturation"), a.numOrNull("temperature"), a.numOrNull("highlights"), a.numOrNull("shadows"), a.numOrNull("tint"),
    )
    private fun filter(o: Obj) = o.objOrNull("filter")?.let { FilterRef(it.str("id"), it.num("amount")) }
    private fun look(o: Obj) = o.objOrNull("look")?.let(::lookOf)

    /**
     * A [Look] (plans/video-editor.md "Looks"). Shapes are checked here (an unknown key, curve or leak kind, a curve
     * point that isn't `[x, y]`) with the reference's field paths; ranges and the LUT reference are [validate]'s.
     */
    internal fun lookOf(l: Obj): Look {
        l.o.keys.firstOrNull { it !in Look.KEYS }?.let { l.bad(it, "is not a look setting") }
        return Look(
            lut = l.strOrNull("lut"), strength = l.numOrNull("strength"),
            curves = l.objOrNull("curves")?.let { c ->
                val m = LinkedHashMap<CurveChannel, List<CurvePoint>>()
                for ((k, v) in c.o) {
                    val ch = wireOf<CurveChannel>(k) ?: c.bad(k, "unknown curve")
                    m[ch] = Obj.list(v, "${c.path}.$k").map { (e, f) ->
                        val pt = (e as? JsonArray)?.takeIf { it.size == 2 }?.map { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.doubleOrNull?.takeIf { d -> d.isFinite() } }
                        if (pt == null || pt.any { it == null }) throw EditProblem(f, "must be [x, y], each 0–1")
                        CurvePoint(pt[0]!!, pt[1]!!)
                    }
                }
                m
            },
            hsl = l.objOrNull("hsl")?.let { h ->
                val m = LinkedHashMap<HueBand, HslBand>()
                for (k in h.o.keys) {
                    val band = wireOf<HueBand>(k) ?: h.bad(k, "unknown colour")
                    val o = h.objOrNull(k) ?: h.bad(k, "must be an object")
                    o.o.keys.firstOrNull { it !in setOf("hue", "sat", "light") }?.let { o.bad(it, "is not an HSL setting") }
                    m[band] = HslBand(o.numOrNull("hue"), o.numOrNull("sat"), o.numOrNull("light"))
                }
                m
            },
            lift = l.numOrNull("lift"), sharpen = l.numOrNull("sharpen"), chromatic = l.numOrNull("chromatic"),
            halation = l.objOrNull("halation")?.let { Halation(it.num("amount"), it.numOrNull("radius"), it.numOrNull("threshold")) },
            leak = l.objOrNull("leak")?.let { Leak(it.enum("kind", "one of ${LeakKind.entries.joinToString(", ") { k -> k.wire }}"), it.num("amount"), it.numOrNull("angle")) },
            vignette = l.objOrNull("vignette")?.let { Vignette(it.num("amount"), it.numOrNull("size"), it.numOrNull("softness")) },
            grain = l.objOrNull("grain")?.let { Grain(it.num("amount"), it.numOrNull("size")) },
        )
    }

    /** Parses a look on its own (e.g. a pack entry); [path] names it in problems. */
    fun parseLook(el: JsonElement, path: String = "look"): Look = lookOf(Obj.of(el, path))
    /** A caption style (a content library caption template). */
    fun parseCaptionStyle(el: JsonElement, path: String = "style"): CaptionStyle = captionStyle(Obj.of(el, path))

    private fun adjustItem(o: Obj): AdjustItem {
        for (k in listOf("look", "mask", "transform", "crop", "fit", "asset")) if (o.el(k) != null) o.bad(k, "is not part of an adjustment layer")
        return AdjustItem(o.str("id"), o.num("startSec"), o.num("durationSec"), adjust(o), filter(o), keyframes(o), o.numOrNull("opacity"))
    }
    private fun loop(o: Obj) = o.objOrNull("animLoop")?.let { AnimLoop(it.enum("kind", "unknown loop animation"), it.num("periodSec"), it.numOrNull("amount")) }
    private fun anim(o: Obj, key: String) = o.objOrNull(key)?.let { Anim(it.enum("kind", "unknown animation"), it.num("durationSec")) }

    internal fun keyframes(o: Obj): Keyframes? = o.objOrNull("keyframes")?.let { k ->
        k.o.entries.associate { (name, list) ->
            val prop = wireOf<KfProp>(name) ?: k.bad(name, "is not a keyframe property here")
            prop to Obj.list(list, "${k.path}.$name").map { (e, f) ->
                Obj.of(e, f).let { kf -> Keyframe(kf.num("t"), kf.num("v"), kf.enumOrNull("ease", "unknown ease")) }
            }
        }
    }

    /** A style kit's parts (Kit.kt parseKit checks the keys, version and rules). */
    internal fun kitOf(o: Obj) = StyleKit(
        look = o.objOrNull("look")?.let(::lookOf), filter = filter(o), adjust = adjust(o),
        transition = o.objOrNull("transition")?.let { Transition(it.enum("kind", "unknown transition"), it.num("durationSec")) },
        captionStyle = o.objOrNull("captionStyle")?.let(::captionStyle), textStyle = o.objOrNull("textStyle")?.let(::textStyle),
        background = o.strOrNull("background"), fill = o.enumOrNull("fill", "must be color or blur"),
    )

    internal fun textStyle(s: Obj) = TextStyle(
        font = s.enum("font", "unknown font"), weight = s.int("weight"), sizePct = s.num("sizePct"), color = s.str("color"),
        align = s.enum("align", "must be left, center or right"),
        maxWidthPct = s.numOrNull("maxWidthPct"), lineHeight = s.numOrNull("lineHeight"), letterSpacing = s.numOrNull("letterSpacing"),
        uppercase = s.boolOrNull("uppercase"),
        stroke = s.objOrNull("stroke")?.let { Stroke(it.str("color"), it.num("widthPct")) },
        shadow = s.objOrNull("shadow")?.let { Shadow(it.str("color"), it.num("opacity"), it.num("blurPct"), it.num("dyPct")) },
        background = s.objOrNull("background")?.let { TextBackground(it.str("color"), it.num("opacity"), it.num("paddingPct"), it.num("radiusPct")) },
        fontAsset = s.strOrNull("fontAsset"),
    )

    internal fun captionStyle(s: Obj) = CaptionStyle(
        text = textStyle(s), preset = s.enum("preset", "unknown preset"), highlightColor = s.str("highlightColor"),
        y = s.numOrNull("y"), wordsPerPage = s.intOrNull("wordsPerPage"), maxLines = s.intOrNull("maxLines"),
    )

    // ------------------------------------------------------------------ emitting
    internal fun encodeAsset(a: Asset) = buildJsonObject {
        put("id", a.id); put("kind", a.kind.wire); str("take", a.take); str("upload", a.upload); str("library", a.library)
        num("durationSec", a.durationSec); int("width", a.width); int("height", a.height); bool("hasAudio", a.hasAudio); str("url", a.url); str("name", a.name); str("reverseOf", a.reverseOf)
        a.derivedFrom?.let { d -> put("derivedFrom", buildJsonObject { put("asset", d.asset); put("op", d.op.wire); num("startSec", d.startSec); num("endSec", d.endSec); int("factor", d.factor) }) }
    }

    internal fun encodeTrack(t: Track) = buildJsonObject {
        put("id", t.id); put("kind", t.kind.wire); str("name", t.name); bool("muted", t.muted); bool("hidden", t.hidden); num("volume", t.volume)
        put("items", JsonArray(t.items.map(::encodeItem)))
        t.caption?.let { c ->
            put("caption", buildJsonObject {
                put("asset", c.asset)
                put("words", JsonArray(c.words.map { w -> buildJsonObject { put("text", w.text); num("startSec", w.startSec); num("endSec", w.endSec) } }))
                put("style", encodeCaptionStyle(c.style))
                str("language", c.language)
                c.original?.let { o -> put("original", buildJsonObject {
                    str("language", o.language)
                    put("words", JsonArray(o.words.map { w -> buildJsonObject { put("text", w.text); num("startSec", w.startSec); num("endSec", w.endSec) } }))
                }) }
            })
        }
        t.duck?.let { d ->
            put("duck", buildJsonObject {
                num("level", d.level); num("fadeSec", d.fadeSec); num("attackSec", d.attackSec); num("releaseSec", d.releaseSec)
                put("under", JsonArray(d.under.map { JsonPrimitive(it.wire) }))
            })
        }
    }

    fun encodeItem(it: Item): JsonObject = when (it) {
        is AdjustItem -> buildJsonObject {
            put("id", it.id); num("startSec", it.startSec); num("durationSec", it.durationSec)
            it.adjust?.let { a -> put("adjust", encodeAdjust(a)) }
            it.filter?.let { f -> put("filter", buildJsonObject { put("id", f.id); num("amount", f.amount) }) }
            num("opacity", it.opacity); keyframes(it.keyframes)
        }
        is VideoClip -> buildJsonObject {
            put("id", it.id); put("asset", it.asset); num("inSec", it.inSec); num("outSec", it.outSec); num("speed", it.speed)
            it.speedCurve?.let { c -> put("speedCurve", encodeSpeedCurve(c)) }
            str("voiceEffect", it.voiceEffect?.wire); bool("enhance", it.enhance)
            num("startSec", it.startSec); num("volume", it.volume); bool("muted", it.muted); num("fadeInSec", it.fadeInSec); num("fadeOutSec", it.fadeOutSec)
            str("audioAsset", it.audioAsset); visual(it)
            it.chroma?.let { c -> put("chroma", buildJsonObject { put("color", c.color); num("similarity", c.similarity); num("smoothness", c.smoothness); num("spill", c.spill) }) }
            it.alphaMatte?.let { m -> put("alphaMatte", buildJsonObject { put("asset", m.asset); bool("invert", m.invert) }) }
            it.transitionIn?.let { tr -> put("transitionIn", buildJsonObject { put("kind", tr.kind.wire); num("durationSec", tr.durationSec) }) }
            num("holdSec", it.holdSec); str("blend", it.blend?.wire); anim("animIn", it.animIn); anim("animOut", it.animOut); loop(it.animLoop)
        }
        is ImageItem -> buildJsonObject {
            put("id", it.id); put("asset", it.asset); num("startSec", it.startSec); num("durationSec", it.durationSec); visual(it)
            anim("animIn", it.animIn); anim("animOut", it.animOut); str("blend", it.blend?.wire); loop(it.animLoop)
            it.transitionIn?.let { tr -> put("transitionIn", buildJsonObject { put("kind", tr.kind.wire); num("durationSec", tr.durationSec) }) }
        }
        is TextItem -> buildJsonObject {
            put("id", it.id); num("startSec", it.startSec); num("durationSec", it.durationSec); put("text", it.text); put("style", encodeTextStyle(it.style))
            transform(it.transform); num("opacity", it.opacity); keyframes(it.keyframes); anim("animIn", it.animIn); anim("animOut", it.animOut); str("template", it.template); loop(it.animLoop)
        }
        is AudioClip -> buildJsonObject {
            put("id", it.id); put("asset", it.asset); num("startSec", it.startSec); num("inSec", it.inSec); num("outSec", it.outSec); num("speed", it.speed)
            num("volume", it.volume); bool("muted", it.muted); num("fadeInSec", it.fadeInSec); num("fadeOutSec", it.fadeOutSec); keyframes(it.keyframes)
            it.beats?.let { b -> put("beats", JsonArray(b.map(::number))) }
            it.strongBeats?.let { b -> put("strongBeats", JsonArray(b.map(::number))) }
            str("voiceEffect", it.voiceEffect?.wire); bool("enhance", it.enhance)
        }
    }

    private fun JsonObjectBuilder.visual(v: Visual) {
        v.fit?.let { put("fit", it.wire) }
        transform(v.transform)
        v.crop?.let { c -> put("crop", buildJsonObject { num("left", c.left); num("top", c.top); num("right", c.right); num("bottom", c.bottom) }) }
        num("opacity", v.opacity)
        keyframes(v.keyframes)
        v.filter?.let { f -> put("filter", buildJsonObject { put("id", f.id); num("amount", f.amount) }) }
        v.adjust?.let { put("adjust", encodeAdjust(it)) }
        v.look?.let { put("look", encodeLook(it)) }
        v.mask?.let { put("mask", encodeMask(it)) }
    }

    fun encodeMask(m: Mask) = buildJsonObject {
        put("shape", m.shape.wire); num("x", m.x); num("y", m.y); num("width", m.width); num("height", m.height)
        num("rotation", m.rotation); num("feather", m.feather); bool("invert", m.invert)
    }

    fun encodeSpeedCurve(c: SpeedCurve) = buildJsonObject {
        put("preset", c.preset.wire)
        put("points", JsonArray(c.points.map { p -> buildJsonArray { add(number(p.x)); add(number(p.speed)) } }))
    }

    fun encodeLook(l: Look) = buildJsonObject {
        str("lut", l.lut); num("strength", l.strength)
        l.curves?.let { c ->
            put("curves", buildJsonObject {
                for ((ch, pts) in c) put(ch.wire, JsonArray(pts.map { p -> buildJsonArray { add(number(p.x)); add(number(p.y)) } }))
            })
        }
        l.hsl?.let { h -> put("hsl", buildJsonObject { for ((band, v) in h) put(band.wire, buildJsonObject { num("hue", v.hue); num("sat", v.sat); num("light", v.light) }) }) }
        num("lift", l.lift); num("sharpen", l.sharpen); num("chromatic", l.chromatic)
        l.halation?.let { h -> put("halation", buildJsonObject { num("amount", h.amount); num("radius", h.radius); num("threshold", h.threshold) }) }
        l.leak?.let { k -> put("leak", buildJsonObject { put("kind", k.kind.wire); num("amount", k.amount); num("angle", k.angle) }) }
        l.vignette?.let { v -> put("vignette", buildJsonObject { num("amount", v.amount); num("size", v.size); num("softness", v.softness) }) }
        l.grain?.let { g -> put("grain", buildJsonObject { num("amount", g.amount); num("size", g.size) }) }
    }

    fun encodeAdjust(a: Adjust) = buildJsonObject {
        num("exposure", a.exposure); num("contrast", a.contrast); num("saturation", a.saturation); num("temperature", a.temperature)
        num("highlights", a.highlights); num("shadows", a.shadows); num("tint", a.tint)
    }


    private fun JsonObjectBuilder.transform(t: Transform?) {
        t?.let { put("transform", encodeTransform(it)) }
    }

    fun encodeTransform(t: Transform) = buildJsonObject { num("x", t.x); num("y", t.y); num("scale", t.scale); num("rotation", t.rotation); bool("flipX", t.flipX); bool("flipY", t.flipY) }

    private fun JsonObjectBuilder.keyframes(k: Keyframes?) {
        k ?: return
        put("keyframes", buildJsonObject {
            for ((prop, list) in k) put(prop.wire, JsonArray(list.map { kf -> buildJsonObject { num("t", kf.t); num("v", kf.v); kf.ease?.let { put("ease", it.wire) } } }))
        })
    }

    private fun JsonObjectBuilder.loop(l: AnimLoop?) {
        if (l != null) put("animLoop", buildJsonObject { put("kind", l.kind.wire); num("periodSec", l.periodSec); num("amount", l.amount) })
    }

    private fun JsonObjectBuilder.anim(key: String, a: Anim?) {
        a?.let { put(key, encodeAnim(it)) }
    }

    fun encodeAnim(a: Anim) = buildJsonObject { put("kind", a.kind.wire); num("durationSec", a.durationSec) }

    fun encodeTextStyle(s: TextStyle) = buildJsonObject { textStyleFields(s) }

    private fun JsonObjectBuilder.textStyleFields(s: TextStyle) {
        put("font", s.font.wire); put("weight", s.weight); num("sizePct", s.sizePct); put("color", s.color); put("align", s.align.wire)
        num("maxWidthPct", s.maxWidthPct); num("lineHeight", s.lineHeight); num("letterSpacing", s.letterSpacing); bool("uppercase", s.uppercase)
        s.stroke?.let { put("stroke", buildJsonObject { put("color", it.color); num("widthPct", it.widthPct) }) }
        s.shadow?.let { put("shadow", buildJsonObject { put("color", it.color); num("opacity", it.opacity); num("blurPct", it.blurPct); num("dyPct", it.dyPct) }) }
        s.background?.let { put("background", buildJsonObject { put("color", it.color); num("opacity", it.opacity); num("paddingPct", it.paddingPct); num("radiusPct", it.radiusPct) }) }
        str("fontAsset", s.fontAsset)
    }

    fun encodeCaptionStyle(s: CaptionStyle) = buildJsonObject {
        textStyleFields(s.text)
        put("preset", s.preset.wire); put("highlightColor", s.highlightColor); num("y", s.y); int("wordsPerPage", s.wordsPerPage); int("maxLines", s.maxLines)
    }

    /** A number as JavaScript prints it: whole numbers without ".0". */
    fun number(v: Double): JsonPrimitive =
        if (v.isFinite() && v == Math.rint(v) && kotlin.math.abs(v) < 1e15) JsonPrimitive(v.toLong()) else JsonPrimitive(v)

    private fun JsonObjectBuilder.num(k: String, v: Double?) { if (v != null) put(k, number(v)) }
    private fun JsonObjectBuilder.int(k: String, v: Int?) { if (v != null) put(k, v) }
    private fun JsonObjectBuilder.str(k: String, v: String?) { if (v != null) put(k, v) }
    private fun JsonObjectBuilder.bool(k: String, v: Boolean?) { if (v != null) put(k, v) }
}

/** A JSON object being read, with its field path for problems. */
internal class Obj(val o: JsonObject, val path: String) {
    fun bad(key: String, reason: String): Nothing = throw EditProblem("$path.$key", reason)
    fun el(k: String): JsonElement? = o[k]?.takeIf { it !is JsonNull }

    fun strOrNull(k: String): String? = el(k)?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content ?: bad(k, "must be text") }
    fun str(k: String): String = strOrNull(k) ?: bad(k, "is required")
    fun numOrNull(k: String): Double? = el(k)?.let { number(it, "$path.$k") }
    fun num(k: String): Double = numOrNull(k) ?: bad(k, "must be a number")
    fun intOrNull(k: String): Int? = numOrNull(k)?.let { if (it != Math.rint(it) || kotlin.math.abs(it) > Int.MAX_VALUE) bad(k, "must be a whole number") else it.toInt() }
    fun int(k: String): Int = intOrNull(k) ?: bad(k, "must be a number")
    fun boolOrNull(k: String): Boolean? = el(k)?.let { (it as? JsonPrimitive)?.takeIf { p -> !p.isString }?.booleanOrNull ?: bad(k, "must be true or false") }
    fun objOrNull(k: String): Obj? = el(k)?.let { of(it, "$path.$k") }
    fun obj(k: String): Obj = objOrNull(k) ?: bad(k, "is required")
    fun arrOrNull(k: String): List<Pair<JsonElement, String>>? = el(k)?.let { list(it, "$path.$k") }
    fun arr(k: String): List<Pair<JsonElement, String>> = arrOrNull(k) ?: bad(k, "is required")
    inline fun <reified E> enumOrNull(k: String, reason: String): E? where E : Enum<E>, E : Wire = el(k)?.let { wire<E>(it, "$path.$k", reason) }
    inline fun <reified E> enum(k: String, reason: String): E where E : Enum<E>, E : Wire = enumOrNull<E>(k, reason) ?: bad(k, reason)

    companion object {
        fun of(e: JsonElement, path: String): Obj = Obj(e as? JsonObject ?: throw EditProblem(path, "must be an object"), path)
        fun list(e: JsonElement, path: String): List<Pair<JsonElement, String>> =
            (e as? JsonArray ?: throw EditProblem(path, "must be a list")).mapIndexed { i, x -> x to "$path.$i" }
        fun number(e: JsonElement, path: String): Double =
            (e as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() } ?: throw EditProblem(path, "must be a number")
        inline fun <reified E> wire(e: JsonElement, path: String, reason: String): E where E : Enum<E>, E : Wire =
            (e as? JsonPrimitive)?.takeIf { it.isString }?.let { wireOf<E>(it.content) } ?: throw EditProblem(path, reason)
    }
}

/** Builds a JSON array of numbers (for matrices and the like). */
internal fun numbers(vs: List<Double>): JsonArray = buildJsonArray { vs.forEach { add(EditJson.number(it)) } }
