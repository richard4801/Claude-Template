package studio.muse.app.ui.screens.claude

import android.graphics.RuntimeShader
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.Caption
import studio.muse.app.ui.screens.PrimaryButton
import studio.muse.app.ui.screens.SecondaryButton
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.claude.CardText
import studio.muse.core.claude.ClaudeCard
import studio.muse.core.claude.ClaudeOrb
import studio.muse.core.claude.ContextItem
import studio.muse.core.claude.OrbState

// The Claude panel on Android (owner's chosen reference, 2026-11-12; the Mac's ClaudeCards / ClaudeOrbView /
// ClaudeContextStrip): cards in the chat, Claude's orb (the C2 "alive" shader as AGSL on Android 13+, a still tint
// below), the floating panel's living edge, and the context strip. Logic lives in :core (studio.muse.core.claude).

// ---------------------------------------------------------------- cards

@Composable
internal fun ChatCardView(item: ChatItem.Card, answer: String?, actions: ClaudeChatActions) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    Column(Modifier.fillMaxWidth().padding(vertical = MuseSpace.s1).clip(shape).background(m.roles.raised)
        .border(1.dp, m.roles.hairline, shape).padding(MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        when (val c = item.card) {
            is ClaudeCard.Plan -> PlanCard(c)
            is ClaudeCard.Media -> ClipCard(c)
            is ClaudeCard.Changes -> ChangesCard(c) { row, what -> actions.undoCard(item.messageId, row, what) }
            is ClaudeCard.Approve -> ApproveCard(c, answer) { yes -> actions.answerCard(item.messageId, c.target, yes) }
        }
    }
}

@Composable
private fun CardTitle(text: String, trailing: String? = null) {
    val m = muse
    Row(verticalAlignment = Alignment.CenterVertically) {
        T(text, m.scale.heading, m.roles.ink, Modifier.weight(1f), maxLines = 2)
        trailing?.let { T(it, m.scale.caption, m.roles.ink2) }
    }
}

@Composable
private fun PlanCard(c: ClaudeCard.Plan) {
    val m = muse
    CardTitle(c.title, "${c.done} of ${c.steps.size}")
    val next = c.steps.indexOfFirst { !it.done }
    c.steps.forEachIndexed { i, s ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2),
            modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = "${s.text}, " + if (s.done) "done" else if (i == next) "next" else "to do" }) {
            Box(Modifier.size(18.dp).clip(CircleShape).background(if (s.done) m.roles.positive else Color.Transparent)
                .border(1.5.dp, if (s.done) m.roles.positive else if (i == next) m.roles.accent else m.roles.hairline, CircleShape), contentAlignment = Alignment.Center) {
                if (s.done) Ic("check", 12.dp, m.roles.onAction)
            }
            T(s.text, m.scale.body, if (s.done) m.roles.ink2 else m.roles.ink, weight = if (i == next) FontWeight.Medium else null)
        }
    }
}

@Composable
private fun ClipCard(c: ClaudeCard.Media) {
    val m = muse
    CardTitle(c.title, c.durationSec?.let { CardText.clock(it) })
    c.summary?.let { Caption(it) }
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(m.radii.control)).background(Color.Black)) {
        StageVideo(c.video.url, null, muted = true, modifier = Modifier.matchParentSize())
    }
    if (c.moments.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        T("Key moments", m.scale.label, m.roles.ink2)
        for (mo in c.moments) Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            T(mo.timecode, m.scale.caption.copy(fontFeatureSettings = "tnum"), m.roles.ink2, Modifier.width(76.dp))
            T(mo.label, m.scale.body, m.roles.ink, Modifier.weight(1f))
        }
    }
}

@Composable
private fun ChangesCard(c: ClaudeCard.Changes, undo: (Int, String) -> Unit) {
    val m = muse
    CardTitle(c.title)
    c.rows.forEachIndexed { i, r ->
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = CardText.change(r) }) {
            Column(Modifier.weight(1f)) {
                T(r.what, m.scale.caption, m.roles.ink2)
                T(r.to, m.scale.body, if (r.undone) m.roles.ink2 else m.roles.ink, maxLines = 2)
            }
            when {
                r.undone -> T("Undone", m.scale.caption, m.roles.ink2)
                r.undoable -> T("Undo", m.scale.label, m.roles.link, Modifier.clip(RoundedCornerShape(m.radii.chip)).press { undo(i, r.what) }
                    .padding(horizontal = MuseSpace.s2, vertical = MuseSpace.s1).semantics { contentDescription = "Undo ${r.what}" })
            }
        }
    }
}

