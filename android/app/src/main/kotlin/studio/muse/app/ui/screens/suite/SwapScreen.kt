package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.Chip
import studio.muse.app.ui.components.ClipPlaceholder
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.Seg
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

/**
 * M6 + D7 · Character swap with Recast inside: the source clip next to the live result, the camera locked to the clip,
 * who to replace (up to 4 people, each → a studio character with a speaking switch), the Draft / Standard / HD / Cinema
 * ladder with each tier's price, keep the clip's audio, and Generate with the estimate's price.
 */
@Composable
fun SuiteSwapScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val d by store.recast.collectAsState()
    val st by c.repo.state.collectAsState()
    val video by c.drafts.video.collectAsState()
    val started by store.swapJobs.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (store.catalog.value == null) store.load() }
    val catalog = cat
    if (catalog != null && !catalog.enabled) { SuiteOffScreen("Character swap"); return }
    // The clip picked in New video becomes the source; the first person starts as the studio's first character.
    LaunchedEffect(video.clip?.id) { video.clip?.id?.let { id -> if (d.clipId != id) store.recast.update { it.copy(clipId = id) } } }
    LaunchedEffect(st.models) { if (d.people.first().characterId == null && st.models.isNotEmpty()) store.recast.update { it.update(0) { p -> p.copy(characterId = st.models.first().id) } } }
    val clip = video.clip?.takeIf { it.id == d.clipId }
    val clipName = clip?.name ?: if (d.clipId == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.name else null
    val clipSec = clip?.durationSec ?: if (d.clipId == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.durationSec else null
    val lead = st.model(d.people.first().characterId)
    val job = started.lastOrNull()?.let { id -> st.jobs.firstOrNull { it.id == id } }
    val pane = SuitePane.of(job, st.takes, lead?.name)
    val ready = d.problem() == null && catalog?.enabled == true
    val req = d.request()
    val (est, estErr) = rememberEstimate(req.takeIf { d.problem() == null }, catalog?.enabled == true)
    val busy = pane.phase == StagePhase.RENDERING || pane.phase == StagePhase.QUEUED
    fun go(r: studio.muse.app.data.SuiteShotRequest = req) { scope.launch { store.generate(r, store.swapJobs) } }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Character swap", onBack = { nav.back() })
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.weight(1f).aspectRatio(.58f).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp))) {
                        if (d.clipId == null) Column(Modifier.fillMaxSize().background(m.t.surface2).press { nav.go(Routes.SOURCE) }.padding(12.dp), verticalArrangement = Arrangement.Center,
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Ic("upload", 22.dp, m.t.ink); T("Choose a clip", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("5–30 s · up to 4 people")
                        } else if (clip?.thumb != null) RefImage(clip.thumb, Modifier.fillMaxSize()) else ClipPlaceholder(Modifier.fillMaxSize(), 1)
                    }
                    Box(Modifier.weight(1f).aspectRatio(.58f).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp))) {
                        SuiteResultPane(pane, lead?.cover, emptyTitle = "Preview", emptyHint = "Pick who they become, then Generate.", compact = true,
                            onRetry = { go() }, onTry = nextTier(d.quality)?.let { t -> { store.recast.update { it.copy(quality = t) }; go(req.copy(quality = t)) } },
                            tryLabel = nextTier(d.quality)?.let { "Try ${SuiteRules.tierLabel(it)}" }, onOpen = { job?.let { nav.go(Routes.suiteTake(it.id)) } })
                    }
                }
                Row(Modifier.fillMaxWidth()) {
                    T("SOURCE" + (clipSec?.let { " · ${"%.1f".format(java.util.Locale.US, it)} s" } ?: ""), m.type.mono.copy(fontSize = 11.sp), m.t.muted, Modifier.weight(1f), maxLines = 1)
                    T("${lead?.name?.uppercase() ?: "—"} · ${SuiteRules.tierLabel(d.quality).uppercase()} PREVIEW", m.type.mono.copy(fontSize = 11.sp), m.t.ink, maxLines = 1)
                }
                if (d.clipId == null && c.repo.demo) Cta2("Use the sample clip", { store.recast.update { it.copy(clipId = SampleData.SAMPLE_CLIP) } }, Modifier.fillMaxWidth(), height = 44.dp)
                else if (clipName != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Tiny(clipName, Modifier.weight(1f)); T("Change…", m.type.tiny, m.t.accent, Modifier.press { nav.go(Routes.SOURCE) })
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill("Camera follows the clip", icon = "lock")
                    Pill(if (d.people.size > 1) "Recast · ${d.people.size} people" else "One person")
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    SLbl("Who to replace", Modifier.weight(1f))
                    Tiny("up to ${catalog?.recastMaxPeople ?: SuiteRules.MAX_CAST}")
                }
                d.people.forEachIndexed { i, p -> PersonCard(i, p, d.people.size, st) }
                if (d.canAdd) Cta2("Add a person", { store.recast.update { it.add() } }, Modifier.fillMaxWidth(), icon = "plus", height = 44.dp)
                SLbl("Render")
                SuiteRules.TIERS.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        row.forEach { t -> TierCard(t, d.quality == t, req.takeIf { ready }?.copy(quality = t), catalog?.tier(t)?.available != false, Modifier.weight(1f)) {
                            store.recast.update { it.copy(quality = t) } } }
                    }
                }
                Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { T("Keep the clip's audio", m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 14.sp), m.t.ink); Tiny("The original sound, put back after the render") }
                    Toggle(d.keepAudio, { store.recast.update { it.copy(keepAudio = !it.keepAudio) } })
                }
                est?.cast?.let { cast -> Tiny(cast.joinToString(" · ") { e -> "${e.who} → ${st.model(e.characterId)?.name ?: "—"}" }) }
            }
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp)) {
                val note = d.problem() ?: estErr ?: est?.message?.takeIf { !est.ok } ?: est?.warnings?.firstOrNull()
                GenerateBar(if (busy) "Rendering · ${pane.percent}" else generateLabel(est), { if (!busy && ready && est?.ok != false) go() },
                    off = busy || !ready || est == null || !est.ok, note = note)
            }
        }
    }
}

