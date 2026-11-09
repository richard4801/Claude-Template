package studio.muse.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.AddProviderModel
import studio.muse.app.data.ApiException
import studio.muse.app.data.CustomModelPatch
import studio.muse.app.data.NewProvider
import studio.muse.app.data.Provider
import studio.muse.app.data.ProviderCatalogModel
import studio.muse.app.data.ProviderKind
import studio.muse.app.data.ProviderPatch
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.SecureKeyField
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// Settings → Providers (owner; settings redesign 2026-11-09, WS5's "Bring your own provider" contract v1, the Mac's copy).
// Connected providers (the key's last 4, when added, models on), Replace key, Remove; Add a provider (Replicate or fal,
// a secure key field: checked, never shown again); a provider's models with search, filter (All / Video / Image / On),
// on/off, Rename, a Video / Image tag and the price. Members never reach this page.

data class ProvidersState(
    val loading: Boolean = true,
    val providers: List<Provider> = emptyList(),
    val kinds: List<ProviderKind> = emptyList(),
    val keysReady: Boolean = true,
    /** "Add a provider" is open. */
    val adding: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
)

class ProvidersViewModel(private val c: AppContainer) : ViewModel() {
    val state = MutableStateFlow(ProvidersState())
    private val api get() = c.repo.api.providers

    fun load() = viewModelScope.launch {
        try {
            val p = api.providers()
            val k = runCatching { api.kinds() }.getOrDefault(emptyList())
            state.update { it.copy(loading = false, providers = p.providers, keysReady = p.keysReady, kinds = k, error = null) }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) {
            state.update { it.copy(loading = false, error = e.message) }
        }
    }

    fun adding(v: Boolean) = state.update { it.copy(adding = v, error = null) }

    /** Checked with the provider before anything is stored (400 invalid_key: nothing saved). The key is never kept here. */
    fun add(kind: String, key: String) = viewModelScope.launch {
        state.update { it.copy(busy = true, error = null) }
        try {
            api.add(NewProvider(kind, key))
            state.update { it.copy(busy = false, adding = false) }
            load()
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) {
            state.update { it.copy(busy = false, error = e.message) }
        }
    }

    fun replaceKey(id: String, key: String) = viewModelScope.launch {
        state.update { it.copy(busy = true, error = null) }
        try { api.patch(id, ProviderPatch(apiKey = key)); state.update { it.copy(busy = false) }; load() }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { state.update { it.copy(busy = false, error = e.message) } }
    }

    fun remove(id: String) = viewModelScope.launch {
        try { api.remove(id); load(); c.repo.toast("Provider removed") }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { c.repo.toast(e.message ?: "Couldn't remove it") }
    }
}

@Composable
private fun providersVm(): ProvidersViewModel {
    val c = LocalContainer.current
    return viewModel { ProvidersViewModel(c) }
}

/** "Key ending 4f2a, added 8 Nov. 9 of 48 models on." */
fun Provider.line(): String {
    val added = if (createdAt > 0) ", added " + java.text.SimpleDateFormat("d MMM", java.util.Locale.UK).format(java.util.Date(createdAt)) else ""
    return "Key ending $keyLast4$added. ${models.enabled} of ${models.added} models on." + if (invalid) " The key stopped working: replace it." else ""
}

@Composable
fun ProvidersScreen() {
    val vm = providersVm()
    val s by vm.state.collectAsState()
    LaunchedEffect(Unit) { vm.load() }
    SectionPage(SettingsSection.PROVIDERS) { ProvidersContent(s, vm) }
}

