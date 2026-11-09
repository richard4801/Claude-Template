package studio.muse.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.DraftReference
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.ui.screens.suite.answerClaude
import studio.muse.app.ui.screens.suite.applyAssist
import studio.muse.app.ui.screens.suite.openClaude
import studio.muse.app.ui.screens.suite.bindClaudeChat
import studio.muse.app.ui.screens.suite.newClaudeChat
import studio.muse.app.ui.screens.suite.claudeKey
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.data.ClaudeSessions
import studio.muse.app.ui.screens.suite.pushComposerToAssist
import studio.muse.app.ui.screens.suite.removeDraftReference
import studio.muse.app.ui.screens.suite.undoRig
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts

/**
 * Claude in the AI Suite (WS1 1eda187) on demo mode: Claude fills in the composer through the shared draft, the owner's
 * own edits go back, and Claude's Generate runs only on the owner's yes. Images attach to Claude's messages.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SuiteClaudeTest {
    private fun <T> withSuite(f: suspend (AppContainer, FakeMuseApi) -> T): T = runBlocking {
        val scope = MainScope()
        val work = CoroutineScope(Dispatchers.Default) // the fake Claude's turns run here (MainScope would wait on runBlocking)
        try {
            val fake = FakeMuseApi(work, null, speed = 0.0, genDelayMs = 0)
            val c = AppContainer(scope, MemoryPrefs(AppPrefs(useFake = true, token = "t", role = "owner")), fake, null)
            c.repo.refresh()
            c.suite.load()
            f(c, fake)
        } finally { scope.cancel(); work.cancel() }
    }

    /** Sends [text] (and [images]) on the assist's Claude thread and waits until Claude's draft is in. */
    private suspend fun ask(c: AppContainer, fake: FakeMuseApi, text: String, images: List<String> = emptyList()) {
        val id = c.suite.assist.value!!.id
        val before = c.suite.assist.value!!.revision
        val thread = fake.claude.thread("suite", id)
        fake.claude.post(thread.id, text, images)
        withTimeout(5_000) { while (fake.suiteAssist(id).revision <= before) delay(10) }
        c.suite.applyAssist(fake.suiteAssist(id)) // as the `suiteAssist` event does
    }

    @Test fun claudeFillsInTheComposerAndWaitsForTheYes() = withSuite { c, fake ->
        val store = c.suite
        assertNotNull(store.openClaude())
        val balance = fake.balance()
        ask(c, fake, "A café morning shot of her by the window")
        val d = store.composer.value
        assertEquals("hd", d.quality)
        assertEquals(8, d.duration)
        assertEquals(c.repo.state.value.models.first().id, d.tokens.character?.id)
        // "Claude set …" with Undo, as on the Mac.
        assertEquals("Claude set Character, Prompt and Quality", store.rigUndo.value!!.first)
        val p = store.assist.value!!.pending!!
        assertTrue(p.label.startsWith("Generate · 8 s · $"))
        assertEquals(balance, fake.balance()) // nothing ran before the yes
        store.answerClaude(true)
        assertNull(store.assist.value!!.pending)
        assertTrue(store.shotJobs.value.isNotEmpty()) // the render joins the composer's renders
    }

    @Test fun declineLeavesTheComposerAndRunsNothing() = withSuite { c, fake ->
        val store = c.suite
        store.openClaude()
        ask(c, fake, "Night walk")
        val jobs = store.shotJobs.value
        store.answerClaude(false)
        assertNull(store.assist.value!!.pending)
        assertEquals(jobs, store.shotJobs.value)
        assertEquals("hd", store.composer.value.quality)
    }

    @Test fun theOwnersOwnEditsGoBackSoClaudeSeesThem() = withSuite { c, fake ->
        val store = c.suite
        val id = store.openClaude()!!
        store.composer.value = store.composer.value.copy(quality = "cinema", takes = 2)
        store.pushComposerToAssist()
        val server = fake.suiteAssist(id).draft
        assertEquals("cinema", server.quality); assertEquals(2, server.takes)
        val rev = fake.suiteAssist(id).revision
        store.pushComposerToAssist() // nothing changed: nothing sent
        assertEquals(rev, fake.suiteAssist(id).revision)
        // Claude changed it meanwhile: the owner's stale edit gives way to Claude's draft.
        ask(c, fake, "Make it HD")
        store.composer.value = store.composer.value.copy(takes = 3)
        fake.patchSuiteAssist(id, ComposerDrafts.draft(ComposerDraft(quality = "standard")), null)
        store.pushComposerToAssist()
        assertEquals("standard", store.composer.value.quality)
    }

    @Test fun attachedPhotosBecomeReferenceChipsAndGoInTheRequest() = withSuite { c, fake ->
        val store = c.suite
        store.openClaude()
        ask(c, fake, "Use this pose", listOf("up_img_1"))
        val refs = store.composer.value.references
        assertEquals(listOf(DraftReference("up_img_1", "https://demo.muse.studio/uploads/up_img_1.jpg", "pose", "Your photo")), refs)
        assertEquals("Pose", refs.first().useLabel)
        // Round trip through the draft, as Reuse settings and the shared draft carry it.
        assertEquals(refs, ComposerDrafts.restore(ComposerDrafts.draft(store.composer.value), ComposerDraft()).references)
        // The shot request carries it as a reference image with its use.
        val r = store.composer.value.withDraftReferences(studio.muse.app.data.SuiteShotRequest(prompt = "x"))
        assertEquals("pose", r.references!!.images!!.single().role)
        store.removeDraftReference("up_img_1", refs.first().url)
        assertTrue(store.composer.value.references.isEmpty())
    }

    @Test fun imagesAttachToClaudesMessages() = withSuite { c, fake ->
        val scope = CoroutineScope(Dispatchers.Default)
        try {
            val chat = ClaudeChatStore({ fake.claude }, scope, "recreate", "rx_1")
            chat.load().join()
            chat.attach("content://pick/1") { fake.uploadClaudeImage("a.jpg", ByteArray(10), "image/jpeg") }
            withTimeout(2_000) { while (chat.ui.value.uploading) delay(5) }
            assertTrue(chat.ui.value.canSend) // an image alone can be sent
            assertTrue(chat.send())
            withTimeout(2_000) { while (chat.ui.value.messages.none { it.role == "user" }) { delay(10); chat.reload() } }
            assertEquals(1, chat.ui.value.messages.first { it.role == "user" }.attachments.size)
            assertTrue(chat.ui.value.attachments.isEmpty())
            // Camera stage takes no images yet.
            val camera = ClaudeChatStore({ fake.claude }, scope, "camera", "cs_1")
            camera.attach("content://pick/2") { "up_x" }
            assertTrue(camera.ui.value.attachments.isEmpty())
        } finally { scope.cancel() }
    }

    @Test fun claudesChangesSayWhatAndCanBeUndone() = withSuite { c, fake ->
        val store = c.suite
        store.openClaude()
        val before = store.composer.value
        ask(c, fake, "A café shot")
        store.undoRig()
        assertEquals(before.quality, store.composer.value.quality)
        assertEquals(null, studio.muse.app.ui.screens.suite.SuiteClaudeWords.claudeSet(emptyList()))
        assertEquals("Claude set Camera", studio.muse.app.ui.screens.suite.SuiteClaudeWords.claudeSet(listOf("Camera")))
        assertEquals("Claude set Camera and Light", studio.muse.app.ui.screens.suite.SuiteClaudeWords.claudeSet(listOf("Camera", "Light")))
        assertEquals(listOf("Fill this in from my idea", "Make it more cinematic", "Explain the settings"), studio.muse.app.ui.screens.suite.SuiteClaudeWords.suggestions.map { it.first })
    }

    // WS18: each mode has its own chats, bound to their drafts; opening the mode again returns to its latest chat.
    @Test fun eachModeKeepsItsOwnChatsAndReturnsToTheLatest() = withSuite { c, fake ->
        val store = c.suite
        val a = store.openClaude()!!
        assertEquals("suite:shot", store.claudeKey)
        val ta = fake.claude.thread("suite", a)
        fake.claude.post(ta.id, "A café morning")
        withTimeout(5_000) { while (fake.claude.getThread(ta.id).activeTurn != null) delay(10) }
        val b = store.newClaudeChat()!!
        assertTrue(a != b)
        fake.claude.thread("suite", b)
        assertEquals(2, fake.claude.threads("suite:shot").size)
        // Switch back to A: its draft is the composer's again.
        assertTrue(store.bindClaudeChat(fake.claude.threads("suite:shot").first { it.id == ta.id }))
        assertEquals(a, store.assist.value!!.id)
        // The app started again: Shot returns to A, with its messages on the server.
        store.assist.value = null
        assertEquals(a, store.openClaude())
        assertTrue(fake.claude.getThread(ta.id).messages!!.any { it.role == "user" && it.text == "A café morning" })
        // Photo has its own chats.
        store.composer.value = store.composer.value.copy(tool = ComposerTool.PHOTO)
        val p = store.openClaude()!!
        assertTrue(p != a && p != b)
        assertEquals("suite:photo", store.assist.value!!.key)
        assertEquals("photo", fake.suiteAssist(p).draft.tool)
    }

    @Test fun claudesDraftNeverSwitchesTheComposersMode() = withSuite { c, fake ->
        val store = c.suite
        store.composer.value = store.composer.value.copy(tool = ComposerTool.PHOTO)
        val id = store.openClaude()!!
        // A draft an older server set to Shot: the rows apply, the composer stays in Photo.
        fake.patchSuiteAssist(id, ComposerDrafts.draft(ComposerDraft(tool = ComposerTool.SHOT, quality = "cinema")), null)
        store.applyAssist(fake.suiteAssist(id))
        assertEquals(ComposerTool.PHOTO, store.composer.value.tool)
        assertEquals("cinema", store.composer.value.quality)
    }
}