@Composable
private fun ApproveCard(c: ClaudeCard.Approve, answer: String?, answerIt: (Boolean) -> Unit) {
    val m = muse
    CardTitle(c.title)
    c.subtitle?.let { Caption(it) }
    val money = m.scale.body.copy(fontFeatureSettings = "tnum")
    for (l in c.lines) Row { T(l.label, m.scale.body, m.roles.ink2, Modifier.weight(1f)); T(CardText.money(l.usd), money, m.roles.ink) }
    Box(Modifier.fillMaxWidth().height(1.dp).background(m.roles.hairline))
    Row { T("Total", m.scale.body, m.roles.ink, Modifier.weight(1f), weight = FontWeight.SemiBold); T(CardText.money(CardText.total(c.lines, c.totalUsd)), money, m.roles.ink, weight = FontWeight.SemiBold) }
    if (answer != null) Caption(if (answer == "…") "Answering…" else answer)
    else Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        SecondaryButton(c.declineLabel, { answerIt(false) }, Modifier.weight(1f), height = 44.dp)
        PrimaryButton(c.approveLabel, { answerIt(true) }, Modifier.weight(1f))
    }
}

// ---------------------------------------------------------------- the orb

/** The chat's orb, fed only by real events from the thread (the turn, its streamed text, tool steps, a failed turn). */
@Stable
class ChatOrb internal constructor() {
    val orb = ClaudeOrb()
    /** Seconds since the orb was made (the shader's clock). */
    var now by mutableDoubleStateOf(0.0)
    var phase by mutableDoubleStateOf(0.0)
    var state by mutableStateOf(OrbState.IDLE)
}

@Composable
internal fun rememberChatOrb(ui: ClaudeChatUi): ChatOrb {
    val o = remember { ChatOrb() }
    val t0 = remember { System.nanoTime() }
    fun now() = (System.nanoTime() - t0) / 1e9
    val turn = ui.turn
    val text = turn?.parts?.sumOf { (it as? LivePart.Text)?.text?.length ?: 0 } ?: 0
    val running = turn?.parts?.filterIsInstance<LivePart.Tool>()?.filter { it.status == "running" }?.map { it.id }.orEmpty()
    LaunchedEffect(turn?.id, turn?.active) {
        if (turn?.active == true) o.orb.turnStarted() else if (o.orb.turnRunning) o.orb.turnEnded(turn?.error == null && turn?.state != "failed", now())
    }
    LaunchedEffect(text) { if (text > 0 && turn?.active == true) o.orb.chunk(now()) }
    LaunchedEffect(running) {
        running.forEach { o.orb.uiCallBegan(it, now()) }
        if (running.isEmpty()) o.orb.stopped()
    }
    LaunchedEffect(ui.cardAnswers.size) { if (ui.cardAnswers.isNotEmpty()) o.orb.changeApplied(now()) }
    val reduce = rememberReduceMotion()
    // Frames only while something moves (0 / 12 / 30 fps, as on the Mac).
    LaunchedEffect(reduce) {
        var last = now()
        while (true) {
            val n = now()
            o.orb.look(n, reduce).let { l -> o.phase = ClaudeOrb.advance(o.phase, n - last, l) }
            last = n; o.now = n; o.state = o.orb.state(n)
            val fps = o.orb.frameRate(n, reduce)
            if (fps == 0) delay(250) else { delay((1000L / fps) - 2); withFrameNanos { } }
        }
    }
    return o
}

