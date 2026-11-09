package studio.muse.app.platform

import studio.muse.app.data.ApiException
import java.io.File

/**
 * A video from a link, the one way the app gets one (WS4's Recreate flow made general, WS7 for "Import a video from a
 * link"; plans/api.md "Fetching on the device, and Strict link rules"):
 * 1. the server checks the link: refused → its reason, no other attempt; already known → that, with no download;
 * 2. the phone downloads it under the server's rules ([LinkFetcher]) and uploads it, then [LinkSteps.finish] makes the
 *    thing (a reference, an import) from the upload and the link;
 * 3. when the phone can't (blocked, unsupported, no Python on this CPU), the server's own fetch ([LinkSteps.serverFetch]);
 * 4. when that fails too, the exception says why and the caller offers "Pick the saved video".
 * A rule the link breaks (too long, too big, not public, downloads off) is said straight away. The phone's temp file is
 * always deleted.
 */
class LinkSteps<T>(
    /** The server's check: may the phone fetch it, its normalized URL and platform, or what it already is. */
    val check: suspend (url: String) -> LinkCheck<T>,
    /** The server's rules for the phone's fetch (null = the defaults: strict, 60 s, 80 MB). */
    val rules: suspend () -> LinkRules?,
    /** Uploads the phone's file; returns the upload id. */
    val upload: suspend (file: File, onProgress: (Float) -> Unit) -> String,
    /** Makes the result from the upload, the link and a title (the given name, else the video's own title). */
    val finish: suspend (uploadId: String, url: String, title: String?) -> T,
    /** The server's own fetch of the link, when the phone couldn't get it. */
    val serverFetch: suspend (url: String, title: String?) -> T,
)

/** The server's answer to a link check: [allowed] (else [code] and [reason]), the normalized [url], the [platform], and [known] when there's nothing to fetch. */
data class LinkCheck<T>(
    val allowed: Boolean,
    val url: String,
    val platform: String? = null,
    val known: T? = null,
    val code: String? = null,
    val reason: String? = null,
)

/**
 * Runs [steps] for [url]. [onStep] gets the progress (0–1) and the line to show: "Checking the link", "Getting the video
 * from the link", "Uploading the video". [onUploaded] gets the phone's upload id (for Try again without uploading twice).
 */
suspend fun <T> fetchLink(
    url: String, name: String?, fetcher: LinkFetcher?, cacheDir: File, steps: LinkSteps<T>,
    onUploaded: (String) -> Unit = {},
    onStep: (Float, String) -> Unit = { _, _ -> },
): T {
    onStep(.02f, "Checking the link")
    val check = steps.check(url)
    if (!check.allowed) throw ApiException(check.code ?: "link_unsupported", check.reason ?: "This link can't be used")
    check.known?.let { return it }
    if (fetcher != null) {
        val s = runCatching { steps.rules() }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }.getOrNull()
        val rules = (s ?: LinkRules()).copy(platform = check.platform)
        onStep(.03f, "Getting the video from the link")
        when (val got = fetcher.fetch(check.url, rules, File(cacheDir, "links"))) {
            is DeviceFetch.Got -> try {
                val uploadId = steps.upload(got.file) { p -> onStep(.05f + p * .15f, "Uploading the video") }
                onUploaded(uploadId)
                return steps.finish(uploadId, url, name ?: got.title.take(80).ifBlank { null })
            } finally { got.file.delete() }
            is DeviceFetch.Refused -> throw ApiException(got.code, got.message)
            is DeviceFetch.Failed -> Unit // the server's fetch next
        }
    }
    onStep(.05f, "Getting the video from the link")
    return steps.serverFetch(url, name)
}
