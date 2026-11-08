package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.planRender
import studio.muse.core.edit.problemOf

/**
 * The rebuilt Edit timeline (owner report 2026-11-08, phone, 9:16 take of 15 s): scrub maths, frame-exact landing,
 * split at the playhead, trimming by the clip's edges, and the clip's own sound as its own lane (detach, mute,
 * volume, fades), each asserted on the project.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EditTimelineTest {
    private object NoBackend : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?): Pair<EditorEstimate?, String?> = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private fun TestScope.controller(sound: Boolean = true) = EditSuiteController(this, NoBackend).also {
        it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, sound)), "Take", "take_1", null, reopened = false)
    }

    private fun EditSuiteController.p() = project!!

    // ------------------------------------------------------------------ geometry
    @Test fun theStartOfTheTimelineSitsUnderTheCentrePlayheadAtZero() {
        val w = 1080f; val pps = 100f
        assertEquals(540f, TimelineMath.xOf(0.0, 0.0, w, pps), 1e-3f)
        assertEquals(0.0, TimelineMath.timeAt(540f, 0.0, w, pps), 1e-9)
        // 2 s later, the clip start is 200 px left of the playhead.
        assertEquals(340f, TimelineMath.xOf(0.0, 2.0, w, pps), 1e-3f)
    }

    @Test fun draggingLeftGoesLaterAndStaysInsideTheEdit() {
        assertEquals(1.5, TimelineMath.dragged(1.0, -50f, 100f, 15.0), 1e-9)
        assertEquals(0.5, TimelineMath.dragged(1.0, 50f, 100f, 15.0), 1e-9)
        assertEquals(0.0, TimelineMath.dragged(1.0, 5000f, 100f, 15.0), 1e-9)
        assertEquals(15.0, TimelineMath.dragged(1.0, -5000f, 100f, 15.0), 1e-9)
    }

    @Test fun scrubbingLandsOnAFrameWhenTheFingerStops() {
        assertEquals(1.0, TimelineMath.snapFrame(1.01, 30.0), 1e-9)
        assertEquals(31 / 30.0, TimelineMath.snapFrame(1.02, 30.0), 1e-9)
        assertEquals(12 / 24.0, TimelineMath.snapFrame(0.49, 24.0), 1e-9)
    }

    @Test fun zoomIsClampedAndTheRulerRefinesAsYouZoomIn() {
        assertEquals(TimelineMath.MIN_PPS, TimelineMath.clampPps(1f))
        assertEquals(TimelineMath.MAX_PPS, TimelineMath.clampPps(9999f))
        assertEquals(5.0, TimelineMath.rulerStep(10f), 0.0)
        assertEquals(1.0, TimelineMath.rulerStep(34f), 0.0)
        assertEquals(0.25, TimelineMath.rulerStep(300f), 0.0)
        assertEquals("0:02", TimelineMath.rulerLabel(2.0)); assertEquals("1:05.5", TimelineMath.rulerLabel(65.5)); assertEquals("0:00.25", TimelineMath.rulerLabel(0.25))
    }

    @Test fun trimHandlesMoveTheSourceInAndOutWithinLimits() {
        // Right edge dragged 100 px left at 100 px/s, 1×: out 15 → 14.
        assertEquals(0.0 to 14.0, TimelineMath.trimmed(0.0, 15.0, 1.0, 15.0, left = false, dxPx = -100f, ppsPx = 100f))
        // Left edge 50 px right at 2×: in 0 → 1.
        assertEquals(1.0 to 15.0, TimelineMath.trimmed(0.0, 15.0, 2.0, 15.0, left = true, dxPx = 50f, ppsPx = 100f))
        // Can't go past the file or below 0.1 s of source.
        assertEquals(0.0 to 15.0, TimelineMath.trimmed(0.0, 15.0, 1.0, 15.0, left = false, dxPx = 900f, ppsPx = 100f))
        assertEquals(14.9 to 15.0, TimelineMath.trimmed(0.0, 15.0, 1.0, 15.0, left = true, dxPx = 9000f, ppsPx = 100f))
    }

    // ------------------------------------------------------------------ editor state
    @Test fun scrubPausesMovesThePlayheadAndEndsOnAFrame() = runTest {
        val c = controller()
        c.act(EditAction.PlayPause); assertTrue(c.ui.value.playing)
        c.act(EditAction.Scrub(4.012))
        assertFalse(c.ui.value.playing); assertTrue(c.ui.value.scrubbing); assertEquals(4.012, c.ui.value.playheadSec, 1e-9)
        c.act(EditAction.Scrub(4.012, end = true))
        assertFalse(c.ui.value.scrubbing); assertEquals(4.0, c.ui.value.playheadSec, 1e-9)
        c.act(EditAction.Scrub(99.0, end = true)); assertEquals(15.0, c.ui.value.playheadSec, 1e-9)
    }

    @Test fun splitAtThePlayheadCutsTheClipThereAndUndoes() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(6.0, end = true))
        c.act(EditAction.Split)
        val clips = c.p().mainClips
        assertEquals(2, clips.size)
        assertEquals(6.0, clips[0].outSec, 1e-6); assertEquals(6.0, clips[1].inSec, 1e-6)
        assertEquals(15.0, durationSec(c.p()), 1e-6)
        c.act(EditAction.Undo); assertEquals(1, c.p().mainClips.size)
    }

    @Test fun splitTooCloseToAnEdgeIsRefusedWithAReason() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(0.0, end = true)); c.act(EditAction.Split)
        assertEquals(1, c.p().mainClips.size)
        assertNotNull(c.ui.value.message)
    }

    @Test fun selectThenTrimByTheEdgeIsOneUndoStep() = runTest {
        val c = controller()
        val id = c.p().mainClips.first().id
        c.act(EditAction.Select(id)); assertEquals(id, c.ui.value.selectedId)
        c.act(EditAction.Trim(id, 0.0, 14.0, done = false))
        c.act(EditAction.Trim(id, 0.0, 12.5, done = false))
        c.act(EditAction.Trim(id, 0.0, 12.5, done = true))
        assertEquals(12.5, c.p().mainClips.first().outSec, 1e-9)
        assertEquals(12.5, c.ui.value.duration, 1e-9)
        assertNull(c.ui.value.message)
        c.act(EditAction.Undo)
        assertEquals(15.0, c.p().mainClips.first().outSec, 1e-9)
        assertFalse(c.ui.value.canUndo)
    }

    @Test fun zoomIsKept() = runTest {
        val c = controller()
        c.act(EditAction.Zoom(120f)); assertEquals(120f, c.ui.value.pxPerSec)
    }

    // ------------------------------------------------------------------ the clip's own sound
    @Test fun theClipsSoundHasItsOwnLaneUnderTheVideo() = runTest {
        val c = controller()
        val lanes = lanesOf(c.p())
        assertEquals(TrackKind.MAIN, lanes[0].track?.kind); assertEquals(LaneKind.TRACK, lanes[0].kind)
        assertEquals(LaneKind.CLIP_SOUND, lanes[1].kind)
        assertTrue(lanes[1].top >= lanes[0].top + lanes[0].height)
        assertEquals("Clip sound", laneName(lanes[1]))
        // A take without sound has no sound lane.
        val silent = EditSuiteViewModel.newProject("t", 15.0, SourceSize(1080, 1920, 30.0, false))
        assertTrue(lanesOf(silent).none { it.kind == LaneKind.CLIP_SOUND })
    }

    @Test fun detachAudioMovesTheSoundToItsOwnClipAndSilencesTheVideo() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Split)
        val second = c.p().mainClips[1]
        c.act(EditAction.Select(second.id))
        c.act(EditAction.Volume(-6.0)); c.act(EditAction.Fades(0.5, 1.0))
        c.act(EditAction.DetachAudio)
        val p = c.p()
        assertEquals(true, p.mainClips[1].muted)
        assertNull(p.mainClips[0].muted)
        val track = p.tracks.single { it.name == SuiteOps.CLIP_SOUND_TRACK }
        assertEquals(TrackKind.VOICE, track.kind)
        val a = track.items.single() as AudioClip
        assertEquals("src", a.asset); assertEquals(6.0, a.startSec, 1e-6); assertEquals(6.0, a.inSec, 1e-6); assertEquals(15.0, a.outSec, 1e-6)
        assertEquals(SuiteOps.dbToGain(-6.0), a.volume!!, 0.01); assertEquals(0.5, a.fadeInSec!!, 1e-9); assertEquals(1.0, a.fadeOutSec!!, 1e-9)
        assertEquals(a.id, c.ui.value.selectedId) // the detached sound is selected
        assertNull(problemOf(p))
        // The render plays it from its own lane, and the video clip no longer carries sound.
        val plan = planRender(p, mapOf("src" to MediaInfo(15.0, 1080, 1920, 30.0, true)))
        assertTrue(plan.audioLanes.any { l -> l.clips.any { it.itemId == a.id } })
        assertFalse(plan.layers.flatMap { it.clips }.any { it.itemId == second.id && it.withAudio })
        // Undo puts the sound back on the clip.
        c.act(EditAction.Undo)
        assertNull(c.p().tracks.firstOrNull { it.name == SuiteOps.CLIP_SOUND_TRACK })
        assertNull(c.p().mainClips[1].muted)
    }

    @Test fun detachIsRefusedWithAReasonWhenItCannotWork() = runTest {
        val silent = controller(sound = false)
        silent.act(EditAction.DetachAudio)
        assertEquals("This clip has no sound", silent.ui.value.message)
        val fast = controller()
        fast.act(EditAction.Speed(2.0)); fast.act(EditAction.DetachAudio)
        assertEquals("Set the clip to 1× to detach its sound", fast.ui.value.message)
        assertTrue(fast.p().tracks.none { it.kind == TrackKind.VOICE })
    }

    @Test fun muteAndUnmuteTheClipSound() = runTest {
        val c = controller()
        c.act(EditAction.MuteClip(true)); assertEquals(true, c.p().mainClips.first().muted)
        c.act(EditAction.MuteClip(false)); assertNull(c.p().mainClips.first().muted)
        // Muting the main track from the tablet's sound-lane header.
        c.act(EditAction.ToggleTrackMuted("main")); assertEquals(true, c.p().main.muted)
        val plan = planRender(c.p(), mapOf("src" to MediaInfo(15.0, 1080, 1920, 30.0, true)))
        assertFalse(plan.layers.flatMap { it.clips }.any { it.withAudio })
    }

    // ------------------------------------------------------------------ waveforms
    @Test fun peaksKeepTheLoudestChannelPerSlice() {
        val b = Peaks.Companion.Builder(sampleRate = 100, channels = 2, perSec = 10f) // 10 frames per slice
        val pcm = ShortArray(40) // 20 frames
        pcm[2 * 3 + 1] = 16384 // frame 3, right channel: half scale
        pcm[2 * 15] = (-32768).toShort() // frame 15, left: full scale
        b.add(pcm)
        val p = b.build()
        assertEquals(2, p.values.size)
        assertEquals(0.5f, p.values[0], 1e-4f); assertEquals(1f, p.values[1], 1e-4f)
        assertEquals(0.5f, p.at(0.05), 1e-4f); assertEquals(0f, p.at(5.0), 0f)
        assertEquals(1f, p.max(0.0, 0.19), 1e-4f)
        assertEquals(0.2, p.durationSec, 1e-9)
    }
}