@Composable
private fun rememberReduceMotion(): Boolean {
    val ctx = LocalContext.current
    return remember { android.provider.Settings.Global.getFloat(ctx.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}

/** Claude's orb: the C2 "alive" glass ball with luminous smoke (AGSL, Android 13+); a still tinted ball below that. */
@Composable
fun ClaudeOrbView(o: ChatOrb, size: Dp, modifier: Modifier = Modifier) {
    val m = muse
    val reduce = rememberReduceMotion()
    val page = m.roles.canvas
    val light = !m.t.dark
    Box(modifier.size(size).semantics { contentDescription = "Claude, " + orbWords(o.state) }) {
        if (Build.VERSION.SDK_INT >= 33) OrbShaderCanvas(o, reduce, page, light)
        else OrbStill(o.state, page, light)
    }
}

private fun orbWords(s: OrbState) = when (s) {
    OrbState.IDLE -> "ready"; OrbState.THINKING -> "thinking"; OrbState.OPERATING -> "working in the app"
    OrbState.WAITING -> "waiting for you"; OrbState.ERROR -> "something went wrong"
}

@RequiresApi(33)
@Composable
private fun OrbShaderCanvas(o: ChatOrb, reduce: Boolean, page: Color, light: Boolean) {
    val shader = remember { RuntimeShader(ORB_AGSL) }
    val brush = remember { ShaderBrush(shader) }
    Canvas(Modifier.fillMaxSize()) {
        val n = o.now
        val u = o.orb.uniforms(n, reduce)
        shader.setFloatUniform("size", this.size.width, this.size.height)
        shader.setFloatUniform("scale", ClaudeOrb.SCALE.toFloat())
        shader.setFloatUniform("phase", o.phase.toFloat())
        shader.setFloatUniform("time", if (reduce) 0f else n.toFloat())
        shader.setFloatUniform("bright", u.bright.toFloat())
        shader.setFloatUniform("spin", u.current.toFloat())
        shader.setFloatUniform("danger", u.danger.toFloat())
        shader.setFloatUniform("pulse", u.pulse.toFloat())
        shader.setFloatUniform("breath", u.breath.toFloat())
        shader.setFloatUniform("lightPage", if (light) 1f else 0f)
        shader.setFloatUniform("wobble", u.wobble.toFloat())
        shader.setFloatUniform("pop", u.pop.toFloat())
        shader.setFloatUniform("page", page.red, page.green, page.blue)
        drawRect(brush)
    }
}

/** Below Android 13: the ball still, tinted with the state's colours (no animation, the same silhouette and rim). */
@Composable
private fun OrbStill(s: OrbState, page: Color, light: Boolean) {
    val pal = (if (s == OrbState.ERROR) ClaudeOrb.ERROR_PALETTE else ClaudeOrb.PALETTE).map { Color(it) }
    Canvas(Modifier.fillMaxSize()) {
        val r = this.size.minDimension / 2f / ClaudeOrb.SCALE.toFloat()
        val c = center
        drawCircle(page, r, c)
        drawCircle(Brush.radialGradient(listOf(pal[0].copy(alpha = .9f), pal[1].copy(alpha = .8f), pal[2].copy(alpha = .55f), Color.Transparent),
            Offset(c.x - r * .15f, c.y + r * .2f), r * 1.05f), r, c)
        drawCircle(Brush.radialGradient(listOf(pal[3].copy(alpha = .45f), Color.Transparent), Offset(c.x + r * .35f, c.y - r * .1f), r * .6f), r, c)
        if (!light) drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = .35f), Color.Transparent), Offset(c.x + r * .1f, c.y + r * .25f), r * .35f), r, c)
        drawCircle(Brush.radialGradient(listOf(Color.Transparent, Color.White.copy(alpha = if (light) .25f else .35f)), c, r), r, c, style = Stroke(r * .06f))
        drawOval(Color.White.copy(alpha = .14f), Offset(c.x - r * .55f, c.y - r * .8f), Size(r * .9f, r * .3f))
    }
}

/**
 * ClaudeOrb.metal (the Mac) ≙ design/direction/orb_alive.py, in AGSL: keep the three in step. AGSL has no `thread`
 * references (out params instead) and its loops need constant bounds; the picture is the same.
 */
