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

/** Fetches a TikTok, Instagram or YouTube link on the phone (Recreate's paste and Share → MUSE). */
interface LinkFetcher {
    suspend fun fetch(url: String, strict: Boolean, dir: File): DeviceFetch

    companion object {
        /** The server's caps (plans/api.md "Recreate this edit · links"): 60 s and RECREATE_LINK_MAX_MB (80). */
        const val MAX_SEC = 60
        const val MAX_BYTES = 80L * 1024 * 1024
    }
}

/**
 * yt-dlp on the phone, through Chaquopy (app/src/main/python/muse_fetch.py): signed out (no cookies), one video, the
 * server's caps, public only when the owner's "Strict link rules" is on. Platforms block the studio server's address,
 * not a phone's. Python ships for 64-bit ARM only; elsewhere this fails and the caller falls back to the server.
 */
class PhoneLinkFetcher(context: Context) : LinkFetcher {
    private val app = context.applicationContext

    override suspend fun fetch(url: String, strict: Boolean, dir: File): DeviceFetch = withContext(Dispatchers.IO) {
        try {
            if (!com.chaquo.python.Python.isStarted()) com.chaquo.python.Python.start(com.chaquo.python.android.AndroidPlatform(app))
            dir.mkdirs()
            val out = com.chaquo.python.Python.getInstance().getModule("muse_fetch")
                .callAttr("fetch", url, dir.absolutePath, LinkFetcher.MAX_SEC, LinkFetcher.MAX_BYTES, strict).toString()
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
