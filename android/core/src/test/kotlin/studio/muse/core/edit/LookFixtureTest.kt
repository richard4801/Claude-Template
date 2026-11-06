package studio.muse.core.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.core.edit.Fixtures.assertJson
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The shared looks fixture (looks.json, generated from server/api/src/editor/look.ts): the Kotlin port must give the
 * same LUT samples, curves, noise, vignette, leak, radii, .cube verdicts and full renders.
 */
class LookFixtureTest {
    private val f = Fixtures.load("looks.json").obj
    private val packDir = File("../../server/api/assets/lookpack/looks")

    private fun lut(name: String): Lut = when (name) {
        "test5" -> parseCube(f["cubes"]!!.obj["test5"]!!.str)
        "pack:film-gold" -> parseCube(File(packDir, "film-gold.cube").readText())
        else -> error("unknown lut $name")
    }

    private fun near(where: String, want: Double, got: Double, tol: Double) {
        if (abs(want - got) > tol) fail("$where: expected $want, got $got (tolerance $tol)")
    }

    @Test fun lutSamples() {
        for (s in f["lutSamples"]!!.arr) {
            val l = lut(s.obj["lut"]!!.str)
            val rgb = s.obj["rgb"]!!.arr.map { it.num }
            val got = lutSample(l, rgb[0], rgb[1], rgb[2])
            s.obj["out"]!!.arr.forEachIndexed { i, w -> near("lutSample ${s.obj["lut"]!!.str} $rgb [$i]", w.num, got[i], 1e-4) }
        }
    }

    @Test fun curves() {
        for (c in f["curves"]!!.arr) {
            val pts = c.obj["points"]!!.arr.map { CurvePoint(it.arr[0].num, it.arr[1].num) }
            val fn = curveFn(pts)!!
            for (s in c.obj["samples"]!!.arr) near("curve $pts at ${s.arr[0].num}", s.arr[1].num, fn(s.arr[0].num), 1e-4)
        }
        assertNull(curveFn(listOf(CurvePoint(0.0, 0.0))))
        assertNull(curvesFn(emptyMap()))
    }

    @Test fun hash() {
        for (h in f["hash"]!!.arr) {
            val o = h.obj
            near("hash01 $o", o["v"]!!.num, hash01(o["x"]!!.num.toInt(), o["y"]!!.num.toInt(), o["frame"]!!.num.toInt()), 1e-12)
        }
    }

    @Test fun vignette() {
        for (v in f["vignette"]!!.arr) {
            val vo = v.obj["vignette"]!!.obj
            val vg = Vignette(vo["amount"]!!.num, vo["size"]?.num, vo["softness"]?.num)
            for (s in v.obj["samples"]!!.arr) near("vignette $vg at ${s.arr[0].num},${s.arr[1].num}", s.arr[2].num, vignetteMask(vg, s.arr[0].num, s.arr[1].num), 1e-4)
        }
    }

    @Test fun leak() {
        for (l in f["leak"]!!.arr) {
            val lk = EditJson.parseLook(JsonObject(mapOf("leak" to l.obj["leak"]!!))).leak!!
            for (s in l.obj["samples"]!!.arr) {
                val o = s.obj
                val got = leakColor(lk, o["u"]!!.num, o["v"]!!.num, o["t"]!!.num)
                o["out"]!!.arr.forEachIndexed { i, w -> near("leak $lk $o [$i]", w.num, got[i], 1e-4) }
            }
        }
    }

    @Test fun radii() {
        for (r in f["radii"]!!.arr) {
            val o = r.obj
            val short = o["short"]!!.num.toInt()
            // The fixture's parameters (scripts/editor-fixtures.ts).
            val (h, g) = when (short) {
                16 -> Halation(1.0, radius = 0.3) to Grain(1.0, size = 1.0)
                1080 -> Halation(1.0) to Grain(1.0, size = 2.0)
                else -> Halation(1.0, radius = 1.0) to Grain(1.0)
            }
            assertEquals("sharpen $short", o["sharpen"]!!.num.toInt(), sharpenRadius(short))
            assertEquals("halation $short", o["halation"]!!.num.toInt(), halationRadius(short, h))
            assertEquals("grain $short", o["grain"]!!.num.toInt(), grainCell(short, g))
        }
    }

