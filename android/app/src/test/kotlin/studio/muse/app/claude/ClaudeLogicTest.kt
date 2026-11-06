package studio.muse.app.claude

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiFallbackStatus
import studio.muse.app.data.ChatEvent
import studio.muse.app.data.ClaudeCodeStatus
import studio.muse.app.data.ClaudeEvent
import studio.muse.app.data.ClaudeFallback
import studio.muse.app.data.ClaudeImageRef
import studio.muse.app.data.ClaudeLive
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudePlanStatus
import studio.muse.app.data.ClaudeThread
import studio.muse.app.data.ClaudeToolRef
import studio.muse.app.data.ClaudeTurn
import studio.muse.app.data.MacClaudeStatus
import studio.muse.app.data.claudeLiveOf
import studio.muse.app.ui.screens.claude.ChatItem
import studio.muse.app.ui.screens.claude.ChatReducer
import studio.muse.app.ui.screens.claude.ChipText
import studio.muse.app.ui.screens.claude.ClaudeChatUi
import studio.muse.app.ui.screens.claude.ClaudeText
import studio.muse.app.ui.screens.claude.Fallback
import studio.muse.app.ui.screens.claude.LiveTurn
import studio.muse.app.ui.screens.claude.Tone

class ClaudeLogicTest {
    private val ready = ClaudePlanStatus(MacClaudeStatus(true, ClaudeCodeStatus(true, true, "2.4.1")), ApiFallbackStatus(true, false), "https://x/mcp", "https://claude.ai/new")
    private val offline = ready.copy(mac = ready.mac.copy(online = false))
    private val thread = ClaudeThread("ct_1", "camera", "cs_1")
    private fun base() = ChatReducer.loaded(ClaudeChatUi("camera", "cs_1", status = ready), thread.copy(messages = listOf(
        ClaudeMessage("m1", "ct_1", "user", "mac", "Lower the camera", "tu_0"),
        ClaudeMessage("m2", "ct_1", "assistant", "mac", "Done.", "tu_0"),
    )))
    private fun ev(turn: String?, e: ClaudeEvent) = ClaudeLive("event", threadId = "ct_1", turnId = turn, event = e)
    private fun msg(m: ClaudeMessage) = ClaudeLive("message", threadId = "ct_1", message = m)

    @Test fun chipWords() {
        assertEquals("Saved camera path", ChipText.of("mcp__muse__set_camera_path"))
        assertEquals("Shot draft", ChipText.of("mcp__muse__create_shot_draft"))
        // The Mac's summary wins, as is.
        assertEquals("Shot draft · $1.92", ChipText.of("create_shot_draft", "Shot draft · $1.92"))
        assertEquals("Trimmed to 0:00.5–0:06.0", ChipText.of("mcp__muse__apply_edit_ops", "Trimmed to 0:00.5–0:06.0"))
        assertEquals("Look · film-gold 70 %", ChipText.of("apply_edit_ops", "Look · film-gold 70 %"))
        assertEquals("Cut silences", ChipText.of("mcp__muse__cut_silences"))
        assertEquals("Undid an edit", ChipText.of("undo_edit"))
        assertEquals("Some new tool", ChipText.of("mcp__muse__some_new_tool"))
        assertEquals("Saving camera path…", ChipText.of("set_camera_path", running = true))
        assertEquals("Denoise…", ChipText.of("denoise", running = true))
        assertEquals("$1.92", ChipText.usd("Shot draft · estimate $1.92"))
    }

