package studio.muse.app.ui.screens.edit.learn

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.LearnLesson
import studio.muse.app.data.LearnRule
import studio.muse.app.data.LearnEvidence

/** The Playbook and Recipes models against demo's /v1/learn (FakeMuseApi), and the plain copy the owner asked for. */
class LearnModelTest {
    private val api = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)
    private val toasts = mutableListOf<String>()
    private val opened = mutableListOf<String>()

    @Test fun `suggestion copy is plain`() {
        assertEquals("You changed Claude's look 4 times", LearnLesson("look", count = 4, undos = 1).sentence)
        assertEquals("You undid Claude's transitions 2 times", LearnLesson("transition", count = 2, undos = 2).sentence)
        assertEquals("You changed Claude's captions once", LearnLesson("captions", count = 1).sentence)
    }

    @Test fun `who wrote a rule, in words`() {
        assertEquals("Yours", LearnRule("r", "x").byline)
        assertEquals("From Claude · 3 corrections", LearnRule("r", "x", source = "claude", evidence = List(3) { LearnEvidence("correction") }).byline)
        assertEquals("Learned · 1 post", LearnRule("r", "x", source = "learned", evidence = listOf(LearnEvidence("post"))).byline)
    }

    @Test fun `add, pin, make from a suggestion and delete a rule`() = runBlocking {
        val m = PlaybookModel({ api }, { toasts += it }, { opened += it })
        m.load()
        val n = m.ui.rules!!.size
        m.act(PlaybookAction.AddRule)
        m.act(PlaybookAction.SaveRule)
        assertEquals("Say what Claude should do", toasts.last()) // nothing saved without words
        m.act(PlaybookAction.Draft(m.ui.editor!!.copy(text = "No zooms on faces.", area = "motion", noting = true, note = "Feels cheap")))
        m.act(PlaybookAction.SaveRule)
        assertNull(m.ui.editor)
        val added = m.ui.rules!!.first { it.text == "No zooms on faces." }
        assertEquals(n + 1, m.ui.rules!!.size)
        assertEquals("note", added.evidence.single().kind)
        m.act(PlaybookAction.Pin(added))
        assertTrue(m.ui.rules!!.first { it.id == added.id }.pinned)
        m.act(PlaybookAction.MakeRule(m.ui.lessons!!.first()))
        assertEquals("look", m.ui.editor!!.area)
        assertEquals("", m.ui.editor!!.text) // the owner writes the rule; nothing is pre-written
        assertEquals(4, m.ui.editor!!.evidence.size)
        m.act(PlaybookAction.CloseEditor)
        m.act(PlaybookAction.AskDelete(added.id))
        m.act(PlaybookAction.KeepRule)
        assertEquals(n + 1, m.ui.rules!!.size)
        m.act(PlaybookAction.AskDelete(added.id))
        m.act(PlaybookAction.ConfirmDelete)
        assertEquals(n, m.ui.rules!!.size)
    }

    @Test fun `recipes filter, sort, rename, tag, open and delete`() = runBlocking {
        val m = RecipesModel({ api }, { toasts += it }, { opened += "take:$it" }, { opened += "ref:$it" }, { opened += "recreate" })
        m.load()
        assertEquals(5, m.ui.shown.size)
        m.act(RecipesAction.Origin(RecipeOrigin.REFERENCES))
        assertTrue(m.ui.shown.all { it.isReference })
        m.act(RecipesAction.Origin(RecipeOrigin.ALL))
        m.act(RecipesAction.Sort(RecipeSort.VIEWED))
        assertEquals("Morning café", m.ui.shown.first().name)
        m.act(RecipesAction.Tag("warm"))
        assertTrue(m.ui.shown.all { "warm" in it.tags })
        m.act(RecipesAction.Tag("warm"))
        assertNull(m.ui.tag) // a second tap clears it
        m.act(RecipesAction.Open("rcp_1"))
        assertTrue(m.ui.detail!!.entry.recipe != null)
        assertEquals(3, m.ui.detail!!.nearest.size)
        m.act(RecipesAction.Rename("Morning café, v2"))
        m.act(RecipesAction.SaveName)
        assertEquals("Morning café, v2", m.ui.detail!!.entry.name)
        m.act(RecipesAction.TagDraft("Cosy"))
        m.act(RecipesAction.SaveTag)
        assertTrue("cosy" in m.ui.detail!!.entry.tags)
        m.act(RecipesAction.RemoveTag("cosy"))
        assertFalse("cosy" in m.ui.detail!!.entry.tags)
        m.act(RecipesAction.Use)
        assertEquals("take:demo_edit_1", opened.last())
        m.act(RecipesAction.AskDelete)
        m.act(RecipesAction.ConfirmDelete)
        assertNull(m.ui.detail)
        assertEquals(4, m.ui.all!!.size)
    }
}
