package studio.muse.app.platform

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/** What the phone's own fetch of a shared link gave. */
sealed interface DeviceFetch {
    /** The video, downloaded into the app's cache. */
    data class Got(val file: File, val title: String, val durationSec: Double) : DeviceFetch
    /** The link breaks a rule (too long, too big, not public): said as is, with no other attempt. */
    data class Refused(val code: String, val message: String) : DeviceFetch
    /** The phone couldn't get it (blocked, unsupported, offline): the server's fetch is tried next. */
    data class Failed(val message: String) : DeviceFetch
}

/**
 * The server's link rules (GET /v1/recreate/settings) for one link: [strict] public videos only, [tiktokRefuse] refuse
 * TikTok's "downloads off", the caps, and the link's [platform] from the server's check.
 */
data class LinkRules(val strict: Boolean = true, val tiktokRefuse: Boolean = true, val maxSec: Int = 60, val maxMb: Int = 80, val platform: String? = null) {
    val maxBytes: Long get() = maxMb * 1024L * 1024L
}

/** Fetches a shared link on the phone (Recreate's paste and Share → MUSE). */
interface LinkFetcher {
    suspend fun fetch(url: String, rules: LinkRules, dir: File): DeviceFetch
}

/**
 * yt-dlp on the phone, through Chaquopy (app/src/main/python/muse_fetch.py): signed out (no cookies), one video, the
 * server's caps, public only and TikTok's "downloads off" refused while the owner's "Strict link rules" is on. Platforms block the studio server's address,
 * not a phone's. Python ships for 64-bit ARM only; elsewhere this fails and the caller falls back to the server.
 */
class PhoneLinkFetcher(context: Context) : LinkFetcher {
    private val app = context.applicationContext

    override suspend fun fetch(url: String, rules: LinkRules, dir: File): DeviceFetch = withContext(Dispatchers.IO) {
        try {
            if (!com.chaquo.python.Python.isStarted()) com.chaquo.python.Python.start(com.chaquo.python.android.AndroidPlatform(app))
            dir.mkdirs()
            val out = com.chaquo.python.Python.getInstance().getModule("muse_fetch")
                .callAttr("fetch", url, dir.absolutePath, rules.maxSec, rules.maxBytes, rules.strict, rules.tiktokRefuse, rules.platform ?: "").toString()
            parse(out)
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Throwable) {
            DeviceFetch.Failed("Couldn't get this video on the phone")
        }
    }

    companion object {
        /** muse_fetch.fetch's JSON. */
        fun parse(json: String): DeviceFetch {
            val o = kotlinx.serialization.json.Json.parseToJsonElement(json) as kotlinx.serialization.json.JsonObject
            fun s(k: String) = (o[k] as? kotlinx.serialization.json.JsonPrimitive)?.content
            return if (s("ok") == "true") DeviceFetch.Got(File(s("path") ?: ""), s("title").orEmpty(), s("durationSec")?.toDoubleOrNull() ?: 0.0)
            else when (val code = s("code") ?: "fetch_failed") {
                "fetch_failed" -> DeviceFetch.Failed(s("message") ?: "Couldn't get this video on the phone")
                else -> DeviceFetch.Refused(code, s("message") ?: "This link can't be used")
            }
        }
    }
}
