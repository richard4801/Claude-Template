package studio.muse.app.ui.screens.edit

import studio.muse.app.data.ApiException
import studio.muse.app.data.MuseApi
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
    /** The phone's upload, for Try again after a server restart (made again from it, not uploaded twice). */
    onUploaded: (String) -> Unit = {},
    onStep: (Float, String) -> Unit = { _, _ -> },
): RecipeReference = studio.muse.app.platform.fetchLink(
    // The shared link flow (platform/LinkPipeline.kt, WS7): the same steps, also used by "Import a video from a link".
    url, name, fetcher, cacheDir,
    studio.muse.app.platform.LinkSteps(
        check = { u -> api.checkRecreateLink(u).let { c -> studio.muse.app.platform.LinkCheck(c.allowed, c.url, c.platform, c.cached, c.code, c.reason) } },
        rules = { api.recreateSettings()?.let { s -> LinkRules(s.strictLinks, s.tiktokDownloadsOff == "refuse", s.maxSec, s.maxMb) } },
        upload = { f, p -> api.uploadEditorFile(f, "video/mp4") { x -> p(x) } },
        // A server without `sourceUrl` yet refuses the field: the reference is still made, as a file.
        finish = { uploadId, u, title ->
            try { api.createReference(uploadId, title, sourceUrl = u) }
            catch (e: ApiException) { if (e.code == "bad_request" || e.code == "validation") api.createReference(uploadId, title) else throw e }
        },
        serverFetch = { u, title -> api.createReferenceFromLink(u, title) },
    ),
    onUploaded, onStep,
)