@Composable
internal fun ProvidersContent(s: ProvidersState, vm: ProvidersViewModel?) {
    val nav = LocalNav.current
    when {
        s.loading -> SkeletonLines(4)
        s.error != null && s.providers.isEmpty() && !s.adding -> ErrorState("Can't load your providers", s.error, onAction = { vm?.load() })
        else -> {
            if (!s.keysReady) Caption("Provider keys aren't set up on the server yet. Adding a key works once they are.")
            if (s.providers.isEmpty() && !s.adding) EmptyState(
                "No providers yet", "Add an API key for an AI provider you use. Its image and video models can then be picked per shot. Members never see them.",
                "Add a provider", { vm?.adding(true) },
            )
            s.providers.forEach { p ->
                var replacing by remember(p.id) { mutableStateOf(false) }
                var removing by remember(p.id) { mutableStateOf(false) }
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2), modifier = Modifier.testTag("provider_${p.id}")) {
                    RowItem(p.label.ifBlank { p.kind }, p.line(), onClick = { nav.go(studio.muse.app.ui.Routes.providerModels(p.id)) }) { Chevron() }
                    if (replacing) Labeled("Replace the ${p.label.ifBlank { p.kind }} key") { SecureKeyField(p.keyLast4, "Paste the new key", s.busy, s.error, s.keysReady, { k -> vm?.replaceKey(p.id, k); replacing = false },
                        note = "Saved encrypted on the MUSE server, checked with ${p.label.ifBlank { p.kind }} first. Afterwards you only see its last 4 characters.",
                        onCancel = { replacing = false }) }
                    else if (removing) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                        // Removing deletes the key and switches its models off everywhere: name it and ask first.
                        val name = p.label.ifBlank { p.kind }
                        Heading("Remove $name?")
                        Body("Its key is deleted and its models leave the AI Suite.")
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            SecondaryButton("Keep", { removing = false }, Modifier.weight(1f))
                            PrimaryButton("Remove $name", { removing = false; vm?.remove(p.id) }, Modifier.weight(1f))
                        }
                    }
                    else Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                        SecondaryButton("Replace key", { replacing = true }, Modifier.weight(1f))
                        SecondaryButton("Remove", { removing = true }, Modifier.weight(1f))
                    }
                }
            }
            if (s.adding) AddProviderForm(s, vm)
            else if (s.providers.isNotEmpty() && s.keysReady) SecondaryButton("Add a provider", { vm?.adding(true) }, Modifier.fillMaxWidth(), icon = "plus")
        }
    }
}

/** Add a provider: which one, then the key (checked with the provider first; afterwards only its last 4 are shown). */
@Composable
private fun AddProviderForm(s: ProvidersState, vm: ProvidersViewModel?) {
    val kinds = s.kinds.ifEmpty { listOf(ProviderKind("replicate", "Replicate"), ProviderKind("fal", "fal")) }
    var kind by remember { mutableStateOf(kinds.first().kind) }
    val k = kinds.firstOrNull { it.kind == kind } ?: kinds.first()
    SettingsGroup("Add a provider") {
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            Labeled("Provider") { Segmented(kinds.map { it.kind to it.label.ifBlank { it.kind } }, kind, { kind = it }) }
            Labeled("API key") {
                SecureKeyField(null, k.keyHint.ifBlank { "Paste the key" }, s.busy, s.error, s.keysReady, { key -> vm?.add(kind, key) },
                    note = "Saved encrypted on the MUSE server, checked with ${k.label.ifBlank { k.kind }} first. Afterwards you only see its last 4 characters.",
                    onCancel = { vm?.adding(false) })
                k.keyUrl?.takeIf { it.startsWith("https://") }?.let { url ->
                    val uri = androidx.compose.ui.platform.LocalUriHandler.current
                    TextAction("Where to find your ${k.label.ifBlank { k.kind }} key", { runCatching { uri.openUri(url) } })
                }
            }
        }
    }
}

// ---------------------------------------------------------------- a provider's models

data class ProviderModelsState(
    val provider: Provider? = null,
    val q: String = "",
    /** all | video | image | on */
    val filter: String = "all",
    val models: List<ProviderCatalogModel> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
)

class ProviderModelsViewModel(private val c: AppContainer, private val providerId: String) : ViewModel() {
    val state = MutableStateFlow(ProviderModelsState())
    private val api get() = c.repo.api.providers
    private var search: Job? = null

    fun load() = viewModelScope.launch {
        val p = runCatching { api.providers().providers.firstOrNull { it.id == providerId } }.getOrNull()
        state.update { it.copy(provider = p) }
        fetch()
    }

    private suspend fun fetch() {
        val s = state.value
        try {
            val kind = s.filter.takeIf { it == "video" || it == "image" }
            val page = api.catalog(providerId, s.q, kind, null, 50)
            state.update { it.copy(models = page.models, loading = false, error = null) }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) {
            state.update { it.copy(loading = false, error = e.message) }
        }
    }

    fun query(q: String) {
        state.update { it.copy(q = q) }
        search?.cancel(); search = viewModelScope.launch { delay(300); fetch() }
    }

    fun filter(f: String) { state.update { it.copy(filter = f) }; viewModelScope.launch { fetch() } }

