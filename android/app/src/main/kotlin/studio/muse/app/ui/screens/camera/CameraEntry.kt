package studio.muse.app.ui.screens.camera

// Workstream 2's entry points (agreed with workstream 1, who wires navigation and the Settings row):
//  - CameraStageScreen(): the Video suite's "Camera stage" mode (route "camera-stage"); owns its own list → session navigation.
//  - DirectedModePanel(shotTitle, onApply): the "Directed · Blender" tab of the Camera bag / Shot builder; onApply gets a CameraSpec JSON.
//  - ConnectionsScreen(onBack): owner Settings → Connections.
// Owner only: members see a short note instead.

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.McpToken
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Cta
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.T
import studio.muse.app.ui.theme.muse

/** Wide windows get D6 (plan, timeline and chat side by side). */
val WIDE = 840.dp

@Composable
private fun OwnerOnly(content: @Composable () -> Unit) {
    val c = LocalContainer.current
    val prefs by c.prefs.collectAsState()
    if (c.repo.demo || prefs.owner || c.repo.state.value.wallet?.owner == true) content()
    else Box(Modifier.fillMaxSize().background(muse.t.bg).padding(24.dp), contentAlignment = Alignment.Center) {
        T("Directed camera sessions are for the studio owner.", muse.type.tiny, muse.t.muted, align = TextAlign.Center)
    }
}

/** A store for this screen, fed by the app's live `camera` / `blender` events. */
@Composable
fun rememberCameraStore(): CameraStore {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val store = remember(c) { CameraStore({ c.repo.api.camera }, scope) }
    LaunchedEffect(store) { c.repo.live.collect { store.onLive(it) } }
    return store
}

/** The clock for "2 min ago" and the 5-minute "your Claude app" rule. */
@Composable
fun rememberNow(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); now = System.currentTimeMillis() } }
    return now
}

@Composable
private fun chatActions(store: CameraStore, c: AppContainer, onBack: () -> Unit, onConnections: () -> Unit, use: (() -> Unit)?, useLabel: String): ChatActions {
    val clip = LocalClipboardManager.current
    return ChatActions(
        send = store::send, back = onBack, openConnections = onConnections,
        copyId = { id -> clip.setText(AnnotatedString(id)); c.repo.toast("Session id copied · say “Open camera session $id” to your Claude") },
        use = use, useLabel = useLabel, dismissNotice = store::dismissNotice,
    )
}

private fun paneActions(store: CameraStore, back: (() -> Unit)?) =
    PaneActions(store::setPlayhead, store::dragCharacter, store::dragCamera, { store.rerender() }, back)

/** The Video suite's "Camera stage": the sessions list → a session (phone: M5 Direct with Claude; wide: D6). */
@Composable
fun CameraStageScreen() = OwnerOnly {
    val c = LocalContainer.current
    val store = rememberCameraStore()
    val ui by store.ui.collectAsState()
    val now = rememberNow()
    val scope = rememberCoroutineScope()
    var openId by rememberSaveable { mutableStateOf<String?>(null) }
    var connections by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) { store.loadList() }
    LaunchedEffect(openId) { openId?.let { store.open(it) } ?: store.close() }
    if (connections) { ConnectionsScreen { connections = false }; BackHandler { connections = false }; return@OwnerOnly }
    if (openId != null) BackHandler { openId = null; store.loadList() }
    val draft: () -> Unit = {
        scope.launch {
            store.handoff().onSuccess {
                val usd = store.ui.value.session?.shotDraft?.estimate?.usd
                c.repo.toast("Shot draft ready" + (usd?.let { " · est. ${SessionText.money(it)}" } ?: "") + " · open it in the Shot builder to generate")
            }.onFailure { c.repo.toast(it.message ?: "Couldn't make a draft") }
        }
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= WIDE
        val id = openId
        when {
            id == null -> CameraSessionsListContent(ui, onOpen = { openId = it }, onNew = {
                val cast = c.repo.state.value.models.take(2).map { it.id }
                store.newSession("New camera session", cast) { openId = it }
            })
            wide -> DirectedCameraPaneContent(ui, now, chatActions(store, c, { openId = null }, { connections = true }, draft, "Make a Shot draft"),
                paneActions(store) { openId = null; store.loadList() })
            else -> DirectWithClaudeContent(ui, now, chatActions(store, c, { openId = null; store.loadList() }, { connections = true }, draft, "Make a Shot draft"))
        }
    }
}

/**
 * The "Directed · Blender" tab of the Camera bag and the Shot builder: pick or start a camera session, see it compactly
 * (phone: session card, status, plan and "Open Direct with Claude"; wide: the D6 pane), and "Use for this shot" →
 * [onApply] with the CameraSpec JSON (`{"mode":"directed","guide":{…}}`) from the session's Shot draft (made first if needed).
 */
