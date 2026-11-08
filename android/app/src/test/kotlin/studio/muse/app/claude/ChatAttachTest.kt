package studio.muse.app.claude

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.ClaudeApi
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.ui.screens.claude.ClaudeChatUi

/** Attach limits and "Send as JPEG" (WS2's Mac wording, plans/claude-chat-android.md). */
class ChatAttachTest {
    private fun store(scope: CoroutineScope) = ClaudeChatStore({ error("no api in this test") as ClaudeApi }, scope, "suite", "sa_1").also { it.set(ClaudeChatUi("suite", "sa_1", loaded = true)) }

    @Test fun limitsAreWordedAsOnTheMac() {
        assertEquals("Up to 4 images (JPEG, PNG, WebP or HEIC), 10 MB each", ClaudeChatStore.LIMITS)
        val scope = CoroutineScope(Dispatchers.Default)
        try {
            val s = store(scope)
            repeat(5) { i -> s.attach("p$i") { "up_$i" } }
            assertEquals(4, s.ui.value.attachments.size)
            assertEquals(ClaudeChatStore.LIMITS, s.ui.value.notice)
        } finally { scope.cancel() }
    }

    @Test fun unreadableImageOffersSendAsJpeg() = runBlocking {
        val scope = CoroutineScope(Dispatchers.Default)
        try {
            val s = store(scope)
            val asked = mutableListOf<Boolean>()
            s.attachAs("content://heic") { jpeg -> asked += jpeg; if (!jpeg) throw ApiException("unsupported_image", "up_1: this HEIC photo can't be read") else "up_jpeg" }
            withTimeout(2_000) { while (s.ui.value.attachments.single().error == null) delay(5) }
            val a = s.ui.value.attachments.single()
            assertTrue(a.unsupported)
            assertFalse(s.ui.value.canSend) // a refused image isn't sent
            s.sendAsJpeg(a.key)
            withTimeout(2_000) { while (s.ui.value.attachments.single().uploadId == null) delay(5) }
            val b = s.ui.value.attachments.single()
            assertEquals("up_jpeg", b.uploadId)
            assertNull(b.error)
            assertFalse(b.unsupported)
            assertEquals(listOf(false, true), asked)
        } finally { scope.cancel() }
    }
}
