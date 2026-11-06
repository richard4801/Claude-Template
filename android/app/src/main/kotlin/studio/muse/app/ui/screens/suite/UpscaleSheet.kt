package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import studio.muse.app.data.FakeSuite
import studio.muse.app.data.Job
import studio.muse.app.data.UpscaleOffer
import studio.muse.app.data.VideoFeatures
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.composer.PickerShell
import studio.muse.app.ui.screens.suite.composer.SheetLabel
import studio.muse.app.ui.theme.muse

/**
 * Upscale on a finished take (the store's [SuiteStore.upscaleFor]): 1080p / 2K / 4K, each with its price (the server's $ per
 * output second × the take's length) or greyed "Soon". Picking one posts it and follows the job like any render
 * ([onStarted]); `upscale_unavailable` greys every size with "Upscale is coming soon". Dark, like every picker.
 */
@Composable
fun BoxScope.UpscaleSheet(takeId: String, wide: Boolean, onStarted: (Job) -> Unit) {
    val c = LocalContainer.current
    val store = c.suite
    val st by c.repo.state.collectAsState()
    val soon by store.upscaleSoon.collectAsState()
    val scope = rememberCoroutineScope()
    var busy by remember(takeId) { mutableStateOf<String?>(null) }
    val close = { store.upscaleFor.value = null }
    val take = st.takes.firstOrNull { it.id == takeId }
    if (take == null) { androidx.compose.runtime.LaunchedEffect(takeId) { close() }; return }
    val secs = UpscaleOffer.seconds(take, st.job(take.jobId ?: ""))
    val up = (st.video ?: VideoFeatures.DEFAULT).upscale
    val choices = UpscaleOffer.choices(up, secs, soon)
    PickerShell("Upscale", wide, close, heightFraction = .62f) {
        val m = muse
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(44.dp, 78.dp).clip(RoundedCornerShape(8.dp)).background(m.t.surface2)) { RefImage(take.thumb, Modifier.size(44.dp, 78.dp), 20) }
                Column(Modifier.weight(1f)) {
                    T(take.title, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                    T(listOfNotNull("Take ${take.index}", secs?.let { "${FakeSuite.fmtSeconds(Math.round(it * 10) / 10.0)} s" }, take.label).joinToString(" · "), m.type.body.copy(fontSize = 12.5.sp), m.t.muted, maxLines = 1)
                    T(up.detail.ifBlank { "Sharper 1080p, 2K or 4K from a finished take" }, m.type.body.copy(fontSize = 12.5.sp), m.t.muted, maxLines = 2)
                }
            }
            SheetLabel("Size", if (secs != null) "price for ${FakeSuite.fmtSeconds(Math.round(secs * 10) / 10.0)} s" else null, Modifier.padding(top = 6.dp))
            choices.forEach { ch ->
                val shape = RoundedCornerShape(12.dp)
                Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).alpha(if (ch.available) 1f else .45f).clip(shape).background(m.t.surface)
                    .let { if (busy == ch.id) it.border(2.dp, m.t.accent, shape) else it }
                    .press(enabled = ch.available && busy == null) {
                        busy = ch.id
                        scope.launch { store.upscale(takeId, ch.id)?.let(onStarted); busy = null }
                    }
                    .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Upscale to ${ch.label}, ${ch.priceText}"; if (!ch.available) disabled() }
                    .padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    T(ch.label, m.type.body.copy(fontSize = 16.sp, fontWeight = FontWeight.Bold), m.t.ink, Modifier.size(width = 64.dp, height = 22.dp), maxLines = 1)
                    T(ch.frame, m.type.mono.copy(fontSize = 12.sp, letterSpacing = .04.em), m.t.muted, Modifier.weight(1f), maxLines = 1)
                    T(if (busy == ch.id) "Starting…" else ch.priceText, m.type.mono.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), if (ch.available) m.t.ink else m.t.muted, maxLines = 1)
                }
            }
            if (soon || !UpscaleOffer.live(up)) T(UpscaleOffer.SOON_TEXT + " · the sizes open here when it's ready", m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 2)
            else T("A new take, sharper; the original stays as it is.", m.type.body.copy(fontSize = 12.5.sp), m.t.muted, maxLines = 2)
            Spacer(Modifier.height(8.dp))
        }
    }
}
