package studio.muse.app.ui.screens.suite.composer

import studio.muse.app.AppContainer
import studio.muse.app.ui.Nav
import studio.muse.app.ui.Routes

/**
 * "New shot" (Home, Queue, Library; "Shot" on a model's profile) opens the AI Suite on Shot, with that character picked when there
 * is one (owner, 2026-11-08: the Suite covers the old Source → Direct flow, as on the Mac). The prompt and chips stay;
 * a character token naming someone else gives way, as for [openPhoto].
 */
fun openShot(c: AppContainer, nav: Nav, modelId: String? = null) {
    c.suite.composer.value = shotFor(c.suite.composer.value, modelId)
    c.suite.sheet.value = null
    nav.go(Routes.SUITE_SHOT)
}

/** The draft [openShot] opens: on Shot, with [modelId] as the character when given. */
fun shotFor(d: ComposerDraft, modelId: String?): ComposerDraft {
    val base = if (d.tool == ComposerTool.SHOT) d else d.withTool(ComposerTool.SHOT)
    if (modelId == null) return base
    val t = base.tokens.character?.takeIf { it.id != modelId }?.let { base.tokens.remove(it.key) } ?: base.tokens
    return base.copy(modelId = modelId, tokens = t)
}
