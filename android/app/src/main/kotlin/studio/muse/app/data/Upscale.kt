package studio.muse.app.data

import studio.muse.core.Pricing
import kotlin.math.roundToLong

// Upscale on a finished take (plans/api.md "App clean-up" §2, built 2026-11-06): POST /v1/takes/{id}/upscale {size}. Pure, so
// the price maths and the "Soon" rules are unit-tested. Every price comes from features.video.addons[upscale].sizes[] (the
// server's $ per output second), times the take's length.

/** One size of the Upscale sheet: its label and frame, and either its price ([available]) or "Soon". */
data class UpscaleChoice(val id: String, val label: String, val width: Int, val height: Int, val available: Boolean, val price: Double?) {
    /** "$0.32", or "Soon" when the size can't be picked. */
    val priceText: String get() = if (available && price != null) Pricing.money(price) else "Soon"
    val frame: String get() = "$width × $height"
}

object UpscaleOffer {
    /** The take's length for the price: its own `durationSec`, else the seconds its job rendered. */
    fun seconds(take: Take, job: Job?): Double? = take.durationSec?.takeIf { it > 0 } ?: job?.request?.seconds?.takeIf { it > 0 }

    /** price × the take's seconds, to the cent's hundredth (the server holds the same figure); null without a price or a length. */
    fun price(size: UpscaleSizeInfo, seconds: Double?): Double? {
        val p = size.price ?: return null
        val s = seconds?.takeIf { it > 0 } ?: return null
        return (p * s * 10_000).roundToLong() / 10_000.0
    }

    /**
     * The three sizes for [up] on a take of [seconds]. A size is pickable when the add-on and the size are available, it has
     * a price and the take has a length; [soon] (the server just answered upscale_unavailable) greys every size.
     */
    fun choices(up: AddonInfo, seconds: Double?, soon: Boolean = false): List<UpscaleChoice> =
        up.sizes.ifEmpty { VideoFeatures.DEFAULT.upscale.sizes }.map { z ->
            val price = price(z, seconds)
            UpscaleChoice(z.id, z.label.ifBlank { z.id }, z.width, z.height, !soon && up.available && z.available && price != null, price.takeIf { !soon && up.available && z.available })
        }

    /** The add-on is live: at least one size is priced and available. */
    fun live(up: AddonInfo): Boolean = up.available && up.sizes.any { it.available && it.price != null }

    /** A take Upscale is offered on: a finished render with a file (demo: simulated takes too), not already an upscale. */
    fun canUpscale(t: Take, demo: Boolean): Boolean =
        t.kind == "take" && (t.videoUrl != null || demo) && !t.label.startsWith("Upscale") && !t.engineLabel.startsWith("Upscale")

    const val UNAVAILABLE = "upscale_unavailable"
    const val SOON_TEXT = "Upscale is coming soon"
}
