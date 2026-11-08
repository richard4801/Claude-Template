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

/** The server's renders (plans/api.md "The built edit, rendered" and Recreate "Export"), as the apps read them. */
class RecreateRenderJsonTest {
    private val json = kotlinx.serialization.json.Json

    @Test fun aPreviewThatLeavesSomethingOutIsLabelled() {
        val r = RecreateJson.render(json.parseToJsonElement("""{"sessionId":"es_1","revision":4,"state":"ready","url":"/v1/edit-sessions/es_1/preview.mp4?revision=4","durationSec":14.2,"width":405,"height":720,"unsupported":["captions","masks"]}"""))
        assertTrue(r.ready)
        assertEquals(4, r.revision)
        assertEquals("Preview of the cut", r.label)
        assertEquals(listOf("captions", "masks"), r.unsupported)
    }

    @Test fun aFullRenderHasNoLabelAndNoneIsNotReady() {
        assertEquals(null, RecreateJson.render(json.parseToJsonElement("""{"sessionId":"es_1","revision":4,"state":"ready","unsupported":[]}""")).label)
        val none = RecreateJson.render(json.parseToJsonElement("""{"sessionId":"es_1","revision":null,"state":"none"}"""))
        assertTrue(none.failed); assertEquals(null, none.revision)
    }

    @Test fun anExportCarriesTheUseThisSoundReminder() {
        val r = RecreateJson.render(json.parseToJsonElement("""{"referenceId":"rx_1","sessionId":"es_1","revision":2,"sound":"guide","state":"rendering",
            "useThisSound":{"platform":"tiktok","sourceUrl":"https://www.tiktok.com/@a/video/1","startAtSec":0,"durationSec":14.2,"title":"Post with the original sound",
            "steps":["Open the original on TikTok","Tap Use this sound"],"note":"The guide sound is only for timing."}}"""))
        assertTrue(r.rendering)
        assertEquals("guide", r.sound)
        val u = r.useThisSound!!
        assertEquals("tiktok", u.platform)
        assertEquals(2, u.steps.size)
        assertEquals("The guide sound is only for timing.", u.note)
    }
}
