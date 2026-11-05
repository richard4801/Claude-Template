package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.CreateTemplateRequest
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakeTemplates
import studio.muse.app.data.SampleData
import studio.muse.app.data.ShootRequest
import studio.muse.app.data.Template
import studio.muse.app.data.TemplateFilter
import studio.muse.app.data.TemplatePromptRequest
import studio.muse.app.ui.screens.TemplatesViewModel
import studio.muse.app.ui.screens.splitTags

/** Demo mode's templates follow the server's rules (plans/api.md "Photo templates"), and the library filters. */
class TemplatesTest {
    private val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)

    @Test fun ownersSeeLayersOthersSeeOneLockedLine(): Unit = runBlocking {
        val all = api.listTemplates()
        assertEquals(7, all.count { it.starter != null })
        assertTrue(all.filter { it.starter != null }.all { it.isOwner && it.layers != null })
        val maya = all.first { it.id == "tpl_maya_walk" }
        assertTrue(!maya.isOwner); assertNull(maya.layers); assertNull(maya.variationPool)
        assertTrue(all.none { it.id == "tpl_maya_private" })
        val p = api.templatePrompt(maya.id, TemplatePromptRequest(SampleData.DEMO, direction = "on the steps"))
        assertTrue(p.slots.any { it.locked && it.text == "Template: Golden hour walk" })
        assertTrue(!p.text.contains("warm candid street photo"))
        val shots = api.shoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, "", "", templateId = maya.id, shuffleSeed = 3))
        assertTrue(shots.all { it.templateName == "Golden hour walk" && !it.prompt.contains("warm candid") && it.variation == null })
        try { api.templateDraft(shots[0].id); error("should be hidden") } catch (e: ApiException) { assertEquals("template_hidden", e.code) }
        try { api.patchTemplate(maya.id, studio.muse.app.data.PatchTemplateRequest(name = "x")); error("owner only") } catch (e: ApiException) { assertEquals("owner_only", e.code) }
        val own = api.shoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, "", "", count = 1, templateId = "tpl_mirror-selfie")).first()
        assertTrue(own.prompt.contains("real mirror selfie")); assertNotNull(own.variation)
        assertEquals(1, api.template("tpl_mirror-selfie").uses)
    }

    @Test fun directionReplacesPoseAndAngleAndDrawsVary() {
        val pool = mapOf("pose" to listOf("a", "b", "c"), "bodyAngle" to listOf("x", "y"), "framing" to listOf("1", "2", "3"))
        val d = FakeTemplates.draw(pool, 5, 0, "sitting")
        assertNull(d["pose"]); assertNull(d["bodyAngle"]); assertEquals("sitting", d["direction"]); assertNotNull(d["framing"])
        assertEquals(FakeTemplates.draw(pool, 5, 0, null), FakeTemplates.draw(pool, 5, 0, null))
        assertTrue((0L until 12L).map { FakeTemplates.draw(pool, it, 0, null) }.toSet().size > 3)
    }

    @Test fun saveAsTemplateIsPrivateByDefault(): Unit = runBlocking {
        val shot = api.listTakes().first { it.kind == "shot" }
        val draft = api.templateDraft(shot.id)
        val t = api.createTemplate(CreateTemplateRequest("Mine", splitTags("Selfie, selfie, Night"), fromShotId = shot.id, variationPool = draft.variationPool))
        assertEquals("private", t.visibility); assertEquals(listOf("Selfie", "Night"), t.tags); assertEquals(shot.id, t.createdFromShotId)
    }

    @Test fun libraryTabsSearchAndTags(): Unit = runBlocking {
        val all: List<Template> = api.favouriteTemplate("tpl_reflection", true).let { api.listTemplates() }
        val f = { tf: TemplateFilter -> TemplatesViewModel.filter(all, tf).map { it.id } }
        assertTrue(f(TemplateFilter("mine")).none { it.startsWith("tpl_maya") })
        assertEquals(setOf("tpl_maya_walk", "tpl_reflection"), f(TemplateFilter("favourites")).toSet())
        assertEquals(listOf("tpl_mirror-selfie"), f(TemplateFilter(query = "mirror")))
        assertEquals(setOf("tpl_mirror-selfie", "tpl_motion-blur-face"), f(TemplateFilter(tag = "faceless")).toSet())
    }
}
