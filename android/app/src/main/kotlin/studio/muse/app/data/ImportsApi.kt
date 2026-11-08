package studio.muse.app.data

// WS7: "Import a video from a link" (owner-approved 2026-11-08), against WS12's contract (provisional until it lands):
//   POST /v1/links/check {url, purpose: "import"} · GET /v1/links/settings · upload + POST /v1/imports {uploadId, sourceUrl, name?}.
// The flow itself is platform/LinkPipeline.kt (shared with Recreate). The demo studio's version is FakeImportsApi.
// MuseApi exposes it as `api.imports`.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

@Serializable
data class LinkCheckRequest(val url: String, val purpose: String = "import")

/** POST /v1/links/check: may the phone fetch this link (its normalized form), or is it already imported ([cached])? */
@Serializable
data class LinkCheckResult(
    val allowed: Boolean = false,
    val url: String = "",
    val platform: String? = null,
    val purpose: String? = null,
    val code: String? = null,
    val reason: String? = null,
    val cached: ImportedVideo? = null,
)

/** A purpose's own caps (Recreate references: 60 s, 80 MB). */
@Serializable
data class LinkCaps(val maxSec: Int = 60, val maxMb: Int = 80)

/**
 * GET /v1/links/settings: the owner's link rules, which the phone applies to its own fetch too. The top-level caps are
 * for imports (30 s, 150 MB); [reference] are Recreate's. The toggle is PATCH /v1/recreate/settings {strictLinks}.
 */
@Serializable
data class LinkSettings(
    val strictLinks: Boolean = true,
    /** The platforms links may come from, or ["any"]. */
    val platforms: List<String> = emptyList(),
    /** "refuse" | "allow": TikTok videos whose owner turned downloads off. */
    val tiktokDownloadsOff: String = "refuse",
    val maxSec: Int = 30,
    val maxMb: Int = 150,
    /** The server can fetch links itself (the fallback). */
    val serverFetch: Boolean = true,
    val cookies: Boolean = false,
    val canEdit: Boolean = false,
    val reference: LinkCaps = LinkCaps(),
)

/** POST /v1/imports from the phone's upload (PUT, no confirm). */
@Serializable
data class ImportUpload(val uploadId: String, val sourceUrl: String? = null, val name: String? = null)

/** POST /v1/imports, the server's own fetch (synchronous, about 2 min): codes link_private, link_downloads_off, link_blocked. */
@Serializable
data class ImportFetch(val url: String, val name: String? = null)

@Serializable
data class ImportRename(val name: String)

/**
 * An imported video (WS12): it IS a clip. [id] is the clip id for Character swap / Recast; [videoKey] is a Suite
 * reference video ({key}); [uploadId] is the editor's media. Its first frame is [posterUrl].
 */
@Serializable
data class ImportedVideo(
    val id: String,
    val name: String = "",
    val durationSec: Double = 0.0,
    val width: Int = 0,
    val height: Int = 0,
    val fps: Int = 30,
    val checks: List<ClipCheck> = emptyList(),
    val audio: ClipAudio? = null,
    val source: String = "import",
    val sourceUrl: String? = null,
    val platform: String? = null,
    val bytes: Long = 0,
    val posterUrl: String? = null,
    val videoUrl: String? = null,
    val videoKey: String? = null,
    val uploadId: String? = null,
    val createdBy: String? = null,
    val createdAt: Long = 0,
    /** True when links/check found it already imported (no download). */
    val cached: Boolean = false,
    /** The demo's bundled frame (no poster URL in demo mode). */
    val demoThumb: ImageRef? = null,
) {
    /** The clip id for Character swap / Recast. */
    val clipId: String get() = id
    val thumb: ImageRef? get() = demoThumb ?: posterUrl?.let { ImageRef(url = it) }

    /** The same video as a clip (Swap's source, the composer's clip card). */
    fun asClip() = Clip(id, name, durationSec, width.takeIf { it > 0 } ?: 1080, height.takeIf { it > 0 } ?: 1920, fps, checks, thumb, audio)
}