private val ORB_AGSL = """
uniform float2 size; uniform float scale; uniform float phase; uniform float time; uniform float bright; uniform float spin;
uniform float danger; uniform float pulse; uniform float breath; uniform float lightPage; uniform float wobble; uniform float pop;
uniform float3 page;

float sstep(float e0, float e1, float x) { float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float hash3(float3 p) { return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise3(float3 p) {
    float3 i = floor(p); float3 f = fract(p); float3 u = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(hash3(i), hash3(i + float3(1, 0, 0)), u.x), mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), u.x), u.y);
    float b = mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), u.x), mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), u.x), u.y);
    return mix(a, b, u.z);
}
float fbm4(float3 p) { float v = 0.0; float a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise3(p); p = p * 2.07 + float3(1.7, 9.2, 4.1); a *= 0.5; } return v; }
float fbm3(float3 p) { float v = 0.0; float a = 0.5; for (int i = 0; i < 3; i++) { v += a * noise3(p); p = p * 2.07 + float3(1.7, 9.2, 4.1); a *= 0.5; } return v; }

float3 dye(float3 p) {
    float h = fbm3(p * 0.9 + float3(11.0, 3.0, phase * 0.05));
    float g = sstep(0.62, 0.75, fbm3(p * 1.3 + float3(-4.0, 7.0, 2.0)));
    float3 m = float3(1.0, 0.24, 0.66); float3 v = float3(0.56, 0.33, 1.0); float3 bl = float3(0.22, 0.48, 1.0); float3 c = float3(0.15, 0.9, 0.95);
    float t = clamp((h - 0.3) * 2.5, 0.0, 1.0) * 3.0;
    float3 col = t < 1.0 ? mix(m, v, t) : (t < 2.0 ? mix(v, bl, t - 1.0) : mix(bl, c, t - 2.0));
    col = mix(col, float3(1.0, 0.72, 0.3), g * 0.8);
    float3 err = mix(float3(1.0, 0.25, 0.1), float3(1.0, 0.62, 0.15), clamp((h - 0.35) * 3.0, 0.0, 1.0));
    return mix(col, err, danger);
}

float density(float3 p, out float3 q) {
    float t = phase;
    float3 w = float3(fbm3(p * 1.1 + float3(0.0, -t * 0.18, t * 0.07)), fbm3(p * 1.1 + float3(5.2, 1.3 - t * 0.2, -t * 0.05)), fbm3(p * 1.1 + float3(2.7, 8.1, t * 0.09)));
    q = p + (w - 0.5) * 1.3 + float3(-spin * t * 0.5, -t * 0.12, 0.0);
    float d = fbm4(q * 2.8 + float3(0.0, 0.0, t * 0.04));
    float edge = sstep(0.86, 0.45, length(p));
    float low = mix(1.15, 0.6, sstep(-0.6, 0.7, p.y));
    float thick = mix(0.5, 0.42, danger) - 0.04 * bright;
    d = sstep(thick, thick + 0.2, d) * edge * low;
    float age = 1.0 - pulse;
    float3 c = float3(0.18 * sin(time * 1.3), -0.55 + 0.55 * age, 0.1 * cos(time * 1.1));
    d += pulse * sstep(0.32 + 0.2 * age, 0.0, length((p - c) * float3(1.0, 0.7, 1.0)) - 0.15 * (fbm3(p * 4.0 + t) - 0.5));
    return d;
}

half4 main(float2 position) {
    float2 px = float2(position.x - 0.5 * size.x, 0.5 * size.y - position.y) / (0.5 * min(size.x, size.y)) * scale;
    float2 drift = float2(0.012 * sin(phase * 0.31) + 0.015 * spin, 0.01 * cos(phase * 0.27));
    float ang = atan(px.y - drift.y, px.x - drift.x);
    float3 dir = float3(cos(ang), sin(ang), 0.0);
    float press = fbm3(dir * 0.9 + float3(0.0, -phase * 0.12, phase * 0.05));
    float wob = (fbm3(dir * 1.4 + float3(phase * 0.2, 3.0, -phase * 0.15)) - 0.5) * 2.0;
    float shape = (1.0 + pop) * (1.0 + wobble * (0.6 * wob + 0.8 * (press - 0.45)));
    float2 uv = (px - drift) / shape;
    float r = length(uv);
    if (r >= 1.0) { return half4(0.0); }
    float nz = sqrt(1.0 - r * r);
    float br = bright * (1.0 + 0.5 * pulse) * (1.0 - 0.3 * breath);

    bool light = lightPage > 0.5;
    float shade = mix(light ? 0.9 : 0.03, light ? 0.97 : 0.3, sstep(0.3, -0.9, uv.y));
    float3 glass = page * shade + (light ? float3(0.0) : float3(0.015, 0.015, 0.025));

    float z0 = nz * 0.9; float z1 = -nz * 0.9; float dz = (z0 - z1) / 22.0;
    float3 acc = float3(0.0); float T = 1.0;
    for (int i = 0; i < 22; i++) {
        float z = z0 - (float(i) + 0.5) * dz;
        float3 p = float3(uv, z);
        float3 q;
        float d = density(p, q);
        if (d > 0.01) {
            float3 qs;
            float sh = density(p + float3(-0.12, 0.16, 0.12), qs);
            float3 col = dye(q);
            float hot = sstep(0.45, 0.95, d);
            float3 e = mix(col, float3(1.0, 0.97, 0.95), hot * 0.85) * d * (1.0 + 0.5 * hot) * (1.0 - 0.45 * clamp(sh, 0.0, 1.0));
            e *= mix(0.55, 1.0, (z - z1) / max(z0 - z1, 1e-3));
            acc += T * e * dz * 6.5 * br;
            T *= exp(-d * dz * 4.5);
            if (T < 0.03) { break; }
        }
    }
    float dense = 1.0 - T;

    float f = pow(1.0 - nz, 3.0);
    float where = 0.35 + 0.65 * max(sstep(0.4, -0.9, uv.y) * sstep(0.2, -0.8, uv.x), sstep(0.3, 0.95, uv.x));
    float3 smokeTint = acc / max(0.15, max(acc.r, max(acc.g, acc.b)));
    float3 rim = float3(f, pow(f, 1.15), pow(f, 1.3)) * 0.55 * where + smokeTint * f * 0.5 * clamp(dense * 2.0, 0.0, 1.0) * br;
    float tiltA = 0.07 * sin(phase * 0.23) + 0.09 * spin;
    float2 su = float2(cos(tiltA) * uv.x - sin(tiltA) * uv.y, sin(tiltA) * uv.x + cos(tiltA) * uv.y);
    float3 spec = float3(1.0) * exp(-(pow(su.x + 0.12, 2.0) / 0.22 + pow(su.y - 0.62, 2.0) / 0.035)) * 0.16;

    float3 col;
    if (light) {
        float a = clamp(dense * 1.25, 0.0, 0.95);
        float3 dyeC = clamp(acc / max(0.2, max(acc.r, max(acc.g, acc.b))), 0.0, 1.0);
        col = mix(glass, dyeC, a) + rim * 0.55 - float3(0.05) * f + spec * 0.6;
    } else {
        float3 lit = 1.0 - exp(-acc * 1.15);
        col = glass * T + lit + rim + spec;
    }
    float aa = sstep(1.0, 0.985, r);
    return half4(half3(clamp(col, 0.0, 1.0) * aa), half(aa));
}
"""

