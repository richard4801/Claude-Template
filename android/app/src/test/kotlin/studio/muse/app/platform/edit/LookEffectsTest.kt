package studio.muse.app.platform.edit

import android.graphics.Bitmap
import androidx.media3.effect.SingleColorLut
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.core.edit.Adjust
import studio.muse.core.edit.ColorStack
import studio.muse.core.edit.CubeCheck
import studio.muse.core.edit.CurveChannel
import studio.muse.core.edit.CurvePoint
import studio.muse.core.edit.Grain
import studio.muse.core.edit.Halation
import studio.muse.core.edit.Leak
import studio.muse.core.edit.LeakKind
import studio.muse.core.edit.Look
import studio.muse.core.edit.Vignette
import studio.muse.core.edit.colorMatrix
import java.io.File
import studio.muse.app.platform.edit.LookEffects.Stage

/** The look → Media3 effects builder, the pack in the app's assets, .cube import and filter thumbnails. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LookEffectsTest {
    private val context get() = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val library by lazy { LookLibrary(context) }

    private val full = Look(
        lut = "pack:film-gold", strength = 0.8, curves = mapOf(CurveChannel.RGB to listOf(CurvePoint(0.0, 0.05), CurvePoint(1.0, 0.95))), lift = 0.3,
        sharpen = 0.4, chromatic = 0.5, halation = Halation(0.4), leak = Leak(LeakKind.AMBER, 0.4), vignette = Vignette(0.4), grain = Grain(0.4, 2.0),
    )

    @Test fun stagesFollowThePipelineOrder() {
        val m = colorMatrix(Adjust(exposure = 0.2), null)
        val st = LookEffects.stages(m, full, library.packLut("film-gold"), 30.0)
        assertEquals(listOf(Stage.Sharpen::class, Stage.Chromatic::class, Stage.BakedLut::class, Stage.Halo::class, Stage.Finish::class), st.map { it::class })
        assertEquals(Stage.Finish(full.leak, full.vignette, full.grain, 30.0), st.last())
        val fx = LookEffects.effects(st)
        assertTrue(fx[0] is SharpenEffect); assertTrue(fx[1] is ChromaticEffect); assertTrue(fx[2] is SingleColorLut)
        assertTrue(fx[3] is HalationEffect); assertTrue(fx[4] is LookFinishEffect)
    }

    @Test fun matrixAloneStaysAnExactMatrixAndNothingIsNothing() {
        val m = colorMatrix(Adjust(contrast = 0.3), null)
        assertEquals(listOf(Stage.Matrix(m)), LookEffects.stages(m, null, null, 30.0))
        assertEquals(listOf(Stage.Matrix(m)), LookEffects.stages(m, Look(lut = "pack:film-gold", strength = 0.0, vignette = Vignette(0.0)), library.packLut("film-gold"), 30.0))
        assertEquals(emptyList<Stage>(), LookEffects.stages(null, Look(), null, 30.0))
        // A LUT that could not be loaded drops only the LUT step.
        assertEquals(listOf(Stage.Finish(null, null, Grain(0.2), 24.0)), LookEffects.stages(null, Look(lut = "cube1", grain = Grain(0.2)), null, 24.0))
    }

    @Test fun theBakedLutIsMatrixCurvesLutStrengthAndLiftInMedia3Order() {
        val m = colorMatrix(Adjust(saturation = -0.4, temperature = 0.3), null)
        val lut = library.packLut("film-gold")
        val bake = LookEffects.stages(m, full, lut, 30.0).filterIsInstance<Stage.BakedLut>().single()
        assertEquals(LookEffects.BAKE_SIZE, bake.size)
        val stack = ColorStack(m, full, lut)
        val cube = LookEffects.argbCube(bake.size, bake.cube)
        val n = bake.size - 1.0
        for ((r, g, b) in listOf(Triple(0, 0, 0), Triple(32, 0, 0), Triple(0, 32, 0), Triple(0, 0, 32), Triple(7, 19, 28), Triple(32, 32, 32))) {
            val want = stack.apply(doubleArrayOf(r / n, g / n, b / n)).map { Math.round(it * 255).toInt() }
            val px = cube[r][g][b]
            assertEquals("[$r][$g][$b]", want, listOf((px shr 16) and 0xff, (px shr 8) and 0xff, px and 0xff))
            assertEquals(0xff, px ushr 24)
        }
    }

    @Test fun identityBakeIsTheIdentityCubeInRgbOrder() {
        val cube = LookEffects.argbCube(3, ColorStack(null, Look(lift = 0.0), null).bakeCube(3))
        assertEquals(0xff000000.toInt(), cube[0][0][0])
        assertEquals(0xffff0000.toInt(), cube[2][0][0])
        assertEquals(0xff00ff00.toInt(), cube[0][2][0])
        assertEquals(0xff0000ff.toInt(), cube[0][0][2])
        assertEquals(0xff80ff00.toInt(), cube[1][2][0])
    }

    @Test fun grainFrameFollowsPresentationTime() {
        assertEquals(0, LookEffects.frameAt(0, 30.0))
        assertEquals(30, LookEffects.frameAt(1_000_000, 30.0))
        assertEquals(45, LookEffects.frameAt(1_500_000, 30.0))
        assertEquals(1, LookEffects.frameAt(33_334, 30.0))
    }

    /** Every float/vec uniform the programs set is declared and used by its shader (GlProgram throws on a missing one). */
    @Test fun shaderUniformsMatchWhatTheProgramsSet() {
        fun uniforms(src: String) = Regex("uniform\\s+\\w+\\s+(\\w+);").findAll(src).map { it.groupValues[1] }.toSet()
        fun used(src: String, name: String) = Regex("\\b$name\\b").findAll(src).count() >= 2
        val finishSet = setOf("uLeakAmount", "uLeakAngle", "uLeak0", "uLeak1", "uVigAmount", "uVigSize", "uVigSoft", "uGrainAmount", "uGrainCell", "uFrame", "uSize", "uTexSampler")
        assertEquals(finishSet, uniforms(LookShaders.FINISH))
        assertEquals(setOf("uTexSampler", "uShift"), uniforms(LookShaders.CHROMATIC))
        assertEquals(setOf("uTexSampler", "uTexel", "uRadius"), uniforms(LookShaders.BLUR_H))
        assertEquals(setOf("uTexSampler", "uBlurH", "uTexel", "uRadius", "uAmount"), uniforms(LookShaders.SHARPEN))
        assertEquals(setOf("uTexSampler", "uBlurH", "uTexel", "uRadius", "uAmount", "uThreshold", "uTint"), uniforms(LookShaders.HALATION))
        for (src in listOf(LookShaders.FINISH, LookShaders.CHROMATIC, LookShaders.BLUR_H, LookShaders.SHARPEN, LookShaders.HALATION))
            for (u in uniforms(src)) assertTrue("$u is declared but never used", used(src, u))
        assertTrue(LookShaders.BLUR_H.contains("k < 511"))
    }

    @Test fun thePackShipsAsAppAssets() {
        val pack = library.pack
        assertEquals(32, pack.looks.size)
        for (e in pack.looks) assertEquals(e.id, 17, library.packLut(e.id).size)
        assertEquals("MUSE Gold 200", library.packLut("film-gold").title)
        assertEquals(library.packLut("film-gold"), library.lutFor(Look(lut = "pack:film-gold"), emptyMap()))
        assertNull(library.lutFor(Look(lut = "pack:nope"), emptyMap()))
        assertNull(library.lutFor(Look(lut = "cube1"), emptyMap()))
        assertNull(library.lutFor(null, emptyMap()))
    }

    @Test fun importedCubesAreCheckedAndLoadedFromTheirFile() = runBlocking {
        val dir = File(context.cacheDir, "cubes").apply { mkdirs() }
        val good = File(dir, "tiny.cube").apply { writeText("TITLE \"tiny\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n") }
        val ok = LookLibrary.checkImport(good, Dispatchers.Unconfined) as CubeCheck.Ok
        assertEquals(2, ok.size); assertEquals("tiny", ok.title)
        assertEquals(2, library.lutFor(Look(lut = "cube1"), mapOf("cube1" to good))!!.size)
        val bad = File(dir, "bad.cube").apply { writeText("LUT_1D_SIZE 16\n") }
        assertEquals(CubeCheck.Bad("line 1: 1D LUTs are not supported, use a 3D .cube"), LookLibrary.checkImport(bad, Dispatchers.Unconfined))
        assertNull(library.lutFor(Look(lut = "cube2"), mapOf("cube2" to bad)))
        assertTrue(LookLibrary.checkImportText("0 0 0\n") is CubeCheck.Bad)
    }

    @Test fun thumbnailsRenderEveryPackLookAt96PxTall() = runBlocking {
        val frame = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
        for (y in 0 until 180) for (x in 0 until 320) frame.setPixel(x, y, android.graphics.Color.rgb(x * 255 / 319, y * 255 / 179, 128))
        val thumbs = LookThumbnails.renderPack(frame, library, dispatcher = Dispatchers.Unconfined)
        assertEquals(library.pack.ids, thumbs.keys.toList())
        for ((id, b) in thumbs) { assertEquals(id, 96, b.height); assertEquals(id, 171, b.width) }
        // A mono look gives grey pixels.
        val bw = thumbs.getValue("bw-classic").getPixel(85, 48)
        assertEquals(android.graphics.Color.red(bw).toDouble(), android.graphics.Color.blue(bw).toDouble(), 3.0)
    }
}
