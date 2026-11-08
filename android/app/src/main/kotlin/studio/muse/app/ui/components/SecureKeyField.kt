package studio.muse.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
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
import studio.muse.app.ui.screens.Caption
import studio.muse.app.ui.screens.PrimaryButton
import studio.muse.app.ui.screens.SecondaryButton
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/**
 * The provider key field (WS7, Settings → Providers; WS5 contract: a key goes up once and never comes back).
 * - Typing: masked by default (the field's eye shows it while typing), password keyboard. The text lives in plain
 *   `remember`, not `rememberSaveable`, so it never lands in the saved-instance bundle, and it's cleared after [onSave].
 * - Saved: only "Key ending 7Q2k" and Replace key. The app never holds or shows more of a saved key than its last 4.
 * - [keysReady] false: the server can't store keys yet; the field is replaced by that sentence.
 */
@Composable
fun SecureKeyField(
    keyLast4: String?,
    hint: String,
    busy: Boolean,
    error: String?,
    keysReady: Boolean,
    onSave: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val m = muse
    var editing by remember(keyLast4) { mutableStateOf(keyLast4 == null) }
    var typed by remember { mutableStateOf("") }
    Column(modifier.fillMaxWidth().testTag("secure_key"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when {
            !keysReady -> Caption("Provider keys aren't set up on the server yet")
            !editing && keyLast4 != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                T("Key ending $keyLast4", m.scale.body, m.roles.ink, Modifier.weight(1f).semantics { contentDescription = "API key ending $keyLast4" }, maxLines = 1)
                SecondaryButton("Replace key", { editing = true })
            }
            else -> {
                Input(typed, { typed = it.trim() }, password = true, calm = true, placeholder = hint)
                error?.let { T(it, m.scale.caption, m.roles.danger) } ?: Caption("Stored encrypted on the studio server. MUSE shows only its last 4 characters after this.")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (keyLast4 != null) SecondaryButton("Keep the old key", { typed = ""; editing = false })
                    PrimaryButton(if (busy) "Checking the key…" else if (keyLast4 == null) "Save key" else "Replace key", {
                        if (typed.isNotBlank() && !busy) { onSave(typed); typed = "" }
                    }, Modifier.weight(1f), busy = busy)
                }
            }
        }
    }
}
