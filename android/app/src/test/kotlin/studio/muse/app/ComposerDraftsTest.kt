package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.muse.app.data.SuiteDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptPart
import studio.muse.app.ui.screens.suite.composer.PromptTokens

/** Reuse settings: the composer's draft round-trips exactly, in the Mac's JSON. */
class ComposerDraftsTest {
    private val tokens = PromptTokens(listOf(
        PromptPart.Mention("character", "m_1", "Maya", 1), PromptPart.Text(" walks into the café, "),
        PromptPart.Move("dolly_in", "Dolly in", "push", 70, 2),
    ))
    private val d = ComposerDraft(tool = ComposerTool.SHOT, tokens = tokens, settings = ComposerSettings(body = "phone", lens = "35"), quality = "standard",
        aspect = "16:9", duration = 6, sound = false, speaking = true, takes = 2, outfitId = "o_9")

    @Test fun aDraftComesBackExactly() {
        val s = ComposerDrafts.draft(d)
        assertEquals("shot", s.tool); assertEquals("16:9", s.aspect); assertEquals(6.0, s.duration!!, 0.0); assertEquals(false, s.sound)
        // Through the wire and back, into a blank composer.
        val wire = SuiteDraft(kotlinx.serialization.json.Json.parseToJsonElement(s.json.toString()) as kotlinx.serialization.json.JsonObject)
        val back = ComposerDrafts.restore(wire, ComposerDraft())
        assertEquals(d.tokens, back.tokens)
        assertEquals(d.copy(collapsed = false, directed = null).let { listOf(it.tool, it.quality, it.aspect, it.duration, it.sound, it.speaking, it.takes, it.outfitId, it.settings.body, it.settings.lens) },
            listOf(back.tool, back.quality, back.aspect, back.duration, back.sound, back.speaking, back.takes, back.outfitId, back.settings.body, back.settings.lens))
        assertEquals(listOf("m_1"), ComposerDrafts.characterIds(back.tokens))
        assertEquals(.7, ComposerDrafts.rigMoves(back.tokens)!!.single().intensity!!, 1e-9)
    }

    @Test fun aMacDraftIsReadToo() {
        val mac = """{"v":1,"tool":"shot","quality":"draft","aspect":"9:16","duration":8,"takes":1,"sound":true,
            "tokens":[{"t":"text","text":"Sunset on the pier"},{"t":"move","id":"orbit","label":"Orbit","category":"orbit","intensity":40,"key":3}]}"""
        val back = ComposerDrafts.restore(SuiteDraft(kotlinx.serialization.json.Json.parseToJsonElement(mac) as kotlinx.serialization.json.JsonObject), ComposerDraft(quality = "hd"))
        assertEquals("draft", back.quality)
        assertEquals("Sunset on the pier", (back.tokens.parts.first() as PromptPart.Text).text)
        assertEquals(40, back.tokens.moves.single().intensity)
    }
}
