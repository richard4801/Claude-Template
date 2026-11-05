package studio.muse.app.camera

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.CamKey
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.CameraMessage
import studio.muse.app.data.CameraPath
import studio.muse.app.data.CameraSession
import studio.muse.app.data.CameraTool
import studio.muse.app.data.CharKey
import studio.muse.app.data.CharacterTrack
import studio.muse.app.data.ChatEvent
import studio.muse.app.data.ClaudeStatus
import studio.muse.app.data.Connections
import studio.muse.app.data.FakeCameraApi
import studio.muse.app.data.RelayStatus
import studio.muse.app.ui.screens.camera.Bounds
import studio.muse.app.ui.screens.camera.CameraGuideHandoff
import studio.muse.app.ui.screens.camera.CameraLive
import studio.muse.app.ui.screens.camera.CameraUi
import studio.muse.app.ui.screens.camera.ChatNotice
import studio.muse.app.ui.screens.camera.ChatTurn
import studio.muse.app.ui.screens.camera.ConnectionText
import studio.muse.app.ui.screens.camera.Dot
import studio.muse.app.ui.screens.camera.Drag
import studio.muse.app.ui.screens.camera.History
import studio.muse.app.ui.screens.camera.P2
import studio.muse.app.ui.screens.camera.Plan
import studio.muse.app.ui.screens.camera.PlanFit
import studio.muse.app.ui.screens.camera.SessionText
import studio.muse.app.ui.screens.camera.Timeline
import studio.muse.app.ui.screens.camera.Transcript
import studio.muse.app.ui.screens.camera.Turn
import studio.muse.app.ui.screens.camera.collapseTools
import kotlin.math.abs

class CameraLogicTest {
    private val now = 1_800_000_000_000L
    private val seed: CameraSession = runBlocking { FakeCameraApi(now = { now }).session(FakeCameraApi.SEED_ID) }

    private fun near(a: Double, b: Double, eps: Double = 1e-6) = assertTrue("$a ≈ $b", abs(a - b) < eps)

    @Test fun idChipTakesFourCharactersUpperCase() {
        assertEquals("cs_7Q2M", SessionText.idChip("cs_7q2m4x9kfb2a"))
        assertEquals("cs_AB", SessionText.idChip("cs_ab"))
        assertEquals("cs_7Q2M · 6.0 s · rev 4", SessionText.subtitle(seed))
        assertEquals("9:16 · 24 fps · 6.0 s · rev 4", SessionText.specLine(seed))
    }

    @Test fun boundsFitEveryPointWithAOneMetreMargin() {
        val path = CameraPath(listOf(CamKey(0.0, listOf(0.0, -2.0, 1.5), listOf(1.0, 1.0, 1.5))))
        val tracks = listOf(CharacterTrack("m", listOf(CharKey(0.0, listOf(-3.0, 2.0, 0.0)))))
        assertEquals(Bounds(-4.0, -3.0, 2.0, 3.0), Plan.bounds(path, tracks))
        assertNull(Plan.bounds(null, emptyList()))
        // Side view: X/Z, never below the floor minus the margin.
        assertEquals(Bounds(-4.0, -1.0, 2.0, 2.5), Plan.bounds(path, tracks, side = true))
    }

    @Test fun planFitMapsMetresToPixelsWithYUp() {
        val fit = PlanFit(Bounds(0.0, 0.0, 6.0, 4.0), 600f, 400f)
        near(fit.scale, 100.0)
        assertEquals(0f, fit.x(0.0)); assertEquals(600f, fit.x(6.0))
        assertEquals(400f, fit.y(0.0)); assertEquals(0f, fit.y(4.0)) // +Y (away from the camera) is up
        val back = fit.toMetres(fit.x(2.5), fit.y(1.25))
        near(back.x, 2.5, 1e-4); near(back.y, 1.25, 1e-4)
        // Letterboxed: a wide drawing area centres the plan.
        val wide = PlanFit(Bounds(0.0, 0.0, 2.0, 2.0), 400f, 200f)
        assertEquals(100f, wide.x(0.0)); assertEquals(300f, wide.x(2.0))
    }

