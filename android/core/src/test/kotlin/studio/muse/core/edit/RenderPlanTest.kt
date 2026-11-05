package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The pure render planner behind the Media3 composition engine, on the fixture projects. */
class RenderPlanTest {
    private val projects = Fixtures.load("projects.json").arr.associate { it.obj["name"]!!.str to EditJson.parse(it.obj["project"]!!) }
    private val infos = mapOf(
        "src" to MediaInfo(10.0, 1080, 1920, 30.0, true),
        "pip" to MediaInfo(6.0, 720, 1280, 30.0, true),
        "logo" to MediaInfo(0.0, 512, 512),
        "song" to MediaInfo(30.0, 0, 0, 0.0, true),
        "vo" to MediaInfo(4.0, 0, 0, 0.0, true),
    )
    private fun plan(name: String) = planRender(projects.getValue(name), infos)
    private fun us(s: Double) = RenderPlan.us(s)

    /** Every layer and lane covers exactly the whole duration, in order, without overlaps. */
    private fun assertCovers(plan: RenderPlan) {
        for (entries in plan.layers.map { it.entries } + plan.audioLanes.map { it.entries }) {
            var cur = 0L
            for (e in entries) { assertEquals("contiguous", cur, e.startUs); assertTrue(e.durationUs > 0); cur = e.endUs }
            assertEquals("to the end", plan.durationUs, cur)
        }
    }

    @Test fun singleClipIsOneMainLayerUnderTheClock() {
        val p = plan("single clip")
        assertCovers(p)
        assertEquals(listOf(LayerRole.CLOCK, LayerRole.MAIN), p.layers.map { it.role })
        val c = p.layers[1].clips.single()
        assertEquals(0L, c.startUs); assertEquals(us(9.3), c.endUs)
        assertEquals(us(0.5), c.clipStartUs); assertEquals(us(9.8), c.clipEndUs)
        assertTrue(c.withAudio); assertTrue(p.hasAudio)
        assertEquals(VideoLook(null, 1080, 1920, 1.0, null, null), c.look)
        assertEquals(Placement.HIDDEN, p.placement(0, 1.0))
        assertEquals(Placement(1.0, 0.5, 0.5, 1.0, 0.0), p.placement(1, 1.0))
        assertEquals(Placement.HIDDEN.alpha, p.placement(1, 9.31).alpha, 0.0)
    }

    @Test fun transitionsAreLaidOutAsABRoll() {
        val p = plan("transitions")
        assertCovers(p)
        assertEquals(listOf(LayerRole.CLOCK, LayerRole.MAIN, LayerRole.MAIN), p.layers.map { it.role })
        val a = p.layers[1]; val b = p.layers[2]
        assertEquals(listOf("c1", "c3"), a.clips.map { it.itemId })
        assertEquals(listOf("c2"), b.clips.map { it.itemId })
        assertEquals(listOf(Gap(0, us(3.5)), Gap(us(6.5), us(8.5))), b.entries.filterIsInstance<Gap>())
        assertEquals(listOf(Gap(us(4.0), us(5.5))), a.entries.filterIsInstance<Gap>())
        // Fade at its middle: c2 (incoming) sits behind c1, so c1 fades out over an opaque c2.
        assertEquals(0.5, p.placement(1, 3.75).alpha, 1e-9)
        assertEquals(1.0, p.placement(2, 3.75).alpha, 1e-9)
        // Slide left at its middle (eased 0.5): c2 has moved half out, c3 half in; c3 is now on the front layer.
        assertEquals(0.0, p.placement(2, 6.0).centerX, 1e-9)
        assertEquals(1.0, p.placement(1, 6.0).centerX, 1e-9)
        assertEquals(1.0, p.placement(1, 6.0).alpha, 1e-9)
        // Sound crossfades with the envelopes from audioEnvelope.
        assertEquals(audioEnvelope(p.project, "main", "c2"), b.clips.single().envelope)
        assertTrue(p.overlays.isEmpty())
    }

    @Test fun fadeRemapGivesTheSamePictureAsIncomingOnTop() {
        // Reference: B (alpha b) over A (alpha a) over black. Remapped: A (a') over B (b').
        val p = plan("transitions")
        for (t in listOf(3.55, 3.6, 3.75, 3.9, 3.99)) {
            val pp = (t - 3.5) / 0.5
            val a = 1.0; val b = pp
            val ref = b + a * (1 - b)                      // coverage of a white A and white B: always 1
            val ta = p.placement(1, t).alpha; val tb = p.placement(2, t).alpha
            assertEquals(ref, ta + tb * (1 - ta), 1e-9)
            // and the share of B in the mix is b, of A is a(1−b)
            assertEquals(b, tb * (1 - ta), 1e-9)
            assertEquals(a * (1 - b), ta, 1e-9)
        }
    }

