package studio.muse.app.ui.screens.suite

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.app.AppContainer
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

// AI suite (workstream 1): the input slots' views and uploads. No layout decisions: [InputSlotTile] draws one slot in
// whatever size its modifier gives it, and the screen (the composer, when its design lands) lays the tiles out from
// InputSlots.visible(tier.slots). Picking and uploading are separate so any button can open the picker for a slot.

/** Reads a picked file and uploads it into its slot: images as images, video and audio as studio uploads. */
class InputSlotUploader(private val c: AppContainer) {
    suspend fun upload(slots: MutableStateFlow<InputSlots>, id: SlotId, uri: Uri) {
        val media = c.media ?: return
        val name = media.displayName(uri)
        val mime = media.mime(uri).let { t ->
            when {
                id.kind.isImage || t.startsWith(id.kind.mime.substringBefore('/')) -> t
                id.kind == SlotKind.AUDIO -> "audio/mpeg"
                else -> "video/mp4"
            }
        }
        val tok = System.nanoTime()
        slots.update { s -> s.put(id, SlotValue(name = name, preview = uri.takeIf { id.kind.isImage }?.toString(), progress = 0f, token = tok)) }
        val bytes = media.bytes(uri)
        val limit = if (id.kind.isImage) InputSlots.MAX_IMAGE_BYTES else InputSlots.MAX_MEDIA_BYTES
        val err: String? = when {
            bytes == null -> "Couldn't read that file"
            bytes.size > limit -> "That file is over ${limit / (1024 * 1024)} MB"
            else -> null
        }
        if (err != null || bytes == null) return slots.update { s -> s.updateToken(tok) { it.copy(progress = null, error = err) } }
        val progress: (Float) -> Unit = { p -> slots.update { s -> s.updateToken(tok) { v -> if (v.progress != null) v.copy(progress = p.coerceIn(0f, .99f)) else v } } }
        if (id.kind.isImage) {
            val (ref, e) = c.repo.attemptInline { uploadImage(name, bytes, mime, progress) }
            slots.update { s -> s.updateToken(tok) { it.copy(image = ref, progress = null, error = e) } }
        } else {
            val (ref, e) = c.repo.attemptInline { uploadSuiteMedia(name, bytes, mime, progress) }
            slots.update { s -> s.updateToken(tok) { it.copy(media = ref, progress = null, error = e) } }
        }
    }
}

/**
 * The system picker for slots: call the returned function with a slot to pick a file of its kind; [onPicked] gets the
 * slot and the file. One launcher for all slots, so a screen remembers it once.
 */
@Composable
fun rememberInputSlotPicker(onPicked: (SlotId, Uri) -> Unit): (SlotId) -> Unit {
    var pending by remember { mutableStateOf<SlotId?>(null) }
    val cb by rememberUpdatedState(onPicked)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        val id = pending
        pending = null
        if (uri != null && id != null) cb(id, uri)
    }
    return remember(launcher) { { id: SlotId -> pending = id; launcher.launch(id.kind.mime) } }
}

/**
 * One input slot, filling the size its [modifier] gives it. Empty: the kind's icon, title and hint (tap to pick).
 * Filled: the image (or the file's name for video/audio), upload progress, or the error; a remove button in the corner.
 */
@Composable
fun InputSlotTile(id: SlotId, value: SlotValue?, onPick: () -> Unit, onClear: () -> Unit, modifier: Modifier = Modifier, compact: Boolean = false) {
    val m = muse
    val filled = value != null
    val desc = when {
        value == null -> "${id.title}, empty · ${id.kind.hint}"
        value.error != null -> "${id.title}: ${value.error}"
        value.uploading -> "${id.title}, uploading ${((value.progress ?: 0f) * 100).toInt()} %"
        else -> "${id.title}: ${value.name}"
    }
    Box(
        modifier.suiteCard(m, on = value?.ready == true).press(onClick = onPick)
            .semantics(mergeDescendants = true) { contentDescription = desc; role = Role.Button },
    ) {
        val img = value?.image ?: value?.preview?.let { ImageRef(url = it) }
        if (img != null && id.kind.isImage) RefImage(img, Modifier.fillMaxSize(), alignPct = 30)
        Column(
            Modifier.align(if (img != null && id.kind.isImage) Alignment.BottomStart else Alignment.Center).padding(if (compact) 6.dp else 10.dp),
            horizontalAlignment = if (img != null && id.kind.isImage) Alignment.Start else Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            val overImage = img != null && id.kind.isImage
            val ink = if (overImage) Color.White else m.t.ink
            if (!overImage) Ic(when { value?.error != null -> "retry"; id.kind == SlotKind.AUDIO -> "audio"; id.kind == SlotKind.VIDEO -> "play"; filled -> "check"; else -> "upload" }, if (compact) 18.dp else 22.dp, if (value?.error != null) m.t.rec else ink)
            val label = if (overImage) Modifier.clip(androidx.compose.foundation.shape.RoundedCornerShape(4.dp)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp) else Modifier
            T(id.title, m.type.tiny.copy(fontWeight = FontWeight.Bold), ink, label, maxLines = 1, align = if (overImage) null else TextAlign.Center)
            when {
                value?.error != null -> Tiny(value.error, color = if (overImage) Color.White else m.t.rec)
                value != null && !id.kind.isImage -> Tiny(value.name, color = m.t.muted)
                value == null && !compact -> T(id.kind.hint, m.type.tiny.copy(fontSize = 11.sp), m.t.muted, maxLines = 2, align = TextAlign.Center)
            }
        }
        value?.progress?.let { p ->
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(m.t.line)) {
                Box(Modifier.fillMaxWidth(p.coerceIn(.04f, 1f)).height(4.dp).background(m.t.accent))
            }
        }
        if (filled) {
            // 48 dp target, small visible dot.
            Box(Modifier.align(Alignment.TopEnd).size(48.dp).press(onClick = onClear).semantics { contentDescription = "Remove ${id.title}"; role = Role.Button }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(24.dp).clip(CircleShape).background(Color.Black.copy(alpha = .6f)), contentAlignment = Alignment.Center) {
                    T("×", m.type.body.copy(fontSize = 16.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold), Color.White)
                }
            }
        }
    }
}
