package studio.muse.app.data

/**
 * Applies one live event (GET /v1/events) to the studio state, so a change made on another device (the Mac, a member's
 * phone) shows up here within a second or two. Pure: side effects (toasts, notifications) stay in [MuseRepository].
 */
object LiveEvents {
    /** An outfit deleted: out of the list and her outfits. */
    fun dropOutfit(s: StudioState, id: String): StudioState =
        s.copy(outfits = s.outfits.filterNot { it.id == id }, models = s.models.map { if (id in it.outfitIds) it.copy(outfitIds = it.outfitIds - id) else it })

    fun apply(s0: StudioState, ev: ApiEvent, owner: Boolean): StudioState {
        var s = s0
        val delete = ev.op == "delete"
        ev.balance?.let { s = s.copy(balance = it) }
        ev.wallet?.let { s = s.copy(wallet = it) }
        when (ev.type) {
            "model" -> s = when {
                delete && ev.id != null -> dropModel(s, ev.id)
                // An archived model drops out of every list (and her outfits with her).
                ev.model?.archived == true -> s.copy(models = s.models.filterNot { it.id == ev.model.id })
                ev.model != null -> s.copy(models = s.models.upsert(ev.model) { it.id == ev.model.id })
                else -> s
            }
            "outfit" -> {
                if (delete && ev.id != null) s = dropOutfit(s, ev.id)
                else ev.outfit?.let { o ->
                    s = s.copy(outfits = s.outfits.upsert(o) { it.id == o.id },
                        models = if (o.state == "ready") s.models.map { if (it.id == o.modelId && o.id !in it.outfitIds) it.copy(outfitIds = it.outfitIds + o.id) else it } else s.models)
                }
            }
            "tool" -> ev.tool?.let { t -> s = s.copy(toolRuns = s.toolRuns + (t.id to t)) }
            "lora" -> ev.lora?.let { l -> s = s.copy(loras = s.loras + (l.modelId to l)) }
            "post" -> s = when {
                delete && ev.id != null -> s.copy(posts = s.posts.filterNot { it.id == ev.id })
                ev.post != null -> s.copy(posts = s.posts.upsert(ev.post) { it.id == ev.post.id })
                else -> s
            }
            "account" -> {
                val m = ev.modelId ?: ev.account?.modelId
                if (m != null) {
                    val p = ev.account?.platform ?: ev.platform
                    val rest = s.accountsOf(m).filterNot { it.platform == p }
                    s = s.copy(accounts = s.accounts + (m to (if (delete) rest else rest + listOfNotNull(ev.account))))
                }
            }
            "take" -> s = when {
                delete && ev.id != null -> s.copy(takes = s.takes.filterNot { it.id == ev.id })
                ev.take != null -> s.copy(takes = putTakes(s.takes, listOf(ev.take)))
                else -> s
            }
            "job" -> if (delete && ev.id != null) s = s.copy(jobs = s.jobs.filterNot { it.id == ev.id })
            "template" -> s = when {
                delete && ev.id != null -> s.copy(templates = s.templates.filterNot { it.id == ev.id })
                // Keep the detail screen's recent stills: the event doesn't carry them.
                ev.template != null -> s.copy(templates = s.templates.upsert(ev.template.copy(recent = ev.template.recent ?: s.templates.firstOrNull { it.id == ev.template.id }?.recent)) { it.id == ev.template.id })
                else -> s
            }
            "settings" -> ev.settings?.features?.let { f ->
                s = s.copy(video = f.video ?: s.video, photo = f.photo?.prices ?: s.photo, tools = f.tools ?: s.tools)
            }
            "studio" -> if (owner) ev.studioBalance?.let { s = s.copy(studioBalance = it) }
        }
        if (ev.takes.isNotEmpty()) s = s.copy(takes = putTakes(s.takes, ev.takes))
        ev.job?.let { j -> if (!delete) s = s.copy(jobs = s.jobs.upsert(j) { it.id == j.id }.sortedByDescending { it.createdAt }) }
        return s
    }

    /** New takes go first (newest at the top), changed ones replace theirs in place. */
    fun putTakes(list: List<Take>, add: List<Take>): List<Take> {
        val known = list.map { it.id }.toSet()
        val fresh = add.filter { it.id !in known }.sortedByDescending { it.createdAt }
        val changed = add.filter { it.id in known }.associateBy { it.id }
        return fresh + list.map { changed[it.id] ?: it }
    }

    /** A deleted model takes her outfits, LoRA, accounts and unsent posts with her (the server deletes them too). */
    fun dropModel(s: StudioState, id: String) = s.copy(models = s.models.filterNot { it.id == id }, outfits = s.outfits.filterNot { it.modelId == id },
        loras = s.loras - id, accounts = s.accounts - id, posts = s.posts.filterNot { it.modelId == id && !it.out })

    private inline fun <T> List<T>.upsert(item: T, match: (T) -> Boolean): List<T> =
        if (any(match)) map { if (match(it)) item else it } else listOf(item) + this
}
