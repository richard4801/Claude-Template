package studio.muse.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The maths of the rig's drum picker (the owner-approved design/drum-wheels-prototype.html): positions are in items
 * (0 = first item centred), drums of 5+ items loop, shorter ones rubber-band at the ends; a fling decays towards a
 * detent and a critically damped spring settles it with no overshoot. Pure, so the Mac (MuseCore RigDrumMath) and this
 * port are tested against the same numbers.
 */
object RigDrumMath {
    const val STEP_DEGREES = 21.0
    const val TAU = 0.325   // momentum time constant (s), like a native scroll
    const val K = 170.0     // spring stiffness

    fun loops(n: Int) = n >= 5

    /** Rounds halves up (floor(x + 0.5)) on both platforms, so a fling ends on the same detent everywhere. */
    fun roundHalfUp(x: Double) = kotlin.math.floor(x + 0.5)

    fun wrap(i: Int, n: Int) = ((i % n) + n) % n

    /** Signed distance in items from [pos] to item [i]; the shortest way round when the drum loops. */
    fun delta(i: Int, pos: Double, n: Int, loop: Boolean): Double {
        var d = i - pos
        if (loop) d -= n * roundHalfUp(d / n)
        return d
    }

    /** The item under the band at [pos]. */
    fun nearest(pos: Double, n: Int, loop: Boolean): Int {
        val r = roundHalfUp(pos).toInt()
        return if (loop) wrap(r, n) else r.coerceIn(0, n - 1)
    }

    /** Dragging past the ends of a drum that doesn't loop: a rubber band, at most 0.6 of an item. */
    fun clampSoft(pos: Double, n: Int, loop: Boolean): Double {
        if (loop) return pos
        val last = (n - 1).toDouble()
        return when {
            pos < 0 -> -min(0.6, -pos * 0.35)
            pos > last -> last + min(0.6, (pos - last) * 0.35)
            else -> pos
        }
    }

    /** Where a fling at [velocity] items/s lands: always on a detent. Looping drums keep the position unwrapped. */
    fun flingTarget(pos: Double, velocity: Double, n: Int, loop: Boolean, tau: Double = TAU): Double {
        val t = roundHalfUp(pos + velocity * tau)
        return if (loop) t else t.coerceIn(0.0, (n - 1).toDouble())
    }

    /** The fling's position [elapsed] seconds after release, decaying from [start] onto [target]. */
    fun decay(start: Double, target: Double, elapsed: Double, tau: Double = TAU) = target - (target - start) * exp(-elapsed / tau)

    /** One step of the settling spring: [x] is the distance from the detent, [v] its velocity. */
    fun springStep(x: Double, v: Double, dt: Double, k: Double = K): Pair<Double, Double> {
        val h = min(dt, 0.032)
        val c = 2 * sqrt(k)
        val a = -k * x - c * v
        val nv = v + a * h
        return (x + nv * h) to nv
    }

    fun settled(x: Double, v: Double) = abs(x) < 0.002 && abs(v) < 0.01

    data class ItemLook(val visible: Boolean, val y: Double, val scale: Double, val alpha: Double, val rotationDegrees: Double, val brightness: Double)

    /** How an item [d] items from the band is drawn on a drum whose rows are [itemHeight] tall. */
    fun look(d: Double, itemHeight: Double, selected: Boolean): ItemLook {
        val deg = d * STEP_DEGREES
        val rad = deg * PI / 180
        val falloff = cos(rad)
        val r = itemHeight / (2 * sin(STEP_DEGREES * PI / 360))
        return ItemLook(
            visible = abs(deg) <= 95,
            y = r * sin(rad),
            scale = 0.78 + 0.22 * falloff,
            alpha = max(0.0, falloff).pow(2.2),
            rotationDegrees = -deg,
            brightness = if (selected) 1.0 else 0.55 + 0.35 * falloff,
        )
    }
}
