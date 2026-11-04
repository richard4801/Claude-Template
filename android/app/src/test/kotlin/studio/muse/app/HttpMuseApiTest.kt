package studio.muse.app

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiException
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.JobRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.SignInRequest
import studio.muse.app.data.SignUpRequest
import studio.muse.app.data.CreatePostRequest
import studio.muse.app.data.PatchLoraRequest
import studio.muse.app.data.TopUpRequest
import studio.muse.app.data.UpdateModelRequest
import java.io.File
import java.net.ServerSocket

/** Contract test: the Android HTTP client against server/mock (skipped when Node isn't installed). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HttpMuseApiTest {
    private var proc: Process? = null
    private lateinit var api: HttpMuseApi

    /**
     * Starts server/mock by default. Set MUSE_TEST_SERVER_CMD to run the same tests against another server, e.g. the real
     * API in dev mode (the command runs in android/app):
     *   MUSE_TEST_SERVER_CMD="cd ../../server/api && exec node --import tsx scripts/test-server.ts"
     * The command runs through `sh -c` with PORT, SPEED and GEN_MS set, and must print a line containing "mock server".
     */
    @Before fun start() {
        val port = ServerSocket(0).use { it.localPort }
        val cmd = System.getenv("MUSE_TEST_SERVER_CMD")?.takeIf { it.isNotBlank() }
        val pb = if (cmd != null) {
            ProcessBuilder("sh", "-c", cmd)
        } else {
            val server = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "server/mock/server.js") }.firstOrNull { it.exists() }
            val node = runCatching { ProcessBuilder("node", "--version").start().waitFor() == 0 }.getOrDefault(false)
            assumeTrue("node + server/mock required", server != null && node)
            ProcessBuilder("node", server!!.path)
        }
        proc = pb.apply { environment()["PORT"] = "$port"; environment()["SPEED"] = "2400"; environment()["GEN_MS"] = System.getenv("MUSE_TEST_GEN_MS") ?: "50"; environment()["MUSE_EXIT_ON_STDIN_CLOSE"] = "1"; redirectErrorStream(true) }.start()
        val reader = proc!!.inputStream.bufferedReader()
        val deadline = System.currentTimeMillis() + if (cmd != null) 90_000 else 10_000
        while (true) {
            val line = reader.readLine() ?: error("test server exited before it was ready")
            if (line.contains("mock server")) break
            check(System.currentTimeMillis() < deadline) { "test server not ready in time" }
        }
        Thread { runCatching { reader.forEachLine { } } }.apply { isDaemon = true }.start()
        api = HttpMuseApi("http://127.0.0.1:$port/")
    }


    /** Closing stdin also stops a MUSE_TEST_SERVER_CMD server that runs under a wrapper (sh, npx), see MUSE_EXIT_ON_STDIN_CLOSE. */
    @After fun stop() { proc?.let { p -> runCatching { p.outputStream.close() }; p.destroy() } }

    @Test fun fullRenderOverRestAndSse() = runBlocking {
        try { api.signUp(SignUpRequest("S", "a@b.c", "x", true, false)); error("should fail") } catch (e: ApiException) { assertEquals("attestation_required", e.code) }
        api.setToken(api.signUp(SignUpRequest("Jenne Studio", "a@b.c", "x", true, true)).token)
        assertEquals(listOf("Sienna Vale", "Noor Ellis"), api.listModels().map { it.name })
        assertEquals(6.07, api.balance().balance, 1e-9)
        val clip = api.uploadClip(SampleData.sampleMeta, null)
        assertTrue(clip.ok)
        val job = api.createJob(JobRequest("Dance", SampleData.SIENNA, SampleData.GREEN, clip.id, steps = 10))
        val done = withTimeout(15_000) { api.events().first { it.job?.id == job.id && it.job.done } }
        assertEquals(1, done.takes.size)
        assertTrue(api.listTakes().any { it.jobId == job.id })
        val img = api.uploadImage("a.jpg", ByteArray(10) { 1 }, "image/jpeg")
        assertTrue(img.url!!.startsWith("http://127.0.0.1"))
    }

    /** The LoRA, accounts, posts, queue and model-edit contract (plans/api.md, 2026-11-04) against server/mock. */
    @Test fun loraAccountsPostsQueueAndModelEdit() = runBlocking {
        api.setToken(api.signIn(SignInRequest("jen@studio.com", "x")).token) // the mock accepts anyone; the real API needs a session
        assertEquals(0.13, api.balance().today, 1e-9)
        assertEquals("none", api.lora(SampleData.SIENNA).state)
        api.buildLoraSet(SampleData.SIENNA)
        val review = withTimeout(10_000) { api.events().first { it.lora?.state == "review" } }.lora!!
        assertEquals(30, review.candidates.size)
        assertEquals(27, review.kept)
        try { api.trainLora(SampleData.SIENNA); error("should be blocked") } catch (e: ApiException) { assertEquals("insufficient_balance", e.code) }
        api.topUp(TopUpRequest(25.0))
        assertEquals(26, api.keepCandidate(SampleData.SIENNA, review.candidates.first { it.keep }.id, false).kept)
        assertEquals("training", api.trainLora(SampleData.SIENNA).state)
        val ready = withTimeout(15_000) { api.events().first { it.lora?.state == "ready" } }.lora!!
        assertEquals(1, ready.version)
        assertEquals(false, api.patchLora(SampleData.SIENNA, PatchLoraRequest(use = false)).use)

        val c = api.connectAccount(SampleData.SIENNA, "instagram")
        assertEquals("@sienna.vale", c.account!!.handle)
        assertEquals(listOf("instagram"), api.listAccounts(SampleData.SIENNA).map { it.platform })
        val post = api.createPost(CreatePostRequest(SampleData.SIENNA, "t_j1", listOf("instagram"), "Kick"))
        assertEquals("handoff", post.state)
        assertEquals(false, post.aiLabel); assertEquals(false, post.paidPartnership)
        val later = api.createPost(CreatePostRequest(SampleData.SIENNA, "t_j1", listOf("instagram"), "", `when` = java.time.Instant.now().plusSeconds(3600).toString()))
        assertEquals(listOf(later.id), api.listPosts("scheduled").map { it.id })
        api.deletePost(later.id)
        assertTrue(api.listPosts("scheduled").isEmpty())
        api.disconnectAccount(SampleData.SIENNA, "instagram")
        assertTrue(api.listAccounts(SampleData.SIENNA).isEmpty())

        val clip = api.uploadClip(SampleData.sampleMeta, null)
        val q = api.createJob(JobRequest("Q", SampleData.SIENNA, SampleData.GREEN, clip.id, queue = true))
        assertEquals("queued", q.state)
        assertEquals(listOf(q.id), api.runQueue().map { it.id })
        val m = api.updateModel(SampleData.SIENNA, UpdateModelRequest(personality = "Warm", notes = "No gym content"))
        assertEquals("Warm", m.personality)
        assertEquals("Warm", api.listModels().first { it.id == SampleData.SIENNA }.personality)
        api.deleteModel(SampleData.NOOR)
        assertEquals(listOf("Sienna Vale"), api.listModels().map { it.name })
    }
}
