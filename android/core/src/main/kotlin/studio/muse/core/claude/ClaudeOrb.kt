package studio.muse.core.claude

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Claude's orb (owner, 2026-11-12: Option C2 "alive"; plans/design/claude-panel/orb-alive-*.png): a glass ball with
// luminous 3D smoke inside, the glass wobbling, breathing and turning a little with it. ONE state machine, fed only by
// real events (the chat stream, cards, jobs), the same as the Mac's MuseCore ClaudeOrb + ClaudeOrbShader, so both apps
// move the same way. The app's AGSL shader (Android 13+) reads [ClaudeOrbUniforms]; older phones draw a still tint.

enum class OrbState { IDLE, THINKING, OPERATING, WAITING, ERROR }

/** How a state looks: [swirl] the flow speed (phase per second), [glow] the halo/edge, [breath] seconds per breath. */
data class OrbLook(val swirl: Double, val band: Double, val glow: Double, val breath: Double, val breathDepth: Double,
                   val sweep: Boolean, val flashes: Boolean, val danger: Boolean, val edge: Double)

/** The shader's inputs (ClaudeOrb.agsl ≙ the Mac's ClaudeOrb.metal). */
data class ClaudeOrbUniforms(val bright: Double, val current: Double, val danger: Double, val pulse: Double, val breath: Double,
                             val wobble: Double, val pop: Double)

class ClaudeOrb {
    var turnRunning = false; private set
    private val openUi = mutableSetOf<String>()
    var waitingCount = 0; private set
    var jobRunning = false; private set
    var errorUntil: Double? = null; private set
    var pulses = 0; private set
    var lastPulseAt = Double.NEGATIVE_INFINITY; private set
    /** The person is typing: the edge stays calm. */
    var typing = false

    // ---- events in
    fun turnStarted() { turnRunning = true; errorUntil = null }
    fun chunk(now: Double) { turnRunning = true; pulse(now) }
    fun turnEnded(ok: Boolean, now: Double) { turnRunning = false; if (!ok) errorUntil = now + ERROR_HOLD }
    fun uiCallBegan(id: String, now: Double) { openUi += id; pulse(now) }
    fun uiCallEnded(id: String, ok: Boolean = true, now: Double) { openUi -= id; if (!ok) errorUntil = now + ERROR_HOLD }
    fun stopped() = openUi.clear()
    fun changeApplied(now: Double) = pulse(now)
    fun waiting(count: Int) { waitingCount = max(0, count) }
    fun job(running: Boolean, failed: Boolean = false, now: Double) { jobRunning = running; if (failed) errorUntil = now + ERROR_HOLD }
    private fun pulse(now: Double) { pulses++; lastPulseAt = now }

    // ---- what it shows
    fun state(now: Double): OrbState = when {
        errorUntil?.let { now < it } == true -> OrbState.ERROR
        openUi.isNotEmpty() -> OrbState.OPERATING
        turnRunning || jobRunning -> OrbState.THINKING
        waitingCount > 0 -> OrbState.WAITING
        else -> OrbState.IDLE
    }

    /** The last pulse's flash at [now], 1 → 0 over [FLASH_DECAY] (0 under Reduce Motion). */
    fun pulse(now: Double, reduceMotion: Boolean = false): Double {
        if (reduceMotion || now < lastPulseAt) return 0.0
        val t = (now - lastPulseAt) / FLASH_DECAY
        return if (t >= 0.999) 0.0 else (1 - t) * (1 - t)
    }

    fun look(now: Double, reduceMotion: Boolean = false) = look(state(now), reduceMotion, typing)

    /** The glow 0…1 (halo and panel edge move together): the state's glow, its breath, the last flash. */
    fun glow(now: Double, reduceMotion: Boolean = false): Double {
        val l = look(now, reduceMotion)
        var g = l.glow
        if (l.breath > 0) g *= 1 - l.breathDepth * 0.5 * (1 - cos(2 * PI * now / l.breath))
        if (l.flashes && !typing) g += (1 - g) * 0.6 * pulse(now, reduceMotion)
        return g.coerceIn(0.0, 1.0)
    }

    fun edge(now: Double, reduceMotion: Boolean = false): Double {
        val l = look(now, reduceMotion)
        val base = if (l.glow > 0) glow(now, reduceMotion) / l.glow else 1.0
        return (l.edge * base).coerceIn(0.0, 1.0)
    }

    /** Frames per second to draw at: 0 when nothing moves, 12 idle or error, 30 at most. */
    fun frameRate(now: Double, reduceMotion: Boolean = false): Int {
        val l = look(now, reduceMotion)
        val moves = l.swirl > 0 || l.breath > 0 || l.sweep || pulse(now, reduceMotion) > 0
        if (!moves) return 0
        val s = state(now)
        return if (s == OrbState.IDLE || s == OrbState.ERROR) 12 else 30
    }

