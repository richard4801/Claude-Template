package studio.muse.app

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.RequestCache
import java.util.concurrent.atomic.AtomicInteger

/** The HTTP layer's read sharing (performance): coalescing, the short-lived cache and its invalidation. */
class RequestCacheTest {
    @Test fun identicalReadsInFlightShareOneRequest() = runBlocking {
        val cache = RequestCache()
        val calls = AtomicInteger()
        val results = List(5) { async { cache.get("models|t") { calls.incrementAndGet(); delay(50); "ok" } } }.awaitAll()
        assertEquals(List(5) { "ok" }, results)
        assertEquals(1, calls.get())
        // Not cached (no TTL): the next read asks again.
        cache.get("models|t") { calls.incrementAndGet(); "ok" }
        assertEquals(2, calls.get())
    }

    @Test fun errorsReachEveryWaiter() = runBlocking {
        val cache = RequestCache()
        val calls = AtomicInteger()
        val results = List(3) { async { runCatching { cache.get("x") { calls.incrementAndGet(); delay(30); throw ApiException("offline", "no") } } } }.awaitAll()
        assertTrue(results.all { (it.exceptionOrNull() as? ApiException)?.code == "offline" })
        assertEquals(1, calls.get())
    }

    @Test fun aCancelledOwnerDoesNotCancelTheOthers() = runBlocking {
        val cache = RequestCache()
        val calls = AtomicInteger()
        val gate = CompletableDeferred<Unit>()
        val owner = async { cache.get("k") { calls.incrementAndGet(); gate.await(); "first" } }
        yield(); yield()
        val waiter = async { cache.get("k") { calls.incrementAndGet(); "second" } }
        yield(); yield()
        owner.cancel()
        assertEquals("second", waiter.await())
        assertEquals(2, calls.get())
    }

    @Test fun catalogsAreCachedUntilInvalidatedOrExpired() = runBlocking {
        var now = 1_000L
        val cache = RequestCache { now }
        val calls = AtomicInteger()
        suspend fun read() = cache.get("prompts|t", ttlMs = 60_000) { calls.incrementAndGet() }
        read(); read(); read()
        assertEquals(1, calls.get())
        cache.invalidate("prompts")
        read(); assertEquals(2, calls.get())
        now += 60_001
        read(); assertEquals(3, calls.get())
        cache.clear()
        read(); assertEquals(4, calls.get())
        cache.invalidate("templates") // another catalog: this one stays
        read(); assertEquals(4, calls.get())
    }
}
