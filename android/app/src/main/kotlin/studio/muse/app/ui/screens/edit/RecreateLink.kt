package studio.muse.app.ui.screens.edit

import studio.muse.app.data.ApiException
import studio.muse.app.data.MuseApi
import studio.muse.app.platform.DeviceFetch
import studio.muse.app.platform.LinkFetcher
import studio.muse.core.edit.RecipeReference
import java.io.File

/**
 * A shared link becomes a reference (owner's decision, Release 1 test: platforms block the studio server):
 * 1. the phone downloads it ([LinkFetcher]) and uploads it as an ordinary reference, with its `sourceUrl`;
 * 2. when the phone can't, the server's own link fetch;
 * 3. when that fails too, the caller offers "Pick the saved video" (the exception's message says why).
 * A rule the link breaks (too long, too big, not public) is said straight away, with no other attempt.
 */
suspend fun referenceFromLink(
    api: MuseApi, fetcher: LinkFetcher?, url: String, name: String?, strict: Boolean, cacheDir: File,
    onStep: (Float, String) -> Unit = { _, _ -> },
): RecipeReference {
    if (fetcher != null) {
        onStep(.03f, "Getting the video from the link")
        when (val got = fetcher.fetch(url, strict, File(cacheDir, "links"))) {
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
