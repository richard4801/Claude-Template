package studio.muse.app.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import studio.muse.app.BuildConfig
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles

// Settings redesign (owner-approved 2026-11-09; plans/settings-redesign.md, the Mac's copy by WS6). The Settings tab is one
// list of sections, each its own page: Account, Studio, Members (owner), AI & spending, Providers (owner), Apps & devices
// (owner) and Advanced (owner, once turned on under Account). Members get Account, Studio and AI & spending, with no
// provider or model names. One word: "Models", never "engines".

/** A section of Settings: its title, the one plain line under it (the Mac's), its route and who sees it. */
enum class SettingsSection(val title: String, val line: String, val route: String, val ownerOnly: Boolean) {
    ACCOUNT("Account", "You, how MUSE looks, and when it tells you things.", Routes.SETTINGS_ACCOUNT, false),
    STUDIO("Studio", "How new videos and photos start, the studio's prompts, and archived models.", Routes.SETTINGS_STUDIO, false),
    MEMBERS("Members", "Who works in the studio, what each person can spend, and invitations.", Routes.MEMBERS, true),
    AI("AI & spending", "Your balance, spend caps and the models behind each quality.", Routes.SETTINGS_AI, false),
    PROVIDERS("Providers", "Your own accounts with AI providers. Their models join the AI Suite's model picker.", Routes.SETTINGS_PROVIDERS, true),
    APPS("Apps & devices", "Claude, Blender and your phone working with MUSE.", Routes.SETTINGS_APPS, true),
    ADVANCED("Advanced", "Server, testing and performance tools. Hidden unless turned on under Account.", Routes.SETTINGS_ADVANCED, true);

    companion object {
        /** The sections this person sees, in order. Members: Account, Studio, AI & spending. Advanced only once turned on. */
        fun visible(owner: Boolean, showAdvanced: Boolean) = entries.filter { (owner || !it.ownerOnly) && (it != ADVANCED || showAdvanced) }
    }
}

/** A section page: the title bar, its one line, then its groups separated by space. */
@Composable
internal fun SectionPage(section: SettingsSection, content: @Composable ColumnScope.() -> Unit) {
    val nav = LocalNav.current
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize().testTag("settings_${section.name.lowercase()}")) {
            CalmTopBar(section.title, onBack = { nav.back() })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s1, bottom = 60.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s6),
            ) {
                Caption(section.line)
                content()
            }
        }
    }
}

/** A group inside a section: its heading and rows, close together. */
@Composable
internal fun SettingsGroup(title: String, hint: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading(title)
        hint?.let { Caption(it) }
        Column { content() }
    }
}

// ---------------------------------------------------------------- Account

@Composable
fun AccountSettingsScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val context = LocalContext.current
    var notifOn by remember { mutableStateOf(vm.notifStatus()) }
    var notifAskedHere by remember { mutableStateOf(false) }
    LifecycleResumeEffect(Unit) { notifOn = vm.notifStatus(); onPauseOrDispose {} }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { notifOn = it }
    val studio by vm.c.repo.state.collectAsState()
    val preview = remember(studio.models, studio.outfits) { previewProfileState(studio, vm.demo) }
    SectionPage(SettingsSection.ACCOUNT) {
        // Who you are, and Sign out, at the top.
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Heading(s.prefs.studioName.ifBlank { "Your studio" })
            Caption(listOf(s.prefs.email.ifBlank { null }, if (s.prefs.owner) "owner" else "member of ${s.prefs.studioName.ifBlank { "the studio" }}").filterNotNull().joinToString(", "))
            SecondaryButton("Sign out", { vm.signOut { nav.reset(Routes.WELCOME) } }, Modifier.fillMaxWidth())
        }
        SettingsGroup("Appearance") {
            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                ThemeId.entries.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                        row.forEach { t -> ThemeCard(t, t.key == s.prefs.theme, Modifier.weight(1f), preview) { vm.theme(t) } }
                    }
                }
            }
        }
        SettingsGroup("Notifications", "Renders finished or failed, a low balance and posting times. Sound and banners follow your phone's settings.") {
            RowItem("Notifications on this phone", onClick = {
                // Off on Android 13+: ask once from here; after that (or when on) open the system page.
                if (!notifOn && Build.VERSION.SDK_INT >= 33 && !notifAskedHere) { notifAskedHere = true; notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
                else vm.openNotificationSettings(context)
            }) { RowValue(if (notifOn) "On" else "Off"); Chevron() }
        }
        SettingsGroup("About") {
            RowItem("Version") { RowValue(BuildConfig.VERSION_NAME) }
            // Model names are owner-only; the owner sees the licence attribution.
            Caption(if (s.prefs.owner) "MiniMax H3 licence terms apply." else "Third-party model licence terms apply.")
        }
        if (s.prefs.owner) Column {
            RowItem("Show advanced settings", "Server, testing and performance tools", onClick = { vm.showAdvanced(!s.prefs.showAdvanced) }) {
                Toggle(s.prefs.showAdvanced, { vm.showAdvanced(!s.prefs.showAdvanced) })
            }
        }
    }
}

