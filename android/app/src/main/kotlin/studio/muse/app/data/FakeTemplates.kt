package studio.muse.app.data

import studio.muse.core.Identity
import studio.muse.core.PromptEngine
import kotlin.random.Random

/**
 * Demo mode's template library: the same rules as server/api (plans/api.md "Photo templates"), in memory. The demo
 * user ("u1") owns the starter pack; Maya, a member, owns two public templates, so the demo shows the locked
 * "Template: <name>" line too. Covers are the bundled stills (the real server bakes the grade into them).
 */
class FakeTemplates(private val me: String = "u1", private val now: () -> Long = System::currentTimeMillis) {
    private data class Row(
        val id: String, val owner: String, val ownerName: String, val visibility: String, val name: String, val tags: List<String>,
        val layers: TemplateLayers, val pool: Map<String, List<String>>, val cover: ImageRef?, val starter: String?, val fromShot: String?,
        val uses: Int, val createdAt: Long, val updatedAt: Long,
    )

    private val rows = mutableListOf<Row>()
    private val favs = mutableSetOf<String>()
    /** Template shots: take id → (template id, full prompt, draws). */
    private val shotSecrets = mutableMapOf<String, Triple<String, String, Map<String, String>>>()

    init {
        val t = now()
        STARTERS.forEachIndexed { i, s -> rows += Row("tpl_${s.slug}", me, "Jenne", "public", s.name, s.tags, s.layers, s.pool, ImageRef.asset(s.cover), s.slug, null, 0, t - i, t - i) }
        rows += Row("tpl_maya_walk", "u_maya", "Maya", "public", "Golden hour walk", listOf("Golden hour", "Street"),
            TemplateLayers(style = "warm candid street photo", scene = "a quiet residential street", light = "low golden sun behind her", afterEffects = TemplateAfterEffects(grade = "golden")),
            mapOf("pose" to listOf("mid-step", "turning back", "fixing her hair")), ImageRef.asset("g_tq"), null, null, 12, t - 100, t - 100)
        rows += Row("tpl_maya_cafe", "u_maya", "Maya", "public", "Café window", listOf("Candid", "Café"),
            TemplateLayers(style = "soft window-light café photo", scene = "a café window seat"), mapOf("pose" to listOf("holding a cup", "looking out")),
            ImageRef.asset("c_tq"), null, null, 4, t - 101, t - 101)
        rows += Row("tpl_maya_private", "u_maya", "Maya", "private", "Maya's secret", emptyList(), TemplateLayers(style = "hidden"), emptyMap(), null, null, null, 0, t - 102, t - 102)
        favs += "tpl_maya_walk"
    }

    private fun view(r: Row, recent: List<RecentShot>? = null) = Template(
        r.id, r.name, r.tags, r.visibility, r.owner, r.ownerName, r.owner == me, r.uses, r.id in favs, r.cover, !r.layers.product.isNullOrBlank(), r.starter, r.fromShot,
        r.createdAt, r.updatedAt, if (r.owner == me) r.layers else null, if (r.owner == me) r.pool else null, recent,
    )

    private fun visible(id: String): Row = rows.firstOrNull { it.id == id && (it.owner == me || it.visibility == "public") }
        ?: throw ApiException("not_found", "That template isn't there any more")
    private fun owned(id: String): Row = visible(id).also { if (it.owner != me) throw ApiException("owner_only", "Only the person who made this template can change it") }
    private fun put(r: Row) { rows.replaceAll { if (it.id == r.id) r else it } }

    fun list(scope: String, q: String?, tag: String?): List<Template> {
        val text = q?.trim()?.lowercase().orEmpty()
        return rows.filter { it.owner == me || it.visibility == "public" }
            .filter { when (scope) { "mine" -> it.owner == me; "public" -> it.visibility == "public"; "favourites" -> it.id in favs; else -> true } }
            .filter { text.isEmpty() || it.name.lowercase().contains(text) || it.tags.any { t -> t.lowercase().contains(text) } }
            .filter { tag.isNullOrBlank() || it.tags.any { t -> t.equals(tag, true) } }
            .sortedByDescending { it.updatedAt }.map { view(it) }
    }

