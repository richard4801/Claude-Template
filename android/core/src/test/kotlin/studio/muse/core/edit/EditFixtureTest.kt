package studio.muse.core.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.core.edit.Fixtures.assertJson

/**
 * Every case of the shared editor fixtures (generated from the TypeScript reference by server/api
 * scripts/editor-fixtures.ts): the Kotlin port must give the same answers to 1e-6.
 */
class EditFixtureTest {
    private fun n(v: Double) = EditJson.number(v)

    // ------------------------------------------------------------------ presets.json
    @Test fun presetsMatchTheReferenceTables() {
        val f = Fixtures.load("presets.json").obj
        val filters = JsonArray(Presets.FILTERS.map { p ->
            buildJsonObject {
                put("id", p.id); put("label", p.label); put("adjust", EditJson.encodeAdjust(p.adjust))
                p.tint?.let { t -> put("tint", buildJsonObject { put("color", t.color); put("strength", n(t.strength)) }) }
            }
        })
        assertJson("filters", f["filters"], filters, 0.0)
        val styles = JsonObject(Presets.CAPTION_STYLES.entries.associate { (k, v) -> k.wire to EditJson.encodeCaptionStyle(v) })
        assertJson("captionStyles", f["captionStyles"], styles, 0.0)
        val hooks = JsonArray(Presets.HOOKS.map { h ->
            buildJsonObject {
                put("id", h.id); put("label", h.label); put("text", h.text); put("durationSec", n(h.durationSec))
                put("style", EditJson.encodeTextStyle(h.style)); put("transform", EditJson.encodeTransform(h.transform)); put("animIn", EditJson.encodeAnim(h.animIn))
                h.animOut?.let { put("animOut", EditJson.encodeAnim(it)) }
            }
        })
        assertJson("hooks", f["hooks"], hooks, 0.0)
        assertEquals(CaptionPreset.entries.map { it.wire }, f["captionStyles"]!!.obj.keys.toList())
        assertJson("captionStyleLabels", f["captionStyleLabels"], JsonArray(Presets.CAPTION_STYLE_LABELS.map { (k, v) -> buildJsonArray { add(JsonPrimitive(k.wire)); add(JsonPrimitive(v)) } }), 0.0)
        assertJson("transitionLabels", f["transitionLabels"], JsonArray(Presets.TRANSITION_LABELS.map { (k, v) -> buildJsonArray { add(JsonPrimitive(k)); add(JsonPrimitive(v)) } }), 0.0)
        for ((k, _) in Presets.TRANSITION_LABELS) if (k != "cut") assertTrue(Presets.transitionOf(k) != null)
    }

