package studio.muse.app

import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiException
import studio.muse.app.data.CreateInviteRequest
import studio.muse.app.data.CreateTemplateRequest
import studio.muse.app.data.PatchTemplateRequest
import studio.muse.app.data.PromptSlotView
import studio.muse.app.data.ShootRequest
import studio.muse.app.data.TemplatePromptRequest
import studio.muse.app.data.ErrorText
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemberPatch
import studio.muse.app.data.ReclaimRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.SignInRequest
import studio.muse.app.data.SignUpRequest
import studio.muse.app.data.StudioSettingsPatch
import studio.muse.app.data.TransferRequest
import studio.muse.app.data.UploadMode
import studio.muse.app.ui.screens.looksLikeInvite
import java.io.File
import java.net.ServerSocket

/**
 * Contract test against the real backend (server/api) started locally by scripts/test-server.ts: embedded Postgres in
 * memory, local storage, simulated GPU and images, dev seed (owner jen@studio.com / x). Never touches the live server.
 * Skipped when Node or server/api's node_modules are missing (run `npm install` in server/api).
 *
 * invite → sign-up → me → wallet → owner sends tokens to a member (wallet event) → member job charges tokens →
 * insufficient_tokens, plus over-allocation, caps, switch-off, presigned and multipart uploads, settings and sign-out.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RealApiContractTest {
    private var proc: Process? = null
    private lateinit var base: String

    @Before fun start() {
        val dir = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "server/api") }.firstOrNull { File(it, "scripts/test-server.ts").exists() }
        val node = runCatching { ProcessBuilder("node", "--version").start().waitFor() == 0 }.getOrDefault(false)
        assumeTrue("node + server/api (with node_modules) required", dir != null && node && File(dir, "node_modules/tsx").exists())
        val port = ServerSocket(0).use { it.localPort }
        proc = ProcessBuilder("node", "--import", "tsx", "scripts/test-server.ts").directory(dir).apply {
            environment()["PORT"] = "$port"; environment()["SPEED"] = "2400"; environment()["GEN_MS"] = "50"; environment()["MUSE_EXIT_ON_STDIN_CLOSE"] = "1"
            environment()["PUBLIC_URL"] = "http://127.0.0.1:$port"
            redirectErrorStream(true)
        }.start()
        val reader = proc!!.inputStream.bufferedReader()
        val deadline = System.currentTimeMillis() + 120_000
        while (true) {
            val line = reader.readLine() ?: error("server/api exited before it was ready")
            if (line.contains("mock server")) break
            check(System.currentTimeMillis() < deadline) { "server/api not ready in time" }
        }
        Thread { runCatching { reader.forEachLine { println("[server/api] $it") } } }.apply { isDaemon = true }.start()
        base = "http://127.0.0.1:$port/"
    }

    @After fun stop() { proc?.let { p -> runCatching { p.outputStream.close() }; p.destroy() } }

    private suspend fun expectCode(code: String, block: suspend () -> Unit): ApiException {
        try { block() } catch (e: ApiException) { assertEquals(e.message, code, e.code); return e }
        error("expected $code")
    }

    @Test fun inviteSignUpTokensJobsAndOwnerScreens(): Unit = runBlocking {
        val owner = HttpMuseApi(base)
        val member = HttpMuseApi(base)
        assertEquals("local", owner.health().storage)

        // ---- owner signs in; invites a member
        val auth = owner.signIn(SignInRequest("jen@studio.com", "x"))
        assertEquals("owner", auth.user.role)
        owner.setToken(auth.token)
        assertEquals("owner", owner.me().role)
        val email = "maya@test.local"
        val inv = owner.createInvite(CreateInviteRequest(email = email))
        assertTrue(inv.code, looksLikeInvite(inv.code))
        assertEquals(email, inv.email)
        // Share sends the server's message: the download page, the code and the email.
        assertTrue(inv.shareText.orEmpty(), inv.shareText.orEmpty().contains("/get") && inv.shareText!!.contains(inv.code) && inv.shareText!!.contains(email))
        assertEquals(inv.shareText, inv.shareMessage(base))

        // ---- sign-up errors map to friendly messages
        expectCode("attestation_required") { member.signUp(SignUpRequest("", email, "pw-123456", true, false, inv.code)) }
        expectCode("invite_invalid") { member.signUp(SignUpRequest("", email, "pw-123456", true, true, "MUSE-AAAA-BBBB-CCCC")) }
        val other = expectCode("invite_invalid") { member.signUp(SignUpRequest("", "someone@else.test", "pw-123456", true, true, inv.code)) }
        assertTrue(ErrorText.of(other).contains("different email"))
        expectCode("email_taken") { member.signUp(SignUpRequest("", "jen@studio.com", "pw-123456", true, true, inv.code)) }

        // ---- invite → sign-up → me
        val signed = member.signUp(SignUpRequest("", email, "pw-123456", true, true, inv.code))
        assertEquals("member", signed.user.role)
        member.setToken(signed.token)
        val me = member.me()
        assertEquals(email, me.email); assertEquals("member", me.role); assertEquals(signed.user.id, me.id)
        expectCode("invite_invalid") { HttpMuseApi(base).signUp(SignUpRequest("", "second@test.local", "pw-123456", true, true, inv.code)) } // used once
        expectCode("bad_credentials") { HttpMuseApi(base).signIn(SignInRequest(email, "wrong")) }
        expectCode("owner_only") { member.listMembers() }
        expectCode("owner_only") { member.createInvite(CreateInviteRequest(email = "x@y.z")) }

        // ---- wallet: empty until the owner sends tokens
        val w0 = member.wallet()
        assertEquals(0L, w0.tokens); assertEquals("member", w0.role)
        val ow = owner.wallet()
        assertTrue(ow.owner); assertNotNull(ow.availableToSend); assertNotNull(ow.studioBalance); assertEquals("studio", ow.balanceSource)
        val over = expectCode("over_allocation") { owner.transfer(TransferRequest(me.id, ow.tokensToSend + 1_000)) }
        // The server counts tokens; the app shows its explanation in dollars only.
        assertTrue(ErrorText.of(over), ErrorText.of(over).startsWith("You can send at most $"))
        assertTrue(ErrorText.of(over), !ErrorText.of(over).contains("token", ignoreCase = true))

        // ---- owner sends 500 tokens; the member's wallet event arrives
        val walletEvent = async { withTimeout(10_000) { member.events().first { it.wallet != null && it.wallet.tokens == 500L } } }
        delay(700) // let the event stream connect
        val sent = owner.transfer(TransferRequest(me.id, 500, "for the test"))
        assertEquals(500L, sent.member.tokens)
        assertEquals("member", walletEvent.await().wallet!!.role)
        assertEquals(500L, member.wallet().tokens)
        assertEquals(500L, owner.listMembers().first { it.id == me.id }.tokens)

        // ---- caps and members
        assertEquals(3.0, owner.patchMember(me.id, MemberPatch(capPerDay = 3.0)).capPerDay!!, 1e-9)
        val cleared = owner.patchMember(me.id, MemberPatch(clearCapPerDay = true))
        assertTrue(cleared.capPerDay == null || cleared.capPerDay == owner.studioSettings().capPerUserDay)

        // ---- the member's job charges tokens
        val clip = member.uploadClip(SampleData.sampleMeta, null)
        val req = JobRequest("Dance", SampleData.DEMO, SampleData.GREEN, clip.id, steps = 10)
        val done = async { withTimeout(20_000) { member.events().first { it.job?.done == true } } }
        delay(500)
        val job = member.createJob(req)
        assertEquals(job.id, done.await().job!!.id)
        val after = withTimeout(5_000) { var w = member.wallet(); while (w.heldTokens > 0) { delay(100); w = member.wallet() }; w }
        assertTrue("charged: ${after.tokens}", after.tokens in 1..440)
        assertTrue(after.todayUsd > 0.5)
        val take = member.listTakes().first { it.jobId == job.id }
        assertNull(take.videoUrl) // simulated GPU: no video, the app keeps the still

        // ---- photo templates: hidden layers stay with the owner, the server builds the prompt
        val ownerList = owner.listTemplates()
        val mirrorOwn = ownerList.first { it.starter == "mirror-selfie" }
        assertTrue(mirrorOwn.isOwner); assertNotNull(mirrorOwn.layers); assertTrue(mirrorOwn.variationPool!!.getValue("pose").isNotEmpty())
        val secretStyle = mirrorOwn.layers!!.style!!
        val mirror = member.listTemplates("public").first { it.starter == "mirror-selfie" }
        assertTrue(!mirror.isOwner && mirror.public); assertNull(mirror.layers); assertNull(mirror.variationPool)
        assertTrue(mirror.cover!!.url!!.startsWith(base.trimEnd('/')))
        assertEquals(7, member.listTemplates().count { it.starter != null })
        assertTrue(member.listTemplates(q = "faceless").any { it.id == mirror.id })
        val view = member.templatePrompt(mirror.id, TemplatePromptRequest(SampleData.DEMO, SampleData.GREEN, "sitting on the steps", 7))
        assertEquals(PromptSlotView("template", "Template: Mirror selfie", true), view.slots.first { it.layer == "template" })
        assertTrue(view.text, !view.text.contains(secretStyle) && view.text.contains("Direction: sitting on the steps."))
        assertNull(view.variation)
        val shots = member.shoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, "", "", count = 2, templateId = mirror.id, shuffleSeed = 11))
        assertEquals(2, shots.size)
        shots.forEach { assertEquals("Mirror selfie", it.templateName); assertTrue(it.prompt.contains("Template: Mirror selfie")); assertTrue(!it.prompt.contains(secretStyle)); assertNull(it.variation) }
        val asOwner = owner.listTakes().first { it.id == shots[0].id }
        assertTrue(asOwner.prompt.contains(secretStyle)); assertNotNull(asOwner.variation)
        expectCode("template_hidden") { member.templateDraft(shots[0].id) }
        assertTrue(member.favouriteTemplate(mirror.id, true).favourite)
        assertEquals(listOf(mirror.id), member.listTemplates("favourites").map { it.id })
        assertEquals(1, member.template(mirror.id).uses)
        expectCode("owner_only") { member.patchTemplate(mirror.id, PatchTemplateRequest(name = "mine")) }
        // Save as template from the member's own plain shoot: private by default, the pool editable
        val plain = member.shoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, "Bedroom mirror", "", count = 1)).first()
        // ---- the server builds the prompt (2026-11-05): preview = what is sent; reference images; the owner's prompt library
        val refReq = ShootRequest(SampleData.DEMO, SampleData.GREEN, "Bedroom mirror", count = 1, direction = "laughing",
            refs = listOf(studio.muse.app.data.ShootRef(studio.muse.app.data.ImageRef.asset("c_front"), listOf("pose", "scene"))))
        val pv = member.previewShoot(refReq)
        val idx = pv.refs.single().index!!
        assertTrue(pv.text, pv.text.contains("Copy the pose and framing from image $idx. Use the place and background from image $idx. Do not take the face, body, hair or clothes from image $idx."))
        assertEquals(listOf("identity", "outfit", "scene", "camera", "light", "direction", "reference", "style", "negative", "seed"), pv.slots.map { it.layer })
        assertTrue(pv.estimate > 0 && pv.estimateLabel.startsWith("about $"))
        assertEquals(listOf("identity", "outfit", "direction", "reference", "seed"), member.previewShoot(refReq.copy(presets = false)).slots.map { it.layer })
        val refShot = member.shoot(refReq).first()
        assertTrue(refShot.prompt.contains("from image $idx."))
        assertEquals(listOf("pose", "scene"), refShot.refs?.single()?.guides)
        expectCode("bad_request") { member.previewShoot(refReq.copy(refs = List(4) { refReq.refs!!.first() })) }
        // Template shoots take references too: the viewer's view of the template plus their lines.
        val tplPv = member.previewShoot(ShootRequest(SampleData.DEMO, SampleData.GREEN, templateId = mirror.id, shuffleSeed = 5, refs = refReq.refs))
        assertTrue(tplPv.slots.map { it.layer }.toString(), tplPv.slots.any { it.layer == "reference" } && tplPv.refs.single().index != null)
        expectCode("owner_only") { member.prompts() }
        expectCode("owner_only") { member.savePrompt("style.house", "x") }
        val lib = owner.prompts()
        assertTrue("${lib.prompts.size} prompts", lib.prompts.size >= 52)
        assertEquals(lib.prompts.size, lib.prompts.map { it.key }.toSet().size)
        assertEquals("References", lib.groups[1].label)
        expectCode("prompt_invalid") { owner.savePrompt("refs.pose", "no number") }
        assertTrue(owner.savePrompt("style.house", "HOUSE X").overridden)
        assertTrue(member.previewShoot(refReq).text.contains("Style: HOUSE X."))
        assertTrue(owner.previewPrompt(studio.muse.app.data.PromptPreviewRequest("refs.look", "Look like image {refIndex}.")).text.startsWith("Look like image "))
        assertEquals(false, owner.resetPrompt("style.house").overridden)
        val draft = member.templateDraft(plain.id)
        assertTrue(draft.variationPool.getValue("pose").isNotEmpty())
        val mine = member.createTemplate(CreateTemplateRequest("My mirror", listOf("Selfie"), variationPool = draft.variationPool + ("expression" to listOf("soft smile")), fromShotId = plain.id))
        assertEquals("private", mine.visibility); assertEquals(listOf("soft smile"), mine.variationPool!!["expression"])
        assertTrue(owner.listTemplates().none { it.id == mine.id })
        assertEquals("public", member.patchTemplate(mine.id, PatchTemplateRequest(visibility = "public")).visibility)
        owner.listTemplates().first { it.id == mine.id }.let { assertNull(it.layers); assertEquals(false, it.isOwner) }
        member.deleteTemplate(mine.id)
        expectCode("not_found") { member.template(mine.id) }

        // ---- take back what's left → insufficient_tokens
        owner.reclaim(ReclaimRequest(me.id, member.wallet().tokens)) // after the template shoots too
        assertEquals(0L, member.wallet().tokens)
        val broke = expectCode("insufficient_tokens") { member.createJob(req) }
        assertEquals(ErrorText.NOT_ENOUGH_CREDIT, ErrorText.of(broke))

        // ---- uploads: multipart (storage local) and presign → PUT → confirm, with progress
        val img = member.uploadImage("a.jpg", ByteArray(200_000) { 7 }, "image/jpeg")
        assertTrue(img.url!!.startsWith(base.trimEnd('/')))
        val progress = mutableListOf<Float>()
        val presigned = HttpMuseApi(base, UploadMode.PRESIGNED).apply { setToken(signed.token) }
        val img2 = presigned.uploadImage("b.jpg", ByteArray(300_000) { 3 }, "image/jpeg") { progress += it }
        assertTrue(img2.url!!.contains("/uploads/u/"))
        assertEquals(1f, progress.last())
        assertTrue(progress.size > 3)
        val clip2 = presigned.uploadClip(SampleData.sampleMeta.copy(name = "mine.mp4"), ByteArray(150_000) { 1 }, "video/mp4")
        assertTrue(clip2.ok)

        // ---- studio settings and the image engine
        assertEquals("owner", owner.patchStudioSettings(StudioSettingsPatch(overheadPayer = "owner", maxGpus = 2)).overheadPayer)
        expectCode("owner_only") { member.patchStudioSettings(StudioSettingsPatch(maxGpus = 9)) }
        assertEquals("simulated", owner.imageEngine().provider)
        assertTrue(owner.listInvites().any { it.id == inv.id && it.usedAt != null })

        // ---- switching the member off ends their session; signing out ends the owner's
        assertTrue(owner.patchMember(me.id, MemberPatch(disabled = true)).disabled)
        val off = try { member.me(); error("should be signed out") } catch (e: ApiException) { e }
        assertTrue(off.code, off.code in ErrorText.SIGN_OUT_CODES)
        expectCode("account_disabled") { HttpMuseApi(base).signIn(SignInRequest(email, "pw-123456")) }
        owner.signOut()
        expectCode("unauthorized") { owner.me() }
    }

    /** Keep add-on engine ready (was Keep GPU warm) against server/api: owner only (simulated GPU: ready at once). */
    @Test fun keepGpuWarm(): Unit = runBlocking {
        val owner = HttpMuseApi(base)
        owner.setToken(owner.signIn(SignInRequest("jen@studio.com", "x")).token)
        val off = owner.warmGpu()
        assertEquals("off", off.state); assertTrue(off.allowed); assertEquals(20, off.idleMinutes); assertEquals(120, off.maxMinutes)
        assertEquals(20, owner.studioSettings().engines!!.keepReady.idleMinutes)
        val events = async { withTimeout(20_000) { owner.events().first { it.type == "gpu" && it.gpu?.state == "warm" } } }
        delay(300)
        val on = owner.setWarmGpu(studio.muse.app.data.WarmRequest(on = true))
        assertEquals("warm", on.state); assertTrue(on.on); assertNotNull(on.startedAt); assertEquals("idle", on.autoOffReason); assertTrue(on.canExtend)
        assertEquals("state", events.await().event)
        assertEquals(on.startedAt, owner.setWarmGpu(studio.muse.app.data.WarmRequest(on = true)).startedAt) // idempotent
        assertTrue(owner.setWarmGpu(studio.muse.app.data.WarmRequest(extend = true)).canExtend) // idle reset, cap untouched
        val done = owner.setWarmGpu(studio.muse.app.data.WarmRequest(on = false))
        assertEquals("off", done.state); assertEquals("user", done.lastOff?.reason)
        expectCode("not_warm") { owner.setWarmGpu(studio.muse.app.data.WarmRequest(extend = true)) }
        // Owner only: a member is refused.
        val inv = owner.createInvite(CreateInviteRequest(email = "warm@test.local"))
        val member = HttpMuseApi(base)
        member.setToken(member.signUp(SignUpRequest("", "warm@test.local", "pw-123456", true, true, inv.code)).token)
        expectCode("owner_only") { member.warmGpu() }
        val e = expectCode("owner_only") { member.setWarmGpu(studio.muse.app.data.WarmRequest(on = true)) }
        assertEquals("Only the studio owner can do that.", ErrorText.of(e))
        // Members' settings carry no engines, GPUs or Keep ready rules.
        val ms = member.studioSettings()
        assertNull(ms.engines)
        assertTrue(ms.features.video!!.addons.any { it.id == "upscale" && it.comingSoon && !it.available })
    }

    /** The owner-loaded studio balance and pass-through photo prices (plans/api.md "App clean-up" §3–4). */
    @Test fun studioBalanceAndPhotoPrices(): Unit = runBlocking {
        val owner = HttpMuseApi(base)
        owner.setToken(owner.signIn(SignInRequest("jen@studio.com", "x")).token)
        val sb0 = owner.studioBalance()
        val sb1 = owner.addTopUp(studio.muse.app.data.AddTopUpRequest(20.0, "card"))
        assertEquals(sb0.toppedUpUsd + 20.0, sb1.toppedUpUsd, 1e-9)
        assertEquals(sb0.balanceUsd + 20.0, sb1.balanceUsd, 1e-9)
        assertEquals("card", sb1.topUps.first().note)
        assertEquals(false, sb1.needsFirstTopUp)
        val b = owner.balance()
        assertEquals("studio", b.balanceSource); assertEquals(sb1.balanceUsd, b.studioBalance!!, 1e-9)
        val photo = owner.studioSettings().features.photo!!
        assertEquals(studio.muse.core.PhotoPrices(), photo.prices)
        assertEquals("about \$0.46", studio.muse.core.PhotoPricing.about(studio.muse.core.PhotoPricing.shoot(photo.prices)))
        val owners = owner.studioSettings().engines!!.list.map { it.id }
        assertEquals(listOf("replicate", "runpod"), owners)
        expectCode("upscale_unavailable") { owner.upscale("t_j1", "2k") }
    }

    /** Model tools (plans/api.md "Model tools") on the real server with simulated images: Enhance, Dress up, review, apply, archive. */
    @Test fun modelTools(): Unit = runBlocking {
        val owner = HttpMuseApi(base)
        owner.setToken(owner.signIn(SignInRequest("jen@studio.com", "x")).token)
        val demo = owner.listModels().first { it.id == SampleData.DEMO }
        assertEquals(studio.muse.app.data.Sheet.KEYS, demo.slots.map { it.key })
        val tools = owner.studioSettings().features.tools!!
        assertEquals(listOf("Option A", "Option B", "Both"), tools.dressUp.options.map { it.label })
        val est = owner.enhanceEstimate(demo.id, studio.muse.app.data.EnhanceRequest())
        assertEquals(7, est.images); assertEquals("7 images · about \$0.30", est.label)
        var run = owner.startEnhance(demo.id, studio.muse.app.data.EnhanceRequest(upscale = "off"))
        val deadline = System.currentTimeMillis() + 20_000
        while (run.state == "running") { check(System.currentTimeMillis() < deadline); kotlinx.coroutines.delay(100); run = owner.toolRun(run.id) }
        assertEquals("review", run.state)
        run = owner.decideTool(run.id, "face", studio.muse.app.data.DecideRequest("keep"))
        val applied = owner.applyTool(run.id)
        assertEquals("applied", applied.run.state)
        assertEquals(1, owner.sheetVersions(demo.id).size)
        var dress = owner.startDressUp(demo.id, studio.muse.app.data.DressUpRequest(studio.muse.app.data.ImageRef.asset("c_front"), "Silver night", "both"))
        while (dress.state == "running") { check(System.currentTimeMillis() < deadline + 20_000); kotlinx.coroutines.delay(100); dress = owner.toolRun(dress.id) }
        assertEquals(listOf("a", "b"), dress.engines)
        owner.pickTool(dress.id, "b")
        val outfit = owner.applyTool(dress.id).outfit!!
        assertEquals("dressup", outfit.mode); assertEquals(3, outfit.faces!!.size)
        // Image models: the owner sees six steps (simulated server: no catalog).
        assertEquals(studio.muse.app.data.Sheet.STEPS, owner.imageModels().steps.map { it.step })
        // Archive: hidden from the list, listed as archived, back again.
        assertTrue(owner.archiveModel(SampleData.NOOR, true).archived)
        assertTrue(owner.listModels().none { it.id == SampleData.NOOR })
        assertEquals(listOf(SampleData.NOOR), owner.archivedModels().map { it.id })
        expectCode("model_archived") { owner.startEnhance(SampleData.NOOR, studio.muse.app.data.EnhanceRequest()) }
        owner.archiveModel(SampleData.NOOR, false)
        assertTrue(owner.listModels().any { it.id == SampleData.NOOR })
    }
}
