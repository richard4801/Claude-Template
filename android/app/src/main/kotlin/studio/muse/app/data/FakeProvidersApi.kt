package studio.muse.app.data

import kotlinx.coroutines.delay

/**
 * The demo studio's providers (WS7, against WS5's contract v1): one Replicate key already connected, a searchable sample
 * catalog of image and video models, and two models added (one on, one off). A key that doesn't start with the kind's
 * prefix is refused as invalid_key, so the error state can be shown. Nothing leaves the phone.
 */
class FakeProvidersApi(private val now: () -> Long, private val delayMs: Long = 0) : ProvidersApi {
    private val kindList = listOf(
        ProviderKind("replicate", "Replicate", "Starts with r8_", "https://replicate.com/account/api-tokens"),
        ProviderKind("fal", "fal", "A key id and secret, joined with a colon", "https://fal.ai/dashboard/keys"),
    )
    private val list = mutableListOf(
        Provider("p_demo", "replicate", "Studio Replicate", "7Q2k", "ok", 1_762_600_000_000, 1_762_000_000_000),
    )
    private val sample = listOf(
        ProviderCatalogModel("black-forest-labs/flux-1.1-pro", "FLUX 1.1 Pro", "Fast, sharp text-to-image", "image",
            ProviderInputs(prompt = true, aspectRatios = listOf("1:1", "9:16", "16:9"), seed = true), ready = true, price = ProviderPrice("per_run", 0.04)),
        ProviderCatalogModel("bytedance/seedream-4", "Seedream 4", "Image generation and editing with references", "image",
            ProviderInputs(prompt = true, referenceImages = 10, aspectRatios = listOf("1:1", "9:16", "16:9")), ready = true, price = ProviderPrice("per_run", 0.03)),
        ProviderCatalogModel("google/nano-banana", "Nano Banana", "Image editing from references", "image",
            ProviderInputs(prompt = true, referenceImages = 3), ready = true, price = ProviderPrice("per_run", 0.039)),
        ProviderCatalogModel("kwaivgi/kling-v2.5-turbo-pro", "Kling 2.5 Turbo Pro", "Text and image to video", "video",
            ProviderInputs(prompt = true, negativePrompt = true, startImage = true, duration = DurationRange(5, 10, listOf(5, 10)), aspectRatios = listOf("9:16", "16:9", "1:1")),
            ready = true, price = ProviderPrice("per_second", 0.07)),
        ProviderCatalogModel("wan-video/wan-2.5-i2v", "Wan 2.5 i2v", "Image to video with audio", "video",
            ProviderInputs(prompt = true, startImage = true, duration = DurationRange(5, 10), resolutions = listOf("480p", "720p", "1080p")),
            ready = true, price = ProviderPrice("per_second", 0.10)),
        ProviderCatalogModel("someone/odd-video-model", "Odd video model", "Its schema doesn't name a prompt field", "video",
            ProviderInputs(startImage = true), missing = listOf("prompt", "price"), ready = false, price = null),
    )
    private val added = mutableListOf(
        custom("c_demo1", sample[1], displayName = "Seedream", enabled = true, members = false),
        custom("c_demo2", sample[3], displayName = "Kling turbo", enabled = false, members = false),
    )

    private fun custom(id: String, m: ProviderCatalogModel, displayName: String = m.name, enabled: Boolean = false, members: Boolean = false) = CustomModel(
        id, "p_demo", "replicate", m.ref, m.name, displayName, m.kind, enabled, members, if (m.ready) "ready" else "needs_setup", m.missing, m.inputs,
        price = m.price, memberPrice = m.price?.let { MemberPrice(it.basis, it.costUsd) }, createdAt = now(), updatedAt = now(),
    )