// ---------------------------------------------------------------- Studio

@Composable
fun StudioSectionScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    SectionPage(SettingsSection.STUDIO) {
        SettingsGroup("New videos and photos") {
            Labeled("Start at") {
                Segmented(listOf("draft" to "Draft", "standard" to "Standard", "hd" to "HD", "cinema" to "Cinema"), s.prefs.startAt, vm::startAt)
                Caption("The quality new videos use. Change it per shot in the AI Suite.")
            }
            RowItem("Test renders are kept for") { RowValue("30 days") }
        }
        SettingsGroup("Posting") {
            s.modelName?.let { name -> RowItem("$name's accounts", onClick = { nav.go(Routes.ACCOUNTS) }) { RowValue("${s.connected} of 5"); Chevron() } }
            RowItem("Scheduled posts", onClick = { nav.go(Routes.POSTS) }) { RowValue("${s.scheduled}"); Chevron() }
        }
        if (s.prefs.owner) {
            SettingsGroup("Prompts and house style") {
                RowItem("Prompt library", "The house style added to every photo, and each prompt MUSE writes", onClick = { nav.go(Routes.PROMPTS) }) { Chevron() }
            }
            SettingsGroup("Links") { LinkRulesRow() }
            SettingsGroup("Archived models") {
                RowItem("Show archived models", "Hidden from every list. Their photos, renders and posts are kept.",
                    onClick = { nav.go(Routes.ARCHIVED) }) { Chevron() }
            }
        }
    }
}

// ---------------------------------------------------------------- AI & spending

@Composable
fun AiSpendingScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    SectionPage(SettingsSection.AI) {
        SettingsGroup("Credit") {
            RowItem("Balance", onClick = { nav.go(Routes.CREDITS) }) { RowValue(creditLabel(s.wallet, s.balance)); Chevron() }
            s.wallet?.let { w -> RowItem("This month") { RowValue(studio.muse.core.Pricing.money(w.monthUsd)) } }
            if (s.prefs.owner) TextAction("Add credit", { nav.go(Routes.CREDITS) }) else TextAction("Open credit", { nav.go(Routes.CREDITS) })
        }
        if (s.prefs.owner) OwnerAiSpending()
        else SettingsGroup("Spend caps", "Set by the studio owner") {}
    }
}

/** The owner's half of AI & spending: caps, AI editing helpers, Default models, and the disclosures. */
@Composable
private fun OwnerAiSpending() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    LaunchedEffect(Unit) { vm.loadSettings() }
    val st = s.settings
    SettingsGroup("Spend caps", "Running jobs count towards today.") {
        if (st == null) SkeletonLines(3) else CapsForm(vm, st, s)
    }
    EditorHelpersSection()
    SettingsGroup("Default models", "What “Auto” uses for each kind of work. You can still pick another model each time. Only you see models.") {
        RowItem("Default models", "Shots, photos, swaps, upscale and the rest", onClick = { nav.go(Routes.DEFAULT_MODELS) }) { Chevron() }
    }
    SettingsGroup("Models and our own GPUs", "Status, GPU limits, the photo service and price corrections") {
        RowItem("Our own GPUs", st?.let { "${it.maxGpus} at once, off after ${it.engines?.keepReady?.idleMinutes ?: it.warmIdleMinutes} idle minutes" }, onClick = { nav.go(Routes.SETTINGS_GPUS) }) { Chevron() }
        RowItem("Price corrections", "Each model's price and the qualities that use it", onClick = { nav.go(Routes.SUITE_ENGINES) }) { Chevron() }
        RowItem("Photo models by step", "The model behind each photo step: new shots, edits, Enhance and Dress up", onClick = { nav.go(Routes.IMAGE_MODELS) }) { Chevron() }
        RowItem("Model status", modelStatusLine(st), onClick = { nav.go(Routes.SETTINGS_MODEL_STATUS) }) { Chevron() }
    }
}

