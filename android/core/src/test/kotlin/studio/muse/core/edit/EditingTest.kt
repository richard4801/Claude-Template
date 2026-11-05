package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditingTest {
    private val src = Asset("src", AssetKind.VIDEO, take = "take_src", durationSec = 10.0, width = 1080, height = 1920, hasAudio = true)
    private val song = Asset("song", AssetKind.AUDIO, library = "music_01", durationSec = 30.0)
    private fun project(vararg clips: VideoClip) = EditProject(
        sourceTakeId = "take_src", canvas = Canvas(1080, 1920, 30.0, "#000000"), assets = listOf(src, song),
        tracks = listOf(Track("main", TrackKind.MAIN, items = clips.toList())),
    )
    private val p = project(VideoClip("c1", "src", 0.0, 4.0), VideoClip("c2", "src", 4.0, 10.0, speed = 2.0, transitionIn = Transition(TransitionKind.FADE, 0.5)))

    @Test fun splitAtATimelineTime() {
        // c1 0–4, c2 3.5–6.5 (2×). Split c2 at timeline 5.0 → source 4 + 1.5 × 2 = 7.
        val s = p.splitAt(5.0)!!
        val c = s.mainClips
        assertEquals(listOf("c1", "c2", "c2.2"), c.map { it.id })
        assertEquals(7.0, c[1].outSec, 1e-9); assertEquals(7.0, c[2].inSec, 1e-9)
        assertEquals(Transition(TransitionKind.FADE, 0.5), c[1].transitionIn)
        assertNull(c[2].transitionIn)
        assertEquals(durationSec(p), durationSec(s), 1e-9)
        assertNull(problemOf(s))
        // Inside the transition overlap, or too close to an edge: refused.
        assertNull(p.splitAt(3.7))
        assertNull(p.splitAt(0.05))
        assertNull(p.splitAt(20.0))
    }

    @Test fun splitCarriesKeyframesAcrossTheCut() {
        val k = project(VideoClip("c1", "src", 0.0, 4.0, keyframes = mapOf(KfProp.SCALE to listOf(Keyframe(0.0, 1.0), Keyframe(4.0, 2.0)))))
        val s = k.splitAt(1.0)!!.mainClips
        assertEquals(listOf(Keyframe(0.0, 1.0), Keyframe(1.0, 1.25)), s[0].keyframes!![KfProp.SCALE])
        assertEquals(listOf(Keyframe(0.0, 1.25), Keyframe(3.0, 2.0)), s[1].keyframes!![KfProp.SCALE])
    }

    @Test fun transitionsObeyTheHalfRule() {
        assertNull(p.setTransition("c1", Transition(TransitionKind.FADE, 0.5)))          // first clip
        assertNull(p.setTransition("c2", Transition(TransitionKind.ZOOM, 1.6)))          // > half of c2 (3 s)
        val z = p.setTransition("c2", Transition(TransitionKind.ZOOM, 1.5))!!
        assertEquals(TransitionKind.ZOOM, z.mainClips[1].transitionIn!!.kind)
        assertNull(problemOf(z))
        assertNull(z.setTransition("c2", Transition(TransitionKind.ZOOM, 1.5)))           // no change
        assertNull(z.setTransition("c2", null)!!.mainClips[1].transitionIn)
    }

    @Test fun addMoveAndRemoveItems() {
        val withMusic = p.addTrack(TrackKind.MUSIC, "mus")!!
            .addItem("mus", AudioClip("m1", "song", 0.0, 0.0, 3.0))!!
            .addItem("mus", AudioClip("m2", "song", 4.0, 5.0, 6.0))!!
        assertNull(problemOf(withMusic))
        assertNull(withMusic.addItem("mus", AudioClip("m3", "song", 2.0, 0.0, 2.0)))       // overlaps m1
        assertNull(withMusic.moveItem("m2", 2.5))                                           // would overlap m1
        val moved = withMusic.moveItem("m2", 3.5)!!
        assertEquals(3.5, (moved.track("mus")!!.items[1] as AudioClip).startSec, 0.0)
        val other = moved.addTrack(TrackKind.SFX, "sfx")!!.moveItemToTrack("m1", "sfx")!!
        assertEquals(listOf("m1"), other.track("sfx")!!.items.map { it.id })
        assertNull(problemOf(other))
        // The main track keeps one clip; removing c1 drops the transition that would now be first.
        val one = p.removeItem("c1")!!
        assertNull(one.mainClips[0].transitionIn)
        assertNull(one.removeItem("c2"))
        assertNull(p.addItem("main", VideoClip("c1", "src", 0.0, 1.0)))                       // id in use
        assertNull(p.addTrack(TrackKind.MAIN))
    }

    @Test fun reorderingDropsTransitionsThatNoLongerFit() {
        val r = p.moveMainClip(1, 0)!!
        assertEquals(listOf("c2", "c1"), r.mainClips.map { it.id })
        assertNull(r.mainClips[0].transitionIn)
        assertNull(problemOf(r))
    }

    @Test fun hookTemplatesMakeValidTextItems() {
        var q = p.addTrack(TrackKind.TEXT, "txt")!!
        var start = 0.0
        for ((i, h) in Presets.HOOKS.take(3).withIndex()) { q = q.addItem("txt", h.toItem("t$i", start))!!; start += h.durationSec }
        assertNull(problemOf(q))
        assertEquals("hook-bold", (q.track("txt")!!.items[0] as TextItem).template)
    }

    @Test fun historyUndoesAndRedoes() {
        val h = ProjectHistory(p)
        assertFalse(h.canUndo)
        assertTrue(h.edit { it.splitAt(1.0) })
        assertFalse(h.edit { it.splitAt(0.01) })
        assertEquals(3, h.current.mainClips.size)
        assertTrue(h.undo()); assertEquals(p, h.current)
        assertTrue(h.redo()); assertEquals(3, h.current.mainClips.size)
        assertTrue(h.undo()); assertTrue(h.edit { it.setTransition("c2", null) })
        assertFalse(h.canRedo)
    }

    @Test fun ids() {
        assertEquals("c3", p.newId("c"))
        assertEquals("c1.2", p.newId("c1", dotted = true))
        assertNotNull(p.locate("c2"))
    }

    @Test fun envelopeInterpolates() {
        val env = listOf(GainPoint(1.0, 0.0), GainPoint(2.0, 1.0), GainPoint(3.0, 1.0))
        assertEquals(0.5, envelopeGain(env, 1.5), 1e-9)
        assertEquals(0.0, envelopeGain(env, 0.5), 1e-9)
        assertEquals(1.0, envelopeGain(env, 3.0), 1e-9)
    }
}
