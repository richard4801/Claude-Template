package studio.muse.app.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Read-request sharing for [HttpMuseApi] (performance, plans/perf-audit.md):
 * - **Coalescing:** identical GETs that are in flight at the same moment share one request (a reconnect catch-up racing a
 *   "Try again" tap, two screens asking for the same catalog).
 * - **Short-lived cache:** catalogs and rarely-changing lists ([get] with `ttlMs > 0`) answer from memory for a while. Writes
 *   and the matching live events call [invalidate]; a (re)connect of the live stream calls [clear], so a catch-up after a
 *   drop always refetches.
 *
 * Keys carry the session token, so a sign-in or account switch never sees another session's answers.
 */
class RequestCache(private val now: () -> Long = System::currentTimeMillis) {
    private class Entry(val value: Any?, val at: Long, val ttl: Long)

    private val lock = Any()
    private val inflight = HashMap<String, CompletableDeferred<Any?>>()
    private val cached = HashMap<String, Entry>()
    /** Bumped by [clear] / [invalidate]: an answer that started before them isn't stored. */
    private var generation = 0L

    suspend fun <T> get(key: String, ttlMs: Long = 0, block: suspend () -> T): T {
        while (true) {
            var owner = false
            var gen = 0L
            val shared: CompletableDeferred<Any?> = synchronized(lock) {
                if (ttlMs > 0) cached[key]?.let { e ->
                    @Suppress("UNCHECKED_CAST")
                    if (now() - e.at < e.ttl) return e.value as T else cached.remove(key)
                }
                gen = generation
                inflight[key] ?: CompletableDeferred<Any?>().also { inflight[key] = it; owner = true }
            }
            if (owner) {
                try {
                    val v = block()
                    synchronized(lock) { if (ttlMs > 0 && gen == generation) cached[key] = Entry(v, now(), ttlMs) }
                    shared.complete(v)
                    return v
                } catch (e: Throwable) {
                    shared.completeExceptionally(e)
                    throw e
                } finally {
                    synchronized(lock) { if (inflight[key] === shared) inflight.remove(key) }
                }
            }
            try {
                @Suppress("UNCHECKED_CAST")
                return shared.await() as T
            } catch (e: CancellationException) {
                // The caller that ran the request was cancelled (it left its screen), not us: ask again ourselves.
                currentCoroutineContext().ensureActive()
            }
        }
    }

    /** Drops the cached answers whose key starts with any of [prefixes] (a write or a live event changed them). */
    fun invalidate(vararg prefixes: String) = synchronized(lock) {
        generation++
        cached.keys.removeAll { k -> prefixes.any { k.startsWith(it) } }
    }

    fun clear() = synchronized(lock) { generation++; cached.clear() }
}