    @Test fun interpolationEasesAndHoldsAtTheEnds() {
        val keys = listOf(CharKey(0.0, listOf(0.0, 0.0, 0.0), 0.0, "walk"), CharKey(2.0, listOf(2.0, 0.0, 0.0), 90.0, "turn"))
        near(Plan.characterAt(keys, 1.0)!!.position[0], 1.0)
        near(Plan.characterAt(keys, 1.0)!!.facingDeg!!, 45.0)
        near(Plan.characterAt(keys, -1.0)!!.position[0], 0.0)
        near(Plan.characterAt(keys, 9.0)!!.position[0], 2.0)
        assertEquals("walk", Plan.characterAt(keys, 1.9)!!.action)
        assertEquals("turn", Plan.characterAt(keys, 2.0)!!.action)
        near(Plan.ease("in_out", .5), .5); near(Plan.ease("in_out", .25), .15625)
        near(Plan.ease("in", .5), .25); near(Plan.ease("out", .5), .75); near(Plan.ease(null, .3), .3)
        val cam = listOf(CamKey(0.0, listOf(0.0, 0.0, 1.0), focalMm = 24.0), CamKey(4.0, listOf(4.0, 0.0, 1.0), focalMm = 50.0, ease = "in_out"))
        val mid = Plan.cameraAt(cam, 1.0)!!
        near(mid.position[0], 4 * Plan.ease("in_out", .25)); near(mid.focalMm!!, 24 + 26 * Plan.ease("in_out", .25))
        near(Plan.lerpAngle(350.0, 10.0, .5), 360.0) // the short way round
    }

    @Test fun viewConeFromFocalLength() {
        near(Plan.hfovDeg(35.0), 54.432, 1e-3)
        near(Plan.hfovDeg(18.0), 90.0, 1e-9)
        val (c, a, b) = Plan.viewCone(CamKey(0.0, listOf(0.0, 0.0, 1.5), listOf(0.0, 2.0, 1.5), 18.0), length = 2.0)
        assertEquals(P2(0.0, 0.0), c)
        near(a.x, Math.sqrt(2.0), 1e-9); near(a.y, Math.sqrt(2.0), 1e-9)
        near(b.x, -Math.sqrt(2.0), 1e-9); near(b.y, Math.sqrt(2.0), 1e-9)
        assertEquals("CAM A · 35 mm · 1.5 m", Plan.camLabel(seed.cameraPath!!.keyframes[0]))
        val f = Plan.facing(0.0); near(f.x, 0.0); near(f.y, -1.0)
    }

    @Test fun ticksAndRuler() {
        assertEquals("0.0s", Plan.tick(0.0)); assertEquals("1.2s", Plan.tick(1.2)); assertEquals("2.4 s", Plan.chip(2.4))
        assertEquals(listOf("0s", "1s", "2s", "3s", "4s", "5s", "6s"), Plan.ruler(6.0).map { it.second })
        assertEquals(7, Plan.ruler(6.5).size)
        assertEquals("NE", Plan.initials("Noor Ellis")); assertEquals("DM", Plan.initials("Demo model")); assertEquals("AV", Plan.initials("ava"))
        val (xs, ys) = Plan.gridLines(Bounds(-1.0, 0.0, 1.0, 1.0))
        assertEquals(listOf(-1.0, -0.5, 0.0, 0.5, 1.0), xs); assertEquals(3, ys.size)
    }

