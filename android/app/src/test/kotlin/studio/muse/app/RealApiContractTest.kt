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
        assertTrue(ow.owner); assertNotNull(ow.availableToSend); assertNotNull(ow.runpodBalance)
        val over = expectCode("over_allocation") { owner.transfer(TransferRequest(me.id, ow.tokensToSend + 1_000)) }
        assertEquals(over.message, ErrorText.of(over)) // the server's own explanation is shown

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
        val req = JobRequest("Dance", SampleData.SIENNA, SampleData.GREEN, clip.id, steps = 10)
        val done = async { withTimeout(20_000) { member.events().first { it.job?.done == true } } }
        delay(500)
        val job = member.createJob(req)
        assertEquals(job.id, done.await().job!!.id)
        val after = withTimeout(5_000) { var w = member.wallet(); while (w.heldTokens > 0) { delay(100); w = member.wallet() }; w }
        assertTrue("charged: ${after.tokens}", after.tokens in 1..440)
        assertTrue(after.todayUsd > 0.5)
        val take = member.listTakes().first { it.jobId == job.id }
        assertNull(take.videoUrl) // simulated GPU: no video, the app keeps the still

        // ---- take back what's left → insufficient_tokens
        owner.reclaim(ReclaimRequest(me.id, after.tokens))
        assertEquals(0L, member.wallet().tokens)
        val broke = expectCode("insufficient_tokens") { member.createJob(req) }
        assertEquals(ErrorText.NOT_ENOUGH_TOKENS, ErrorText.of(broke))

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
}