/** AI & spending → Our own GPUs (owner). */
@Composable
fun OwnGpusScreen() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    LaunchedEffect(Unit) { vm.loadSettings() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Our own GPUs", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                Caption("Edit, Fast · beta and Upscale run on the studio's own GPUs.")
                s.settings?.let { OwnGpusForm(vm, it, s) } ?: SkeletonLines(4)
            }
        }
    }
}

/** AI & spending → Model status (owner): each model service, its key and status. */
@Composable
fun ModelStatusScreen() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    LaunchedEffect(Unit) { vm.loadSettings() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Model status", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                Caption("Members only ever see results, time and price. Models, keys and GPUs live here.")
                s.settings?.let { ModelStatusList(it) } ?: SkeletonLines(4)
            }
        }
    }
}

// ---------------------------------------------------------------- Apps & devices

@Composable
fun AppsDevicesScreen() {
    val nav = LocalNav.current
    SectionPage(SettingsSection.APPS) {
        SettingsGroup("Claude and Blender", "Chat with Claude inside MUSE, connect your Claude apps with a token, and run Blender for Directed shots.") {
            RowItem("Claude apps and Blender", "Tokens, setup guide and the Blender relay", onClick = { nav.go(Routes.CONNECTIONS) }) { Chevron() }
        }
        SettingsGroup("Phones") {
            RowItem("MUSE for Android", "This phone. Renders finished here show up on the Mac too.") { RowValue("This phone") }
        }
    }
}

// ---------------------------------------------------------------- Advanced

@Composable
fun AdvancedSettingsScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    SectionPage(SettingsSection.ADVANCED) {
        SettingsGroup("Server") {
            RowItem("Demo mode (no server)", "The sample studio, in the app", onClick = { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } }) {
                Toggle(s.prefs.useFake, { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } })
            }
            if (!s.prefs.useFake) Labeled("Server address", Modifier.padding(vertical = MuseSpace.s2)) {
                Input(s.prefs.serverUrl, vm::serverUrl, placeholder = BuildConfig.DEFAULT_SERVER_URL, keyboard = androidx.compose.ui.text.input.KeyboardType.Uri, calm = true)
                Caption("Remote servers need HTTPS")
                if (s.prefs.serverUrl != BuildConfig.DEFAULT_SERVER_URL) TextAction("Use the MUSE server", { vm.resetServer { nav.reset(Routes.WELCOME) } })
            }
        }
        SettingsGroup("Testing") {
            RowItem("Fast · beta", "Show the Fast · beta option", onClick = { vm.fastBeta() }) { Toggle(s.prefs.fastBeta, { vm.fastBeta() }) }
            // A demo-studio test switch: the real server has no such thing.
            if (vm.demo) RowItem("Fail the next render", "Stops partway and refunds, to test failure handling", onClick = { vm.failNext() }) { Toggle(s.failNext, { vm.failNext() }) }
            RowItem("Reload everything", "Fetches models, outfits, jobs, takes and balance again", onClick = { vm.reload() }) { RowValue("Reload") }
        }
        if (s.prefs.owner) OwnerPhotoService()
    }
}

@Composable
private fun OwnerPhotoService() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    LaunchedEffect(Unit) { vm.loadSettings() }
    SettingsGroup("Photo service", "Makes character-sheet angles, outfit sets and photos. Members pay exactly what each photo costs.") {
        PhotoServiceForm(vm, s)
    }
}