    /** On: added (if it isn't yet) and switched on; Off: switched off. 409 needs_setup says what's missing. */
    fun toggle(m: ProviderCatalogModel, on: Boolean) = viewModelScope.launch {
        try {
            val id = m.added?.id ?: api.addModel(providerId, AddProviderModel(m.ref)).id
            api.patchModel(id, CustomModelPatch(enabled = on))
            fetch()
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { c.repo.toast(e.message ?: "Couldn't change it") }
    }

    fun rename(m: ProviderCatalogModel, name: String) = viewModelScope.launch {
        try {
            val id = m.added?.id ?: api.addModel(providerId, AddProviderModel(m.ref, name)).id
            api.patchModel(id, CustomModelPatch(displayName = name.trim()))
            fetch(); c.repo.toast("Renamed")
        } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) { c.repo.toast(e.message ?: "Couldn't rename it") }
    }
}

@Composable
fun ProviderModelsScreen(providerId: String) {
    val c = LocalContainer.current
    val vm: ProviderModelsViewModel = viewModel(key = "provider-$providerId") { ProviderModelsViewModel(c, providerId) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    LaunchedEffect(providerId) { vm.load() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize().testTag("provider_models")) {
            CalmTopBar("${s.provider?.label?.ifBlank { null } ?: "Provider"} models", onBack = { nav.back() })
            ProviderModelsContent(s, onQuery = vm::query, onFilter = vm::filter, onToggle = vm::toggle, onRename = vm::rename)
        }
    }
}

@Composable
internal fun ProviderModelsContent(
    s: ProviderModelsState, onQuery: (String) -> Unit, onFilter: (String) -> Unit,
    onToggle: (ProviderCatalogModel, Boolean) -> Unit, onRename: (ProviderCatalogModel, String) -> Unit,
) {
    val shown = if (s.filter == "on") s.models.filter { it.added?.enabled == true } else s.models
    Column(Modifier.fillMaxSize().padding(horizontal = MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Segmented(listOf("all" to "All", "video" to "Video", "image" to "Image", "on" to "On"), s.filter, onFilter)
        Input(s.q, onQuery, placeholder = "Search ${s.provider?.label?.ifBlank { null } ?: "the provider's"} models", calm = true)
        when {
            s.loading -> SkeletonLines(5)
            s.error != null -> ErrorState("Can't load the models", s.error, action = null)
            shown.isEmpty() -> Caption(if (s.filter == "on") "No models switched on yet." else "No models match.")
            else -> LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                items(shown, key = { it.ref }) { mdl -> ProviderModelRow(mdl, onToggle, onRename) }
            }
        }
    }
}

/** One model: its name (or the studio's name for it), the provider's id for it, Video / Image, the price, on/off and Rename. */
@Composable
private fun ProviderModelRow(mdl: ProviderCatalogModel, onToggle: (ProviderCatalogModel, Boolean) -> Unit, onRename: (ProviderCatalogModel, String) -> Unit) {
    val m = muse
    var renaming by remember(mdl.ref) { mutableStateOf(false) }
    var name by remember(mdl.ref) { mutableStateOf(mdl.name) }
    val on = mdl.added?.enabled == true
    val price = mdl.price?.let { p -> if (p.perSecond) "${studio.muse.app.ui.screens.suite.composer.ModelPicker.perSec(p.costUsd)}" else studio.muse.app.ui.screens.suite.composer.ModelPicker.money(p.costUsd) }
    Column(Modifier.fillMaxWidth().padding(vertical = MuseSpace.s1), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Column(Modifier.weight(1f).semantics(mergeDescendants = true) { contentDescription = "${mdl.name}, ${mdl.ref}" }) {
                T(mdl.name.ifBlank { mdl.ref }, m.scale.body, m.roles.ink, maxLines = 1)
                T(listOfNotNull(if (mdl.kind == "video") "Video" else "Image", mdl.ref, price).joinToString(", "), m.scale.caption, m.roles.ink2, maxLines = 1)
                if (!mdl.ready) T("Needs a setting MUSE can't fill in yet: ${mdl.missing.joinToString(", ").ifBlank { "details" }}", m.scale.caption, m.roles.caution, maxLines = 2)
            }
            Toggle(on, { onToggle(mdl, !on) }, Modifier.semantics { contentDescription = "Use ${mdl.name}" })
        }
        if (renaming) Labeled("Rename model") {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                Input(name, { name = it.take(60) }, Modifier.weight(1f), calm = true)
                TextAction("Save", { onRename(mdl, name); renaming = false })
            }
            Caption("The name you see in the AI Suite's model picker.")
        } else TextAction("Rename", { renaming = true })
    }
}
