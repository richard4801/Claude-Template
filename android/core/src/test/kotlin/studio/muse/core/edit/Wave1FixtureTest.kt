package studio.muse.core.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Wave 1 (plans/edit-parity.md): functions.json → wave1, from the TypeScript reference. */
class Wave1FixtureTest {
    private val w = Fixtures.load("functions.json").obj["wave1"]!!.obj
    private fun rgb(e: kotlinx.serialization.json.JsonElement) = e.arr.map { it.num }.toDoubleArray()

    @Test fun blendModes() {
        val cases = w["blend"]!!.arr
        assertEquals(BlendMode.entries.size * 4, cases.size)
        for (c in cases) {
            val o = c.obj
            val mode = BlendMode.entries.first { it.wire == o["mode"]!!.str }
            val got = blendPixel(mode, rgb(o["top"]!!), rgb(o["below"]!!), o["a"]!!.num)
            val want = rgb(o["out"]!!)
            for (i in 0..2) assertEquals("${mode.wire} $o", want[i], got[i], 1e-6)
        }
    }

    @Test fun cornersWithFlipsAndRotation() {
        for (c in w["corners"]!!.arr) {
            val o = c.obj
            val cv = o["canvas"]!!.obj
            val t = o["t"]!!.obj
            fun d(k: String) = (t[k] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.toDoubleOrNull()
            fun b(k: String) = (t[k] as? JsonPrimitive)?.booleanOrNull
            val tr = Transform(d("x"), d("y"), d("scale"), d("rotation"), b("flipX"), b("flipY"))
            val got = itemCorners(cv["width"]!!.num.toInt(), cv["height"]!!.num.toInt(), o["w"]!!.num, o["h"]!!.num, if (o["fit"]!!.str == "cover") Fit.COVER else Fit.CONTAIN, tr)
            val want = o["corners"]!!.arr.map { it.arr[0].num to it.arr[1].num }
            for (i in 0..3) { assertEquals("$o", want[i].first, got[i].first, 1e-6); assertEquals("$o", want[i].second, got[i].second, 1e-6) }
        }
    }

    @Test fun blurFillAndItsClip() {
        val b = w["blurFill"]!!.obj
        val got = blurFill(rgb(b["rgb"]!!), b["w"]!!.num.toInt(), b["h"]!!.num.toInt(), b["radius"]!!.num.toInt())
        val want = rgb(b["out"]!!)
        for (i in want.indices) assertEquals(want[i], got[i], 1e-6)
        assertEquals(BLUR_FILL_DARKEN, b["darken"]!!.num, 0.0)
        for (r in b["radii"]!!.arr) assertEquals(r.obj["radius"]!!.num.toInt(), blurFillRadius(r.obj["width"]!!.num.toInt(), r.obj["height"]!!.num.toInt()))
        val p = wave1Project()
        for (c in b["clipAt"]!!.arr) {
            val at = c.obj["at"]
            val got2 = blurFillClip(p, c.obj["t"]!!.num)
            if (at == null || at is JsonNull) assertNull(got2)
            else { assertEquals("t=${c.obj["t"]}", at.obj["clipId"]!!.str, got2!!.first); assertEquals(at.obj["local"]!!.num, got2.second, 1e-6) }
        }
    }

    @Test fun holdsTiming() {
        val h = w["hold"]!!.obj
        val p = wave1Project()
        val hold = p.mainClips[1]
        assertEquals(h["length"]!!.num, clipLength(hold), 1e-9)
        for (s in h["sourceAt"]!!.arr) assertEquals(s.obj["src"]!!.num, clipSourceAt(hold, s.obj["t"]!!.num), 1e-9)
        assertEquals(h["timeAt"]!!.num, clipTimeAt(hold, 4.05), 1e-9)
        for (c in h["cuts"]!!.arr) {
            val cuts = c.obj["cuts"]!!.arr.map { Range(it.obj["startSec"]!!.num, it.obj["endSec"]!!.num) }
            Fixtures.assertJson("hold cuts", c.obj["project"], EditJson.encode(applyCuts(p, "src", cuts)))
        }
        // Splitting a hold makes two holds of the same frame.
        val s = timeline(p)[1]
        val split = p.splitAt(s.startSec + 0.7)!!
        assertEquals(listOf(0.7, 0.8), split.mainClips.filter { it.holdSec != null }.map { Math.round(it.holdSec!! * 1000) / 1000.0 })
        assertNull(p.splitAt(s.startSec + 0.05)) // under 0.1 s
    }

    private fun wave1Project(): EditProject {
        val projects = Fixtures.load("projects.json").arr
        val o = projects.first { it.obj["name"]!!.str.startsWith("wave 1") }.obj
        return EditJson.parse(o["project"]!!)
    }
}
