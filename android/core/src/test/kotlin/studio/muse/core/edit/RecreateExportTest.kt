package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Recreate's export: the reference's sound as the only sound (guide), or no sound at all, timed for it. */
class RecreateExportTest {
    private val built = EditProject(
        sourceTakeId = "t1", canvas = Canvas(1080, 1920, 30.0),
        assets = listOf(Asset("a1", AssetKind.VIDEO, take = "t1"), Asset("a2", AssetKind.VIDEO, take = "t2")),
        tracks = listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "a1", 0.0, 2.0, 1.0), VideoClip("c2", "a2", 0.0, 2.4, 1.0)))),
    )
    private val infos = mapOf("a1" to MediaInfo(5.0, 1080, 1920, 30.0, true), "a2" to MediaInfo(5.0, 1080, 1920, 30.0, true),
        RecreateExport.GUIDE_ASSET to MediaInfo(4.4, 180, 320, 30.0, true))

    @Test fun theGuideIsTheOnlySound() {
        val p = RecreateExport.withGuide(built, 4.4)
        val plan = planRender(p, infos)
        val sounding = plan.audioLanes.flatMap { it.entries }.filterIsInstance<ClipEntry>().map { it.clip.assetId } +
            plan.layers.filter { it.withAudio }.flatMap { it.entries }.filterIsInstance<ClipEntry>().filter { it.clip.withAudio }.map { it.clip.assetId }
        assertEquals(listOf(RecreateExport.GUIDE_ASSET), sounding.distinct())
        // Applying it twice keeps one guide.
        assertEquals(1, RecreateExport.withGuide(p, 4.4).tracks.count { it.id == RecreateExport.GUIDE_TRACK })
    }

    @Test fun silentHasNoSound() {
        val plan = planRender(RecreateExport.silent(RecreateExport.withGuide(built, 4.4)), infos)
        assertTrue(plan.audioLanes.flatMap { it.entries }.filterIsInstance<ClipEntry>().none { it.clip.withAudio })
        assertTrue(plan.layers.none { it.withAudio })
    }
}
