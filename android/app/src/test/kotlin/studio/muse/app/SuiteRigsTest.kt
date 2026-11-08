package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SuiteRig
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SuiteFeedFilter
import studio.muse.app.ui.screens.suite.applyDefaultRigIfAny
import studio.muse.app.ui.screens.suite.applySavedRig
import studio.muse.app.ui.screens.suite.compare
import studio.muse.app.ui.screens.suite.loadFeed
import studio.muse.app.ui.screens.suite.loadSavedRigs
import studio.muse.app.ui.screens.suite.reuseSettings
import studio.muse.app.ui.screens.suite.saveRig
import studio.muse.app.ui.screens.suite.undoRig
import studio.muse.app.ui.screens.suite.useAsStartFrame
import studio.muse.app.ui.screens.suite.vary
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.PromptPart
import studio.muse.app.ui.screens.suite.composer.PromptTokens

/** The AI suite plan in the current Suite on demo mode: Reuse settings, Vary, start frame, Compare, rigs and the feed. Nothing spends. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SuiteRigsTest {
    private fun <T> withSuite(f: suspend (AppContainer, FakeMuseApi) -> T): T = runBlocking {
        val scope = MainScope()
        try {
            val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val c = AppContainer(scope, MemoryPrefs(AppPrefs(useFake = true, token = "t", role = "owner")), fake, null)
            c.repo.refresh()
            c.suite.load()
            f(c, fake)
        } finally { scope.cancel() }
    }

    @Test fun reuseSettingsAndVaryPutTheTakesComposerBack() = withSuite { c, _ ->
        val model = c.repo.state.value.models.first()
        val d = ComposerDraft(tokens = PromptTokens(listOf(PromptPart.Mention("character", model.id, model.name, 1), PromptPart.Text(" on the pier at sunset"))),
            settings = ComposerSettings(body = "phone"), aspect = "16:9", duration = 6)
        val take = c.repo.state.value.takes.first { it.kind == "take" }.copy(draft = ComposerDrafts.draft(d))
        c.suite.composer.value = ComposerDraft()
        assertNotNull(c.suite.reuseSettings(take))
        assertEquals("16:9", c.suite.composer.value.aspect)
        assertEquals(d.tokens, c.suite.composer.value.tokens)
        c.suite.composer.value = ComposerDraft()
        c.suite.vary(take)
        assertEquals(6, c.suite.composer.value.duration)
        assertNull(c.suite.vary(take.copy(draft = null, jobId = null))) // made before Reuse settings
    }

    @Test fun startFrameAndCompare() = withSuite { c, _ ->
        val takes = c.repo.state.value.takes.filter { it.kind == "take" }
        c.suite.useAsStartFrame(takes[0])
        assertEquals(takes[0].thumb, c.suite.composerSlots.value[SlotId(SlotKind.START)]?.image)
        assertFalse(c.suite.compare(takes[0]))
        assertTrue(c.suite.compare(takes[1]))
        assertEquals(listOf(takes[0].id, takes[1].id), c.suite.compareIds.value)
        c.suite.compare(takes[1]) // tapping one again takes it out
        assertEquals(listOf(takes[0].id), c.suite.compareIds.value)
    }

    @Test fun savedRigsApplyWithUndoAndDefaultRigsFillOnlyAuto() = withSuite { c, fake ->
        val cam = fake.suite.camera
        val body = cam.bodies.first().id; val lens = cam.lenses.first().id; val otherBody = cam.bodies.last().id; val otherLens = cam.lenses.last().id
        c.suite.composer.value = ComposerDraft(settings = ComposerSettings(body = body, lens = lens))
        assertTrue(c.suite.saveRig("Golden hour"))
        c.suite.loadSavedRigs()
        val r = c.suite.savedRigs.value.first { it.name == "Golden hour" }
        c.suite.composer.value = ComposerDraft()
        c.suite.applySavedRig(r)
        assertEquals(body, c.suite.composer.value.settings.body)
        c.suite.undoRig()
        assertNull(c.suite.composer.value.settings.body)
        // A model's default rig fills only the rows still on Auto.
        val m = c.repo.state.value.models.first()
        fake.setModelDefaultRig(m.id, SuiteRig(body = otherBody, lens = otherLens))
        c.repo.refresh()
        c.suite.composer.value = ComposerDraft(tokens = PromptTokens(listOf(PromptPart.Mention("character", m.id, m.name, 1))), settings = ComposerSettings(lens = lens))
        assertTrue(c.suite.applyDefaultRigIfAny())
        assertEquals(otherBody, c.suite.composer.value.settings.body) // Auto row filled
        assertEquals(lens, c.suite.composer.value.settings.lens) // the user's row kept
    }

    @Test fun theFeedLoadsAndFilters() = withSuite { c, _ ->
        assertTrue(c.suite.loadFeed(photo = false))
        assertNotNull(c.suite.feed.value)
        c.suite.feedFilter.value = SuiteFeedFilter.FAILED
        assertTrue(c.suite.loadFeed(photo = false))
        assertTrue(c.suite.feed.value!!.all { it.status == "failed" })
    }
}
