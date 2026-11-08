package studio.muse.app.data

/**
 * Share → MUSE (plans/recreate-edit.md "Getting the reference"): what another app shared, waiting for Edit → Recreate to
 * take it. A link goes to `POST /v1/recreate/references {url}`; a video file goes through the usual upload.
 */
sealed interface SharedReference {
    data class Link(val url: String) : SharedReference
    data class File(val uri: android.net.Uri, val mime: String?) : SharedReference
}
