package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.FakeMuseApi

/**
 * Recreate phases 2–3 on demo mode's fake, following WS1's recreate-e2e flow: match → estimate → confirm → fill → poll →
 * apply → compare. Nothing is spent before the yes, and demo mode never spends at all.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RecreateBuildTest {
    private suspend fun ready(api: FakeMuseApi): studio.muse.core.edit.RecipeReference {
        var ref = api.createReference("up_1", "Café trend")
        while (ref.state == "analyzing") ref = api.reference(ref.id)
        return ref
    }

    @Test fun theWholeFlowBuildsTheEditAndNeverSpendsInDemo() = runBlocking {
        val scope = MainScope()
        val work = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val ref = ready(api)
            val takes = api.listTakes().filter { it.kind == "take" }.map { RecreateTakeChoice(it.id, it.title, it.durationSec) }
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, ref.name, takes = takes), defaultModelId = { "m_demo" }, pollMs = 5)
            val before = api.balance()

            model.load()
            var ui = model.ui.value
            assertEquals("3 from your takes, 4 to generate · $2.56 in all", ui.summary)
            assertEquals("You approve before anything is made.", ui.note)
            assertEquals(4, ui.estimates.size)
            assertEquals("Yours", ui.tag("s1", scores = false)); assertEquals("To generate", ui.tag("s2", scores = false))

            // Build asks once, listing each shot to generate with its price; nothing is started yet.
            model.requestBuild()
            ui = model.ui.value
            assertEquals(listOf("s2", "s4", "s5", "s7"), ui.confirmSlots)
            assertEquals(2.56, ui.confirmTotal, 1e-9)
            assertTrue(ui.fill!!.slots.none { it.state == "generating" })

            // Cancel spends nothing; Build again, then yes.
            model.cancelBuild(); assertNull(model.ui.value.confirmSlots)
            model.requestBuild()
            model.confirmBuild().join()
            assertTrue(model.ui.value.building || model.ui.value.mode == RecreateMode.Compare)

            withTimeout(5_000) { while (model.ui.value.mode != RecreateMode.Compare) delay(5) }
            ui = model.ui.value
            assertEquals(.86, ui.match!!.overall!!, 1e-9)
            assertNotNull(ui.builtTakeId)
            assertFalse(ui.building)
            assertEquals(4, ui.weakest) // shot 5 scores lowest: "Fix shot 5"
            assertEquals("62%", ui.tag("s5", scores = true))
            assertEquals(before, api.balance())

            model.fixWeakest()
            assertEquals(RecreateMode.Recipe, model.ui.value.mode); assertEquals(4, model.ui.value.selected)

            // Fix shot 5: make it anew. It is priced, confirmed with the next Build, generated, and the edit rebuilt.
            model.remake("s5")
            assertEquals("To generate", model.ui.value.tag("s5", scores = false))
            model.requestBuild()
            assertEquals(listOf("s5"), model.ui.value.confirmSlots)
            assertEquals(.64, model.ui.value.confirmTotal, 1e-9)
            model.confirmBuild().join()
            withTimeout(5_000) { while (model.ui.value.mode != RecreateMode.Compare) delay(5) }
            assertEquals("ready", model.ui.value.slotFill("s5")?.state)
            assertEquals(RecreateMode.Compare, model.ui.value.mode)
            assertTrue(model.ui.value.remake.isEmpty())
            assertEquals(before, api.balance())
        } finally { scope.cancel(); work.cancel() }
    }

    @Test fun aTakeReplacesAShotToGenerateAndItsPrice() = runBlocking {
        val scope = MainScope()
        val work = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val ref = ready(api)
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, ref.name), defaultModelId = { "m_demo" }, pollMs = 5)
            model.load()
            model.useTake("s2", RecreateTakeChoice("t_x", "Window light", 4.2))
            assertEquals("4 from your takes, 3 to generate · $1.92 in all", model.ui.value.summary)
            assertEquals("You picked “Window light”", model.ui.value.slotFill("s2")?.reason)
            // Compare waits for a build.
            model.setMode(RecreateMode.Compare)
            assertEquals(RecreateMode.Recipe, model.ui.value.mode)
            assertEquals("Compare opens once the edit is built", model.ui.value.message)
        } finally { scope.cancel(); work.cancel() }
    }

    @Test fun thePlayheadDrivesBothPlayersAndTheSelectedShot() = runBlocking {
        val scope = MainScope()
        val work = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val ref = ready(api)
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, ref.name), defaultModelId = { "m_demo" }, pollMs = 5)
            val slots = ref.recipe!!.slots
            model.select(2)
            assertEquals((slots[2].startSec + slots[2].endSec) / 2, model.ui.value.time, 1e-9)
            model.advance(1.0); assertEquals((slots[2].startSec + slots[2].endSec) / 2, model.ui.value.time, 1e-9) // paused: no move
            model.togglePlay(); assertTrue(model.ui.value.playing)
            model.advance(slots[3].startSec - model.ui.value.time + 0.01)
            assertEquals(3, model.ui.value.selected) // the selected shot follows the playhead
            model.advance(100.0); assertEquals(0.0, model.ui.value.time, 1e-9) // loops at the end
            model.step(3); assertFalse(model.ui.value.playing); assertEquals(0.1, model.ui.value.time, 1e-9)
            model.setJobProgress(mapOf("job_rx_s2" to 42))
            assertNull(model.ui.value.progress("s2")) // not being made: no job yet
        } finally { scope.cancel(); work.cancel() }
    }

    @Test fun aNewLeadMatchesAndPricesAgain() = runBlocking {
        val scope = MainScope()
        val work = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val ref = ready(api)
            val models = api.listModels()
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, ref.name, cast = models.map { RecreateCastChoice(it.id, it.name) }, castId = models.first().id),
                defaultModelId = { null }, pollMs = 5)
            model.load()
            assertEquals(4, model.ui.value.estimates.size)
            val other = models.last().id
            model.setCast(other)
            assertEquals(other, model.ui.value.castId)
            assertEquals(4, model.ui.value.estimates.size) // priced again for the new lead
            assertFalse(model.ui.value.loadingFill)
        } finally { scope.cancel(); work.cancel() }
    }

    @Test fun withoutAModelNoShotIsOfferedToSpendOn() = runBlocking {
        val scope = MainScope()
        val work = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val ref = ready(api)
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, ref.name), defaultModelId = { null }, pollMs = 5)
            model.load()
            model.requestBuild()
            assertEquals(emptyList<String>(), model.ui.value.confirmSlots)
            assertEquals("3 from your takes, 4 can’t be made · nothing to pay", model.ui.value.summary)
        } finally { scope.cancel(); work.cancel() }
    }
}
