package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import studio.muse.app.data.ErrorText
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.VideoFeatures
import studio.muse.app.ui.screens.failLine
import studio.muse.app.ui.screens.memberPhase
import studio.muse.app.ui.screens.statusLine

/** App clean-up (plans/api.md "App clean-up" §1): members see results, time and price, never hardware or providers. */
class MemberTextTest {
    private val hardware = Regex("(?i)gpu|runpod|replicate|\\bh3\\b|\\blite\\b|steps?\\b|warm|start-up|h100|viggle")
    private fun job(phase: String, state: String = "running", queue: Int? = null, left: Double = 0.0, error: String? = null, refunded: Double = 0.0) =
        Job("j", "Dance", SampleData.SIENNA, "Sienna Vale", SampleData.GREEN, JobRequest("Dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP),
            state, 0.0, phase = phase, secondsLeft = left, totalSeconds = 600.0, cost = 0.14, queuePosition = queue, error = error, refunded = refunded)

    @Test fun phasesReadAsOutcomes() {
        assertEquals("Rendering · about 2 min · \$0.14", job("Rendering · ~2 min left", left = 120.0).statusLine())
        assertEquals("Waiting to start · \$0.14", job("Waiting to start", queue = 1).statusLine())
        assertEquals("#2 in line · about 9 min · \$0.14", job("#2 in line · starts in ~4 min", queue = 2, left = 540.0).statusLine())
        // Older servers' wording is translated.
        assertEquals("Rendering", memberPhase("step 4/10 · ~7 min left"))
        assertEquals("take 2/3 · Rendering", memberPhase("take 2/3 · Rendering on Replicate · ~3 min left"))
        assertEquals("Getting ready", memberPhase("Starting GPU · ~9 min left"))
        assertEquals("Waiting to start", memberPhase("Waiting for a GPU · 2nd in line"))
        assertEquals("Waiting to start", memberPhase("Waiting for Replicate · 2nd in line"))
        assertEquals("Waiting to start", memberPhase("Paused: the studio's GPU credit is low"))
        assertEquals("Waiting to start", memberPhase("Replicate is busy · retrying in 10s"))
        for (p in listOf("step 4/10 · ~7 min left", "Starting GPU", "Waiting for a GPU · 3rd in line", "Rendering on Replicate", "Lip sync · ~2 min left")) {
            assertFalse(p, hardware.containsMatchIn(job(p).statusLine()))
        }
    }

    @Test fun failuresAreMemberSafe() {
        assertEquals("Something went wrong · you weren't charged · \$0.14 back", job("Failed", "failed", error = "The GPU disconnected at step 3.", refunded = 0.14).failLine())
        assertEquals("Something went wrong · you weren't charged · \$0.14 back", job("Failed", "failed", error = "CUDA out of memory", refunded = 0.14).failLine())
        assertEquals("This clip was refused by the content filter · you weren't charged", job("Failed", "failed", error = "This clip was refused by the content filter · you weren't charged").failLine())
    }

    @Test fun errorTextNamesNoProviderOrHardware() {
        val codes = listOf("insufficient_balance", "insufficient_tokens", "over_job_limit", "over_allocation", "balance_unavailable", "topup_unavailable", "engine_unavailable",
            "image_engine_failed", "provider_refused", "provider_rate_limited", "provider_out_of_credit", "upscale_unavailable", "warm_not_allowed", "owner_balance_low",
            "no_gpu_free", "no_gpu_available", "not_warm")
        for (c in codes) assertFalse(c, hardware.containsMatchIn(ErrorText.of(c, "Replicate's safety filter refused this clip (GPU)")))
    }

    @Test fun defaultsOfferRenderEditAndUpscaleComingSoon() {
        val v = VideoFeatures.DEFAULT
        assertEquals(listOf("draft", "standard", "hd"), v.options.map { it.id })
        assertEquals(listOf("edit", "fast", "upscale"), v.addons.map { it.id })
        assertFalse(v.upscale.available)
        assertEquals(listOf("1080p", "2K", "4K"), v.upscale.sizes.map { it.label })
        for (o in v.options) assertFalse(o.detail, hardware.containsMatchIn(o.detail + o.label))
        for (o in v.addons) assertFalse(o.detail, hardware.containsMatchIn(o.detail + o.label))
    }
}