@Composable
fun DirectedModePanel(shotTitle: String, onApply: (String) -> Unit) = OwnerOnly {
    val m = muse
    val c = LocalContainer.current
    val store = rememberCameraStore()
    val ui by store.ui.collectAsState()
    val now = rememberNow()
    val scope = rememberCoroutineScope()
    var chatOpen by remember { mutableStateOf(false) }
    var connections by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { store.loadList() }
    // Open the newest session once the list arrives.
    LaunchedEffect(ui.listLoaded, ui.sessions.firstOrNull()?.id) { if (ui.openId == null) ui.sessions.firstOrNull()?.let { store.open(it.id) } }
    val apply: () -> Unit = {
        scope.launch {
            store.handoff().onSuccess { onApply(it.cameraJson()) }.onFailure { c.repo.toast(it.message ?: "No guides yet") }
        }
    }
    val useLabel = "Use for ${shotTitle.ifBlank { "this shot" }}"
    if (connections) { Dialog({ connections = false }, DialogProperties(usePlatformDefaultWidth = false)) { ConnectionsScreen { connections = false } }; }
    if (chatOpen) Dialog({ chatOpen = false }, DialogProperties(usePlatformDefaultWidth = false)) {
        DirectWithClaudeContent(ui, now, chatActions(store, c, { chatOpen = false }, { connections = true }, { chatOpen = false; apply() }, useLabel))
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val s = ui.session
        when {
            !ui.listLoaded -> T("Loading camera sessions…", m.type.tiny, m.t.muted, Modifier.padding(16.dp))
            s == null && ui.sessions.isEmpty() -> Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T("No camera session yet. Start one, then tell Claude how the characters and the camera move; Blender runs on your Mac.", m.type.tiny, m.t.muted)
                Cta2("New camera session", { store.newSession(shotTitle.ifBlank { "New camera session" }, c.repo.state.value.models.take(2).map { it.id }) { store.open(it) } },
                    Modifier.fillMaxWidth(), icon = "plus", height = 48.dp)
            }
            maxWidth >= WIDE -> DirectedCameraPaneContent(ui, now, chatActions(store, c, {}, { connections = true }, apply, useLabel), paneActions(store, null))
            else -> Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (ui.sessions.size > 1) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ui.sessions.take(3).forEach { x -> studio.muse.app.ui.components.Chip(x.title.take(18), x.id == ui.openId, { store.open(x.id) }) }
                }
                if (s != null) {
                    SessionHeader(s)
                    Column(Modifier.fillMaxWidth().camBox().padding(horizontal = 12.dp, vertical = 6.dp)) { SessionText.rows(s, ui.connections, ui.turn != null, now).forEach { StatusLine(it) } }
                    PlanView(s, ui.playhead, Modifier.fillMaxWidth().height(196.dp).camBox(), compact = true)
                    Cta2("Open Direct with Claude", { chatOpen = true }, Modifier.fillMaxWidth(), height = 48.dp)
                    Cta(useLabel, apply, Modifier.fillMaxWidth(), off = !SessionText.hasGuides(s))
                    T(SessionText.footer(s), m.type.tiny, m.t.muted)
                }
            }
        }
    }
}

/** Owner Settings → Connections: Claude & MCP tokens, the Blender relay status (it runs in the Mac app) and the in-app chat. */
@Composable
fun ConnectionsScreen(onBack: () -> Unit) = OwnerOnly {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val clip = LocalClipboardManager.current
    val uri = LocalUriHandler.current
    val now = rememberNow()
    var conn by remember { mutableStateOf<studio.muse.app.data.Connections?>(null) }
    var tokens by remember { mutableStateOf<List<McpToken>>(emptyList()) }
    var created by remember { mutableStateOf<McpToken?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val api = { c.repo.api.camera }
    LaunchedEffect(Unit) {
        runCatching { api().connections() }.onSuccess { conn = it }.onFailure { error = it.message }
        runCatching { api().tokens() }.onSuccess { tokens = it }
    }
    LaunchedEffect(Unit) {
        c.repo.live.collect { ev -> if (ev.type == "blender" && ev.op == "relay" && ev.online != null) conn = conn?.copy(relay = studio.muse.app.data.RelayStatus(ev.online, ev.blender ?: false, ev.addonVersion)) }
    }
    ConnectionsContent(conn, tokens, created, now, error, ConnectionActions(
        back = onBack,
        create = { name -> scope.launch { runCatching { api().createToken(name) }.onSuccess { t -> created = t; tokens = listOf(t.copy(token = null)) + tokens; error = null }.onFailure { error = it.message } } },
        revoke = { id -> scope.launch { runCatching { api().revokeToken(id) }.onSuccess { tokens = tokens.filterNot { it.id == id }; if (created?.id == id) created = null; c.repo.toast("Token revoked") }.onFailure { error = it.message } } },
        copy = { text, msg -> clip.setText(AnnotatedString(text)); c.repo.toast(msg) },
        openDocs = { runCatching { uri.openUri(it) } },
    ))
}