    fun detail(id: String, takes: List<Take>) = visible(id).let { r -> view(r, takes.filter { it.templateId == r.id }.take(6).map { RecentShot(it.id, it.thumb, it.createdAt) }) }

    fun draft(shot: Take): TemplateDraft {
        if (shot.templateId != null && rows.firstOrNull { it.id == shot.templateId }?.owner != me) {
            throw ApiException("template_hidden", "This photo was made with someone else's template, so its look can't be saved. Use that template instead.")
        }
        val src = shot.templateId?.let { id -> rows.firstOrNull { it.id == id } }
        val layers = src?.layers ?: layersFrom(shot.prompt)
        val pool = src?.pool ?: suggestPool(layers, shot.title).let { p ->
            val dir = Regex("^Direction: (.+)$", RegexOption.MULTILINE).find(shot.prompt)?.groupValues?.get(1)?.trimEnd('.')
            if (dir != null) p + ("pose" to (listOf(dir) + p["pose"].orEmpty()).take(12)) else p
        }
        return TemplateDraft(src?.name ?: takeDisplayTitle(shot.title).removePrefix("Photo · "), src?.tags.orEmpty(), layers, pool, shot.thumb, shot.id)
    }

    fun create(req: CreateTemplateRequest, shot: Take?): Template {
        val d = shot?.let { draft(it) }
        val t = now()
        val pool = req.variationPool?.takeIf { p -> p.values.any { it.isNotEmpty() } } ?: d?.variationPool ?: suggestPool(req.layers ?: TemplateLayers(), req.name)
        val r = Row("tpl_${Random.nextInt(1_000_000)}", me, "Jenne", req.visibility ?: "private", req.name.ifBlank { "My look" }, req.tags ?: d?.tags.orEmpty(),
            d?.layers ?: req.layers ?: TemplateLayers(), pool, d?.cover, null, shot?.id, 0, t, t)
        rows += r
        return view(r)
    }

    fun patch(id: String, p: PatchTemplateRequest): Template {
        val r = owned(id)
        val u = r.copy(name = p.name ?: r.name, tags = p.tags ?: r.tags, visibility = p.visibility ?: r.visibility, layers = p.layers ?: r.layers,
            pool = p.variationPool ?: r.pool, updatedAt = now())
        put(u)
        return view(u)
    }

    fun delete(id: String) { val r = owned(id); rows.removeAll { it.id == r.id }; favs.remove(r.id) }

    fun duplicate(id: String): Template {
        val r = owned(id)
        val t = now()
        val c = r.copy(id = "tpl_${Random.nextInt(1_000_000)}", name = "${r.name} copy", visibility = "private", starter = null, uses = 0, createdAt = t, updatedAt = t)
        rows += c
        return view(c)
    }

    fun favourite(id: String, on: Boolean): Template { val r = visible(id); if (on) favs += r.id else favs -= r.id; return view(r) }

    data class Built(val shown: TemplatePrompt, val full: String, val visible: String, val draws: Map<String, String>)

