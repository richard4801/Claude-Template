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
    val code: String? = null,
    val reason: String? = null,
    val cached: ImportedVideo? = null,
)

/** GET /v1/links/settings: the owner's link rules, which the phone applies to its own fetch too. */
@Serializable
data class LinkSettings(
    val strictLinks: Boolean = true,
    /** "refuse" | "allow": TikTok videos whose owner turned downloads off. */
    val tiktokDownloadsOff: String = "refuse",
    val maxSec: Int = 60,
    val maxMb: Int = 80,
    val platforms: List<String> = emptyList(),
)

/** POST /v1/imports. [uploadId] null = the server fetches [sourceUrl] itself (the phone couldn't). */
@Serializable
data class ImportRequest(val uploadId: String? = null, val sourceUrl: String, val name: String? = null)

/** An imported video in the studio's library: usable as Swap's source ([clipId]) and in Edit. */
@Serializable
data class ImportedVideo(
    val id: String,
    val name: String = "",
    val sourceUrl: String? = null,
    val platform: String? = null,
    val durationSec: Double = 0.0,
    val width: Int? = null,
    val height: Int? = null,
    val thumb: ImageRef? = null,
    val videoUrl: String? = null,
    /** The same video as a source clip (Character swap / Recast take a clip). */
    val clipId: String? = null,
    val createdAt: Long = 0,
)

@Serializable
data class ImportedVideos(val imports: List<ImportedVideo> = emptyList())

interface ImportsApi {
    suspend fun check(url: String): LinkCheckResult
    suspend fun settings(): LinkSettings
    suspend fun create(req: ImportRequest): ImportedVideo
    suspend fun list(): List<ImportedVideo>

    /** Servers without imports (the caller says "This studio server can't import links yet"). */
    object Unsupported : ImportsApi {
        private fun no(): Nothing = throw ApiException("unsupported", "This studio server can't import links yet")
        override suspend fun check(url: String) = no()
        override suspend fun settings() = no()
        override suspend fun create(req: ImportRequest) = no()
        override suspend fun list() = no()
    }
}

class HttpImportsApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ImportsApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val jsonType = "application/json".toMediaType()

    private suspend fun <T> send(method: String, path: String, body: String?, out: KSerializer<T>): T = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody(jsonType) ?: if (method == "POST") "{}".toRequestBody(jsonType) else null
        val res = try { client.newCall(Request.Builder().url(base + path).method(method, rb).build()).execute() }
            catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val text = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { json.decodeFromString(ErrorBody.serializer(), text) }.getOrNull()
                throw ApiException(err?.code ?: if (r.code == 404) "unsupported" else "http_${r.code}", err?.error ?: if (r.code == 404) "This studio server can't import links yet" else "Server error ${r.code}")
            }
            try { json.decodeFromString(out, text) } catch (e: kotlinx.serialization.SerializationException) {
                throw ApiException("bad_response", "The server sent something this app version can't read")
            }
        }
    }

    override suspend fun check(url: String) = send("POST", "v1/links/check", json.encodeToString(LinkCheckRequest.serializer(), LinkCheckRequest(url)), LinkCheckResult.serializer())
    override suspend fun settings() = send("GET", "v1/links/settings", null, LinkSettings.serializer())
    override suspend fun create(req: ImportRequest) = send("POST", "v1/imports", json.encodeToString(ImportRequest.serializer(), req), ImportedVideo.serializer())
    override suspend fun list() = send("GET", "v1/imports", null, ImportedVideos.serializer()).imports
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
        return LinkCheckResult(true, u, p ?: "other", cached = made.firstOrNull { it.sourceUrl == u })
    }

    override suspend fun settings() = LinkSettings(strictLinks = strict, tiktokDownloadsOff = if (strict) "refuse" else "allow")

    override suspend fun create(req: ImportRequest): ImportedVideo {
        if (req.uploadId == null && "blocked" in req.sourceUrl) throw ApiException("fetch_failed", "The studio server couldn't get this video. Save it to your phone and pick it instead.")
        val n = made.size + 1
        val v = ImportedVideo("imp_$n", req.name?.ifBlank { null } ?: "Imported video $n", req.sourceUrl, platformOf(req.sourceUrl), 9.4, 1080, 1920,
            ImageRef.asset("g_front"), null, clipId = SampleData.SAMPLE_CLIP, createdAt = now())
        made += v
        return v
    }

    override suspend fun list() = made.toList()
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
        rules = { api.imports.settings().let { s -> studio.muse.app.platform.LinkRules(s.strictLinks, s.tiktokDownloadsOff == "refuse", s.maxSec, s.maxMb) } },
        upload = { f, p -> api.uploadEditorFile(f, "video/mp4", "import", p) },
        finish = { id, u, title -> api.imports.create(ImportRequest(id, u, title)) },
        serverFetch = { u, title -> api.imports.create(ImportRequest(null, u, title)) },
    ),
    onUploaded, onStep,
)