@Serializable
data class ImportedVideos(val imports: List<ImportedVideo> = emptyList())

interface ImportsApi {
    suspend fun check(url: String): LinkCheckResult
    suspend fun settings(): LinkSettings
    /** From the phone's clip upload. 400 too_long, 422 link_too_big / link_unsupported, 409 upload_used / upload_missing. */
    suspend fun fromUpload(req: ImportUpload): ImportedVideo
    /** The server fetches the link itself. */
    suspend fun fromLink(req: ImportFetch): ImportedVideo
    /** Members: their own; the owner: the studio's. */
    suspend fun list(): List<ImportedVideo>
    suspend fun rename(id: String, name: String): ImportedVideo
    /** 409 import_in_use. */
    suspend fun delete(id: String)

    /** Servers without imports (the caller says "This studio server can't import links yet"). */
    object Unsupported : ImportsApi {
        private fun no(): Nothing = throw ApiException("unsupported", "This studio server can't import links yet")
        override suspend fun check(url: String) = no()
        override suspend fun settings() = no()
        override suspend fun fromUpload(req: ImportUpload) = no()
        override suspend fun fromLink(req: ImportFetch) = no()
        override suspend fun list() = no()
        override suspend fun rename(id: String, name: String) = no()
        override suspend fun delete(id: String) = no()
    }
}

class HttpImportsApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ImportsApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val jsonType = "application/json".toMediaType()

    private suspend fun text(method: String, path: String, body: String?): String = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody(jsonType) ?: if (method == "POST" || method == "PATCH") "{}".toRequestBody(jsonType) else null
        // The server's own fetch takes up to about 2 minutes.
        val c = if (path == "v1/imports" && method == "POST") client.newBuilder().readTimeout(150, java.util.concurrent.TimeUnit.SECONDS).build() else client
        val res = try { c.newCall(Request.Builder().url(base + path).method(method, rb).build()).execute() }
            catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val t = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { json.decodeFromString(ErrorBody.serializer(), t) }.getOrNull()
                throw ApiException(err?.code ?: if (r.code == 404) "unsupported" else "http_${r.code}", err?.error ?: if (r.code == 404) "This studio server can't import links yet" else "Server error ${r.code}")
            }
            t
        }
    }

    private suspend fun <T> send(method: String, path: String, body: String?, out: KSerializer<T>): T = text(method, path, body).let { t ->
        try { json.decodeFromString(out, t) } catch (e: kotlinx.serialization.SerializationException) {
            throw ApiException("bad_response", "The server sent something this app version can't read")
        }
    }

    override suspend fun check(url: String) = send("POST", "v1/links/check", json.encodeToString(LinkCheckRequest.serializer(), LinkCheckRequest(url)), LinkCheckResult.serializer())
    override suspend fun settings() = send("GET", "v1/links/settings", null, LinkSettings.serializer())
    override suspend fun fromUpload(req: ImportUpload) = send("POST", "v1/imports", json.encodeToString(ImportUpload.serializer(), req), ImportedVideo.serializer())
    override suspend fun fromLink(req: ImportFetch) = send("POST", "v1/imports", json.encodeToString(ImportFetch.serializer(), req), ImportedVideo.serializer())
    override suspend fun list(): List<ImportedVideo> {
        // A bare list or {imports: [...]}: both read.
        val t = text("GET", "v1/imports", null)
        return runCatching { json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(ImportedVideo.serializer()), t) }
            .getOrElse { runCatching { json.decodeFromString(ImportedVideos.serializer(), t).imports }.getOrElse { throw ApiException("bad_response", "The server sent something this app version can't read") } }
    }
    override suspend fun rename(id: String, name: String) = send("PATCH", "v1/imports/$id", json.encodeToString(ImportRename.serializer(), ImportRename(name)), ImportedVideo.serializer())
    override suspend fun delete(id: String) { text("DELETE", "v1/imports/$id", null) }
}

