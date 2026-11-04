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
import studio.muse.app.data.SignUpRequest
import java.io.File
import java.net.ServerSocket

/** Contract test: the Android HTTP client against server/mock (skipped when Node isn't installed). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class HttpMuseApiTest {
    private var proc: Process? = null
    private lateinit var api: HttpMuseApi

    @Before fun start() {
        val server = generateSequence(File("").absoluteFile) { it.parentFile }.map { File(it, "server/mock/server.js") }.firstOrNull { it.exists() }
        val node = runCatching { ProcessBuilder("node", "--version").start().waitFor() == 0 }.getOrDefault(false)
        assumeTrue("node + server/mock required", server != null && node)
        val port = ServerSocket(0).use { it.localPort }
        proc = ProcessBuilder("node", server!!.path).apply { environment()["PORT"] = "$port"; environment()["SPEED"] = "2400"; environment()["GEN_MS"] = "50"; redirectErrorStream(true) }.start()
        val reader = proc!!.inputStream.bufferedReader()
        withTimeoutBlocking { while (!reader.readLine().contains("mock server")) Unit }
        api = HttpMuseApi("http://127.0.0.1:$port/")
    }

    private fun withTimeoutBlocking(b: () -> Unit) = runBlocking { withTimeout(10_000) { b() } }

    @After fun stop() { proc?.destroy() }

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
}