/** One person of the clip: where they are, who they become, and whether their mouth follows speech. */
@Composable
private fun PersonCard(i: Int, p: RecastPerson, count: Int, st: studio.muse.app.data.StudioState) {
    val m = muse
    val store = LocalContainer.current.suite
    Column(Modifier.fillMaxWidth().suiteCard(m).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            T("Person ${i + 1}", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f))
            if (count > 1) T("Remove", m.type.tiny, m.t.muted, Modifier.press { store.recast.update { it.remove(i) } })
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            RecastDraft.HINTS.forEach { h -> Chip(RecastDraft.hintLabel(h), p.hint == h, { store.recast.update { it.update(i) { x -> x.copy(hint = h) } } }) }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            st.models.forEach { mod ->
                val on = mod.id == p.characterId
                Row(Modifier.suiteCard(m, on).press { store.recast.update { it.update(i) { x -> x.copy(characterId = mod.id, outfitId = null) } } }.padding(6.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    RefImage(mod.cover, Modifier.size(30.dp, 38.dp).background(m.t.surface2))
                    Column {
                        T(mod.name, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                        T(if (mod.filled == 0) "no sheet yet" else "sheet ✓", m.type.tiny.copy(fontSize = 11.sp), m.t.muted, maxLines = 1)
                    }
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            T("Speaking", m.type.body.copy(fontSize = 14.sp), m.t.ink)
            Spacer(Modifier.weight(1f))
            Seg(listOf("auto" to "Auto", "yes" to "Yes", "no" to "No"), when (p.speaking) { true -> "yes"; false -> "no"; null -> "auto" }, { k ->
                store.recast.update { it.update(i) { x -> x.copy(speaking = when (k) { "yes" -> true; "no" -> false; else -> null }) } }
            }, Modifier.size(190.dp, 34.dp), small = true)
        }
    }
}

/** A tier with its own price (the estimate for this clip at that tier). */
@Composable
private fun TierCard(tier: String, on: Boolean, req: studio.muse.app.data.SuiteShotRequest?, available: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    val (e, _) = rememberEstimate(req, req != null && available)
    Column(modifier.suiteCard(m, on).press(enabled = available, onClick = onClick).padding(horizontal = 10.dp, vertical = 9.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        T(SuiteRules.tierLabel(tier), m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.Bold), if (available) m.t.ink else m.t.muted)
        T(e?.let { studio.muse.core.Pricing.money(it.estimate) } ?: "—", m.type.h2.copy(fontSize = 22.sp, lineHeight = 24.sp), if (available) m.t.ink else m.t.muted, maxLines = 1)
        T(if (!available) "Not available" else e?.let { "${FakeSuiteSecs(it.seconds)} s · ${it.resolution ?: ""}" } ?: " ", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
    }
}

private fun FakeSuiteSecs(s: Double) = studio.muse.app.data.FakeSuite.fmtSeconds(s)