    private suspend fun pause() { if (delayMs > 0) delay(delayMs) }
    private fun counts(pid: String) = added.filter { it.providerId == pid }.let { ProviderModelCounts(it.size, it.count { m -> m.enabled }) }
    private fun view(p: Provider) = p.copy(models = counts(p.id))
    private fun provider(id: String) = list.firstOrNull { it.id == id } ?: throw ApiException("not_found", "That provider isn't connected any more")
    private fun check(kind: String, key: String) {
        val ok = when (kind) { "replicate" -> key.startsWith("r8_") && key.length >= 12; "fal" -> ':' in key && key.length >= 12; else -> false }
        if (!ok) throw ApiException("invalid_key", "That key didn't work with ${kindList.firstOrNull { it.kind == kind }?.label ?: kind}. Nothing was saved.")
    }

    override suspend fun kinds() = kindList
    override suspend fun providers(): List<Provider> { pause(); return list.map(::view) }
    override suspend fun add(req: NewProvider): Provider {
        pause(); check(req.kind, req.apiKey.trim())
        val p = Provider("p_${now()}", req.kind, req.label?.ifBlank { null } ?: kindList.first { it.kind == req.kind }.label, req.apiKey.trim().takeLast(4), "ok", now(), now())
        list += p
        return view(p)
    }
    override suspend fun patch(id: String, patch: ProviderPatch): Provider {
        pause()
        var p = provider(id)
        patch.apiKey?.let { k -> check(p.kind, k.trim()); p = p.copy(keyLast4 = k.trim().takeLast(4), status = "ok", checkedAt = now()) }
        patch.label?.let { p = p.copy(label = it) }
        list[list.indexOfFirst { it.id == id }] = p
        return view(p)
    }
    override suspend fun remove(id: String) { pause(); list.removeAll { it.id == id }; added.removeAll { it.providerId == id } }
    override suspend fun catalog(providerId: String, q: String, kind: String?, cursor: String?, limit: Int): ProviderCatalogPage {
        pause(); provider(providerId)
        val hits = sample.filter { (kind == null || it.kind == kind) && (q.isBlank() || it.name.contains(q, true) || it.ref.contains(q, true)) }
            .map { m -> m.copy(added = added.firstOrNull { it.ref == m.ref && it.providerId == providerId }?.let { AddedRef(it.id, it.enabled) }) }
        return ProviderCatalogPage(hits.take(limit), null)
    }
    override suspend fun addModel(providerId: String, req: AddProviderModel): CustomModel {
        pause(); provider(providerId)
        added.firstOrNull { it.ref == req.ref && it.providerId == providerId }?.let { return it }
        val m = sample.firstOrNull { it.ref == req.ref } ?: throw ApiException("not_found", "That model isn't on this provider")
        return custom("c_${now()}", m, req.displayName?.ifBlank { null } ?: m.name).also { added += it }
    }
    override suspend fun models(): List<CustomModel> { pause(); return added.toList() }
    override suspend fun patchModel(modelId: String, patch: CustomModelPatch): CustomModel {
        pause()
        val i = added.indexOfFirst { it.id == modelId }.takeIf { it >= 0 } ?: throw ApiException("not_found", "That model was removed")
        var m = added[i]
        if (patch.enabled == true && !m.ready) throw ApiException("needs_setup", "Finish setting it up first: ${m.missing.joinToString(", ")}")
        patch.enabled?.let { m = m.copy(enabled = it) }
        patch.displayName?.let { m = m.copy(displayName = it.trim()) }
        patch.members?.let { m = m.copy(members = it) }
        patch.price?.let { m = m.copy(price = it.copy(source = "owner"), memberPrice = MemberPrice(it.basis, it.costUsd * m.priceScale)) }
        patch.priceScale?.let { m = m.copy(priceScale = it, memberPrice = m.price?.let { p -> MemberPrice(p.basis, p.costUsd * it) }) }
        m = m.copy(updatedAt = now())
        added[i] = m
        return m
    }
    override suspend fun removeModel(modelId: String) { pause(); added.removeAll { it.id == modelId } }
}
