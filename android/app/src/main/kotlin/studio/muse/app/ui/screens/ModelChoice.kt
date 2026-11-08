package studio.muse.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.ApiException
import studio.muse.app.data.ModelPurpose
import studio.muse.app.data.ModelsForPurpose
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.composer.ModelList
import studio.muse.app.ui.screens.suite.composer.ModelPicker
import studio.muse.app.ui.screens.suite.composer.PickerEngine
import studio.muse.app.ui.screens.suite.composer.PickerGroups
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// "Pick the model everywhere" (owner, 2026-11-08): the same owner-only picker as Shot and Photo on every surface that
// runs an image or video model. A surface puts [ModelChoiceRow] where its settings are, keeps the pick, and sends it
// (engineModel / imageModel) with its request. Members never see any of it.

/** Whether this account is the studio owner (the wallet's word, else the signed-in role). */
fun AppContainer.isOwner(): Boolean = repo.state.value.wallet?.owner ?: prefs.value.owner

/** A pick: the model id and its resolution (null = Auto, the studio's default). */
data class ModelPick(val model: String? = null, val resolution: String? = null)

/**
 * The models for [purpose]: WS13's list (GET /v1/models) when the server has it; else the Suite catalog's engines of the
 * purpose's kind (shots and photos, before WS13 lands). Null while loading.
 */
@Composable
fun rememberModelOptions(purpose: ModelPurpose): ModelsForPurpose? {
    val c = LocalContainer.current
    val cat by c.suite.catalog.collectAsState()
    return produceState<ModelsForPurpose?>(null, purpose, cat) {
        value = try { c.repo.api.modelChoice.models(purpose) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) {
            // Before WS13: only shots and photos have a list (the catalog's engines); the rest show no row.
            if (purpose == ModelPurpose.SHOT || purpose == ModelPurpose.PHOTO) cat?.engines?.filter { it.kind == purpose.kind }?.let { ModelsForPurpose(purpose.id, null, it) }
            else ModelsForPurpose(purpose.id, null, emptyList())
        }
    }.value
}

/** The options as the picker groups them: on [quality]'s ladder, the others, the studio's own. */
fun ModelsForPurpose.groups(purpose: ModelPurpose, quality: String?): PickerGroups =
    ModelPicker.groups(SuiteCatalog(engines = models), quality ?: "", if (purpose.kind == "image") "image" else "video").let { g -> if (quality == null) PickerGroups(emptyList(), g.ladder + g.others, g.custom) else g }

/** "Kling 4.0, 1080p", or "Auto" (then the studio's default, when it has one: "Auto (Kling 4.0)"). */
fun ModelsForPurpose?.label(pick: ModelPick): String {
    val all = this?.models.orEmpty()
    fun name(id: String?, res: String?) = all.firstOrNull { it.model == id }?.let { e -> e.name + (res?.let { r -> ", " + (e.resolutions.firstOrNull { it.id == r }?.label?.substringBefore(' ') ?: r) } ?: "") }
    return pick.model?.let { name(it, pick.resolution) ?: it } ?: this?.default?.let { d -> name(d, null)?.let { "Auto ($it)" } } ?: "Auto"
}

/**
 * The owner's Model row for any surface: "Model" with the pick under it and "Only you see models" on the right; a tap
 * opens the list. Shows nothing for members, or when the server lists no models for [purpose].
 */
@Composable
fun ModelChoiceRow(purpose: ModelPurpose, pick: ModelPick, onPick: (ModelPick) -> Unit, modifier: Modifier = Modifier, quality: String? = null) {
    val c = LocalContainer.current
    if (!c.isOwner()) return
    val options = rememberModelOptions(purpose)
    if (options != null && options.models.isEmpty()) return
    val m = muse
    var open by remember { mutableStateOf(false) }
    Row(
        modifier.fillMaxWidth().heightIn(min = 56.dp).press { open = true }
            .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Model for ${purpose.label}: ${options.label(pick)}. Only you see models" }
            .testTag("model_choice_${purpose.id}"),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            T("Model", m.scale.body, m.roles.ink, maxLines = 1)
            T(options.label(pick), m.scale.caption, m.roles.ink2, maxLines = 1)
        }
        T("Only you see models", m.scale.caption, m.roles.ink2, maxLines = 1)
        Chevron()
    }
    if (open && options != null) ModelChoiceDialog(purpose, options, pick, quality, onClose = { open = false }) { p -> onPick(p); open = false }
}

