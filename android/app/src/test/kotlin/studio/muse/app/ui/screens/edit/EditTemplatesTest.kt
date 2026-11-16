package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditTemplate
import studio.muse.app.data.EditTemplateLibrary
import studio.muse.app.data.EditTemplateParam
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.core.edit.SourceSize

/** Edit templates (plans/edit-templates.md §5): the sheet's sections, where Apply goes, its title, and the library's JSON. */
class EditTemplatesTest {
    private class NoAi : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }
    private val library = """
        {"templates":[
          {"id":"window-open-next","name":"Window opens the next shot","kind":"transition","target":"cut","level":"live","state":"ready","timing":"0.3 s before the cut",
           "params":[{"key":"shape","label":"Shape","type":"enum","options":["box","band","column","slats"],"default":"box"},{"key":"lead","label":"Opens before the cut","type":"number","unit":"s","min":0.1,"max":1,"default":0.3}],
           "preview":{"uploadId":"up_prev"},"by":"seed","futureField":1},
          {"id":"glass-shatter","name":"Glass shatter","kind":"transition","target":"cut","level":"reference","state":"not_ready","reason":"Ask Claude on the Mac","reference":{"uploadId":"up_ref"},"by":"seed"},
          {"id":"punch-in","name":"Punch-in","kind":"effect","target":"clip","state":"ready","by":"seed"},
          {"id":"band-behind-subject","name":"Band behind the subject","kind":"transition","target":"cut","level":"matte","state":"ready","paid":true,"by":"seed"},
          {"id":"quick-punch","name":"Quick punch","kind":"effect","target":"clip","state":"ready","by":"claude"}],
         "captionStyles":[{"id":"pop","name":"Word pop"}]}
    """.trimIndent()

    @Test fun libraryDecodesAndSectionsFilter() {
        val lib = json.decodeFromString(EditTemplateLibrary.serializer(), library)
        assertEquals(5, lib.templates.size)
        assertEquals("up_prev", lib.templates[0].preview?.uploadId)
        assertEquals(JsonPrimitive("box"), lib.templates[0].params[0].defaultValue)
        val all = EditTemplatesLogic.sections(lib, "All")
        assertEquals(listOf("Yours", "Made by Claude"), all.map { it.first })
        assertEquals(listOf("band-behind-subject", "punch-in", "window-open-next", "glass-shatter"), all[1].second.map { it.id }) // ready first, then by name
        assertEquals(listOf("band-behind-subject", "window-open-next", "glass-shatter"), EditTemplatesLogic.sections(lib, "Transitions").flatMap { it.second }.map { it.id })
        assertTrue(EditTemplatesLogic.sections(lib, "Captions").isEmpty())
        assertEquals("Not ready", EditTemplatesLogic.badge(lib.templates[1]))
        assertNull(EditTemplatesLogic.badge(lib.templates[0]))
        assertEquals("Ease out", EditTemplatesLogic.optionLabel("easeOut"))
        assertEquals("0.3 s", EditTemplatesLogic.valueLabel(EditTemplateParam("lead", unit = "s"), 0.3))
    }

    @Test fun applyGoesOnTheSelectionOrThePlayhead() = runTest {
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true)), "T", "t_j1", null, reopened = false)
        c.act(EditAction.Seek(4.0)); c.act(EditAction.Split)
        c.act(EditAction.Seek(8.0)); c.act(EditAction.Split)
        val p = c.project!!
        val ids = p.mainClips.map { it.id }
        val cut = EditTemplate("x", "X", kind = "transition", target = "cut")
        // The selected third clip: the cut before it.
        val a = EditTemplatesLogic.target(cut, p, ids[2], 0.0)!!
        assertEquals(JsonObject(mapOf("cutAfter" to JsonPrimitive(ids[1]))), a.json)
        assertEquals("Cut at 0:08.0", a.title)
        assertEquals("Between clip 2 and clip 3", a.detail)
        assertEquals("Apply to the cut into clip 3", EditTemplatesLogic.applyTitle(cut, a, null))
        // Nothing selected: the cut nearest the playhead.
        assertEquals(JsonObject(mapOf("cutAfter" to JsonPrimitive(ids[0]))), EditTemplatesLogic.target(cut, p, null, 3.0)!!.json)
        // A clip template: the clip under the playhead; a paid one shows its price on Apply.
        val clip = EditTemplate("y", "Y", target = "clip", paid = true)
        val b = EditTemplatesLogic.target(clip, p, null, 9.0)!!
        assertEquals("Clip 3", b.title)
        assertEquals("Apply to clip 3 · $0.82", EditTemplatesLogic.applyTitle(clip, b, 0.82))
        assertEquals("Apply to every cut on a note", EditTemplatesLogic.every(cut.copy(each = "note-cut"))!!.second)
    }

    @Test fun membersAreToldTemplatesAreTheOwners() = runTest {
        val c = EditSuiteController(backgroundScope, NoAi())
        c.load(EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true)), "T", "t_j1", null, reopened = false)
        c.act(EditAction.Open(Panel.TEMPLATES))
        assertEquals(Panel.TEMPLATES, c.ui.value.panel)
        assertEquals("Templates are for the studio owner", c.ui.value.message)
        c.act(EditAction.TemplateFilter("Effects"))
        assertEquals("Effects", c.ui.value.templates.filter)
    }
}
