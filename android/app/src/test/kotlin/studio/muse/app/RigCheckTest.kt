package studio.muse.app

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.RigRules
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteRigCheck
import studio.muse.app.data.SuiteRigFix
import studio.muse.app.data.SuiteRigWarning
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.RigDismissals
import studio.muse.app.ui.screens.suite.composer.RigFixes

/**
 * The rig check on Android (workstream 3, plans/video-composer.md "Rig check"): the wire types decode (missing = none),
 * the demo's port of the rules gives the server's own answers, every patch shape lands on the composer's choices the way
 * a picker tap would (so the request equals the merge-patched one), × hides until the choices change, and a fix changes
 * the request, so the estimate (keyed on it) is fetched again without the warning.
 */
class RigCheckTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()
    private val cat: CameraCatalog = FakeSuite().camera
    private fun o(s: String) = Json.parseToJsonElement(s).jsonObject

    private fun draft(settings: ComposerSettings = ComposerSettings(), moves: List<String> = emptyList(), speaking: Boolean? = null, text: String = "She walks in "): ComposerDraft {
        var t = PromptTokens().withText(text)
        moves.forEach { id -> t = t.addMove(cat.move(id)!!, t.caretAtEnd, 70).first }
        return ComposerDraft(tokens = t, settings = settings, modelId = SampleData.DEMO, speaking = speaking)
    }
    private fun req(d: ComposerDraft) = d.request(InputSlots(), SuiteInputs.NONE, RecastDraft())
    private fun camera(d: ComposerDraft) = req(d).camera

    // ---------------------------------------------------------------- decoding

    @Test fun decodesRigAndDefaultsToNone() {
        val e = json.decodeFromString(SuiteEstimate.serializer(), res("suite_estimate_rig_member"))
        assertEquals(listOf("deep_focus", "look_clash"), e.rig.map { it.id })
        val w = e.rig[0]
        assertEquals("warn", w.severity); assertFalse(w.tip)
        assertEquals("Phone keeps everything in focus, so the rack focus won’t show", w.reason)
        assertEquals("Use Cinema camera", w.fix.label)
        assertEquals(o("""{"camera":{"rig":{"body":"cinema_digital"}}}"""), w.fix.patch)
        assertEquals("Drop the rack focus", w.alt!!.label)
        assertTrue(e.rig[1].tip)
        // Older servers: no `rig` at all.
        assertTrue(json.decodeFromString(SuiteEstimate.serializer(), res("suite_estimate_member")).rig.isEmpty())
        assertTrue(json.decodeFromString(SuiteRigCheck.serializer(), "{}").rig.isEmpty())
        // rig-check, with a mix removal (a JSON null inside the patch) and no alt.
        val r = json.decodeFromString(SuiteRigCheck.serializer(), res("suite_rigcheck_member")).rig
        assertEquals(JsonNull, r[1].fix.patch["camera"]!!.jsonObject["mix"])
        assertNull(r[1].alt)
        // A sparse warning still decodes (severity defaults to warn).
        val bare = json.decodeFromString(SuiteRigWarning.serializer(), """{"id":"x","reason":"r","fix":{"label":"L","patch":{}}}""")
        assertEquals("warn", bare.severity)
        // Members keep the list (no provider words in it); a line that named one would be dropped.
        assertEquals(e.rig, SuiteRules.memberSafe(e).rig)
        assertTrue(SuiteRules.memberSafe(listOf(bare.copy(reason = "Kling can't do this"))).isEmpty())
    }

    // ---------------------------------------------------------------- the demo's rules = the server's

    @Test fun demoRulesMatchTheServer() {
        val cases = Json.parseToJsonElement(res("suite_rigcheck_cases")) as JsonArray
        assertTrue(cases.size >= 10)
        for (c in cases) {
            val input = c.jsonObject["in"]!!.jsonObject
            val want = json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(SuiteRigWarning.serializer()), c.jsonObject["out"].toString())
            val got = RigRules.check((input["prompt"] as? JsonPrimitive)?.content, input["camera"], (input["speaking"] as? JsonPrimitive)?.content == "true", cat)
            assertEquals("$input", want, got)
        }
    }

    @Test fun demoEstimateAndRigCheckCarryTheRow() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val d = draft(ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 14, shotSize = "cu"), moves = listOf("orbit_left"), speaking = true)
        val e = api.suiteEstimate(req(d))
        assertEquals(listOf("deep_focus", "wide_close", "talk_move"), e.rig.map { it.id })
        assertTrue(e.ok) // never changes ok
        // The estimate fails (nothing fits): rig-check still has the list.
        val tooLong = req(d).copy(duration = 30)
        assertTrue(runCatching { api.suiteEstimate(tooLong) }.isFailure)
        assertEquals(e.rig, api.suiteRigCheck(tooLong).rig)
        // Swap and recast: none.
        assertTrue(api.suiteRigCheck(req(d).copy(mode = "swap")).rig.isEmpty())
    }

    // ---------------------------------------------------------------- applying a fix

    /** Applies [patch] and checks the request's camera is exactly the merge-patched camera (what the server would get). */
    private fun applies(d: ComposerDraft, patch: String): ComposerDraft {
        val p = o(patch)
        val next = RigFixes.apply(d, p, cat)
        val want = RigFixes.mergePatch(camera(d) ?: JsonObject(emptyMap()), p["camera"]!!)
        assertEquals(patch, want, camera(next))
        return next
    }

    @Test fun everyPatchShapeLandsOnTheChoices() {
        val base = draft(ComposerSettings(body = "phone", aperture = "f1.4", focalMm = 14, stock = "bw_film", palette = "hyper_neon", height = "worm", shotSize = "cu"))
        assertEquals("cinema_digital", applies(base, """{"camera":{"rig":{"body":"cinema_digital"}}}""").settings.body)
        assertEquals("f11", applies(base, """{"camera":{"rig":{"aperture":"f11"}}}""").settings.aperture)
        assertEquals(85, applies(base, """{"camera":{"rig":{"focalMm":85}}}""").settings.focalMm)
        assertEquals("digital_clean", applies(base, """{"camera":{"rig":{"look":"digital_clean"}}}""").settings.stock)
        assertEquals("naturalistic", applies(base, """{"camera":{"palette":{"preset":"naturalistic"}}}""").settings.palette)
        assertEquals("low", applies(base, """{"camera":{"angle":{"height":"low"}}}""").settings.height)
        val ms = applies(base, """{"camera":{"angle":{"shotSize":"ms"}}}""")
        assertEquals("ms", ms.settings.shotSize); assertEquals("worm", ms.settings.height) // objects merge: the rest stays
        // Everything else is untouched, as with one picker tap.
        assertEquals(base.settings.copy(body = "cinema_digital"), RigFixes.apply(base, o("""{"camera":{"rig":{"body":"cinema_digital"}}}"""), cat).settings)
        assertEquals(base.tokens, RigFixes.apply(base, o("""{"camera":{"rig":{"body":"cinema_digital"}}}"""), cat).tokens)
    }

    @Test fun moveAndMixPatchesEditThePromptsMoveTokens() {
        // move {id}: the first #move becomes the new one in place, keeping its intensity (merge).
        val one = draft(moves = listOf("orbit_left"))
        val s = applies(one, """{"camera":{"move":{"id":"static"}}}""")
        assertEquals(listOf("static"), s.tokens.moves.map { it.id })
        assertEquals(one.tokens.moves[0].key, s.tokens.moves[0].key)
        assertEquals(70, s.tokens.moves[0].intensity)
        assertEquals(cat.moveLabel("static"), s.tokens.moves[0].label) // the picker's name for it ("Locked-off")
        // No move yet: the fix adds one, as picking it would.
        val none = draft()
        assertEquals(listOf("dolly_out"), RigFixes.apply(none, o("""{"camera":{"move":{"id":"dolly_out"}}}"""), cat).tokens.moves.map { it.id })
        // mix: null removes the second move.
        val two = draft(moves = listOf("handheld", "dolly_in"))
        val dropped = applies(two, """{"camera":{"mix":null}}""")
        assertEquals(listOf("handheld"), dropped.tokens.moves.map { it.id })
        assertFalse(camera(dropped)!!.jsonObject.containsKey("mix"))
        // "Drop the rack focus" with a mix: the mix becomes the move, the mix goes.
        val rack = draft(moves = listOf("rack_focus", "handheld"))
        val promoted = applies(rack, """{"camera":{"move":{"id":"handheld","intensity":0.7},"mix":null}}""")
        assertEquals(listOf("handheld"), promoted.tokens.moves.map { it.id })
        // The server's own fix for that shot.
        val w = RigRules.check(null, camera(rack.copy(settings = ComposerSettings(body = "webcam"))), false, cat).first { it.id == "deep_focus" }
        assertEquals(listOf("handheld"), RigFixes.apply(rack, w.alt!!.patch, cat).tokens.moves.map { it.id })
        // "Lock it off" with a talk-safe mix: static can't be combined, so it takes the shot alone (the picker refuses the pair).
        val locked = RigFixes.apply(draft(moves = listOf("orbit_left", "rack_focus")), o("""{"camera":{"move":{"id":"static"}}}"""), cat)
        assertEquals(listOf("static"), locked.tokens.moves.map { it.id })
        // The prompt text is unchanged by any of it.
        assertEquals(two.tokens.promptText(), dropped.tokens.promptText())
    }

    @Test fun otherShapesNullsSpeakingAndDirected() {
        val d = draft(ComposerSettings(body = "phone", lighting = "window", genre = "ugc"))
        val auto = RigFixes.apply(d, o("""{"camera":{"rig":{"body":null},"lighting":{"preset":"neon"},"style":{"genre":null}}}"""), cat)
        assertNull(auto.settings.body); assertEquals("neon", auto.settings.lighting); assertNull(auto.settings.genre)
        assertEquals(true, RigFixes.apply(d, o("""{"speaking":true}"""), cat).speaking)
        assertEquals(d, RigFixes.apply(d, o("""{"unknown":{"x":1}}"""), cat))
        // A Directed camera (owner) replaces the chips: the fix goes into that JSON instead.
        val dir = d.copy(directed = """{"mode":"directed","rig":{"body":"phone","aperture":"f1.4"},"mix":{"id":"rack_focus"}}""")
        val fixed = RigFixes.apply(dir, o("""{"camera":{"rig":{"body":"cinema_digital"},"mix":null}}"""), cat)
        assertEquals(o("""{"mode":"directed","rig":{"body":"cinema_digital","aperture":"f1.4"}}"""), Json.parseToJsonElement(fixed.directed!!))
        assertEquals(d.settings, fixed.settings)
    }

    @Test fun mergePatchIsRfc7386() {
        fun mp(t: String, p: String): JsonElement? = RigFixes.mergePatch(Json.parseToJsonElement(t), Json.parseToJsonElement(p))
        assertEquals(Json.parseToJsonElement("""{"a":"z","c":{"d":"e"}}"""), mp("""{"a":"b","c":{"d":"e","f":"g"}}""", """{"a":"z","c":{"f":null}}"""))
        assertEquals(Json.parseToJsonElement("""["c"]"""), mp("""{"a":"b"}""", """["c"]"""))
        assertEquals(Json.parseToJsonElement("""{"a":{"bb":{}}}"""), mp("""{}""", """{"a":{"bb":{"ccc":null}}}"""))
        assertEquals(Json.parseToJsonElement("""{"e":null}""").jsonObject.let { JsonObject(emptyMap()) }, mp("""{"e":1}""", """{"e":null}"""))
    }

    // ---------------------------------------------------------------- dismiss

    @Test fun crossHidesUntilTheChoicesChange() {
        val a = SuiteRigWarning("deep_focus", "warn", "Phone keeps everything in focus", SuiteRigFix("Use Cinema camera"))
        val b = SuiteRigWarning("look_clash", "tip", "B&W vs neon", SuiteRigFix("Keep B&W"), SuiteRigFix("Keep neon"))
        val d = draft(ComposerSettings(body = "phone", aperture = "f1.4"))
        val now = RigDismissals.choicesOf(d)
        var x = RigDismissals()
        assertEquals(listOf(a, b), x.visible(listOf(a, b), now))
        x = x.dismiss(a, now)
        assertEquals(listOf(b), x.visible(listOf(a, b), now))
        x = x.dismiss(b, now)
        assertTrue(x.visible(listOf(a, b), now).isEmpty())
        // Typing in the prompt isn't a change of choices.
        assertEquals(now, RigDismissals.choicesOf(d.copy(tokens = d.tokens.setText(0, "Something else"))))
        // A chip, a #move, speaking or the tool is: everything shows again.
        for (changed in listOf(d.copy(settings = d.settings.copy(aperture = "f2")), draft(d.settings, moves = listOf("static")), d.copy(speaking = true), d.copy(tool = ComposerTool.TALKING))) {
            val c = RigDismissals.choicesOf(changed)
            assertNotEquals(now, c)
            assertEquals(listOf(a, b), x.visible(listOf(a, b), c))
        }
        // The same rule with new words (a new clash) still shows.
        assertEquals(1, x.visible(listOf(a.copy(reason = "Webcam keeps everything in focus")), now).size)
        // Hiding under new choices starts a fresh set.
        val fresh = x.dismiss(a, "other")
        assertEquals(setOf(RigDismissals.key(a)), fresh.hidden)
    }

    // ---------------------------------------------------------------- re-fetch after a fix

    @Test fun aFixChangesTheRequestSoTheEstimateRefreshesWithoutIt() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        var d = draft(ComposerSettings(body = "phone", aperture = "f1.4"), moves = listOf("orbit_left"), speaking = true)
        var e = api.suiteEstimate(req(d))
        assertEquals(listOf("deep_focus", "talk_move"), e.rig.map { it.id })
        for (id in listOf("deep_focus", "talk_move")) {
            val w = e.rig.first { it.id == id }
            val next = RigFixes.apply(d, w.fix.patch, cat)
            // rememberEstimate is keyed on the request: a different request = a new estimate.
            assertNotEquals(req(d), req(next))
            d = next
            e = api.suiteEstimate(req(d))
            assertFalse(id, e.rig.any { it.id == id })
        }
        assertTrue(e.rig.isEmpty())
        // The alt fixes clear their rule too.
        val again = draft(ComposerSettings(body = "phone", aperture = "f1.4"), moves = listOf("orbit_left"), speaking = true)
        for (w in api.suiteEstimate(req(again)).rig) {
            val alt = w.alt ?: continue
            assertFalse(w.id, api.suiteEstimate(req(RigFixes.apply(again, alt.patch, cat))).rig.any { it.id == w.id })
        }
    }
}