/** The list, full screen: Auto ("The studio's default"), then the purpose's models with their limits and prices. */
@Composable
fun ModelChoiceDialog(purpose: ModelPurpose, options: ModelsForPurpose, pick: ModelPick, quality: String?, onClose: () -> Unit, onPick: (ModelPick) -> Unit) {
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        ModelChoiceContent(purpose, options, pick, quality, onClose, onPick)
    }
}

/** [ModelChoiceDialog]'s content (screenshot tests render it). */
@Composable
fun ModelChoiceContent(purpose: ModelPurpose, options: ModelsForPurpose, pick: ModelPick, quality: String?, onClose: () -> Unit, onPick: (ModelPick) -> Unit) {
    val m = muse
    val autoLine = options.default?.let { d -> options.models.firstOrNull { it.model == d }?.name?.let { "The studio's default: $it" } }
        ?: "MUSE picks the model for ${purpose.label.lowercase()}"
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize().testTag("model_choice")) {
            CalmTopBar("Model for ${purpose.label.lowercase()}", onBack = onClose)
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                Caption("Only you see models. Members keep the quality choices.")
                ModelList(pick.model, pick.resolution, quality, options.groups(purpose, quality), autoLine) { e: PickerEngine?, r: String? ->
                    onPick(ModelPick(e?.id, r ?: e?.let { quality?.let(it::resolutionOn) ?: it.resolution }))
                }
            }
        }
    }
}

/**
 * Settings → Default models (owner): one row per purpose with its default; a tap opens the same list and sets the
 * studio's default (Auto = MUSE picks). Every surface's "Auto" then means this default.
 */
@Composable
fun DefaultModelsScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val scope = rememberCoroutineScope()
    val m = muse
    var loaded by remember { mutableStateOf<Map<ModelPurpose, ModelsForPurpose>>(emptyMap()) }
    var error by remember { mutableStateOf<String?>(null) }
    var editing by remember { mutableStateOf<ModelPurpose?>(null) }
    LaunchedEffect(Unit) {
        try { loaded = ModelPurpose.entries.associateWith { c.repo.api.modelChoice.models(it) } }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { error = e.message }
    }
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Default models", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                Caption("What \"Auto\" uses for each kind of work. You can still pick another model each time. Only you see models.")
                when {
                    error != null -> ErrorState("Can't load the models", error ?: "", action = null)
                    loaded.isEmpty() -> SkeletonLines(6)
                    else -> DefaultModelsList(loaded) { editing = it }
                }
            }
        }
    }
    editing?.let { p ->
        val opts = loaded[p] ?: return@let
        ModelChoiceDialog(p, opts.copy(default = null), ModelPick(opts.default), null, onClose = { editing = null }) { pick ->
            editing = null
            scope.launch {
                try { loaded = loaded + (p to c.repo.api.modelChoice.setDefault(p, pick.model)); c.repo.toast("${p.label}: ${loaded[p].label(ModelPick(pick.model))}") }
                catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { c.repo.toast(e.message ?: "Couldn't save the default") }
            }
        }
    }
}

/** One row per purpose (purposes the server lists no models for are left out). */
@Composable
fun DefaultModelsList(loaded: Map<ModelPurpose, ModelsForPurpose>, onEdit: (ModelPurpose) -> Unit) {
    ModelPurpose.entries.filter { loaded[it]?.models?.isNotEmpty() == true }.forEach { p ->
        val o = loaded[p]!!
        RowItem(p.label, o.default?.let { d -> o.models.firstOrNull { it.model == d }?.name } ?: "Auto: MUSE picks", onClick = { onEdit(p) }) { Chevron() }
    }
}