    fun prompt(id: String, identity: Identity, outfitName: String?, direction: String?, shuffleSeed: Long, lockSeed: Boolean, index: Int = 0): Built {
        val r = visible(id)
        val mine = r.owner == me
        val v = draw(r.pool, shuffleSeed, index, direction?.trim()?.ifBlank { null })
        val seed = if (lockSeed) PromptEngine.seedFor("${r.id}:${identity.name}") else Random.nextLong(1_000_000)
        val idLine = PromptSlotView("identity", "${identity.name}: ${identity.look}. Identity from ${identity.referenceCount} locked reference images.")
        val outfit = outfitName?.let { PromptSlotView("outfit", "Wearing: ${it.lowercase()} (outfit reference set).") }
        val dir = v["direction"]?.let { PromptSlotView("direction", "Direction: ${it.trimEnd('.')}.") }
        val never = PromptEngine.neverList(identity)
        val seedLine = PromptSlotView("seed", if (lockSeed) "Seed: $seed (locked look)." else "Seed: $seed (new each shot).")
        val j = { parts: List<String?> -> parts.filterNot { it.isNullOrBlank() }.joinToString("; ") { it!!.trimEnd('.', ';') } }
        val l = r.layers
        val hidden = listOfNotNull(
            j(listOf(l.scene, v["background"], v["timeOfDay"])).ifBlank { null }?.let { PromptSlotView("scene", "Scene: $it.") },
            j(listOf(l.camera, v["framing"])).ifBlank { null }?.let { PromptSlotView("camera", "Camera: $it.") },
            l.light?.let { PromptSlotView("light", "Light: ${it.trimEnd('.')}.") },
            j(listOf(v["pose"], v["bodyAngle"], v["expression"], v["hands"])).ifBlank { null }?.let { PromptSlotView("pose", "Pose: $it.") },
        )
        val full = listOfNotNull(idLine, outfit) + hidden + listOfNotNull(dir,
            l.product?.let { PromptSlotView("product", "Product: ${it.trimEnd('.')}.") },
            PromptSlotView("style", "Style: ${j(listOf(l.style, PromptEngine.HOUSE_STYLE))}."),
            PromptSlotView("negative", "Never add: ${(never + listOfNotNull(l.negative)).joinToString(", ")}."), seedLine)
        val visible = listOfNotNull(idLine, outfit, PromptSlotView("template", "Template: ${r.name}", locked = true), dir,
            PromptSlotView("negative", "Never add: ${never.joinToString(", ")}."), seedLine)
        val shown = if (mine) full else visible
        return Built(TemplatePrompt(shown, shown.joinToString("\n") { it.text }, seed, shuffleSeed, if (mine) v else null),
            full.joinToString("\n") { it.text }, visible.joinToString("\n") { it.text }, v)
    }

    fun recordShot(takeId: String, templateId: String, fullPrompt: String, variation: Map<String, String>) {
        shotSecrets[takeId] = Triple(templateId, fullPrompt, variation)
    }
    fun bumpUses(templateId: String) { rows.firstOrNull { it.id == templateId }?.let { put(it.copy(uses = it.uses + 1)) } }
    fun isMine(templateId: String) = rows.firstOrNull { it.id == templateId }?.owner == me
    fun name(templateId: String) = visible(templateId).name