    @Test fun cubes() {
        for (b in f["badCubes"]!!.arr) {
            val name = b.obj["name"]!!.str
            try { parseCube(b.obj["text"]!!.str); fail("bad cube \"$name\" parsed") } catch (_: CubeException) {}
            assertTrue(name, checkCube(b.obj["text"]!!.str) is CubeCheck.Bad)
        }
        val g = f["goodCube"]!!.obj
        val l = parseCube(g["text"]!!.str)
        assertEquals(g["size"]!!.num.toInt(), l.size)
        assertEquals(g["title"]!!.str, l.title)
        val ok = checkCube(g["text"]!!.str) as CubeCheck.Ok
        assertEquals(2, ok.size)
        // The reference's messages, line numbers included.
        assertEquals("line 1: 1D LUTs are not supported, use a 3D .cube", (checkCube("LUT_1D_SIZE 16\n") as CubeCheck.Bad).message)
        assertEquals("line 2: expected three numbers", (checkCube("LUT_3D_SIZE 2\n0 0 x\n") as CubeCheck.Bad).message)
        assertEquals("expected 2³ = 8 entries, found 2", (checkCube("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n") as CubeCheck.Bad).message)
        assertEquals("line 1: LUT_3D_SIZE must be 2–64", (checkCube("LUT_3D_SIZE 65\n") as CubeCheck.Bad).message)
        // Windows line ends, a range header and an inline comment.
        val r = parseCube("LUT_3D_INPUT_RANGE 0 2\r\nLUT_3D_SIZE 2 # two\r\n" + "0 0 0\r\n".repeat(8))
        assertEquals(2.0, r.domainMax[1], 0.0)
    }

    /** The fixture picture: its values are k/255 rounded to 4 decimals, so restore them exactly. */
    private fun image(): LookImage {
        val im = f["image"]!!.obj
        val w = im["width"]!!.num.toInt(); val h = im["height"]!!.num.toInt()
        val d = im["data"]!!.arr.map { (it.num * 255).roundToInt() / 255f }.toFloatArray()
        return LookImage(w, h, d)
    }