// ---------------------------------------------------------------- the living edge

/**
 * The floating panel's living edge: a thin line around the panel in the orb's colours, glowing with Claude's state
 * (calm when idle or while typing, brighter while working, red on an error). Drawn over the panel, never over content.
 */
@Composable
fun ClaudeLivingEdge(modifier: Modifier, shape: Shape, orb: ChatOrb? = null) {
    val o = orb ?: ClaudePanelOrb.current ?: return
    val reduce = rememberReduceMotion()
    val n = o.now
    val edge = o.orb.edge(n, reduce).toFloat()
    if (edge <= 0.01f) return
    val pal = (if (o.state == OrbState.ERROR) ClaudeOrb.ERROR_PALETTE else ClaudeOrb.PALETTE).map { Color(it) }
    Box(modifier.drawBehind {
        val outline: Outline = shape.createOutline(size, layoutDirection, this)
        val c = Offset(size.width / 2f, size.height / 2f)
        val brush = Brush.sweepGradient((pal + pal.first()).map { it.copy(alpha = edge) }, c)
        drawOutline(outline, brush, style = Stroke(1.5.dp.toPx()))
    })
}

/** The orb the open panel shows, so the frame's living edge glows with the same state as the header's orb. */
val ClaudePanelOrb = androidx.compose.runtime.compositionLocalOf<ChatOrb?> { null }

// ---------------------------------------------------------------- the context strip

/** What Claude sees here now: small thumbnails with a tiny label (clip, her, outfit, background, refs, guide, model). */
@Composable
fun ClaudeContextStrip(items: List<ContextItem>, modifier: Modifier = Modifier) {
    if (items.isEmpty()) return
    val m = muse
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        T("Claude sees", m.scale.caption, m.roles.ink2)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            for (i in items) Column(Modifier.width(56.dp).semantics(mergeDescendants = true) { contentDescription = i.label + (i.detail?.let { ", $it" } ?: "") },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                val shape = RoundedCornerShape(m.radii.chip)
                Box(Modifier.size(44.dp).clip(shape).background(m.roles.field).border(1.dp, m.roles.hairline, shape), contentAlignment = Alignment.Center) {
                    when {
                        i.image != null -> AsyncImage(i.image, null, Modifier.matchParentSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                        i.words != null -> T(i.words!!, m.scale.micro, m.roles.ink2, Modifier.padding(3.dp), maxLines = 3)
                        else -> Ic(contextIcon(i.kind), 18.dp, m.roles.ink2)
                    }
                    if (i.isVideo && i.image != null) Ic("play", 14.dp, Color.White)
                }
                T(i.label, m.scale.micro, m.roles.ink2, maxLines = 1)
            }
        }
    }
}

private fun contextIcon(k: ContextItem.Kind) = when (k) {
    ContextItem.Kind.CLIP, ContextItem.Kind.GUIDE -> "video-camera"
    ContextItem.Kind.CHARACTER, ContextItem.Kind.FACE -> "user"
    ContextItem.Kind.OUTFIT, ContextItem.Kind.PRODUCT -> "t-shirt"
    ContextItem.Kind.BACKGROUND -> "mountains"
    ContextItem.Kind.FRAME, ContextItem.Kind.REFERENCE -> "image"
    ContextItem.Kind.AUDIO -> "music-note"
    ContextItem.Kind.MODEL -> "sparkle"
}