    @Test fun timelineLabels() {
        val spans = Timeline.cameraSpans(seed.cameraPath)
        assertEquals(listOf("push 0.4 m · ease in-out", "orbit 90°"), spans.map { it.label })
        assertEquals(4.5, spans[1].start, 0.0)
        val tgt = listOf(0.0, 2.0, 1.5)
        assertEquals("pull 1.0 m", Timeline.cameraMove(CamKey(0.0, listOf(0.0, 0.0, 1.5), tgt), CamKey(1.0, listOf(0.0, -1.0, 1.5), tgt)))
        assertEquals("hold", Timeline.cameraMove(CamKey(0.0, listOf(0.0, 0.0, 1.5), tgt), CamKey(1.0, listOf(0.0, 0.0, 1.5), tgt)))
        assertEquals("zoom 24→50 mm · ease out", Timeline.cameraMove(CamKey(0.0, listOf(0.0, 0.0, 1.5), tgt, 24.0), CamKey(1.0, listOf(0.0, 0.0, 1.5), tgt, 50.0, ease = "out")))
        val chars = seed.blocking!!.characters
        assertEquals(listOf("walk → counter · 1.1 m/s", "turn · smile to camera"), Timeline.characterSpans(chars[0].keyframes, 6.0).map { it.label })
        assertEquals(6.0, Timeline.characterSpans(chars[0].keyframes, 6.0).last().end, 0.0)
        assertEquals(listOf("waits by window", "looks at Demo"), Timeline.characterSpans(chars[1].keyframes, 6.0).map { it.label })
    }

    @Test fun statusRowsFollowTheSpec() {
        val conn = Connections(inAppChat = true)
        assertEquals("Connected · your Claude app", SessionText.claudeRow(seed.copy(claude = ClaudeStatus(false, now - 60_000)), conn, false, now).text)
        assertEquals("In MUSE (this chat)", SessionText.claudeRow(seed.copy(claude = ClaudeStatus(false, now - 6 * 60_000)), conn, false, now).text)
        assertEquals("Not set up", SessionText.claudeRow(seed.copy(claude = ClaudeStatus()), Connections(inAppChat = false), false, now).text)
        assertEquals("Working…", SessionText.claudeRow(seed.copy(claude = ClaudeStatus(true)), conn, false, now).text)
        assertEquals("Working…", SessionText.claudeRow(seed, conn, true, now).text)

        val b = SessionText.blenderRow(seed.copy(relay = RelayStatus(true, true, "1.8")))
        assertEquals("Blender 1.8" to "Mac · localhost", b.title to b.text); assertEquals(Dot.GOOD, b.dot)
        assertEquals("Mac app online · Blender not connected", SessionText.blenderRow(seed.copy(relay = RelayStatus(true, false))).text)
        assertEquals("Mac app offline", SessionText.blenderRow(seed.copy(relay = RelayStatus(false, false))).text)
        assertEquals("Blender", SessionText.blenderRow(seed.copy(relay = RelayStatus(false, false))).title)

        assertEquals("Guides ready", SessionText.rendersRow(seed).text)
        assertEquals("None yet", SessionText.rendersRow(seed.copy(assets = emptyList())).text)
        val batch = (1..5).map { CameraAsset("a$it", "keyframe_start", state = if (it <= 2) "ready" else "pending", createdAt = now + it) }
        assertEquals("Uploading 3 of 5 to MUSE", SessionText.rendersRow(seed.copy(assets = seed.assets + batch)).text)

        assertEquals("Guides ready" to "good", SessionText.pill(seed))
        assertEquals("Blocking" to "", SessionText.pill(seed.copy(status = "blocking", assets = emptyList())))
        assertEquals("Drafting" to "", SessionText.pill(seed.copy(status = "drafting", assets = emptyList())))
    }

    @Test fun toolChipsCollapse() {
        val chips = collapseTools(listOf("blender_setup_scene" to true, "blender_place_character" to true, "blender_place_character" to false, "blender_render_guides" to true, "blender_setup_scene" to true))
        assertEquals(listOf("SETUP_SCENE", "PLACE_CHARACTER ×2", "RENDER_GUIDES", "SETUP_SCENE"), chips.map { it.label })
        assertEquals(listOf(true, false, true, true), chips.map { it.ok })
    }

