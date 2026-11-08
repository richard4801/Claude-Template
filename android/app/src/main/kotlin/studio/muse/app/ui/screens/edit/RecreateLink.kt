package studio.muse.app.ui.screens.edit

import studio.muse.app.data.ApiException
import studio.muse.app.data.MuseApi
import studio.muse.app.platform.DeviceFetch
import studio.muse.app.platform.LinkFetcher
import studio.muse.app.platform.LinkRules
import studio.muse.core.edit.RecipeReference
import java.io.File

/**
 * A shared link becomes a reference (owner's decision, Release 1 test: platforms block the studio server; plans/api.md
 * "Fetching on the device, and Strict link rules"):
 * 1. the server checks the link (`links/check`): refused → its reason; already a reference → that one, no download;
 * 2. the phone downloads it under the server's rules ([LinkFetcher]) and uploads it with its `sourceUrl`;
 * 3. when the phone can't, the server's own link fetch;
 * 4. when that fails too, the caller offers "Pick the saved video" (the exception's message says why).
 * A rule the link breaks (too long, too big, not public, downloads off) is said straight away, with no other attempt.
 */
suspend fun referenceFromLink(
    api: MuseApi, fetcher: LinkFetcher?, url: String, name: String?, cacheDir: File,
    onStep: (Float, String) -> Unit = { _, _ -> },
): RecipeReference {
    onStep(.02f, "Checking the link")
    val check = api.checkRecreateLink(url)
    if (!check.allowed) throw ApiException(check.code ?: "link_unsupported", check.reason ?: "This link can't be used")
    check.cached?.let { return it }
    if (fetcher != null) {
        val s = runCatching { api.recreateSettings() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }.getOrNull()
        val rules = if (s == null) LinkRules(platform = check.platform)
            else LinkRules(s.strictLinks, s.tiktokDownloadsOff == "refuse", s.maxSec, s.maxMb, check.platform)
        onStep(.03f, "Getting the video from the link")
        when (val got = fetcher.fetch(check.url, rules, File(cacheDir, "links"))) {
            is DeviceFetch.Got -> try {
                val uploadId = api.uploadEditorFile(got.file, "video/mp4") { p -> onStep(.05f + p * .15f, "Uploading the video") }
                val title = name ?: got.title.take(80).ifBlank { null }
                // A server without `sourceUrl` yet refuses the field: the reference is still made, as a file.
                return try { api.createReference(uploadId, title, sourceUrl = url) }
                catch (e: ApiException) { if (e.code == "bad_request" || e.code == "validation") api.createReference(uploadId, title) else throw e }
            } finally { got.file.delete() }
            is DeviceFetch.Refused -> throw ApiException(got.code, got.message)
            is DeviceFetch.Failed -> Unit // the server's fetch next
        }
    }
    onStep(.05f, "Getting the video from the link")
    return api.createReferenceFromLink(url, name)
}