    companion object {
        data class Starter(val slug: String, val name: String, val tags: List<String>, val cover: String, val layers: TemplateLayers, val pool: Map<String, List<String>>)

        val STARTERS = listOf(
            Starter("motion-blur-face", "Motion-blur face", listOf("Faceless", "Motion", "Editorial"), "face",
                TemplateLayers("candid phone photo taken a split second too late, the subject moving while the background holds still", "a plain lived-in space", "phone main camera, 1/30 s handheld",
                    "flat daylight, no flash", "blurred background, tack-sharp face", null, TemplateAfterEffects(0.85, 0.0, "phone-natural", 0.15)),
                mapOf("pose" to listOf("turning her head quickly", "mid-laugh, head tipping back", "spinning round"), "framing" to listOf("waist up", "head and shoulders"))),
            Starter("mirror-selfie", "Mirror selfie", listOf("Faceless", "Selfie", "At home"), "g_front",
                TemplateLayers("real mirror selfie posted straight from the camera roll", "a candid bedroom or bathroom", "shot on the phone in the mirror",
                    "one window, a little underexposed", "ring light reflection", null, TemplateAfterEffects(grade = "underexposed", grain = 0.12)),
                mapOf("pose" to listOf("phone covering the face", "phone low at the chest", "one hip popped"), "bodyAngle" to listOf("three-quarter turn", "square to the mirror"))),
            Starter("harsh-sun-close-up", "Harsh-sun close-up", listOf("Close-up", "Sun", "Beauty"), "face",
                TemplateLayers("extreme close-up in direct midday sun, visible skin texture", "outdoors", "very tight crop at arm's length", "hard direct sun, crisp shadows",
                    "airbrushed skin", null, TemplateAfterEffects(grade = "harsh-sun", grain = 0.08)),
                mapOf("framing" to listOf("cropped at the forehead", "lips and jaw only", "one eye and cheek"))),
            Starter("moody-low-light", "Moody low-light", listOf("Night", "Moody", "At home"), "c_front",
                TemplateLayers("underexposed phone photo at night", "a dim room lit by practical lights", "phone night mode, handheld", "low lamp light, blue and purple tones",
                    "flash", null, TemplateAfterEffects(grade = "moody-blue", grain = 0.45)),
                mapOf("pose" to listOf("on the edge of the bed", "leaning on a window frame"), "background" to listOf("a lamp out of focus", "city lights"))),
            Starter("reflection", "Reflection", listOf("Reflection", "Street", "Editorial"), "c_tq",
                TemplateLayers("the subject and her reflection together", "a glossy car roof, a shop window or still water", "phone held low near the surface", "natural daylight",
                    "missing reflection", null, TemplateAfterEffects(grade = "faded", grain = 0.1)),
                mapOf("framing" to listOf("subject top, reflection bottom", "reflection only"))),
            Starter("product-moment", "Product moment", listOf("Product", "UGC", "Close-up"), "c_face",
                TemplateLayers("casual UGC product photo, the product is the hero", "a real everyday surface", "phone close to the product", "soft window light",
                    "invented logos", "the product from the product photo, exactly as it is", TemplateAfterEffects(grade = "phone-natural")),
                mapOf("pose" to listOf("product next to the cheek", "product in hand at the hip"), "hands" to listOf("fingertips around the cap", "on the palm"))),
            Starter("candid-pov", "Candid POV", listOf("POV", "Candid", "Lifestyle"), "g_tq",
                TemplateLayers("point-of-view phone photo taken by a friend", "out together: a café, a street or a car", "chest height, off-centre, slight tilt", "natural, uneven",
                    "centred posed composition", null, TemplateAfterEffects(grade = "phone-natural", grain = 0.1)),
                mapOf("pose" to listOf("reaching for the camera", "walking ahead, glancing back"), "framing" to listOf("off-centre left", "tilted horizon"))),
        )

        /** One option per slot; a direction replaces pose and body angle. Same seed → same draws. */
        fun draw(pool: Map<String, List<String>>, shuffleSeed: Long, index: Int, direction: String?): Map<String, String> {
            val r = Random(shuffleSeed * 31 + index)
            val out = linkedMapOf<String, String>()
            for (slot in PoolSlots.ALL) {
                val opts = pool[slot].orEmpty().filter { it.isNotBlank() }
                val pick = if (opts.isEmpty()) null else opts[r.nextInt(opts.size)]
                if (direction != null && (slot == "pose" || slot == "bodyAngle")) continue
                if (pick != null) out[slot] = pick
            }
            if (direction != null) out["direction"] = direction
            return out
        }

        fun layersFrom(prompt: String): TemplateLayers {
            fun get(l: String) = Regex("^$l: (.+)$", RegexOption.MULTILINE).find(prompt)?.groupValues?.get(1)?.trimEnd('.')
            return TemplateLayers(scene = get("Scene"), camera = get("Camera"), light = get("Light"))
        }

        fun suggestPool(layers: TemplateLayers, name: String): Map<String, List<String>> {
            val text = listOfNotNull(name, layers.style, layers.scene, layers.camera).joinToString(" ").lowercase()
            return if ("mirror" in text || "selfie" in text) mapOf(
                "pose" to listOf("phone covering the face", "phone low at the chest", "one hip popped"),
                "bodyAngle" to listOf("three-quarter turn to the mirror", "square to the mirror"),
                "framing" to listOf("full length in the mirror", "cropped at the knees"),
            ) else mapOf(
                "pose" to listOf("weight on one leg, relaxed", "mid-step", "leaning on a wall"),
                "bodyAngle" to listOf("three-quarter to camera", "facing camera", "side profile"),
                "framing" to listOf("full body", "three-quarter length", "waist up"),
                "expression" to listOf("easy smile", "neutral, looking away", "laughing"),
            )
        }
    }

    /** What a viewer sees of a template shot (full prompt only for the template's owner). */
    fun shotView(t: Take): Take {
        val s = shotSecrets[t.id] ?: return t
        return if (isMine(s.first)) t.copy(prompt = s.second, variation = s.third) else t
    }
}
