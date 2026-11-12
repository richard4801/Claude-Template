package studio.muse.app

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.SuiteScreen
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts

/** Claude sees what is on screen (owner, 2026-11-11): the shared draft's `screen` (server suite/screen.ts). */
class SuiteScreenTest {
    @Test fun slotsBecomeInputsInOrder() {
        val slots = InputSlots(mapOf(
            SlotId(SlotKind.IMAGE, 0) to SlotValue("beach.jpg", image = ImageRef(url = "/uploads/u/beach.jpg"), role = "location"),
            SlotId(SlotKind.START) to SlotValue("open.png", image = ImageRef(url = "/uploads/u/open.png")),
            SlotId(SlotKind.VIDEO) to SlotValue("walk.mov", media = SuiteMediaRef(key = "u/walk.mov", seconds = 4.0)),
            SlotId(SlotKind.IMAGE, 1) to SlotValue("late.jpg", progress = 0.4f),
        ))
        val i = SuiteScreen.inputs(slots)
        assertEquals(listOf("start", "reference 1", "reference 2", "video 1"), i.map { it.slot })
        assertEquals("location", i[1].role)
        assertEquals("uploading", i[2].state)
        assertEquals("u/walk.mov", i[3].key)
    }

    @Test fun directedGuideAndJson() {
        val cam = """{"mode":"directed","guide":{"video":{"key":"c/grey.mp4","seconds":6},"use":"blocking","cameraSessionId":"cs_1"}}"""
        val g = SuiteScreen.guide(cam)!!
        assertEquals("cs_1", g.cameraSessionId)
        assertEquals("c/grey.mp4", g.key)
        assertNull(SuiteScreen.guide("""{"mode":"preset"}"""))
        val j = SuiteScreen.json("swap", SuiteShotRequest(mode = "swap", clipId = "cl_1", prompt = ""), listOf(SuiteScreen.Input("swap.clip", "video", clipId = "cl_1")), at = null)
        assertNull(j["at"])
        assertEquals(JsonPrimitive("cl_1"), (j["request"] as JsonObject)["clipId"])
        assertEquals(1, (j["inputs"] as JsonArray).size)
        assertNotNull(SuiteScreen.json("shot", null, emptyList())["at"])
    }

    @Test fun directedAndPinnedModelTravelWithTheDraft() {
        val cam = """{"mode":"directed","guide":{"video":{"key":"c/grey.mp4"},"use":"blocking"}}"""
        val d = ComposerDraft(directed = cam, engineModel = "kling", resolution = "1080p")
        val s = ComposerDrafts.draft(d)
        val back = ComposerDrafts.restore(s, ComposerDraft())
        assertEquals("kling", back.engineModel)
        assertEquals("1080p", back.resolution)
        assertNotNull(SuiteScreen.guide(back.directed))
        assertNull(ComposerDrafts.restore(ComposerDrafts.draft(ComposerDraft()), d).directed)
    }
}
