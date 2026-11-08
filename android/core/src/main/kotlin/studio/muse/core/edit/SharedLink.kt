package studio.muse.core.edit

/**
 * Share → MUSE (plans/recreate-edit.md "Getting the reference"): a shared text ("Check this out https://vm.tiktok.com/ZM…
 * #fyp") becomes the link MUSE sends to `POST /v1/recreate/references {url}`. The server decides what it can fetch (its
 * guardrails: plans/research/platform-download-rules.md); the app only finds the link.
 */
object SharedLink {
    private val URL = Regex("""https?://[^\s<>"'“”]+""", RegexOption.IGNORE_CASE)

    /** The first http(s) link in [text], without trailing punctuation; null when there is none. */
    fun first(text: String?): String? = text?.let { URL.find(it)?.value?.trimEnd('.', ',', ')', '!', '?', ';', ':') }

    /** A short name for the reference from where it came ("TikTok link"). */
    fun name(url: String): String {
        val host = Regex("""https?://([^/]+)""").find(url)?.groupValues?.get(1)?.lowercase()?.removePrefix("www.")?.removePrefix("m.") ?: return "Shared link"
        return when {
            "tiktok" in host -> "TikTok link"
            "instagram" in host -> "Instagram link"
            "youtu" in host -> "YouTube link"
            else -> "Shared link"
        }
    }
}