    @Test fun transcriptGroupsClaudeTextWithItsToolSteps() {
        val turns = Transcript.turns(seed.messages!!, setOf())
        assertEquals(2, turns.size)
        val you = turns[0] as Turn.You
        assertEquals("YOU", you.label)
        val claude = turns[1] as Turn.Claude
        assertTrue(claude.text.startsWith("Built the café"))
        assertEquals(listOf("SETUP_SCENE", "PLACE_CHARACTER ×2", "SET_CAMERA", "RENDER_GUIDES"), claude.tools.map { it.label })
        assertEquals("YOU · PHONE", (Transcript.turns(seed.messages!!, setOf(you.text))[0] as Turn.You).label)
    }

    @Test fun workingStripProgress() {
        var t = ChatTurn("Slower orbit", 4)
        assertEquals("Claude · working on rev 5", t.title)
        assertEquals("Reading the session…", t.quote)
        t = CameraLive.turn(t, ChatEvent("text", delta = "Easing the orbit to 45°/s…"))
        t = CameraLive.turn(t, ChatEvent("tool", name = "blender_set_camera", status = "running"))
        t = CameraLive.turn(t, ChatEvent("tool", name = "blender_set_camera", status = "done", summary = "orbit 90°"))
        t = CameraLive.turn(t, ChatEvent("tool", name = "blender_render_guides", status = "running"))
        t = CameraLive.turn(t, ChatEvent("waiting", reason = "blender"))
        assertEquals(2, t.toolsSeen); assertEquals(1, t.toolsDone); assertTrue(t.waitingMac)
        assertEquals("50%", t.percent)
        assertEquals("Easing the orbit to 45°/s…", t.quote)
        assertEquals("64%", t.copy(renderProgress = .64f).percent)
    }

    @Test fun footerText() {
        assertEquals("Claude never spends money. Generating waits for your tap · est. $1.92 at HD.", SessionText.footer(seed))
        assertEquals("Claude never spends money. Generating waits for your tap.", SessionText.footer(seed.copy(shotDraft = null)))
        assertEquals("Claude never spends money. Generating waits for your tap.", SessionText.footer(null))
        assertEquals("Greybox · depth · pose · 3 keyframes", SessionText.guidesLine(seed.assets))
    }

    @Test fun noticesWordTheCodes() {
        assertTrue(ChatNotice.of("director_unavailable", "x").directorUnavailable)
        assertEquals(ChatNotice.UNAVAILABLE, ChatNotice.of("director_unavailable", "x").text)
        assertEquals("Claude is still working on this shot", ChatNotice.of("chat_busy", null).text)
        assertEquals("boom", ChatNotice.of("director_failed", "boom").text)
    }

    @Test fun dragMovesTheKeyAtThePlayheadOrInsertsOne() {
        val tracks = seed.blocking!!.characters
        val id = tracks[0].modelId
        val moved = Drag.moveCharacter(tracks, id, 1.22, P2(-1.0, 2.0))
        assertEquals(tracks[0].keyframes.size, moved[0].keyframes.size)
        assertEquals(listOf(-1.0, 2.0, 0.0), moved[0].keyframes[1].position)
        assertEquals(tracks[1], moved[1])
        val inserted = Drag.moveCharacter(tracks, id, 3.0, P2(0.5, 1.0))
        assertEquals(tracks[0].keyframes.size + 1, inserted[0].keyframes.size)
        assertEquals(listOf(0.0, 1.2, 2.4, 3.0, 3.5), inserted[0].keyframes.map { it.t })
        assertEquals(listOf(0.5, 1.0, 0.0), inserted[0].keyframes[3].position)

        val path = seed.cameraPath!!
        val cam = Drag.moveCamera(path, 4.5, P2(0.0, -1.2))
        assertEquals(listOf(0.0, -1.2, 1.5), cam.keyframes[1].position)
        assertEquals(path.keyframes[1].target, cam.keyframes[1].target)
        val cam2 = Drag.moveCamera(path, 2.0, P2(0.0, -1.0))
        assertEquals(listOf(0.0, 2.0, 4.5, 6.0), cam2.keyframes.map { it.t })
        assertEquals(35.0, cam2.keyframes[1].focalMm!!, 1e-9)
    }

