package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.CameraSession
import studio.muse.app.data.ClaudePlanStatus
import studio.muse.app.data.Connections
import studio.muse.app.data.McpToken
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.components.Lbl
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ---------------------------------------------------------------- Camera stage: the sessions list

/** "Blender connected" / "Mac app online" / "Mac offline" for a list row. */
fun relayShort(s: CameraSession) = when {
    s.relay.blender -> "Blender connected"
    s.relay.online -> "Mac app online · Blender off"
    else -> "Mac offline"
}

@Composable
fun CameraSessionsListContent(ui: CameraUi, onOpen: (String) -> Unit, onNew: () -> Unit, onBack: (() -> Unit)? = null) {
    val m = muse
    Column(Modifier.fillMaxSize().background(m.t.bg)) {
        TopBar("Camera stage", onBack = onBack)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            T("Block a shot in Blender with Claude: who stands where, how they move and how the camera moves. Claude never spends money; you press Generate.", m.type.tiny, m.t.muted)
            if (!ui.listLoaded) T("Loading camera sessions…", m.type.tiny, m.t.muted)
            else if (ui.sessions.isEmpty()) T(ui.error ?: "No camera sessions yet · start one, then direct it here with Claude or from your own Claude app.", m.type.tiny, m.t.muted)
            ui.sessions.forEach { s -> SessionRow(s) { onOpen(s.id) } }
            Cta2("New camera session", onNew, Modifier.fillMaxWidth(), icon = "plus", height = 48.dp)
        }
    }
}

@Composable
fun SessionRow(s: CameraSession, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().camBox().press(onClick = onClick).padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        GuideThumb("greybox", null, Modifier.size(30.dp, 46.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(s.title, m.type.body.copy(fontSize = 14.sp), m.t.ink, weight = FontWeight.Bold, maxLines = 1)
            T(s.characters.joinToString(" · ") { it.name }.ifEmpty { "No cast yet" }, m.type.tiny, m.t.muted, maxLines = 1)
            T(SessionText.subtitle(s), m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted, maxLines = 1)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Box(Modifier.size(6.dp).clip(CircleShape).background(dotColor(SessionText.blenderRow(s).dot)))
                T(relayShort(s), m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
            }
        }
        val (l, k) = SessionText.pill(s)
        Pill(l, k, Modifier.align(Alignment.Top))
    }
}

// ---------------------------------------------------------------- Settings → Connections (owner)

object ConnectionText {
    fun claudeCode(url: String, token: String?) = "claude mcp add --transport http muse $url --header \"Authorization: Bearer ${token ?: "muse_pat_…"}\""

    fun claudeDesktop(url: String, token: String?) = """
        {
          "mcpServers": {
            "blender": { "command": "uvx", "args": ["mcp-for-blender"], "env": { "DISABLE_TELEMETRY": "true", "BLENDER_MCP_SAFE_MODE": "1" } },
            "muse": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "$url", "--header", "Authorization:${'$'}{MUSE_AUTH}"],
              "env": { "MUSE_AUTH": "Bearer ${token ?: "muse_pat_…"}" }
            }
          }
        }
    """.trimIndent()

    private fun day(at: Long) = SimpleDateFormat("d MMM", Locale.US).format(Date(at))

    /** "muse_pat_7f3a… · created 2 Nov · last used 3 min ago" */
    fun tokenLine(t: McpToken, now: Long) = listOfNotNull(
        "${t.prefix}…", "created ${day(t.createdAt)}", t.lastUsedAt?.let { "last used ${SessionText.ago(it, now)}" } ?: "never used",
        t.expiresAt?.let { "expires ${day(it)}" },
    ).joinToString(" · ")

    const val MAC_SETUP = "Set up on your Mac: open MUSE → Settings → Connections → Claude on your plan, then Install Claude Code and Sign in (Claude's own page; MUSE never sees your Claude password)."