    @Test fun renders() {
        val img = image()
        val renders = f["renders"]!!.arr
        assertEquals(11, renders.size)
        for (r in renders) {
            val o = r.obj
            val name = o["name"]!!.str
            val look = EditJson.parseLook(o["look"]!!)
            val matrix = (o["matrix"] as? JsonArray)?.map { it.num }
            val l = (o["lut"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.let(::lut)
            val tone = (o["tone"] as? JsonObject)?.let { Tone(it["shadows"]?.num ?: 0.0, it["highlights"]?.num ?: 0.0) }
            val out = renderLook(img, look, matrix, l, frame = o["frame"]!!.num.toInt(), fps = 30.0, tone = tone)

            val want = o["out"]!!.arr
            assertEquals(want.size, out.data.size)
            var worst = 0.0
            for (i in want.indices) worst = maxOf(worst, abs(want[i].num - out.data[i]))
            assertTrue("render \"$name\": worst channel difference $worst", worst <= 1e-3)
        }
    }

    @Test fun matrixInTheFixtureIsTheModelsColorMatrix() {
        val m = colorMatrix(Adjust(exposure = 0.1, saturation = 0.2), FilterRef("warm", 0.5), Presets.FILTERS)
        assertJson("matrix", f["matrix"], numbers(m))
    }

    @Test fun bundledPackListsItsLooksAndEveryCubeParsesAtSize17() {
        val pack = LookPack.parse(File(packDir, "looks.json").readText())
        assertEquals(32, pack.looks.size)
        assertEquals(17, pack.cubeSize)
        val fixture = f["pack"]!!.obj
        assertEquals(fixture["cubeSize"]!!.num.toInt(), pack.cubeSize)
        assertEquals(fixture["ids"]!!.arr.map { it.str }, pack.ids)
        assertEquals(LookPack.IDS.toList(), pack.ids)
        for (e in pack.looks) {
            val l = parseCube(File(packDir, e.file).readText())
            assertEquals(e.id, 17, l.size)
            assertEquals("pack:${e.id}", e.look.lut)
            assertEquals(1.0, e.look.strength!!, 0.0)
            assertNull(Look::class.simpleName, problemOf(projectWith(e.look)))
        }
        val gold = pack.packLook("film-gold")!!
        assertEquals(Grain(0.22, 1.2), gold.grain)
        assertNull(pack.packLook("nope"))
        // The fixture's "pack look film-gold" render uses exactly the pack's look.
        val fromFixture = f["renders"]!!.arr.first { it.obj["name"]!!.str == "pack look film-gold" }.obj["look"]!!
        assertEquals(EditJson.parseLook(fromFixture), gold)
    }

    private fun projectWith(look: Look) = EditProject(
        sourceTakeId = "t", canvas = Canvas(1080, 1920, 30.0), assets = listOf(Asset("src", AssetKind.VIDEO, take = "t", durationSec = 10.0)),
        tracks = listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "src", 0.0, 5.0, look = look)))),
    )

    @Test fun lookJsonRoundTripsAndOmitsAbsentOptionals() {
        val look = Look(
            lut = "pack:film-cine", strength = 0.75,
            curves = linkedMapOf(CurveChannel.RGB to listOf(CurvePoint(0.0, 0.05), CurvePoint(1.0, 0.95)), CurveChannel.B to listOf(CurvePoint(0.0, 0.1), CurvePoint(0.5, 0.5), CurvePoint(1.0, 1.0))),
            lift = 0.2, sharpen = 0.3, chromatic = 0.4, halation = Halation(0.5, threshold = 0.8), leak = Leak(LeakKind.TEAL, 0.3),
            vignette = Vignette(-0.4, softness = 0.6), grain = Grain(0.2),
        )
        val p = projectWith(look)
        val text = EditJson.stringify(p)
        assertEquals(p, EditJson.parse(text))
        val enc = EditJson.encodeLook(look)
        assertEquals(setOf("lut", "strength", "curves", "lift", "sharpen", "chromatic", "halation", "leak", "vignette", "grain"), enc.keys)
        assertEquals(setOf("amount", "threshold"), enc["halation"]!!.obj.keys)
        assertEquals(setOf("kind", "amount"), enc["leak"]!!.obj.keys)
        assertEquals("""{"lut":"cube1"}""", EditJson.encodeLook(Look(lut = "cube1")).toString())
        assertEquals("""[[0,0.05],[1,0.95]]""", enc["curves"]!!.obj["rgb"].toString())
        // An image item carries a look too.
        val img = ImageItem("i1", "pic", 0.0, 2.0, look = Look(grain = Grain(0.5)))
        assertEquals(img, EditJson.parse(EditJson.stringify(p.copy(
            assets = p.assets + Asset("pic", AssetKind.IMAGE, upload = "u"),
            tracks = p.tracks + Track("im", TrackKind.IMAGE, items = listOf(img)),
        ))).tracks[1].items[0])
        // Every look in the projects fixture (if any) and the validation fixture round-trips exactly.
        for (c in Fixtures.load("validation.json").arr) {
            val src = c.obj["project"]!!
            val parsed = try { EditJson.parse(src) } catch (_: EditProblem) { continue }
            assertJson("${c.obj["name"]!!.str}: round trip", src, EditJson.encode(parsed), 0.0)
        }
    }

    @Test fun paletteLooksAreValidOnlyWhenShipped() {
        val look = Look(lut = "palette:teal_neon", strength = 0.8)
        assertEquals("teal_neon", look.paletteId)
        assertNull(look.packId); assertNull(look.lutAssetId)
        assertEquals("film-cine", Look(lut = "pack:film-cine").packId)
        assertNull(Look(lut = "pack:film-cine").lutAssetId)
        assertEquals("cube1", Look(lut = "cube1").lutAssetId)
        assertNull(Look(lut = "cube1").paletteId)
        val p = projectWith(look)
        val none = problemOf(p)!!
        assertEquals("edits.tracks.0.items.0.look.lut", none.field)
        assertEquals("unknown look", none.reason)
        assertNull(problemOf(p, paletteIds = setOf("teal_neon")))
        assertEquals("unknown look", problemOf(p, paletteIds = setOf("other"))!!.reason)
        assertEquals("must be \"pack:<id>\", \"palette:<id>\" or a lut asset id", problemOf(projectWith(Look(lut = "nope")))!!.reason)
        assertEquals(p, EditJson.parse(EditJson.stringify(p)))
    }

    @Test fun suiteLooksIndexIsReadLeniently() {
        val s = SuiteLooks.parse(
            """{"version":1,"cubeSize":17,"looks":[
              {"id":"teal_neon","name":"Teal Neon","kind":"palette","file":"teal_neon.cube","lut":"palette:teal_neon","swatches":["#00FFFF"]},
              {"id":"bare","file":"bare.cube"},
              {"id":"escape","name":"x","file":"../evil.cube"},
              {"name":"no id","file":"a.cube"}]}""",
        )
        assertEquals(setOf("teal_neon", "bare"), s.ids)
        assertEquals("Teal Neon", s.nameOf("teal_neon"))
        assertEquals("bare", s.nameOf("bare"))
        assertEquals("missing", s.nameOf("missing"))
        assertEquals("teal_neon.cube", s.entry("teal_neon")!!.file)
        assertTrue(SuiteLooks.parse("not json").ids.isEmpty())
        assertTrue(SuiteLooks.parse("""{"looks":3}""").ids.isEmpty())
    }

    @Test fun lookShapeProblemsNameTheField() {
        fun problem(json: String): String? = try { EditJson.parseLook(kotlinx.serialization.json.Json.parseToJsonElement(json)); null } catch (e: EditProblem) { e.field }
        assertEquals("look.bloom", problem("""{"bloom":1}"""))
        assertEquals("look.leak.kind", problem("""{"leak":{"kind":"green","amount":0.3}}"""))
        assertEquals("look.curves.l", problem("""{"curves":{"l":[[0,0],[1,1]]}}"""))
        assertEquals("look.curves.rgb.1", problem("""{"curves":{"rgb":[[0,0],[1]]}}"""))
        assertEquals("look.grain.amount", problem("""{"grain":{}}"""))
        assertNull(problem("""{}"""))
    }

    @Test fun colorStackBakeMatchesThePixelPath() {
        val l = lut("pack:film-gold")
        val look = Look(lut = "pack:film-gold", strength = 0.7, curves = mapOf(CurveChannel.RGB to listOf(CurvePoint(0.0, 0.03), CurvePoint(0.5, 0.55), CurvePoint(1.0, 0.97))), lift = 0.4)
        val m = colorMatrix(Adjust(exposure = 0.2, saturation = -0.3), null, Presets.FILTERS)
        val stack = ColorStack(m, look, l)
        val n = 33
        val cube = stack.bakeCube(n)
        // Grid points are exact.
        for ((r, g, b) in listOf(Triple(0, 0, 0), Triple(32, 32, 32), Triple(5, 17, 30), Triple(16, 8, 4))) {
            val want = stack.apply(doubleArrayOf(r / 32.0, g / 32.0, b / 32.0))
            val i = ((r * n + g) * n + b) * 3
            for (c in 0 until 3) assertEquals(want[c], cube[i + c].toDouble(), 1e-6)
        }
        // Between grid points a trilinear lookup of the baked cube stays close to the exact stack.
        val baked = Lut(n, null, doubleArrayOf(0.0, 0.0, 0.0), doubleArrayOf(1.0, 1.0, 1.0), FloatArray(cube.size).also { out ->
            // Lut stores red fastest; the bake is Media3's [R][G][B] (blue fastest).
            for (r in 0 until n) for (g in 0 until n) for (b in 0 until n) for (c in 0 until 3) out[((b * n + g) * n + r) * 3 + c] = cube[((r * n + g) * n + b) * 3 + c]
        })
        var worst = 0.0
        val rnd = java.util.Random(7)
        repeat(2000) {
            val rgb = doubleArrayOf(rnd.nextDouble(), rnd.nextDouble(), rnd.nextDouble())
            val want = stack.apply(rgb.copyOf())
            val got = lutSample(baked, rgb[0], rgb[1], rgb[2])
            for (c in 0 until 3) worst = maxOf(worst, abs(want[c] - got[c]))
        }
        assertTrue("baked LUT error $worst", worst < 4.0 / 255)
        assertTrue(ColorStack(null, Look(), null).isIdentity)
    }

    @Test fun argbConversion() {
        val px = intArrayOf(0xff102030.toInt(), 0xffffffff.toInt(), 0x80000000.toInt())
        val img = LookImage.fromArgb(3, 1, px)
        assertEquals(0x10 / 255f, img.data[0], 0f)
        assertEquals(listOf(0xff102030.toInt(), 0xffffffff.toInt(), 0xff000000.toInt()), img.toArgb().toList())
    }
}
