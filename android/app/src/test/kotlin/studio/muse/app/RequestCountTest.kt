package studio.muse.app

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.HttpMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.MuseRepository
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Performance (plans/perf-audit.md "Android"): counts the HTTP requests the app makes against a local stand-in server with a
 * fixed 40 ms latency, for the launch load and for the screens that fetch their own lists. Home, Gallery and a model's
 * profile read the launch load only (they make no requests of their own), so the launch numbers are theirs.
 */
class RequestCountTest {
    private lateinit var server: ServerSocket
    private val counts = ConcurrentHashMap<String, AtomicInteger>()
    private val latencyMs = 40L
    private lateinit var scope: CoroutineScope

    private fun body(path: String): String? = when (path) {
        "/v1/auth/me" -> """{"id":"u1","email":"o@s.c","role":"owner","studioName":"S"}"""
        "/v1/models" -> """[{"id":"m1","name":"Ava","age":24,"niche":"fashion"},{"id":"m2","name":"Noor","age":26,"niche":"beauty"},{"id":"m3","name":"Lea","age":22,"niche":"fitness"}]"""
        "/v1/outfits", "/v1/jobs", "/v1/takes", "/v1/posts", "/v1/templates", "/v1/suite/locations" -> "[]"
        "/v1/balance" -> """{"balance":10.0,"month":2.0,"role":"owner"}"""
        "/v1/wallet" -> """{"userId":"u1","role":"owner","tokens":1000}"""
        "/v1/gpu/warm" -> """{"state":"off"}"""
        "/v1/settings/studio" -> "{}"
        "/v1/settings/image-engine" -> "{}"
        "/v1/prompts" -> """{"groups":[],"prompts":[]}"""
        "/v1/suite/catalog" -> "{}"
        else -> when {
            path.matches(Regex("/v1/models/[^/]+/lora")) -> """{"modelId":"${path.split('/')[3]}"}"""
            path.matches(Regex("/v1/models/[^/]+/accounts")) -> "[]"
            else -> null
        }
    }

    /** A minimal HTTP/1.1 server (one thread per connection, `Connection: close`): the JDK's HttpServer isn't on the Android test classpath. */
    @Before fun start() {
        server = ServerSocket(0, 64, java.net.InetAddress.getByName("127.0.0.1"))
        val pool = Executors.newCachedThreadPool()
        Thread {
            while (!server.isClosed) {
                val sock = runCatching { server.accept() }.getOrNull() ?: break
                pool.execute {
                    sock.use { s ->
                        val input = s.getInputStream().bufferedReader()
                        val requestLine = input.readLine() ?: return@use
                        while (true) { val h = input.readLine() ?: break; if (h.isEmpty()) break }
                        val (method, target) = requestLine.split(" ").let { it[0] to it[1] }
                        val path = target.substringBefore('?')
                        if (path != "/v1/events") counts.computeIfAbsent("$method $path") { AtomicInteger() }.incrementAndGet()
                        Thread.sleep(latencyMs)
                        val b = if (path == "/v1/events") null else body(path)
                        val bytes = (b ?: """{"error":"no","code":"not_found"}""").toByteArray()
                        val out = s.getOutputStream()
                        out.write("HTTP/1.1 ${if (b == null) "404 Not Found" else "200 OK"}\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        out.write(bytes); out.flush()
                    }
                }
            }
        }.apply { isDaemon = true }.start()
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }

    @After fun stop() { scope.cancel(); server.close() }

    private fun total() = counts.values.sumOf { it.get() }
    private fun count(key: String) = counts[key]?.get() ?: 0
    private fun report(label: String) = println("[requests] $label: total=${total()} " + counts.entries.sortedBy { it.key }.joinToString { "${it.key}=${it.value}" })

    @Test fun launchAndScreenRequests() = runBlocking {
        val url = "http://127.0.0.1:${server.localPort}/"
        val prefs = MemoryPrefs(AppPrefs(useFake = false, serverUrl = url, token = "t", role = "owner"))
        val repo = MuseRepository(scope, prefs, FakeMuseApi(scope, speed = 0.0), { HttpMuseApi(it) })

        // Launch: sign-in check + the studio load (Home, Gallery, Queue and a model's profile all read this).
        val t0 = System.nanoTime()
        withTimeout(20_000) { repo.state.first { it.loaded && it.models.size == 3 } }
        val launchMs = (System.nanoTime() - t0) / 1_000_000
        val launch = total()
        report("launch (${launchMs} ms at ${latencyMs} ms latency)")
        assertEquals("one request per list, no repeats", 0, counts.filterValues { it.get() > 1 }.keys.filterNot { it.contains("/v1/models/") }.size)

        // A catch-up (reconnect) racing a "Try again" tap: the same lists at the same moment.
        counts.clear()
        coroutineScope { listOf(async { repo.refresh() }, async { repo.refresh() }).awaitAll() }
        val racing = total()
        report("two refreshes at once")

        // Templates opened twice, the prompt library then a prompt's editor, the owner's settings twice, the suite catalog x3 at once.
        counts.clear()
        repo.loadTemplates(); repo.loadTemplates()
        repo.prompts(); repo.prompts()
        repo.studioSettings(); repo.imageEngine(); repo.studioSettings(); repo.imageEngine()
        coroutineScope { List(3) { async { runCatching { repo.api.suiteCatalog() } } }.awaitAll() }
        val screens = total()
        report("screens")

        println("[requests] SUMMARY launch=$launch (${launchMs} ms) racingRefresh=$racing screens=$screens")
        assertTrue("launch makes every request once: $launch", launch <= 16)
        assertTrue("two refreshes at once share their requests: $racing", racing <= launch)
        assertTrue("catalogs come from the cache on the second open: $screens", screens <= 5)
        assertEquals(1, count("GET /v1/suite/catalog"))
        assertTrue("the launch load runs its requests side by side: $launchMs ms", launchMs < 16 * latencyMs)
    }
}