    val CONNECTOR_STEPS = listOf(
        "Open claude.ai or the Claude app → Settings → Connectors",
        "Add custom connector, and name it MUSE",
        "Paste this URL:",
        "Connect, then sign in with your MUSE owner account",
    )

    val INSTALL = listOf(
        "1 · Install Blender and uv, then run: uvx mcp-for-blender install-addon",
        "2 · In Blender: Edit → Preferences → Add-ons → enable “Interface: MCP for Blender”",
        "3 · Viewport sidebar (N) → MCP for Blender → Connect (localhost:9876)",
    )
}

class ConnectionActions(
    val back: () -> Unit = {},
    val create: (String) -> Unit = {},
    val revoke: (String) -> Unit = {},
    val copy: (String, String) -> Unit = { _, _ -> },
    val openDocs: (String) -> Unit = {},
    /** PATCH /v1/claude/settings {apiFallback}. */
    val setApiFallback: (Boolean) -> Unit = {},
)

@Composable
fun ConnectionsContent(conn: Connections?, tokens: List<McpToken>, created: McpToken?, now: Long, error: String?, actions: ConnectionActions, claude: ClaudePlanStatus? = null) {
    val m = muse
    Column(Modifier.fillMaxSize().background(m.t.bg)) {
        TopBar("Connections", onBack = actions.back)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 14.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (error != null) T(error, m.type.tiny, m.t.accent)
            val url = conn?.mcpUrl.orEmpty()
            // Claude on your plan (claude-editing.md parts C and D)
            Section("Claude on your plan") {
                T("MUSE's chat runs on your own Claude subscription through Claude Code on your Mac. Messages from this phone go to your Mac, which answers them.", m.type.tiny, m.t.muted)
                ClaudePlanRows(claude).forEach { StatusLine(it) }
                if (claude?.mac?.ready != true) T(ConnectionText.MAC_SETUP, m.type.tiny, m.t.ink)
                Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
                val fb = claude?.apiFallback
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        T("API fallback", m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.SemiBold)
                        T(when {
                            claude == null -> "…"
                            fb?.available != true -> "Needs ANTHROPIC_API_KEY on the server"
                            else -> "When your Mac is offline, answer on the studio API key · billed per use · off by default"
                        }, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
                    }
                    Toggle(fb?.enabled == true, { if (fb?.available == true) actions.setApiFallback(!fb.enabled) },
                        Modifier.graphicsLayer { alpha = if (fb?.available == true) 1f else .45f })
                }
            }
            // Add MUSE to Claude (the custom connector, claude-editing.md part B)
            Section("Add MUSE to Claude") {
                T("Use MUSE from the Claude apps on your phone, Mac and the web, on your Claude plan.", m.type.tiny, m.t.muted)
                val curl = claude?.connectorUrl?.takeIf { it.isNotBlank() } ?: url
                ConnectionText.CONNECTOR_STEPS.forEachIndexed { i, step ->
                    T("${i + 1} · $step", m.type.tiny, m.t.ink)
                    if (i == 2) CopyBox(curl.ifEmpty { "…" }) { actions.copy(curl, "Connector URL copied") }
                }
            }
            // Claude & MCP
            Section("Claude & MCP · tokens") {
                T("Use MUSE from your own Claude app (Claude Code or Claude Desktop) with a token. Tokens only work for the studio owner.", m.type.tiny, m.t.muted)
                Lbl("MUSE MCP URL")
                CopyBox(url.ifEmpty { "…" }) { actions.copy(url, "MCP URL copied") }
                var name by remember { mutableStateOf("") }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.weight(1f)) { Input(name, { name = it }, placeholder = "Token name") }
                    SmallBtn("New token", primary = true) { if (name.isNotBlank()) { actions.create(name.trim()); name = "" } }
                }
                if (created?.token != null) {
                    Column(Modifier.fillMaxWidth().camBox(m.t.surface2).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        T(created.name, m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.Bold)
                        CopyBox(created.token) { actions.copy(created.token, "Token copied") }
                        T("You won't see it again · copy it into your Claude app now.", m.type.tiny, m.t.accent, weight = FontWeight.SemiBold)
                    }
                }
                if (tokens.isEmpty()) T("No tokens yet.", m.type.tiny, m.t.muted)
                tokens.forEach { t -> TokenRow(t, now, actions) }
                Lbl("Claude Code")
                CopyBox(ConnectionText.claudeCode(url, created?.token), mono = true) { actions.copy(ConnectionText.claudeCode(url, created?.token), "Command copied") }
                Lbl("Claude Desktop config")
                CopyBox(ConnectionText.claudeDesktop(url, created?.token), mono = true) { actions.copy(ConnectionText.claudeDesktop(url, created?.token), "Config copied") }
                conn?.docsUrl?.takeIf { it.isNotBlank() }?.let { d -> T("Setup guide →", m.type.tiny, m.t.accent, Modifier.press { actions.openDocs(d) }, weight = FontWeight.SemiBold) }
            }
            // Blender relay (read-only on the phone)
            Section("Blender relay") {
                val r = conn?.relay
                StatusLine(StatusRow(if (r?.online == true) Dot.GOOD else Dot.OFF, "Mac app", if (r?.online == true) "Online" else "Offline"))
                StatusLine(StatusRow(if (r?.blender == true) Dot.GOOD else if (r?.online == true) Dot.WARN else Dot.OFF, "Blender",
                    if (r?.blender == true) "Connected" + (r.addonVersion?.let { " · add-on $it" } ?: "") else "Not connected"))
                T("Runs in the MUSE Mac app · switch it on there (Settings → Connections).", m.type.tiny, m.t.muted)
                Lbl("Install the Blender add-on")
                ConnectionText.INSTALL.forEach { T(it, m.type.tiny, m.t.ink) }
            }
        }
    }
}

