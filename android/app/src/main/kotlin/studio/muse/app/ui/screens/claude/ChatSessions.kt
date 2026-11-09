package studio.muse.app.ui.screens.claude

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import studio.muse.app.data.ClaudeSessions
import studio.muse.app.data.ClaudeThread
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MuseMenu
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.PrimaryButton
import studio.muse.app.ui.screens.SecondaryButton
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/** WS18: what the sessions row can do (the store's actions, or test stubs). */
class ChatSessionActions(
    val newChat: () -> Unit = {},
    val open: (ClaudeThread) -> Unit = {},
    val rename: (ClaudeThread, String) -> Unit = { _, _ -> },
    val delete: (ClaudeThread) -> Unit = {},
)

/**
 * WS18: the chats of this place, under the chat's header. The open chat's name opens the list (each with when it was last
 * used, then Rename and Delete); "+" starts a new chat. Each place keeps its own list on the server: the AI Suite one per
 * composer mode, Recreate, Edit and Camera one per reference, editor session or camera.
 */
@Composable
fun ChatSessionsRow(ui: ClaudeChatUi, actions: ChatSessionActions, horizontal: Dp) {
    val m = muse
    val current = ui.thread ?: return
    val name = ClaudeSessions.displayTitle(ui.threads.firstOrNull { it.id == current.id } ?: current)
    var list by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    val empty = ui.messages.isEmpty() && ui.turn == null
    Row(Modifier.fillMaxWidth().padding(horizontal = horizontal).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            Row(Modifier.heightIn(min = 48.dp).press { list = true }.semantics { role = Role.Button; contentDescription = "Chat: $name. Open the list of chats" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                T(name, m.scale.label, m.roles.ink, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                Ic("caret-down", 16.dp, m.roles.ink2)
            }
            val now = System.currentTimeMillis()
            MuseMenu(list, { list = false }, ui.threads.map { t ->
                MenuItem(if (t.id == current.id) "check" else "msg", "${ClaudeSessions.displayTitle(t)}, ${ClaudeSessions.lastUsed(t.updatedAt, now)}") { actions.open(t) }
            } + listOf(
                MenuItem("pencil-simple", "Rename chat") { renaming = true },
                MenuItem("trash", "Delete chat", danger = true) { deleting = true },
            ))
        }
        Box(Modifier.size(48.dp).press(enabled = !empty && !ui.busy) { actions.newChat() }
            .semantics { role = Role.Button; contentDescription = "New chat" }, contentAlignment = Alignment.Center) {
            Ic("plus", 20.dp, if (empty || ui.busy) m.roles.ink2.copy(alpha = .4f) else m.roles.ink2)
        }
    }
    if (renaming) {
        var text by remember { mutableStateOf(current.title.orEmpty()) }
        ChatDialog({ renaming = false }) {
            T("Rename chat", m.scale.heading, m.roles.ink)
            Input(text, { text = it }, Modifier.fillMaxWidth(), placeholder = "Name", calm = true)
            T("Leave it empty to name it by its first message.", m.scale.caption, m.roles.ink2)
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                Spacer(Modifier.weight(1f))
                SecondaryButton("Cancel", { renaming = false })
                PrimaryButton("Rename", { renaming = false; actions.rename(current, text) })
            }
        }
    }
    if (deleting) ChatDialog({ deleting = false }) {
        T("Delete this chat?", m.scale.heading, m.roles.ink)
        T("Its messages are deleted on every device. The composer stays as it is.", m.scale.body, m.roles.ink2)
        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Spacer(Modifier.weight(1f))
            SecondaryButton("Keep", { deleting = false })
            PrimaryButton("Delete chat", { deleting = false; actions.delete(current) })
        }
    }
}

@Composable
private fun ChatDialog(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    val m = muse
    Dialog(onDismiss) {
        Column(Modifier.widthIn(max = 420.dp).clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).padding(MuseSpace.s5),
            verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) { content() }
    }
}
