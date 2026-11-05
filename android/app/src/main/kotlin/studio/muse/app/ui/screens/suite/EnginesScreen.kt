package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import studio.muse.app.data.SuiteCompileRequest
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.NoteBox
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing

/**
 * The owner's Engines view (D9 content as a phone screen): what each tier runs today and its $/s, the current Shot's
 * camera compiled for its engine, the licence and budget flags, the cost of this shot against the provider's cost, and
 * the model switches. Members never reach it: the route checks the role and shows nothing of it.
 */
@Composable
fun SuiteEnginesScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val owner = store.owner
    val cat by store.catalog.collectAsState()
    val settings by store.settings.collectAsState()
    val shot by store.shot.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(owner) { if (owner) { if (store.catalog.value == null) store.load(); store.loadSettings() } }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Engines", onBack = { nav.back() })
            if (!owner) { Column(Modifier.padding(16.dp)) { NoteBox("Only the studio owner can see this.") }; return@Column }
            val req = shot.request()
            val est = produceState<studio.muse.app.data.SuiteEstimate?>(null, req, cat?.enabled) { value = if (cat?.enabled == true && shot.problem() == null) store.estimate(req).first else null }.value
            val compiled = produceState<studio.muse.app.data.SuiteCompiled?>(null, shot.camera, shot.quality) {
                value = c.repo.attemptInline { suiteCompile(SuiteCompileRequest(shot.camera.presetSpec(), shot.quality, shot.duration)) }.first
            }.value
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T("Engines", m.type.h3, m.t.ink, Modifier.weight(1f)); SBadge("Owner only", "busy")
                }
                Tiny("Members only ever see Draft · Standard · HD · Cinema. This shows what each tier runs today.")
                cat?.tiers?.forEach { t ->
                    val first = t.models?.firstOrNull()
                    val per = settings?.model(first?.model)?.perSec(first?.resolution)
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).line(m).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        T(t.label, m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 14.sp), m.t.ink, Modifier.width(78.dp))
                        T(first?.let { "${it.name} ${it.resolution}" } ?: "Nothing available", m.type.body.copy(fontSize = 14.sp), m.t.ink, Modifier.weight(1f), maxLines = 2)
                        T(per?.let { "$" + "%.4f".format(java.util.Locale.US, it).trimEnd('0').let { s -> if (s.endsWith(".")) s + "0" else s } + "/s" } ?: "", m.type.mono.copy(fontSize = 12.sp), m.t.ink)
                    }
                }
                val engine = est?.engine
                SLbl("Camera → prompt" + (compiled?.engine?.name ?: engine?.name)?.let { " (compiled for $it)" }.orEmpty())
                T(compiled?.text?.ifBlank { null } ?: "—", m.type.mono.copy(fontSize = 12.sp, lineHeight = 17.sp), m.t.ink, Modifier.fillMaxWidth().background(m.t.surface).padding(12.dp))
                SLbl("Flags")
                val flags = buildList {
                    if (cat?.test == true) add("Test renders · free (${SuiteRules.MODE_VAR} = mock)")
                    settings?.models?.filter { it.blocked }?.forEach { add("${it.name} · ${it.blockedReason ?: "blocked"}" + (it.licence.territoryExcluded?.let { t -> " · not in ${t.joinToString(", ")}" } ?: "")) }
                    settings?.caps?.let { add("Budget cap ${Pricing.money(it.perJob)}/shot · ${Pricing.money(it.perDay)}/day · ${Pricing.money(settings?.spentToday ?: 0.0)} spent today") }
                    engine?.notice?.let { add("Notice: $it") }
                }
                flags.forEach { f -> Tiny("• $f") }
                if (est != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        T("Cost this shot (${est.takes} take${if (est.takes > 1) "s" else ""})", m.type.body, m.t.ink, Modifier.weight(1f))
                        T(Pricing.money(est.estimate), m.type.h2.copy(fontSize = 26.sp), m.t.ink)
                    }
                    val provider = engine?.perSec?.let { p -> p * (engine.billedPerTake ?: est.seconds) * est.takes }
                    if (provider != null) Row { Tiny("Provider cost", Modifier.weight(1f)); T(Pricing.money(provider), m.type.mono, m.t.ink) }
                    est.tried?.takeIf { it.isNotEmpty() }?.let { tr -> Tiny("Skipped: " + tr.joinToString(" · ") { "${it.model} ${it.resolution} (${it.why})" }) }
                }
                SLbl("Models")
                val inLadder = settings?.ladder?.values?.flatten()?.map { it.model }?.toSet().orEmpty()
                settings?.models?.filter { it.id in inLadder || it.blocked }?.forEach { mv ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).line(m), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            T(mv.name, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
                            Tiny(listOfNotNull(mv.provider, if (!mv.configured) "no key" else null, mv.blockedReason, mv.licence.notice).joinToString(" · "))
                        }
                        Toggle(mv.enabled, { if (!mv.blocked) scope.launch { store.setModel(mv.id, !mv.enabled) } })
                    }
                }
                Tiny("Claude never spends: drafts carry a price, and you press Generate.")
            }
        }
    }
}

private fun Modifier.line(m: studio.muse.app.ui.theme.Muse) = drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }
