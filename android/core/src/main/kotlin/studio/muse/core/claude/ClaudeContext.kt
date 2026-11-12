package studio.muse.core.claude

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// The Claude panel's live context strip (owner, 2026-11-12; the Mac's MuseCore/Claude/ClaudeContext.swift): small
// thumbnails, each with a tiny label, of what Claude sees on this page now (the clip, her, the outfit, the background,
// references, the guide, the model), read from the SAME `screen` JSON the composer syncs to the server for Claude.

data class ContextItem(val id: String, val kind: Kind, val label: String, val detail: String?, val image: String?,
                       val clipId: String?, val isVideo: Boolean, val words: String?) {
    enum class Kind { CLIP, CHARACTER, OUTFIT, BACKGROUND, FRAME, REFERENCE, GUIDE, AUDIO, MODEL, PRODUCT, FACE }
}

/** Names and pictures the strip needs (the app looks them up). */
class ContextLookups(
    val character: (String) -> Pair<String, String?>? = { null },
    val outfit: (String) -> Pair<String, String?>? = { null },
    val clipPoster: (String) -> String? = { null },
)

object ClaudeContext {
    fun items(screen: JsonElement?, lookups: ContextLookups = ContextLookups()): List<ContextItem> {
        val s = screen as? JsonObject ?: return emptyList()
        val request = s.obj("request"); val settings = s.obj("settings"); val remix = request.obj("remix")
        val inputs = s.arr("inputs")?.mapNotNull { it as? JsonObject }.orEmpty()
        val out = mutableListOf<ContextItem>()
        fun source(slot: String?) = slot != null && (slot.endsWith(".clip") || slot == "extend.video")
        for (i in inputs.filter { source(it.str("slot")) }) {
            val clip = i.str("clipId")
            out += ContextItem("in:${i.str("slot")}", ContextItem.Kind.CLIP, "Clip", i.str("label"), clip?.let(lookups.clipPoster), clip, true, null)
        }
        request.str("modelId")?.let { m -> val c = lookups.character(m); out += ContextItem("character:$m", ContextItem.Kind.CHARACTER, "Her", c?.first, c?.second, null, false, null) }
        request.str("outfitId")?.let { o -> val x = lookups.outfit(o); out += ContextItem("outfit:$o", ContextItem.Kind.OUTFIT, "Outfit", x?.first, x?.second, null, false, null) }
        remix.obj("outfit").str("words")?.let { w -> out += ContextItem("outfit:words", ContextItem.Kind.OUTFIT, "Outfit", w, null, null, false, w) }
        val bgWords = remix.obj("background").str("words")
            ?: if ((request.str("background") ?: settings.str("background")) == "describe") request.str("direction") ?: request.str("prompt") else null
        if (bgWords != null && inputs.none { it.str("slot")?.endsWith("background") == true })
            out += ContextItem("background:words", ContextItem.Kind.BACKGROUND, "Background", bgWords, null, null, false, bgWords)
        var refs = 0; var frames = 0
        for (i in inputs.filterNot { source(it.str("slot")) }) {
            val slot = i.str("slot") ?: ""
            val kind = i.str("kind") ?: "image"
            val (label, k) = when {
                slot.endsWith("background") -> "Background" to ContextItem.Kind.BACKGROUND
                slot.endsWith(".outfit") -> "Product" to ContextItem.Kind.PRODUCT
                slot.endsWith(".face") -> "Face" to ContextItem.Kind.FACE
                slot == "guide" -> "Guide" to ContextItem.Kind.GUIDE
                slot == "start" -> "Start" to ContextItem.Kind.FRAME
                slot == "end" -> "End" to ContextItem.Kind.FRAME
                slot.startsWith("middle") -> { frames++; "Frame $frames" to ContextItem.Kind.FRAME }
                kind == "audio" -> "Sound" to ContextItem.Kind.AUDIO
                else -> { refs++; (i.str("role")?.replaceFirstChar { it.uppercase() } ?: "Ref $refs") to ContextItem.Kind.REFERENCE }
            }
            out += ContextItem("in:$slot", k, label, i.str("label"), if (kind == "video") null else i.str("url"), i.str("clipId"), kind == "video", null)
        }
        // The picked model, by the server's label (settings.modelLabel: the model pill's words, never built in the app).
        (request.str("engineModel") ?: settings.str("modelLabel"))?.let { e ->
            out += ContextItem("model:$e", ContextItem.Kind.MODEL, "Model", settings.str("modelLabel") ?: e, null, null, false, null)
        }
        return out
    }
}

/** The quick-action chips over the composer (GET v1/claude/chips; this copy when the server is older or offline). */
data class ClaudeChip(val label: String, val prompt: String, val icon: String) {
    companion object {
        fun fallback(page: String?, tool: String?): List<ClaudeChip> {
            val price = ClaudeChip("Check the price", "What will this cost, line by line?", "coins")
            val write = ClaudeChip("Write the prompt", "Write the prompt for this shot.", "pencil-simple")
            return when (page) {
                "suite" -> if (tool in setOf("swap", "remix", "recast", "extend")) listOf(ClaudeChip("Watch my clip", "Watch my clip and tell me the key moments.", "play-circle"), write, price)
                           else listOf(write, ClaudeChip("Set the rig", "Set up the rig for this shot.", "aperture"), price)
                "edit" -> listOf(ClaudeChip("Watch my edit", "Watch my edit and tell me what to fix.", "play-circle"), ClaudeChip("Cut to the beat", "Cut this to the beat.", "scissors"), ClaudeChip("Add captions", "Add captions to this edit.", "text-aa"))
                else -> listOf(ClaudeChip("What can you do", "What can you do on this page?", "chat-circle"), ClaudeChip("Start a shot", "Help me start a new shot.", "video-camera"), ClaudeChip("Watch my clip", "Watch my latest clip.", "play-circle"))
            }
        }
    }
}