/**
 * The demo studio's imports: TikTok, Instagram and YouTube links are allowed (others refused while Strict link rules is
 * on), a link imported before comes back as it is, and a link with "blocked" in it can't be fetched by the server.
 */
class FakeImportsApi(private val now: () -> Long) : ImportsApi {
    var strict = true
    private val made = mutableListOf<ImportedVideo>()
    private fun platformOf(url: String) = when {
        "tiktok.com" in url -> "tiktok"; "instagram.com" in url -> "instagram"; "youtu" in url -> "youtube"; else -> null
    }

    override suspend fun check(url: String): LinkCheckResult {
        val u = url.trim()
        if (!u.startsWith("http")) return LinkCheckResult(false, u, code = "link_invalid", reason = "Paste a link that starts with https://")
        val p = platformOf(u)
        if (p == null && strict) return LinkCheckResult(false, u, code = "link_unsupported", reason = "Paste a TikTok, Instagram Reel or YouTube link")
        return LinkCheckResult(true, u, p ?: "other", "import", cached = made.firstOrNull { it.sourceUrl == u }?.copy(cached = true))
    }

    override suspend fun settings() = LinkSettings(strictLinks = strict, platforms = if (strict) listOf("tiktok", "instagram", "youtube") else listOf("any"),
        tiktokDownloadsOff = if (strict) "refuse" else "allow")

    private fun make(url: String?, name: String?, uploadId: String?): ImportedVideo {
        val n = made.size + 1
        return ImportedVideo("imp_$n", name?.ifBlank { null } ?: "Imported video $n", 9.4, 1080, 1920, 30, sourceUrl = url, platform = url?.let(::platformOf),
            bytes = 4_200_000, uploadId = uploadId, createdAt = now(), demoThumb = ImageRef.asset("g_front")).also { made += it }
    }

    override suspend fun fromUpload(req: ImportUpload) = make(req.sourceUrl, req.name, req.uploadId)
    override suspend fun fromLink(req: ImportFetch): ImportedVideo {
        if ("blocked" in req.url) throw ApiException("link_blocked", "The site blocked the studio server. Save the video to your phone and pick it instead.")
        return make(req.url, req.name, null)
    }
    override suspend fun list() = made.toList()
    override suspend fun rename(id: String, name: String): ImportedVideo {
        val i = made.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: throw ApiException("not_found", "That import was deleted")
        made[i] = made[i].copy(name = name.trim()); return made[i]
    }
    override suspend fun delete(id: String) { made.removeAll { it.id == id } }
}

/**
 * Import a video from a link (WS7): the shared link flow ([studio.muse.app.platform.fetchLink]) with the import steps.
 * The phone fetches it under the server's rules and uploads it (purpose "import"); else the server fetches it.
 */
suspend fun importFromLink(
    api: MuseApi, fetcher: studio.muse.app.platform.LinkFetcher?, url: String, name: String?, cacheDir: java.io.File,
    onUploaded: (String) -> Unit = {},
    onStep: (Float, String) -> Unit = { _, _ -> },
): ImportedVideo = studio.muse.app.platform.fetchLink(
    url, name, fetcher, cacheDir,
    studio.muse.app.platform.LinkSteps(
        check = { u -> api.imports.check(u).let { c -> studio.muse.app.platform.LinkCheck(c.allowed, c.url.ifBlank { u }, c.platform, c.cached, c.code, c.reason) } },
        // The import caps (30 s, 150 MB), not Recreate's.
        rules = { api.imports.settings().let { s -> studio.muse.app.platform.LinkRules(s.strictLinks, s.tiktokDownloadsOff == "refuse", s.maxSec, s.maxMb) } },
        upload = { f, p -> api.uploadClipFile(f, p) },
        finish = { id, u, title -> api.imports.fromUpload(ImportUpload(id, u, title)) },
        serverFetch = { u, title -> api.imports.fromLink(ImportFetch(u, title)) },
    ),
    onUploaded, onStep,
)
