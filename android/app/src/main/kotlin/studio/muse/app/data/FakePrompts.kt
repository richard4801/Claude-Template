package studio.muse.app.data

import kotlinx.serialization.json.Json
import studio.muse.core.CameraSpec
import studio.muse.core.Identity
import studio.muse.core.Layer
import studio.muse.core.OutfitSpec
import studio.muse.core.PhotoPrices
import studio.muse.core.PhotoPricing
import studio.muse.core.PromptEngine
import studio.muse.core.SentRef
import studio.muse.core.ShootSpec

/**
 * Demo mode's prompt library: the server's entries and defaults (resources/prompt_library.json, written by
 * server/api/scripts/gen-shoot-fixture.ts) with the same placeholder rules. On the real API the server owns all of this.
 * The demo shoot preview follows the owner's edits of the house style, the never-add base list and the reference lines.
 */
class FakePromptLibrary(private val now: () -> Long = System::currentTimeMillis) {
    private val base: PromptLibrary = DEFAULTS
    private val overrides = mutableMapOf<String, Pair<String, Long>>()

    fun list(): PromptLibrary = base.copy(prompts = base.prompts.map(::view))
    private fun view(e: PromptEntry): PromptEntry = overrides[e.key]?.let { (t, at) -> e.copy(current = t, overridden = true, updatedAt = at, updatedBy = "jenne@studio.com") } ?: e
    private fun entry(key: String) = base.prompts.firstOrNull { it.key == key } ?: throw ApiException("not_found", "No prompt called $key")

    /** The text the studio uses for [key] now: the owner's edit, else the default. */
    fun text(key: String): String = overrides[key]?.first ?: base.prompts.firstOrNull { it.key == key }?.default.orEmpty()

    fun save(key: String, text: String): PromptEntry {
        val e = entry(key)
        validate(e, text)?.let { throw ApiException("prompt_invalid", it) }
        if (text == e.default) overrides.remove(key) else overrides[key] = text to now()
        return view(e)
    }
    fun reset(key: String): PromptEntry { val e = entry(key); overrides.remove(key); return view(e) }

    /** POST /v1/prompts/preview: this entry with sample values, and the whole prompt it is part of (sample model "Demo model"). */
    fun preview(req: PromptPreviewRequest): PromptPreview {
        val e = entry(req.key)
        val text = req.text ?: view(e).current
        validate(e, text)?.let { throw ApiException("prompt_invalid", it) }
        val lib = { k: String -> if (k == e.key) text else text(k) }
        val values = SAMPLE + mapOf("style" to houseStyle(lib), "never" to neverList(SAMPLE_ID, lib).joinToString(", "))
        val rendered = when (e.kind) {
            "list" -> items(text, ",").joinToString(", ")
            "lines" -> items(text, "\n").joinToString("\n")
            else -> fill(text, values)
        }
        return PromptPreview(e.key, rendered, example(e, lib, values, rendered), e.placeholders.associate { it.name to (values[it.name] ?: "") })
    }

    /** The whole photoshoot prompt for photoshoot and reference entries (the demo builds no other prompts from the library). */
    private fun example(e: PromptEntry, lib: (String) -> String, values: Map<String, String>, rendered: String): String {
        if (e.group != "photoshoot" && e.group != "references") return rendered
        val cam = when (e.key) { "shoot.camera.wide" -> CameraSpec("Wide", 24, "f/5.6"); "shoot.camera.tele" -> CameraSpec("Close", 85, "f/1.4"); else -> CameraSpec() }
        val sent = listOf(SentRef(8, ShootRef.GUIDE_IDS))
        val p = PromptEngine.photoshoot(ShootSpec(SAMPLE_ID, OutfitSpec("Green set"), null, cam, "Golden hour", null, values["direction"], e.key == "shoot.seed.locked", refs = sent))
        val lines = applyLibrary(p.slots.map { PromptSlotView(it.layer.key, it.text) }, SAMPLE_ID, sent, lib).map { it.text }.toMutableList()
        // The engine's own wording for this entry's line (its default with the sample values) becomes the edited text.
        val i = lines.indexOf(fill(e.default, values))
        if (i >= 0 && e.kind == "text") { if (rendered.isBlank()) lines.removeAt(i) else lines[i] = rendered }
        return lines.joinToString("\n")
    }

    /** The demo shoot preview with this studio's library. */
    fun shootPreview(identity: Identity, outfit: String?, r: ShootRequest, prices: PhotoPrices, maxInputs: Int = 8): ShootPreview =
        shootPreview(identity, outfit, r, prices, maxInputs, ::text)

