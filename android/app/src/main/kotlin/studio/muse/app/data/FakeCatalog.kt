package studio.muse.app.data

/**
 * Demo mode's stand-in for Replicate's catalog (owner Settings → Engines → Image models): the default model of each step
 * and a few alternatives, with the prices on their model pages (checked 2026-11-04). The real list comes from the server.
 */
object FakeCatalog {
    val DEFAULTS = mapOf(
        "shot" to "black-forest-labs/flux-2-pro", "edit" to "qwen/qwen-image-edit-2511", "realism" to "black-forest-labs/flux-krea-dev",
        "upscale" to "philz1337x/clarity-upscaler", "dressA" to "qwen/qwen-image-edit-2511", "dressB" to "black-forest-labs/flux-2-pro",
    )
    val STEP_LABELS = mapOf("shot" to "New shots", "edit" to "Edits", "realism" to "Enhance · realism", "upscale" to "Enhance · upscale",
        "dressA" to "Dress up · Option A", "dressB" to "Dress up · Option B")

    private val flux2 = PriceInfo("per-unit", listOf(PriceUnit("run_count", 0.015, "per run"), PriceUnit("image_input_megapixel_count", 0.015, "per input MP"),
        PriceUnit("image_output_megapixel_count", 0.015, "per output MP")), source = "model page")
    private fun perImage(usd: Double) = PriceInfo("per-unit", listOf(PriceUnit("image_output_count", usd, "per output image")), source = "model page")

    val MODELS = listOf(
        CatalogModel("black-forest-labs/flux-2-pro", "black-forest-labs", "FLUX.2 [pro]", "High-quality image generation and editing with up to 8 reference images",
            12_415_088, true, null, flux2, "$0.015 per run + $0.015 per input MP + $0.015 per output MP", true),
        CatalogModel("qwen/qwen-image-edit-2511", "qwen", "Qwen Image Edit 2511", "Image editing with better consistency across edits",
            1_284_000, true, null, perImage(0.03), "$0.03 per output image", true),
        CatalogModel("google/nano-banana", "google", "Nano Banana", "Image generation and editing with several input images",
            123_193_659, true, null, perImage(0.039), "$0.039 per output image", true),
        CatalogModel("black-forest-labs/flux-krea-dev", "black-forest-labs", "FLUX.1 Krea [dev]", "Photorealistic text-to-image that avoids the oversaturated AI look",
            2_600_000, true, null, perImage(0.025), "$0.025 per output image", true),
        CatalogModel("philz1337x/clarity-upscaler", "philz1337x", "Clarity Upscaler", "High resolution image upscaler and enhancer",
            30_755_727, false, null, PriceInfo("per-second", usdPerSecond = 0.00115, hardware = "A100 (40GB)", typicalUsd = 0.018, source = "model page"),
            "by time · about $0.018 a run ($0.00115/s on A100 (40GB))", true),
        CatalogModel("topazlabs/image-upscale", "topazlabs", "Topaz Image Upscale", "Professional-grade image upscaling, from Topaz Labs",
            3_743_197, true, null, PriceInfo("per-unit", listOf(PriceUnit("unspecified_billing_metric", 0.08, "per unit")), source = "model page"), "$0.08 per unit", true),
        CatalogModel("stability-ai/sdxl", "stability-ai", "sdxl", "A text-to-image generative AI model that creates beautiful images",
            86_524_336, false, null, PriceInfo("per-second", usdPerSecond = 0.000975, hardware = "L40S", typicalUsd = 0.0047, source = "model page"),
            "by time · about $0.0047 a run ($0.000975/s on L40S)", true),
    )
    /** Which models each step lists, and why some can't do it. */
    fun forStep(step: String): List<CatalogModel> = MODELS.map { m ->
        val reasons = when {
            step == "upscale" && m.id !in setOf("philz1337x/clarity-upscaler", "topazlabs/image-upscale") -> emptyList()
            step in setOf("realism", "edit", "shot", "dressA", "dressB") && m.id == "topazlabs/image-upscale" -> listOf("has no prompt")
            step in setOf("dressA", "dressB") && m.id in setOf("black-forest-labs/flux-krea-dev", "philz1337x/clarity-upscaler", "stability-ai/sdxl") ->
                listOf("takes one photo · Dress up needs the sheet photo and the outfit")
            step == "edit" && m.id == "stability-ai/sdxl" -> emptyList()
            else -> emptyList()
        }
        val warnings = if (step == "upscale" && m.id !in setOf("philz1337x/clarity-upscaler", "topazlabs/image-upscale")) listOf("no scale control · 2× / 4× do nothing") else emptyList()
        m.copy(compatible = reasons.isEmpty(), reasons = reasons, warnings = warnings)
    }.sortedWith(compareBy<CatalogModel> { it.compatible == false }.thenBy { it.warnings.isNotEmpty() }.thenByDescending { it.runCount })

    fun collections(step: String) = when (step) {
        "upscale" -> listOf(CollectionRef("super-resolution", "Upscale images with super resolution"), CollectionRef("ai-image-restoration", "Restore images"))
        "shot" -> listOf(CollectionRef("text-to-image", "Generate images"), CollectionRef("image-editing", "Edit any image"))
        "realism" -> listOf(CollectionRef("image-editing", "Edit any image"), CollectionRef("text-to-image", "Generate images"))
        else -> listOf(CollectionRef("image-editing", "Edit any image"))
    }
    fun model(id: String) = MODELS.firstOrNull { it.id == id }

    /** Estimate of one prediction (plans/api.md "Model tools" §3). */
    fun estimate(id: String, outMp: Double, inMp: Double, scale: Double? = null): Double {
        val p = model(id)?.price ?: return 0.05
        return when (p.kind) {
            "per-unit" -> p.units.sumOf { u -> u.usd * when (u.metric) { "image_output_megapixel_count" -> outMp; "image_input_megapixel_count" -> inMp; else -> 1.0 } }
            "per-second" -> (p.typicalUsd ?: ((p.usdPerSecond ?: 0.0) * 20)) * (if (scale != null && scale > 2) (scale / 2) * (scale / 2) else 1.0)
            else -> 0.05
        }
    }

    /** features.tools as the owner gets it: the default model of each tool step by name. */
    fun ownerTools(): ToolsFeatures {
        fun n(step: String) = DEFAULTS.getValue(step).let { OwnerModelName(it, model(it)?.name ?: it) }
        return ToolsFeatures(EnhanceFeatures(models = mapOf("realism" to n("realism"), "upscale" to n("upscale"))),
            DressUpFeatures(models = mapOf("dressA" to n("dressA"), "dressB" to n("dressB"))))
    }
}
