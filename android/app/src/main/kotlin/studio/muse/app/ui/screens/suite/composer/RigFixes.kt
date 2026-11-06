package studio.muse.app.ui.screens.suite.composer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteRigWarning

// AI suite (workstream 3): the rig check's one-tap fixes, applied to the composer's choices (plans/video-composer.md "Rig
// check"). A fix is a JSON Merge Patch (RFC 7386) over the shot request; here each path is mapped to the setter a tap in
// the picker would use, so the chips, the prompt's #move tokens and the request all agree afterwards. Pure, unit-tested.

object RigFixes {
    /** RFC 7386: objects merge, null removes, anything else replaces. */
    fun mergePatch(target: JsonElement?, patch: JsonElement): JsonElement? {
        if (patch !is JsonObject) return patch
        val out = (target as? JsonObject)?.toMutableMap() ?: mutableMapOf()
        for ((k, v) in patch) if (v is JsonNull) out.remove(k) else out[k] = mergePatch(out[k], v) ?: continue
        return JsonObject(out)
    }

    /**
     * Applies [patch] to the draft as picker taps would: `camera.rig.*`, `palette.preset`, `lighting.preset`, `angle.*`
     * and `style.*` set the chips (null = Auto); `camera.move` / `camera.mix` replace or remove the prompt's #move tokens
     * (first = move, second = mix); top-level `speaking` sets the switch. With a Directed camera applied, the camera part
     * is merged into that JSON instead (the chips aren't sent then). Unknown paths are left alone.
     */
    fun apply(d: ComposerDraft, patch: JsonObject, cat: CameraCatalog): ComposerDraft {
        var out = d
        when (val sp = patch["speaking"]) {
            null -> {}
            is JsonNull -> out = out.copy(speaking = null)
            is JsonPrimitive -> sp.booleanOrNull?.let { out = out.copy(speaking = it) }
            else -> {}
        }
        val camera = patch["camera"] as? JsonObject ?: return out
        out.directed?.let { dir ->
            val merged = runCatching { mergePatch(Json.parseToJsonElement(dir), camera) }.getOrNull()
            if (merged != null) return out.copy(directed = merged.toString())
        }
        var s = out.settings
        fun obj(k: String) = camera[k] as? JsonObject
        fun str(o: JsonObject, k: String, cur: String?): String? = when (val v = o[k]) { null -> cur; is JsonNull -> null; is JsonPrimitive -> v.content; else -> cur }
        obj("rig")?.let { r ->
            s = s.copy(body = str(r, "body", s.body), lens = str(r, "lens", s.lens), aperture = str(r, "aperture", s.aperture), stock = str(r, "look", s.stock),
                focalMm = when (val v = r["focalMm"]) { null -> s.focalMm; is JsonNull -> null; is JsonPrimitive -> v.intOrNull ?: s.focalMm; else -> s.focalMm })
        }
        obj("palette")?.let { s = s.copy(palette = str(it, "preset", s.palette)) }
        obj("lighting")?.let { s = s.copy(lighting = str(it, "preset", s.lighting)) }
        obj("angle")?.let { a -> s = s.copy(height = str(a, "height", s.height), shotSize = str(a, "shotSize", s.shotSize)) }
        obj("style")?.let { st -> s = s.copy(genre = str(st, "genre", s.genre), era = str(st, "era", s.era), tempo = str(st, "tempo", s.tempo), format = str(st, "format", s.format)) }
        // A whole group set to null goes back to Auto, like "Reset all" in that picker.
        if (camera["rig"] is JsonNull) s = s.copy(body = null, lens = null, focalMm = null, aperture = null, stock = null)
        if (camera["palette"] is JsonNull) s = s.copy(palette = null)
        if (camera["lighting"] is JsonNull) s = s.copy(lighting = null)
        if (camera["angle"] is JsonNull) s = s.copy(height = null, shotSize = null)
        if (camera["style"] is JsonNull) s = s.copy(genre = null, era = null, tempo = null, format = null)
        return out.copy(settings = s, tokens = moves(out.tokens, camera, cat))
    }