    /** The shader's uniforms at [now] (Reduce Motion: the shape stays still). */
    fun uniforms(now: Double, reduceMotion: Boolean = false): ClaudeOrbUniforms {
        val s = state(now); val l = look(now, reduceMotion)
        return uniforms(s, l, now, pulse(now, reduceMotion), reduceMotion)
    }

    companion object {
        const val ERROR_HOLD = 8.0
        const val FLASH_DECAY = 0.6
        /** The ball fills 1/SCALE of its frame (room for the wobble and the pop). */
        const val SCALE = 1.1
        /** The smoke's colours (magenta, violet, blue, cyan) and the error ones: the panel edge uses them too. */
        val PALETTE = listOf(0xFFFF3DA8, 0xFF8E5BFF, 0xFF3B82FF, 0xFF2FE0C0)
        val ERROR_PALETTE = listOf(0xFFFF4D3D, 0xFFFF8A2B, 0xFFD9302B, 0xFFFFB347)

        fun look(s: OrbState, reduceMotion: Boolean = false, typing: Boolean = false): OrbLook {
            var l = when (s) {
                OrbState.IDLE -> OrbLook(1.05, 0.85, 0.10, 6.0, 0.35, false, false, false, 0.12)
                OrbState.THINKING -> OrbLook(2.7, 1.1, 0.28, 0.0, 0.0, false, true, false, 0.30)
                OrbState.OPERATING -> OrbLook(2.4, 1.0, 0.35, 0.0, 0.0, true, true, false, 0.40)
                OrbState.WAITING -> OrbLook(0.75, 1.15, 0.45, 3.2, 0.20, false, false, false, 0.45)
                OrbState.ERROR -> OrbLook(0.45, 0.9, 0.30, 0.0, 0.0, false, false, true, 0.35)
            }
            if (reduceMotion) l = l.copy(swirl = 0.0, breath = 0.0, breathDepth = 0.0, sweep = false, flashes = false)
            if (typing) l = l.copy(edge = min(l.edge, 0.15))
            return l
        }

        /** The phase only moves forward, at the state's speed; a stalled frame counts at most 0.25 s. */
        fun advance(phase: Double, dt: Double, look: OrbLook) = phase + dt.coerceIn(0.0, 0.25) * look.swirl

        fun uniforms(s: OrbState, look: OrbLook, time: Double, pulse: Double, reduceMotion: Boolean = false): ClaudeOrbUniforms {
            val breath = if (look.breath > 0) 0.5 - 0.5 * cos(2 * PI * time / look.breath) else 0.0
            var u = when (s) {
                OrbState.IDLE -> ClaudeOrbUniforms(0.85, 0.0, 0.0, 0.0, breath, 0.02, 0.0)
                OrbState.THINKING -> ClaudeOrbUniforms(1.1, 0.0, 0.0, pulse, 0.0, 0.05, 0.0)
                OrbState.OPERATING -> ClaudeOrbUniforms(1.0, 1.6, 0.0, pulse, 0.0, 0.045, 0.0)
                OrbState.WAITING -> ClaudeOrbUniforms(1.15, 0.0, 0.0, 0.0, breath, 0.025, 0.0)
                OrbState.ERROR -> ClaudeOrbUniforms(0.9, 0.0, 1.0, 0.0, 0.0, 0.015, 0.0)
            }
            u = u.copy(pop = 0.006 * sin(time * 0.7) + 0.035 * u.pulse + 0.02 * u.breath)
            if (reduceMotion) u = u.copy(wobble = 0.0, pop = 0.0, pulse = 0.0, breath = 0.0)
            return u
        }
    }
}

/** The live activity strip: "Opening Swap… setting outfit…", a percentage. Steps come from the chat's tool steps. */
class ClaudeActivity {
    private val steps = ArrayDeque<String>()
    var progress: Double? = null
    val isActive get() = steps.isNotEmpty() || progress != null
    val line: String get() {
        val last = steps.toList().takeLast(2)
        if (last.isEmpty()) return if (progress != null) "Working…" else ""
        if (last.size == 1) return last[0]
        val b = last[1]
        return "${last[0]} ${b.take(1).lowercase()}${b.drop(1)}"
    }
    val percent: String? get() = progress?.let { "${(it.coerceIn(0.0, 1.0) * 100).let { p -> abs(p).toInt().let { i -> if (p - i >= 0.5) i + 1 else i } }}%" }
    fun step(s: String) { if (steps.lastOrNull() != s) steps.addLast(s); while (steps.size > 6) steps.removeFirst() }
    fun clear() { steps.clear(); progress = null }
}