    /** A template shoot's preview: the viewer's view of the template ([slots]) plus the reference lines, with the image plan and price. */
    fun templatePreview(slots: List<PromptSlotView>, seed: Long?, removed: List<String>, identityImages: Int, r: ShootRequest, prices: PhotoPrices, maxInputs: Int = 8): ShootPreview {
        val plan = imagePlan(identityImages, r.refs.orEmpty(), prices.maxRefs, maxInputs)
        val all = withReferenceLines(slots, plan.sent.map { PromptSlotView("reference", referenceLine(it, ::text)) }.filter { it.text.isNotBlank() })
        val est = estimate(prices, r.count, plan.images)
        return ShootPreview(all, all.joinToString("\n") { it.text }, seed, removed, plan.images, plan.refs, est, PhotoPricing.about(est))
    }

    /** The images a shoot sends: her identity references, then the reference images that fit. */
    data class ImagePlan(val images: Int, val refs: List<ShootPreviewRef>) {
        val sent: List<SentRef> get() = refs.mapNotNull { r -> r.index?.let { SentRef(it, r.guides) } }
    }

    companion object {
        /**
         * The house style (server prompt/library.ts, split 2026-11-11): Camera feel then Realism. The demo has no rigs, so
         * Camera feel is always on (the server leaves it out when a rig or preset sets its own camera, lens, grade or look).
         */
        fun houseStyle(library: (String) -> String): String =
            listOf(library("style.camera"), library("style.realism")).map { it.trim().trimEnd('.', ',', ';', ' ') }.filter { it.isNotEmpty() }.joinToString(", ")

        private val PH = Regex("\\{([A-Za-z][A-Za-z0-9]*)\\}")
        /** The server's default library (the same file the server checks is current). */
        val DEFAULTS: PromptLibrary by lazy {
            FakePromptLibrary::class.java.getResource("/prompt_library.json")?.readText()
                ?.let { Json { ignoreUnknownKeys = true }.decodeFromString(PromptLibrary.serializer(), it) } ?: PromptLibrary()
        }
        /** The server's sample model and values for the editor's preview (server/api/src/prompt/service.ts). */
        private val SAMPLE_ID = Identity("Demo model", "young woman, shoulder-length dark brown hair, brown eyes, light olive skin", 7, listOf("tattoos", "rings"))
        private val SAMPLE = mapOf(
            "name" to "Demo model", "look" to SAMPLE_ID.look, "refCount" to "7", "lora" to "", "outfit" to "green set", "scene" to "rooftop · golden hour",
            "shot" to "medium", "lens" to "35", "aperture" to "f/2.8", "lensNote" to "", "light" to "golden hour", "grade" to "phone-natural",
            "direction" to "laughing mid-step, hair blowing", "refIndex" to "8", "angle" to "body · front", "framing" to "full body, facing the camera",
            "seed" to "421337", "anchor" to "", "camera" to "handheld, slightly tilted", "pose" to "mid-step, glancing back", "product" to "held up next to the cheek",
            "subject" to "the person in <Image 1> to <Image 5>: ${SAMPLE_ID.look}", "reference" to "face and identity from <Image 1> and <Image 2>", "faceRef" to "<Image 1>",
            "performer" to "the person", "setting" to "the room", "refs" to "<Image 1> (face, front) and <Image 2> (face, profile)", "audio" to "", "audioTag" to "",
            "background" to "The camera, framing, background, lighting and timing of <Video 1> are unchanged.", "video" to "fully_preserved", "tattoos" to "", "clean" to "",
            "n" to "6", "variation" to "window light, soft smile",
        )
        fun fill(text: String, values: Map<String, String>) = PH.replace(text) { values[it.groupValues[1]] ?: "" }

        /** A "list" entry's items (comma-separated) or a "lines" entry's (one per line), trimmed, empty ones left out. */
        fun items(text: String, sep: String): List<String> = text.split(sep).map { it.trim() }.filter { it.isNotEmpty() }

        /** Her never-add list, then the library's base list, without repeats. */
        fun neverList(identity: Identity, library: (String) -> String): List<String> =
            (identity.neverAdd + items(library("never.base"), ",")).map { it.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }

        /** The server's rules: known placeholders only, required ones kept, not empty unless allowed, ≤ 4000 characters. */
        fun validate(e: PromptEntry, text: String): String? {
            if (text.length > 4000) return "Keep it under 4000 characters"
            val allowed = e.placeholders.map { it.name }
            val used = mutableSetOf<String>()
            for (m in PH.findAll(text)) {
                val n = m.groupValues[1]
                if (n !in allowed) return if (allowed.isEmpty()) "Unknown placeholder {$n} · this prompt has no placeholders"
                    else "Unknown placeholder {$n} · this prompt can use ${allowed.joinToString(", ") { "{$it}" }}"
                used += n
            }
            e.placeholders.firstOrNull { it.required && it.name !in used }?.let { return "Keep {${it.name}} · this prompt needs it" }
            if (text.isBlank() && !e.allowEmpty) return "This prompt can’t be empty"
            return null
        }

        /**
         * The server's image plan: her identity references (at most maxRefs), then the reference images in order, within the shot
         * model's limit. Identity references give way first (never the face front), then the last reference images (dropped).
         */
        fun imagePlan(identityImages: Int, refs: List<ShootRef>, maxRefs: Int, maxInputs: Int): ImagePlan {
            val id = minOf(identityImages, maxRefs).coerceAtLeast(0)
            val nRefs = minOf(refs.size, maxOf(0, if (id > 0) maxInputs - 1 else maxInputs))
            val nId = minOf(id, maxInputs - nRefs)
            val previewRefs = refs.mapIndexed { k, x -> if (k < nRefs) ShootPreviewRef(nId + k + 1, x.guides) else ShootPreviewRef(null, x.guides, dropped = true) }
            return ImagePlan(nId + nRefs, previewRefs)
        }

        /** The whole shoot: per still run + 2 MP out + 0.79 MP in per image sent (the default shot model's estimate). */
        fun estimate(p: PhotoPrices, count: Int, images: Int): Double = count * (p.perRun + p.perOutputMp * 2.0 + p.perInputMp * p.refMp * images)

        /** One reference image's line from the library: its guides in the order pose, look, scene, then the guard; empty parts left out. */
        fun referenceLine(r: SentRef, library: (String) -> String): String {
            val v = mapOf("refIndex" to r.index.toString())
            return (ShootRef.GUIDE_IDS.filter { it in r.guides }.map { "refs.$it" } + "refs.guard")
                .map { fill(library(it), v).trim() }.filter { it.isNotEmpty() }.joinToString(" ")
        }

        /** Reference slots go after the direction: before the first style, never-add or seed line. */
        fun withReferenceLines(slots: List<PromptSlotView>, refs: List<PromptSlotView>): List<PromptSlotView> {
            if (refs.isEmpty()) return slots
            val at = slots.indexOfFirst { it.layer in setOf("style", "negative", "seed") }.takeIf { it >= 0 } ?: slots.size
            return slots.take(at) + refs + slots.drop(at)
        }

        /**
         * The offline/demo shoot preview: the app's fallback engine (checked against the server's fixture) and the server's
         * image plan. With [library], the house style, never-add base list and reference lines use that library's text.
         */
        fun shootPreview(identity: Identity, outfit: String?, r: ShootRequest, prices: PhotoPrices, maxInputs: Int = 8, library: ((String) -> String)? = null): ShootPreview {
            val plan = imagePlan(identity.referenceCount, r.refs.orEmpty(), prices.maxRefs, maxInputs)
            val est = estimate(prices, r.count, plan.images)
            r.prompt?.takeIf { it.isNotBlank() }?.let { t ->
                return ShootPreview(listOf(PromptSlotView("custom", t)), t, r.seed, emptyList(), plan.images, plan.refs, est, PhotoPricing.about(est), edited = true)
            }
            val cam = r.camera?.let { CameraSpec(it.shot, it.lens, it.aperture) } ?: CameraSpec()
            val p = PromptEngine.photoshoot(ShootSpec(identity, OutfitSpec(outfit ?: "outfit"), r.scene, cam, r.light ?: "Golden hour", r.grade, r.direction, r.lockSeed == true,
                presets = r.presets != false, refs = plan.sent))
            val built = p.slots.map { PromptSlotView(it.layer.key, it.text) }
            val slots = if (library != null) applyLibrary(built, identity, plan.sent, library) else built
            return ShootPreview(slots, slots.joinToString("\n") { it.text }, p.seed, p.removed, plan.images, plan.refs, est, PhotoPricing.about(est))
        }

        /** The engine's style, never-add and reference lines in a library's wording; a line that renders empty is left out. */
        fun applyLibrary(slots: List<PromptSlotView>, identity: Identity, sent: List<SentRef>, library: (String) -> String): List<PromptSlotView> {
            val lines = sent.map { referenceLine(it, library) }.iterator()
            return slots.mapNotNull { s ->
                when (s.layer) {
                    Layer.STYLE.key -> s.copy(text = fill(library("shoot.style"), mapOf("style" to houseStyle(library))))
                    Layer.NEGATIVE.key -> s.copy(text = fill(library("shoot.never"), mapOf("never" to neverList(identity, library).joinToString(", "))))
                    Layer.REFERENCE.key -> s.copy(text = if (lines.hasNext()) lines.next() else s.text)
                    else -> s
                }.takeIf { it.text.isNotBlank() }
            }
        }
    }
}