    // ------------------------------------------------------------------ projects.json
    @Test fun projectsRoundTripAndGiveTheExpectedAnswers() {
        val cases = Fixtures.load("projects.json").arr
        assertTrue(cases.size >= 9)
        for (c in cases) {
            val name = c.obj["name"]!!.str
            val src = c.obj["project"]!!
            val p = EditJson.parse(src)
            assertJson("$name: round trip", src, EditJson.encode(p), 0.0)
            assertJson("$name: round trip via text", src, EditJson.encode(EditJson.parse(EditJson.stringify(p))), 0.0)
            assertEquals(p, EditJson.parse(EditJson.stringify(p)))
            val e = c.obj["expect"]!!.obj
            assertJson("$name: durationSec", e["durationSec"], n(durationSec(p)))
            assertJson("$name: timeline", e["timeline"], JsonArray(timeline(p).map { s ->
                buildJsonObject { put("id", s.id); put("index", s.index); put("startSec", n(s.startSec)); put("endSec", n(s.endSec)); put("transitionSec", n(s.transitionSec)) }
            }))
            assertJson("$name: captionWords", e["captionWords"], JsonArray(captionWords(p).map(::word)))
            val pages = captionPages(p)
            assertJson("$name: captionPages", e["captionPages"], JsonArray(pages.map { pg ->
                buildJsonObject { put("startSec", n(pg.startSec)); put("endSec", n(pg.endSec)); put("words", JsonArray(pg.words.map { JsonPrimitive(it.index) })) }
            }))
            for (s in e["captionAt"]!!.arr) {
                val t = s.obj["t"]!!.num
                val at = captionAt(p, t)
                assertJson("$name: captionAt $t", s.obj["at"], at?.let { buildJsonObject { put("page", it.page); put("word", it.word) } } ?: JsonNull)
                assertEquals(at, captionAt(pages, t))
            }
            val envs = e["envelopes"]!!.obj
            val wantEnvKeys = p.tracks.filter { it.kind in setOf(TrackKind.MAIN, TrackKind.VIDEO, TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX) }
                .flatMap { t -> t.items.map { "${t.id}/${it.id}" } }
            assertEquals("$name: envelope keys", envs.keys.toList(), wantEnvKeys)
            for ((key, want) in envs) {
                val (tid, iid) = key.split('/')
                assertJson("$name: envelope $key", want, JsonArray(audioEnvelope(p, tid, iid).map { g -> buildJsonObject { put("t", n(g.t)); put("gain", n(g.gain)) } }))
            }
            val colors = e["colorMatrices"]!!.obj
            val visuals = p.tracks.flatMap { it.items }.filterIsInstance<Visual>().filter { it.filter != null || it.adjust != null }
            assertEquals("$name: colour items", colors.keys, visuals.map { it.id }.toSet())
            for (v in visuals) assertJson("$name: colorMatrix ${v.id}", colors[v.id], numbers(colorMatrix(v.adjust, v.filter, Presets.FILTERS)))
            assertJson("$name: toV1", e["toV1"], toV1(p)?.let(EditJson::encodeV1) ?: JsonNull, 0.0)
            assertJson("$name: pieces", e["pieces"], JsonObject(p.mainClips.filter { it.speedCurve != null }.associate { c ->
                c.id to JsonArray(speedPieces(c).map { pc -> buildJsonObject { put("inSec", n(pc.inSec)); put("outSec", n(pc.outSec)); put("speed", n(pc.speed)) } })
            }))
            assertEquals("$name: srt", e["srt"]!!.str, toSrt(p))
            assertEquals("$name: valid", durationSec(p), validate(p), 0.0)
        }
    }

    private fun word(w: TimedWord) = buildJsonObject { put("text", w.text); put("startSec", n(w.startSec)); put("endSec", n(w.endSec)); put("index", w.index) }

    // ------------------------------------------------------------------ validation.json
    @Test fun validationGivesTheSameFirstProblem() {
        val cases = Fixtures.load("validation.json").arr
        assertTrue(cases.size >= 30)
        for (c in cases) {
            val name = c.obj["name"]!!.str
            val ok = (c.obj["ok"] as JsonPrimitive).booleanOrNull!!
            val problem = try { validate(EditJson.parse(c.obj["project"]!!), Presets.FILTERS); null } catch (e: EditProblem) { e }
            if (ok) assertEquals("$name: expected valid, got ${problem?.message}", null, problem)
            else assertEquals("$name: ${problem?.message}", c.obj["field"]!!.str, problem?.field)
        }
    }

    @Test fun parsingRejectsUnknownKindsWithTheFieldPath() {
        val src = Fixtures.load("projects.json").arr[8].obj["project"]!!.obj
        fun broken(f: (MutableMap<String, JsonElement>) -> Unit): String? {
            val m = src.toMutableMap(); f(m)
            return try { EditJson.parse(JsonObject(m)); null } catch (e: EditProblem) { e.field }
        }
        val tracks = src["tracks"]!!.arr
        assertEquals("edits.tracks.1.kind", broken { m -> m["tracks"] = JsonArray(tracks.mapIndexed { i, t -> if (i == 1) JsonObject(t.obj + ("kind" to JsonPrimitive("hologram"))) else t }) })
        assertEquals("edits.canvas", broken { m -> m.remove("canvas") })
        assertEquals("edits.assets.0.kind", broken { m -> m["assets"] = JsonArray(src["assets"]!!.arr.mapIndexed { i, a -> if (i == 0) JsonObject(a.obj + ("kind" to JsonPrimitive("gif"))) else a }) })
        assertEquals("edits", try { EditJson.parse("[1]"); null } catch (e: EditProblem) { e.field })
    }