    @Test fun handoffComesFromTheDraftRequest() {
        val h = CameraGuideHandoff.of(seed)
        assertNotNull(h)
        assertEquals(FakeCameraApi.SEED_ID, h!!.sessionId)
        assertEquals("cam/${FakeCameraApi.SEED_ID}/ca_greybo.mp4", h.videoKey)
        assertEquals(1, h.middle.size)
        val json = Json.parseToJsonElement(h.cameraJson()).jsonObject
        assertEquals("directed", json["mode"]!!.jsonPrimitive.content)
        val g = json["guide"]!!.jsonObject
        assertEquals("blocking", g["use"]!!.jsonPrimitive.content)
        assertEquals(FakeCameraApi.SEED_ID, g["cameraSessionId"]!!.jsonPrimitive.content)
        assertEquals(6.0, g["video"]!!.jsonObject["seconds"]!!.jsonPrimitive.content.toDouble(), 0.0)
        assertTrue(g["keyframes"]!!.jsonObject["middle"]!!.jsonArray.size == 1)
        assertNull(CameraGuideHandoff.of(seed.copy(shotDraft = null)))
    }

    @Test fun liveEventsUpdateTheScreens() {
        var ui = CameraUi(sessions = listOf(seed.copy(messages = null)), openId = seed.id, session = seed.copy(messages = null), messages = seed.messages!!)
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "upsert", session = seed.copy(revision = 5, title = "Café v2", updatedAt = now + 1)))
        assertEquals("Café v2", ui.session!!.title); assertEquals(5, ui.sessions[0].revision)
        // An older revision doesn't win.
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "upsert", session = seed.copy(revision = 3, title = "old")))
        assertEquals("Café v2", ui.session!!.title)
        val msg = CameraMessage("cm_x", "tool", "chat", "s", CameraTool("blender_status", true, "s"), now)
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "message", sessionId = seed.id, message = msg))
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "message", sessionId = seed.id, message = msg))
        assertEquals(seed.messages!!.size + 1, ui.messages.size)
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "asset", sessionId = seed.id, asset = CameraAsset("ca_new", "preview", state = "pending")))
        assertEquals("pending", ui.session!!.assets.last().state)
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "asset", sessionId = seed.id, asset = CameraAsset("ca_new", "preview", state = "ready")))
        assertEquals(seed.assets.size + 1, ui.session!!.assets.size); assertEquals("ready", ui.session!!.assets.last().state)
        ui = CameraLive.apply(ui, ApiEvent("blender", op = "relay", online = true, blender = false))
        assertEquals("Mac app online · Blender not connected", SessionText.blenderRow(ui.session!!).text)
        ui = CameraLive.apply(ui, ApiEvent("camera", op = "delete", id = seed.id))
        assertTrue(ui.sessions.isEmpty()); assertNull(ui.session); assertNotNull(ui.error)
    }

    @Test fun historyAndConnectionText() {
        val lines = History.lines(seed.messages!!, seed.assets)
        assertTrue(lines.zipWithNext().all { (a, b) -> a.at >= b.at })
        assertTrue(lines.any { it.who == "Claude (chat)" && it.what.startsWith("render guides") })
        assertTrue(lines.any { it.who == "Your Claude" && it.what == "uploaded .blend" })
        assertEquals("claude mcp add --transport http muse https://x/mcp --header \"Authorization: Bearer muse_pat_abc\"", ConnectionText.claudeCode("https://x/mcp", "muse_pat_abc"))
        assertTrue(ConnectionText.claudeDesktop("https://x/mcp", null).contains("\"Authorization:\${MUSE_AUTH}\""))
        assertEquals("2 min ago", SessionText.ago(now - 120_000, now))
        assertEquals("4.2 MB", SessionText.bytes(4_200_000))
    }
}