/** The Mac's Claude Code: the app online, Claude Code installed (version), signed in (model, owner only). */
fun ClaudePlanRows(s: ClaudePlanStatus?): List<StatusRow> {
    val mac = s?.mac
    val cc = mac?.claudeCode
    return listOf(
        StatusRow(if (mac?.online == true) Dot.GOOD else Dot.OFF, "Mac app", if (s == null) "…" else if (mac!!.online) "Online" else "Offline"),
        StatusRow(if (cc?.installed == true) Dot.GOOD else Dot.OFF, "Claude Code", if (s == null) "…" else if (cc!!.installed) "Installed" + (cc.version?.let { " · $it" } ?: "") else "Not installed"),
        StatusRow(if (cc?.signedIn == true) Dot.GOOD else if (cc?.installed == true) Dot.WARN else Dot.OFF, "Signed in",
            if (s == null) "…" else if (cc!!.signedIn) "Yes" + (cc.model?.let { " · $it" } ?: "") else "No"),
    )
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().camBox().padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(title, m.type.h3, m.t.ink)
        content()
    }
}

@Composable
private fun CopyBox(text: String, mono: Boolean = true, onCopy: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().camBox(m.t.bg).padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        T(text, if (mono) m.type.mono.copy(fontSize = 11.5.sp, lineHeight = 15.sp) else m.type.tiny, m.t.ink, Modifier.weight(1f).padding(vertical = 6.dp))
        Box(Modifier.size(40.dp).press(onClick = onCopy), contentAlignment = Alignment.Center) { CamIc("copy", 18.dp, m.t.ink) }
    }
}

@Composable
private fun TokenRow(t: McpToken, now: Long, actions: ConnectionActions) {
    val m = muse
    var confirm by remember(t.id) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(t.name, m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
            T(ConnectionText.tokenLine(t, now), m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted)
        }
        if (!confirm) SmallBtn("Revoke") { confirm = true }
        else Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SmallBtn("Cancel") { confirm = false }
            SmallBtn("Revoke now", primary = true) { confirm = false; actions.revoke(t.id) }
        }
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
}