    // ------------------------------------------------------------------ functions.json
    private val fn = Fixtures.load("functions.json").obj

    @Test fun keyframes() {
        for ((i, c) in fn["keyframes"]!!.arr.withIndex()) {
            val keys = c.obj["keys"]!!.arr.map { k -> Keyframe(k.obj["t"]!!.num, k.obj["v"]!!.num, k.obj["ease"]?.str?.let { wireOf<Ease>(it)!! }) }
            for ((j, s) in c.obj["samples"]!!.arr.withIndex()) {
                val t = s.obj["t"]!!.num
                // The reference samples at j * 0.2 and prints t rounded; evaluate at the same unrounded time.
                val tt = j * 0.2
                assertJson("keyframes $i at $t", s.obj["v"], n(r6(keyframeValue(keys, tt))))
            }
        }
    }

    @Test fun transitions() {
        for (c in fn["transitions"]!!.arr) {
            val kind = wireOf<TransitionKind>(c.obj["kind"]!!.str)!!
            val p = c.obj["p"]!!.num
            val s = transitionState(kind, p)
            fun layer(l: LayerState) = buildJsonObject {
                put("opacity", n(l.opacity)); put("dx", n(l.dx)); put("dy", n(l.dy)); put("scale", n(l.scale))
                put("rotation", n(l.rotation)); put("blur", n(l.blur)); put("rgbSplit", n(l.rgbSplit))
            }
            assertJson("transition ${kind.wire} $p", c.obj["state"], buildJsonObject {
                put("a", layer(s.a)); put("b", layer(s.b)); put("color", s.color?.let(::JsonPrimitive) ?: JsonNull)
            })
        }
        assertEquals(TransitionKind.entries.size * 7, fn["transitions"]!!.arr.size)
    }

    @Test fun anims() {
        for ((i, c) in fn["anims"]!!.arr.withIndex()) {
            val item = c.obj["item"]!!.obj
            fun anim(k: String) = item[k]?.obj?.let { Anim(wireOf<AnimKind>(it["kind"]!!.str)!!, it["durationSec"]!!.num) }
            for (s in c.obj["samples"]!!.arr) {
                val t = s.obj["t"]!!.num
                val st = animState(item["durationSec"]!!.num, anim("animIn"), anim("animOut"), item["text"]?.str, t)
                assertJson("anim $i at $t", s.obj["state"], buildJsonObject {
                    put("opacity", n(st.opacity)); put("scale", n(st.scale)); put("dy", n(st.dy)); put("chars", st.chars?.let(::JsonPrimitive) ?: JsonNull)
                })
            }
        }
    }

    @Test fun adjustmentLayers() {
        val al = fn["adjustLayers"]!!.obj
        val p = EditJson.parse(al["project"]!!)
        assertEquals(null, problemOf(p)?.message)
        for (sm in al["samples"]!!.arr) {
            val t = sm.obj["t"]!!.num
            assertJson("adjustLayer t=$t", sm.obj["matrix"], adjustLayerMatrix(p, t)?.let(::numbers) ?: kotlinx.serialization.json.JsonNull)
        }
        assertEquals(al["project"], EditJson.encode(p)) // round trip
    }

    @Test fun reverseClips() {
        // Each clip through a one-clip project (the JSON parser is the project's), reversed and back.
        fun clipOf(o: JsonElement): VideoClip = EditJson.parse(buildJsonObject {
            put("version", 2); put("sourceTakeId", "t")
            put("canvas", buildJsonObject { put("width", 1080); put("height", 1920); put("fps", 30); put("background", "#000000") })
            put("assets", buildJsonArray { add(buildJsonObject { put("id", "src"); put("kind", "video"); put("take", "t"); put("durationSec", 20) }) })
            put("tracks", buildJsonArray { add(buildJsonObject { put("id", "main"); put("kind", "main"); put("items", buildJsonArray { add(o) }) }) })
        }).mainClips.single()
        fun enc(c: VideoClip?): JsonElement = c?.let { EditJson.encodeItem(it) } ?: JsonNull
        for (c in fn["reverse"]!!.arr) {
            val clip = clipOf(c.obj["clip"]!!)
            val d = c.obj["durationSec"]!!.num
            val rev = reverseClip(clip, "src_rev", d)
            assertJson("reverse ${clip.id}", c.obj["reversed"], enc(rev))
            assertJson("reverse back ${clip.id}", c.obj["back"], enc(rev?.let { reverseClip(it, clip.asset, d) }))
        }
    }