    @Test fun reducerStreamsAToolAndReplacesLivePartsWithStoredOnes() {
        var ui = base()
        assertEquals(2, ui.items.size)
        ui = ChatReducer.live(ui, ClaudeLive("turn", turn = ClaudeTurn("tu_1", "ct_1", "Slower push", "phone", "queued")))
        assertEquals(ClaudeText.WAITING, ClaudeText.status(ui).text)
        ui = ChatReducer.live(ui, msg(ClaudeMessage("m3", "ct_1", "user", "phone", "Slower push", "tu_1")))
        ui = ChatReducer.live(ui, msg(ClaudeMessage("m3", "ct_1", "user", "phone", "Slower push", "tu_1"))) // duplicate
        assertEquals(3, ui.messages.size)
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("text", delta = "Pushing in ")))
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("text", delta = "slower.")))
        assertEquals("running", ui.turn!!.state)
        assertEquals(ClaudeText.ANSWERING, ClaudeText.status(ui).text)
        val streaming = ui.items.last() as ChatItem.Assistant
        assertEquals("Pushing in slower." to true, streaming.text to streaming.streaming)
        // No duplicate user bubble for the live turn.
        assertEquals(1, ui.items.count { it is ChatItem.User && it.text == "Slower push" })
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("tool", id = "tl1", name = "mcp__muse__set_camera_path", status = "running")))
        assertEquals("Saving camera path…", (ui.items.last() as ChatItem.Tool).text)
        ui = ChatReducer.live(ui, msg(ClaudeMessage("m4", "ct_1", "assistant", "mac", "Pushing in slower.", "tu_1")))
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("tool", id = "tl1", name = "mcp__muse__set_camera_path", status = "done", summary = "Saved camera path")))
        ui = ChatReducer.live(ui, msg(ClaudeMessage("m5", "ct_1", "tool", "mac", "", "tu_1", ClaudeToolRef("tl1", "mcp__muse__set_camera_path", true, "Saved camera path"))))
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("image", data = "iVBOR", mimeType = "image/png")))
        assertTrue(ui.items.last() is ChatItem.Image)
        ui = ChatReducer.live(ui, msg(ClaudeMessage("m6", "ct_1", "tool", "mac", "", "tu_1", image = ClaudeImageRef("https://x/f.png"))))
        assertTrue(ui.turn!!.parts.isEmpty())
        val items = ui.items
        assertEquals(1, items.count { it is ChatItem.Assistant && it.text == "Pushing in slower." })
        assertEquals(1, items.count { it is ChatItem.Tool })
        assertEquals("https://x/f.png", (items.last() as ChatItem.Image).url)
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("done", ok = true)))
        assertFalse(ui.busy)
        ui = ChatReducer.live(ui, ClaudeLive("turn", turn = ClaudeTurn("tu_1", "ct_1", "Slower push", "phone", "done")))
        assertEquals(ClaudeText.MODE, ClaudeText.status(ui).text)
    }

    @Test fun otherThreadsAreIgnoredAndTheMacsOwnTurnIsFollowed() {
        var ui = base()
        ui = ChatReducer.live(ui, ClaudeLive("event", threadId = "ct_other", turnId = "x", event = ClaudeEvent("text", delta = "nope")))
        ui = ChatReducer.live(ui, ClaudeLive("message", threadId = "ct_other", message = ClaudeMessage("z", "ct_other", "assistant", text = "nope")))
        assertEquals(base(), ui)
        // Typed on the Mac: no turnId.
        ui = ChatReducer.live(ui, ev(null, ClaudeEvent("text", delta = "From the Mac")))
        assertEquals("mac", ui.turn!!.from)
        assertTrue(ui.busy)
        ui = ChatReducer.live(ui, ev(null, ClaudeEvent("done", ok = true)))
        assertFalse(ui.busy)
    }

    @Test fun stopAndFailureLines() {
        var ui = base().copy(turn = LiveTurn("tu_1", "running"))
        ui = ChatReducer.live(ui, ClaudeLive("stop", turnId = "tu_1"))
        assertEquals(ClaudeText.STOPPING, ClaudeText.status(ui).text)
        ui = ChatReducer.live(ui, ev("tu_1", ClaudeEvent("done", ok = false, error = "Stopped")))
        assertEquals("stopped", ui.turn!!.state)
        assertEquals("Stopped", ClaudeText.ended(ui.turn))
        // After a reload the line stays, without live parts.
        ui = ChatReducer.loaded(ui, thread.copy(messages = ui.messages))
        assertEquals("Stopped", ClaudeText.ended(ui.turn))
        val failed = ChatReducer.live(base().copy(turn = LiveTurn("tu_2", "queued")), ClaudeLive("turn", turn = ClaudeTurn("tu_2", "ct_1", state = "failed", error = "Your Mac didn't pick this up")))
        assertEquals("Your Mac didn't pick this up", ClaudeText.ended(failed.turn))
    }

    @Test fun statusLines() {
        assertEquals(StatusPair(ClaudeText.MODE, Tone.GOOD), sp(base()))
        assertEquals(StatusPair(ClaudeText.OFFLINE, Tone.OFF), sp(base().copy(status = offline)))
        assertEquals("Claude Code isn't installed on your Mac", ClaudeText.status(base().copy(status = ready.copy(mac = MacClaudeStatus(true, ClaudeCodeStatus(false, false)))) ).text)
        assertEquals("Sign in to Claude Code on your Mac", ClaudeText.status(base().copy(status = ready.copy(mac = MacClaudeStatus(true, ClaudeCodeStatus(true, false)))) ).text)
        assertEquals(ClaudeText.OFFLINE, ClaudeText.status(base().copy(refusal = ClaudeFallback("u"))).text)
        assertEquals(ClaudeText.API, ClaudeText.status(base().copy(turn = LiveTurn(null, "running", api = true))).text)
        // A status event with the Mac back clears the refusal.
        val back = ChatReducer.live(base().copy(status = offline, refusal = ClaudeFallback("u")), ClaudeLive("status", status = ready))
        assertNull(back.refusal)
    }

    private data class StatusPair(val text: String, val tone: Tone)
    private fun sp(ui: ClaudeChatUi) = ClaudeText.status(ui).let { StatusPair(it.text, it.tone) }

    @Test fun fallbackDecision() {
        assertNull(Fallback.decide(ready, null, "camera"))
        assertNull(Fallback.decide(null, null, "camera"))
        val off = Fallback.decide(offline, null, "camera")!!
        assertEquals("https://claude.ai/new", off.openInClaude)
        assertFalse(off.useApiKey)
        assertEquals(ClaudeText.FALLBACK_NOTE, off.note)
        val on = Fallback.decide(offline.copy(apiFallback = ApiFallbackStatus(true, true)), null, "camera")!!
        assertTrue(on.useApiKey); assertNull(on.note)
        assertEquals(ClaudeText.NO_KEY_NOTE, Fallback.decide(offline.copy(apiFallback = ApiFallbackStatus(false, false)), null, "camera")!!.note)
        // The refusal's word wins (and its URL).
        val r = Fallback.decide(ready, ClaudeFallback("claude://open", true), "camera")!!
        assertEquals("claude://open" to true, r.openInClaude to r.useApiKey)
        // Edit threads: no API fallback yet.
        val e = Fallback.decide(offline.copy(apiFallback = ApiFallbackStatus(true, true)), null, "edit")!!
        assertFalse(e.useApiKey); assertEquals(ClaudeText.EDIT_NO_API, e.note)
    }

    @Test fun apiStreamReducer() {
        var ui = base().copy(turn = LiveTurn(null, "running", text = "Lower it", api = true))
        ui = ChatReducer.api(ui, ChatEvent("text", delta = "On it"))
        ui = ChatReducer.api(ui, ChatEvent("tool", id = "a", name = "set_camera_path", status = "running"))
        ui = ChatReducer.api(ui, ChatEvent("tool", id = "a", name = "set_camera_path", status = "done", summary = "Saved camera path"))
        assertEquals(listOf("Lower it", "On it", "Saved camera path"), ui.items.drop(2).map { when (it) { is ChatItem.User -> it.text; is ChatItem.Assistant -> it.text; is ChatItem.Tool -> it.text; else -> "" } })
        assertEquals("api", (ui.items[2] as ChatItem.User).source)
        ui = ChatReducer.api(ui, ChatEvent("done"))
        assertFalse(ui.busy)
        val err = ChatReducer.api(base().copy(turn = LiveTurn(null, "running", api = true)), ChatEvent("error", code = "fallback_off", error = "Turn it on"))
        assertEquals("failed", err.turn!!.state); assertNotNull(err.notice)
    }

    @Test fun liveEventsAreReadApartFromTheStream() {
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }
        val l = claudeLiveOf(json, """{"type":"claude","op":"event","threadId":"ct_1","turnId":"tu_1","event":{"type":"tool","id":"t","name":"mcp__muse__get_frame","status":"running","input":{"t":1.5}}}""")!!
        assertEquals("event" to "tool", l.op to l.event!!.type)
        assertEquals("ct_1", l.threadId)
        val st = claudeLiveOf(json, """{"type":"claude","op":"status","status":{"mac":{"online":true,"claudeCode":{"installed":true,"signedIn":false}},"apiFallback":{"available":true,"enabled":false},"connectorUrl":"u","openInClaudeUrl":"o"}}""")!!
        assertFalse(st.status!!.mac.ready)
        assertNull(claudeLiveOf(json, """{"type":"camera","op":"delete","id":"claude"}"""))
    }
}