    /** `move` / `mix` over the prompt's #move tokens. Merge semantics: a token keeps its intensity unless the patch names one. */
    private fun moves(t: PromptTokens, camera: JsonObject, cat: CameraCatalog): PromptTokens {
        if ("move" !in camera && "mix" !in camera) return t
        var tokens = t
        val first = tokens.moves.getOrNull(0)
        val second = tokens.moves.getOrNull(1)
        // The mix first: removing it, or a move that becomes what the mix was ("drop the rack focus" promotes the mix).
        val mixPatch = camera["mix"]
        val movePatch = camera["move"]
        val newMoveId = ((movePatch as? JsonObject)?.get("id") as? JsonPrimitive)?.content
        var promoted = false
        when {
            movePatch is JsonNull -> first?.let { tokens = tokens.remove(it.key) }
            movePatch is JsonObject && first != null && second != null && newMoveId == second.id -> {
                tokens = tokens.remove(first.key)
                tokens = withIntensity(tokens, second.key, movePatch)
                promoted = true
            }
            movePatch is JsonObject && newMoveId != null && first != null -> tokens = replace(tokens, first, newMoveId, movePatch, cat)
            movePatch is JsonObject && newMoveId != null -> cat.move(newMoveId)?.let { m -> tokens = tokens.addMove(m.copy(label = cat.moveLabel(m.id)), tokens.caretAtEnd, intensityOf(movePatch) ?: 50).first }
        }
        // The token that is still the mix (none once it was promoted to the move).
        val mixNow = if (promoted) null else second?.let { s -> tokens.moves.firstOrNull { it.key == s.key } }
        when {
            mixPatch is JsonNull -> mixNow?.let { tokens = tokens.remove(it.key) }
            mixPatch is JsonObject -> {
                val id = (mixPatch["id"] as? JsonPrimitive)?.content
                if (mixNow != null && id != null) tokens = replace(tokens, mixNow, id, mixPatch, cat)
                else if (mixNow != null) tokens = withIntensity(tokens, mixNow.key, mixPatch)
                else if (id != null) cat.move(id)?.let { m -> tokens = tokens.addMove(m.copy(label = cat.moveLabel(m.id)), tokens.caretAtEnd, intensityOf(mixPatch) ?: 50).first }
            }
        }
        // A move the remaining mix can't go with (Lock it off = static) takes the shot alone, as the picker would refuse the pair.
        val (a, b) = tokens.moves.getOrNull(0) to tokens.moves.getOrNull(1)
        if (a != null && b != null && (a.id == b.id || !PromptTokens.canMix(a.category, a.id, b.category, b.id))) tokens = tokens.remove(b.key)
        return tokens
    }

    private fun intensityOf(o: JsonObject): Int? = (o["intensity"] as? JsonPrimitive)?.content?.toDoubleOrNull()?.let { (it * 100).toInt().coerceIn(0, 100) }

    private fun withIntensity(t: PromptTokens, key: Long, o: JsonObject): PromptTokens = intensityOf(o)?.let { t.setIntensity(key, it) } ?: t

    /** The token becomes move [id] in place (same key and place in the prompt). */
    private fun replace(t: PromptTokens, old: PromptPart.Move, id: String, o: JsonObject, cat: CameraCatalog): PromptTokens {
        val m = cat.move(id)
        val next = PromptPart.Move(id, cat.moveLabel(id).ifBlank { id }, m?.category ?: "", intensityOf(o) ?: old.intensity, old.key)
        return PromptTokens(t.parts.map { if (it is PromptPart.Move && it.key == old.key) next else it })
    }
}

/**
 * The warnings hidden with × (plans/video-composer.md: "hides that warning until the choices change"). [choices] is the
 * fingerprint of the composer's choices when they were hidden; a different fingerprint shows them all again. A warning
 * is known by its rule and its words, so a new clash of the same rule still shows.
 */
data class RigDismissals(val choices: String? = null, val hidden: Set<String> = emptySet()) {
    fun visible(rig: List<SuiteRigWarning>, now: String): List<SuiteRigWarning> = if (now != choices) rig else rig.filterNot { key(it) in hidden }

    fun dismiss(w: SuiteRigWarning, now: String): RigDismissals = if (now == choices) copy(hidden = hidden + key(w)) else RigDismissals(now, setOf(key(w)))

    companion object {
        fun key(w: SuiteRigWarning) = "${w.id}|${w.reason}"

        /** The choices a warning depends on: tool, chips, #moves, the speaking switch, a Directed camera. Not the typing. */
        fun choicesOf(d: ComposerDraft): String = listOf(d.tool.id, d.settings.toString(), d.tokens.moves.joinToString(",") { it.id }, d.speaking.toString(), d.directed.orEmpty()).joinToString("|")
    }
}