    @Test fun derivedCopies() {
        val d = fn["derived"]!!.obj
        val p = EditJson.parse(buildJsonObject {
            put("version", 2); put("sourceTakeId", "tk_1")
            put("canvas", buildJsonObject { put("width", 1080); put("height", 1920); put("fps", 30); put("background", "#000000") })
            put("assets", d["assets"]!!)
            put("tracks", buildJsonArray { add(buildJsonObject { put("id", "main"); put("kind", "main"); put("items", buildJsonArray { add(d["clip"]!!) }) }) })
        })
        for (c in d["chains"]!!.arr) {
            val id = c.obj["asset"]!!.str
            assertEquals("source $id", c.obj["source"]!!.str, sourceOf(p, id))
            assertEquals("ops $id", c.obj["ops"]!!.arr.map { it.str }, derivedOps(p, id))
            assertEquals("label $id", c.obj["label"]!!.str, derivedLabel(p, id))
        }
        val clip = p.mainClips.single()
        for (s in d["swaps"]!!.arr) {
            val op = (s.obj["op"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.let { w -> DerivedOp.entries.first { it.wire == w } }
            assertJson("swap $op", s.obj["clip"], EditJson.encodeItem(deriveClip(clip, s.obj["copy"]!!.str, op)))
        }
    }

    @Test fun slowmo() {
        for (c in fn["slowmo"]!!.arr) {
            val name = c.obj["name"]!!.str
            val p = EditJson.parse(c.obj["project"]!!)
            val r = applySlowmo(p, "c1", "src_sm")
            val want = c.obj["result"]
            if (want == null || want is JsonNull) { assertEquals(name, null, r); continue }
            assertEquals(name, want.obj["id"]!!.str, r!!.second)
            assertJson("slowmo $name", want.obj["project"], EditJson.encode(r.first))
            validate(r.first)
        }
    }

    @Test fun audioSpeedTiming() {
        for (c in fn["audioSpeed"]!!.arr) {
            val o = c.obj["clip"]!!.obj
            val clip = AudioClip(o["id"]!!.str, o["asset"]!!.str, o["startSec"]!!.num, o["inSec"]!!.num, o["outSec"]!!.num, speed = o["speed"]?.num,
                beats = o["beats"]?.arr?.map { it.num })
            assertEquals(c.obj["length"]!!.num, clipLength(clip), 1e-9)
            val beats = c.obj["beatsOnTimeline"]!!.arr.map { it.num }
            assertEquals(beats, clip.beats.orEmpty().map { Math.round((clip.startSec + clipTimeAt(clip, it)) * 1e6) / 1e6 })
            for (sm in c.obj["sourceAt"]!!.arr) assertEquals(sm.obj["src"]!!.num, clipSourceAt(clip, sm.obj["t"]!!.num), 1e-9)
            // MarkBeat stores a tap at timeline T as r3(clipSourceAt(clip, T - start)).
            for (sm in c.obj["tappedMarks"]!!.arr) assertEquals(sm.obj["src"]!!.num, Math.round(clipSourceAt(clip, sm.obj["timelineT"]!!.num - clip.startSec) * 1000) / 1000.0, 1e-9)
        }
    }

    @Test fun loopAnimations() {
        for ((i, c) in fn["loops"]!!.arr.withIndex()) {
            val lo = c.obj["loop"]!!.obj
            val loop = AnimLoop(LoopKind.entries.first { it.wire == lo["kind"]!!.str }, lo["periodSec"]!!.num, lo["amount"]?.num)
            for (sm in c.obj["samples"]!!.arr) {
                val t = sm.obj["t"]!!.num; val want = sm.obj["state"]!!.obj
                val got = loopState(loop, t)
                for ((k, v) in listOf("scale" to got.scale, "rotation" to got.rotation, "dy" to got.dy, "opacity" to got.opacity))
                    assertEquals("loop $i $k t=$t", want[k]!!.num, v, 1e-6)
            }
        }
    }

    @Test fun maskAndLookKeyframes() {
        for ((i, c) in fn["motionKeys"]!!.arr.withIndex()) {
            val o = Obj.of(c.obj["item"]!!, "item")
            val mask = EditJson.mask(o); val look = o.objOrNull("look")?.let(EditJson::lookOf); val keys = EditJson.keyframes(o)
            for (sm in c.obj["samples"]!!.arr) {
                val t = sm.obj["t"]!!.num
                assertJson("motionKeys $i mask t=$t", sm.obj["mask"], maskAt(mask, keys, t)?.let(EditJson::encodeMask) ?: kotlinx.serialization.json.JsonNull)
                assertJson("motionKeys $i look t=$t", sm.obj["look"], lookAt(look, keys, t)?.let(EditJson::encodeLook) ?: kotlinx.serialization.json.JsonNull)
            }
        }
    }

    @Test fun autoAdjustTable() {
        for (c in fn["autoAdjust"]!!.arr) {
            val o = c.obj
            val rgb = o["rgb"]!!.arr.map { it.num }.toDoubleArray()
            val base = (o["base"] as? JsonObject)?.let { Adjust(it["exposure"]?.num, it["contrast"]?.num, it["saturation"]?.num, it["temperature"]?.num, it["highlights"]?.num, it["shadows"]?.num, it["tint"]?.num) }
            assertJson("autoAdjust ${o["name"]}", o["out"], EditJson.encodeAdjust(autoAdjust(rgb, base)))
        }
    }

    @Test fun colorKeyframes() {
        for ((i, c) in fn["colorKeys"]!!.arr.withIndex()) {
            val it0 = c.obj["item"]!!.obj
            val a = (it0["adjust"] as? JsonObject)?.let { Adjust(it["exposure"]?.num, it["contrast"]?.num, it["saturation"]?.num, it["temperature"]?.num, tint = it["tint"]?.num) }
            val f = (it0["filter"] as? JsonObject)?.let { FilterRef(it["id"]!!.str, it["amount"]!!.num) }
            val keys: Keyframes = it0["keyframes"]!!.obj.entries.associate { (k, v) ->
                KfProp.entries.first { p -> p.wire == k } to v.arr.map { kf -> Keyframe(kf.obj["t"]!!.num, kf.obj["v"]!!.num, kf.obj["ease"]?.str?.let { e -> Ease.entries.first { x -> x.wire == e } }) }
            }
            for (sm in c.obj["samples"]!!.arr) {
                val t = sm.obj["t"]!!.num
                val got = adjustAt(a, keys, t)
                assertJson("colorKeys $i adjust t=$t", sm.obj["adjust"], got?.let { EditJson.encodeAdjust(it) } ?: kotlinx.serialization.json.JsonNull)
                assertJson("colorKeys $i matrix t=$t", sm.obj["matrix"], numbers(colorMatrix(got, f, Presets.FILTERS)))
            }
        }
    }

    @Test fun colors() {
        for ((i, c) in fn["colors"]!!.arr.withIndex()) {
            val a = c.obj["adjust"]!!.obj.let { Adjust(it["exposure"]?.num, it["contrast"]?.num, it["saturation"]?.num, it["temperature"]?.num, tint = it["tint"]?.num) }
            val f = (c.obj["filter"] as? JsonObject)?.let { FilterRef(it["id"]!!.str, it["amount"]!!.num) }
            assertJson("color $i", c.obj["matrix"], numbers(colorMatrix(a, f, Presets.FILTERS)))
        }
    }

    @Test fun cuts() {
        for ((i, c) in fn["cuts"]!!.arr.withIndex()) {
            val p = EditJson.parse(c.obj["project"]!!)
            val cuts = c.obj["cuts"]!!.arr.map { Range(it.obj["startSec"]!!.num, it.obj["endSec"]!!.num) }
            val got = applyCuts(p, c.obj["asset"]!!.str, cuts)
            assertJson("cuts $i", c.obj["result"], EditJson.encode(got))
        }
    }

    @Test fun v1() {
        for ((i, c) in fn["v1"]!!.arr.withIndex()) {
            val v1 = EditJson.parseV1(c.obj["v1"]!!)
            val info = c.obj["info"]!!.obj
            val size = SourceSize(info["width"]!!.num.toInt(), info["height"]!!.num.toInt(), info["fps"]!!.num, (info["hasAudio"] as JsonPrimitive).booleanOrNull)
            val p = fromV1(v1, size)
            assertJson("v1 $i project", c.obj["project"], EditJson.encode(p), 0.0)
            assertJson("v1 $i back", c.obj["back"], toV1(p)?.let(EditJson::encodeV1) ?: JsonNull, 0.0)
            // The on-device v1 edit converts the same way.
            assertEquals(p, fromV1(v1.toVideoEdit(), v1.sourceTakeId, size))
        }
    }

    @Test fun chromaKeyMatches() {
        val cases = fn["chroma"]!!.arr
        assertEquals(30, cases.size)
        for ((i, c) in cases.withIndex()) {
            val k = c.obj["key"]!!.obj
            val key = Chroma(k["color"]!!.str, k["similarity"]?.num, k["smoothness"]?.num, k["spill"]?.num)
            val rgb = c.obj["rgb"]!!.arr.map { it.num }
            val got = ChromaKey.apply(rgb[0], rgb[1], rgb[2], key)
            val want = c.obj["out"]!!.arr.map { it.num }
            for (j in 0..3) assertEquals("chroma $i[$j]", want[j], got[j], 1e-6)
        }
    }

    // ------------------------------------------------------------------ Edit suite additions
    @Test fun masks() {
        for (c in fn["masks"]!!.arr) {
            val m = EditJson.parse(maskProject(c.obj["mask"]!!)).tracks[0].items[0].let { (it as VideoClip).mask!! }
            for (s in c.obj["samples"]!!.arr) {
                val (u, v, want) = s.arr.map { it.num }
                assertEquals("mask $m at $u,$v", want, maskAlpha(m, u, v), 1e-6)
            }
        }
    }

    private fun maskProject(mask: JsonElement): JsonElement = Fixtures.load("projects.json").arr[0].obj["project"]!!.obj.let { p ->
        val tracks = p["tracks"]!!.arr
        val main = tracks[0].obj
        val clip = JsonObject(main["items"]!!.arr[0].obj + ("mask" to mask))
        JsonObject(p + ("tracks" to JsonArray(listOf(JsonObject(main + ("items" to JsonArray(listOf(clip))))))))
    }

    @Test fun tone() {
        for (c in fn["tone"]!!.arr) {
            val sh = c.obj["shadows"]!!.num; val hi = c.obj["highlights"]!!.num
            for (s in c.obj["samples"]!!.arr) assertEquals("tone $sh/$hi at ${s.arr[0].num}", s.arr[1].num, toneAdjust(s.arr[0].num, sh, hi), 1e-6)
        }
    }

    private fun curveOf(e: JsonElement) = SpeedCurve(wireOf<SpeedPreset>(e.obj["preset"]!!.str)!!, e.obj["points"]!!.arr.map { SpeedPoint(it.arr[0].num, it.arr[1].num) })

    @Test fun speedCurves() {
        for (c in fn["speedCurves"]!!.arr) {
            val co = c.obj["clip"]!!.obj
            val clip = VideoClip("c", "src", co["inSec"]!!.num, co["outSec"]!!.num, co["speed"]!!.num, speedCurve = curveOf(co["speedCurve"]!!))
            assertEquals("length", c.obj["length"]!!.num, clipLength(clip), 1e-6)
            for (s in c.obj["curve"]!!.arr) assertEquals("curve at ${s.arr[0].num}", s.arr[1].num, r6(curveSpeed(clip.speedCurve!!, s.arr[0].num)), 1e-6)
            for (s in c.obj["timeAt"]!!.arr) assertEquals("timeAt ${s.arr[0].num}", s.arr[1].num, r6(clipTimeAt(clip, s.arr[0].num)), 1e-6)
            // clipSourceAt inverts clipTimeAt.
            for (s in c.obj["timeAt"]!!.arr) assertEquals("sourceAt ${s.arr[1].num}", s.arr[0].num, clipSourceAt(clip, s.arr[1].num), 1e-5)
            assertJson("sub", c.obj["sub"], EditJson.encodeSpeedCurve(subCurve(clip.speedCurve!!, 0.25, 0.8)))
        }
        val presets = fn["speedPresets"]!!.obj
        assertEquals(presets.keys.toList(), SPEED_PRESETS.keys.map { it.wire })
        for ((k, pts) in SPEED_PRESETS) assertJson("preset ${k.wire}", presets[k.wire], EditJson.encodeSpeedCurve(SpeedCurve(k, pts)).getValue("points"), 0.0)
    }

    @Test fun voice() {
        for (c in fn["voice"]!!.arr) {
            val o = c.obj
            val chain = voiceChain(wireOf<VoiceEffect>(o["voiceEffect"]!!.str), (o["enhance"] as JsonPrimitive).booleanOrNull, o["sampleRate"]!!.num)
            assertJson("chain $o", o["chain"], JsonArray(chain.map { b -> buildJsonObject { put("b0", n(b.b0)); put("b1", n(b.b1)); put("b2", n(b.b2)); put("a1", n(b.a1)); put("a2", n(b.a2)) } }), 1e-9)
            val imp = DoubleArray(24).also { it[0] = 1.0 }
            val out = runChain(chain, imp)
            o["impulse"]!!.arr.forEachIndexed { i, w -> assertEquals("impulse $i", w.num, out[i], 1e-8) }
            val streaming = BiquadChain(chain)
            imp.forEachIndexed { i, x -> assertEquals("streaming $i", out[i], streaming.process(x), 1e-12) }
        }
    }

    @Test fun duckTimes() {
        for (c in fn["duckTimes"]!!.arr) {
            val d = c.obj["duck"]!!.obj
            val duck = Duck(fadeSec = d["fadeSec"]?.num, under = emptyList(), attackSec = d["attackSec"]?.num, releaseSec = d["releaseSec"]?.num)
            val (a, r) = duckTimes(duck)
            assertEquals(c.obj["times"]!!.arr[0].num, a, 1e-9); assertEquals(c.obj["times"]!!.arr[1].num, r, 1e-9)
        }
    }

    @Test fun suggestCutsMatches() {

        for ((i, c) in fn["suggestCuts"]!!.arr.withIndex()) {
            val words = c.obj["words"]!!.arr.map { Word(it.obj["text"]!!.str, it.obj["startSec"]!!.num, it.obj["endSec"]!!.num) }
            val o = c.obj["options"]!!.obj
            val opts = CutOptions(
                o["minSilenceSec"]?.num, o["keepPadSec"]?.num, (o["fillers"] as? JsonPrimitive)?.booleanOrNull, (o["repeats"] as? JsonPrimitive)?.booleanOrNull,
                o["extraFillers"]?.arr?.map { it.str },
            )
            val r = suggestCuts(words, c.obj["durationSec"]!!.num, opts)
            assertJson("suggestCuts $i", c.obj["result"], buildJsonObject {
                put("cuts", buildJsonArray {
                    r.cuts.forEach { k -> add(buildJsonObject { put("startSec", n(k.startSec)); put("endSec", n(k.endSec)); put("reason", k.reason.wire); k.text?.let { put("text", it) } }) }
                })
                put("savedSec", n(r.savedSec))
            })
        }
    }
}
