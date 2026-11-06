package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.data.ShootPreview
import studio.muse.app.data.ShootRef
import studio.muse.app.data.PromptSlotView
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.muse

// The reference images panel and the prompt-by-slot view, used by template shoots (TemplateScreens.kt). They came from
// the Photoshoot screen, which is now the Photo tool on the AI suite composer (workstream 3).

/** The server's final prompt by slot (the label is the layer; reference lines are "REF"). */
@Composable
fun PromptBox(slots: List<PromptSlotView>) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        slots.forEach { slot ->
            Row {
                T(if (slot.layer == "reference") "REF" else slot.layer.uppercase(), m.type.mono.copy(fontSize = 10.sp, letterSpacing = .08.em), m.t.muted, Modifier.width(74.dp))
                T(slot.text.replaceFirst(Regex("^[A-Za-z ]+: "), ""), m.type.body.copy(fontSize = 12.5.sp, lineHeight = 17.sp), m.t.ink, Modifier.weight(1f))
            }
        }
    }
}

/**
 * Shoot → Scene (and template shoots): up to 3 reference images, each with what it guides (at least one on), "Image n" / "Not sent"
 * from the server's preview, and remove. Her face, body and outfit never come from them.
 */
@Composable
fun ReferencesPanel(refs: List<ShootRef>, preview: ShootPreview?, uploading: Boolean, onAdd: () -> Unit, onToggle: (Int, String) -> Unit, onRemove: (Int) -> Unit) {
    val m = muse
    RowB { H3("References"); Tiny("${refs.size}/${ShootRef.MAX}") }
    Tiny("Optional · copy a pose, a look or a place from up to ${ShootRef.MAX} photos. Her face, body, hair and outfit always come from her own photos.")
    refs.forEachIndexed { i, r ->
        val shape = RoundedCornerShape(m.t.r * .6f)
        val sent = preview?.refs?.getOrNull(i)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.width(64.dp).heightIn(min = 84.dp, max = 84.dp).clip(shape).border(if (m.isD) 2.dp else m.t.stroke, m.t.line, shape)) {
                RefImage(r.image, Modifier.fillMaxSize())
                if (sent != null) T(sent.badge, m.type.mono.copy(fontSize = 9.5.sp, fontWeight = FontWeight.Bold), androidx.compose.ui.graphics.Color.White,
                    Modifier.align(Alignment.BottomStart).padding(4.dp).clip(RoundedCornerShape(4.dp))
                        .background(if (sent.dropped) m.t.warn.copy(alpha = .9f) else androidx.compose.ui.graphics.Color.Black.copy(alpha = .6f)).padding(horizontal = 5.dp, vertical = 2.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                RowB {
                    T("Reference ${i + 1}", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                    T("Remove", m.type.tiny, m.link, Modifier.press { onRemove(i) }.padding(4.dp))
                }
                FlowRow(hGap = 6.dp, vGap = 6.dp) { ShootRef.GUIDES.forEach { (id, label) -> Chip(label, id in r.guides, { onToggle(i, id) }) } }
            }
        }
    }
    preview?.takeIf { it.droppedRefs > 0 }?.let { p ->
        NoteBox("This shoot can take only ${p.images} images in all, so ${if (p.droppedRefs == 1) "1 reference isn't" else "${p.droppedRefs} references aren't"} sent.", warn = true)
    }
    if (refs.size < ShootRef.MAX) Cta2(if (uploading) "Adding…" else "Add reference photo", { if (!uploading) onAdd() }, Modifier.fillMaxWidth(), icon = "plus", height = 46.dp)
}

