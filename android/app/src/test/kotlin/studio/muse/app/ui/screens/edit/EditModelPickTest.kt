package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorJobRequest
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeEditorResults
import studio.muse.core.edit.SourceSize

/** WS13 model picks in the Edit helpers (owner, 0.1.4): the chosen model goes with each helper's estimate and run. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditModelPickTest {
    private class Recording : EditBackend {
        val calls = ArrayList<Triple<String, String, String?>>() // (estimate|run, kind, engineModel)
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = estimate(kind, source, options, null)
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit) = run(kind, source, options, null, onProgress)
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?): Pair<EditorEstimate?, String?> {
            calls += Triple("estimate", kind + if (options?.containsKey("points") == true) "+points" else "", engineModel); return EditorEstimate(kind, 0.03) to null
        }
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
            calls += Triple("run", kind, engineModel); return FakeEditorResults.result(kind, 15.0, "j", options) to null
        }
    }

    @Test fun eachHelperUsesItsPurposesPick() = runTest {
        val b = Recording()
        val c = EditSuiteController(this, b).also { it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)), "T", "take_1", null, false) }
        assertEquals("captions", c.helperPurpose("cuts", null)); assertEquals("track", c.helperPurpose("matte", JsonObject(mapOf("points" to kotlinx.serialization.json.JsonArray(emptyList())))))
        c.act(EditAction.PickModel("captions", "m_whisper")); c.act(EditAction.PickModel("denoise", "m_clean")); c.act(EditAction.PickModel("matte", "m_cut")); advanceUntilIdle()
        assertTrue(b.calls.contains(Triple("estimate", "matte", "m_cut"))) // re-priced on the new model
        c.act(EditAction.AutoCaptions); c.act(EditAction.NoiseReduction(true)); c.act(EditAction.RemoveBackground); advanceUntilIdle()
        assertTrue(b.calls.contains(Triple("run", "captions", "m_whisper")))
        assertTrue(b.calls.contains(Triple("run", "denoise", "m_clean")))
        assertTrue(b.calls.contains(Triple("run", "matte", "m_cut")))
        c.act(EditAction.PickModel("captions", null)); c.act(EditAction.CutSilences); advanceUntilIdle()
        assertTrue(b.calls.contains(Triple("run", "cuts", null))) // back to the studio's default
    }

    @Test fun theRequestCarriesEngineModelOnlyWhenPicked() {
        val j = Json { explicitNulls = false; encodeDefaults = true }
        val src = EditorSourceDto(takeId = "t")
        assertTrue(j.encodeToString(EditorJobRequest.serializer(), EditorJobRequest("matte", src, null, "m_cut")).contains("\"engineModel\":\"m_cut\""))
        assertFalse(j.encodeToString(EditorJobRequest.serializer(), EditorJobRequest("matte", src)).contains("engineModel"))
    }
}