    @Test fun overlaysLooksAndPip() {
        val p = plan("pip text image look")
        assertCovers(p)
        assertEquals(listOf(LayerRole.CLOCK, LayerRole.OVERLAY, LayerRole.OVERLAY, LayerRole.MAIN), p.layers.map { it.role })
        assertEquals(listOf(null, "imgs", "pipt", "main"), p.layers.map { it.trackId })
        val main = p.layers[3].clips.single()
        assertEquals(colorMatrix(Adjust(exposure = 0.2), FilterRef("film", 0.7)), main.look!!.colorMatrix)
        val pip = p.layers[2].clips.single()
        assertEquals(us(1.0), pip.startUs); assertEquals(us(5.5), pip.endUs)
        assertFalse("volume 0: no sound", pip.withAudio)
        assertEquals(1080, pip.look!!.textureWidth); assertEquals(1920, pip.look!!.textureHeight)
        assertNotNull(pip.look!!.chroma)
        val logo = p.layers[1].clips.single()
        assertTrue(logo.isImage)
        assertEquals(1080, logo.look!!.textureWidth); assertEquals(1080, logo.look!!.textureHeight)
        assertEquals(colorMatrix(null, FilterRef("mono", 1.0)), logo.look!!.colorMatrix)
        // PiP scale keyframe (easeOut 0.2 → 0.4 over 0.5 s) at 0.25 s in: 0.2 + 0.2 × 0.75.
        val pl = p.placement(2, 1.25)
        assertEquals(0.35, pl.scale, 1e-9); assertEquals(0.75, pl.centerX, 1e-9); assertEquals(0.25, pl.centerY, 1e-9)
        assertEquals(Placement.HIDDEN, p.placement(2, 0.5))
        // Logo pops in: at 0.2 s (p 0.5) alpha = easeOut(0.5) and scale 0.2 × pop(0.5).
        val lg = p.placement(1, 0.2)
        assertEquals(0.75, lg.alpha, 1e-6)
        assertEquals(0.2 * (0.6 + 0.48 * (0.5 / 0.7)), lg.scale, 1e-6)
        // Texts: hook then typewriter.
        val texts = p.overlays.filterIsInstance<TextPiece>()
        assertEquals(listOf("t1", "t2"), texts.map { it.item.id })
        val tw = p.textFrame(texts[1], 3.75)!!
        assertEquals("Things nobody t", tw.text)
        assertNull(p.textFrame(texts[0], 3.0))
        assertEquals(0.2, p.textFrame(texts[0], 1.0)!!.centerY, 1e-9)
    }

    @Test fun audioLanesAndCaptions() {
        val p = plan("music ducking")
        assertCovers(p)
        assertEquals(listOf("mus", "voice"), p.audioLanes.map { it.trackId })
        val m = p.audioLanes[0].clips.single()
        assertEquals(us(10.0), m.endUs)                    // cut at the project's end
        assertEquals(us(5.0), m.clipStartUs); assertEquals(us(15.0), m.clipEndUs)
        assertTrue(m.removeVideo)
        assertEquals(audioEnvelope(p.project, "mus", "m1"), m.envelope)
        val v = p.audioLanes[1]
        assertEquals(listOf(Gap(0, us(6.0)), Gap(us(9.5), us(10.0))), v.entries.filterIsInstance<Gap>())
        val cap = p.overlays.filterIsInstance<CaptionPiece>().single()
        assertEquals(CaptionPreset.KARAOKE, cap.style.preset)
        // Karaoke at 2.5 s: page "serum changed my skin." with "changed" active → the first two highlighted.
        val f = p.captionFrame(cap, 2.5)!!
        assertEquals(listOf("serum", "changed", "my", "skin."), f.words)
        assertEquals(1, f.active)
        assertEquals(listOf(true, true, false, false), f.highlighted)
        assertNull(p.captionFrame(cap, 9.5))
    }

    @Test fun speedsDropFramesAndMutedClipsLoseTheirSound() {
        val s = plan("cut and speeds")
        val clips = s.layers[1].clips
        assertEquals(listOf(null, null, 30.0), clips.map { it.frameDropFps })
        assertEquals(listOf(1.0, 0.5, 2.0), clips.map { it.speed })
        val k = plan("volume keyframes")
        assertCovers(k)
        val c2 = k.layers.flatMap { it.clips }.single { it.itemId == "c2" }
        assertFalse(c2.withAudio)
        assertEquals(listOf("sfx"), k.audioLanes.map { it.trackId })
        // Dip to black: the colour fully covers at the middle, and neither clip shows through.
        val flash = k.overlays.filterIsInstance<FlashPiece>().single().flash
        val mid = (flash.startSec + flash.endSec) / 2
        assertEquals(1.0, k.flashAlpha(flash, mid), 1e-9)
        assertEquals(0.5, k.flashAlpha(flash, flash.startSec + (flash.endSec - flash.startSec) / 4), 1e-9)
        assertEquals(1.0, k.placement(1, flash.startSec + 0.05).alpha, 1e-9)
    }

    @Test fun backgroundLayerAndCoverCrop() {
        val base = projects.getValue("single clip")
        val p = base.copy(canvas = base.canvas.copy(width = 1080, height = 1080, background = "#FF0000"))
        val plan = planRender(p, infos)
        assertEquals(LayerRole.BACKGROUND, plan.layers.last().role)
        assertEquals(0xFFFF0000.toInt(), (plan.layers.last().entries.single() as StillEntry).argb)
        // A 9:16 source covering a square canvas: the top and bottom are cropped, rendered at the canvas size.
        val look = plan.layers[1].clips.single().look!!
        assertEquals(1080, look.textureWidth); assertEquals(1080, look.textureHeight)
        val crop = look.crop!!
        assertEquals(-1.0, crop.left, 1e-9); assertEquals(1.0, crop.right, 1e-9)
        assertEquals(2 * 1080.0 / 1920.0, crop.top - crop.bottom, 1e-9)
        // A contain-fit main clip keeps the whole picture: landscape canvas, portrait clip.
        val contain = p.copy(canvas = p.canvas.copy(width = 1920, height = 1080), tracks = listOf(p.main.copy(items = p.mainClips.map { it.copy(fit = Fit.CONTAIN) })))
        val l2 = planRender(contain, infos).layers[1].clips.single().look!!
        assertEquals(608, l2.textureWidth); assertEquals(1080, l2.textureHeight)
    }

    @Test fun invalidProjectsAreRefused() {
        val base = projects.getValue("single clip")
        val bad = base.copy(canvas = base.canvas.copy(fps = 0.0))
        assertEquals("edits.canvas.fps", runCatching { planRender(bad, infos) }.exceptionOrNull().let { (it as EditProblem).field })
    }
}
