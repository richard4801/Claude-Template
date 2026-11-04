package studio.muse.app.data

import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.formatClock
import kotlin.math.ceil
import kotlin.math.floor

/** Renders run this much faster than real time in the demo (same as the prototype and server/mock). */
const val DEMO_SPEED = 24.0

/** Seed data, identical to the prototype's state `S` and server/mock/data.js. */
object SampleData {
    const val SIENNA = "m_sienna"
    const val NOOR = "m_noor"
    const val GREEN = "o_green"
    const val CRYSTAL = "o_crystal"
    const val SAMPLE_CLIP = "clip_sample"
    const val BAD_CLIP = "clip_bad"
    const val SIENNA_LOOK = "young woman, long wavy honey-blonde hair with brown roots, green eyes, light freckles, tanned skin"

    /** Slot key → the bundled sample image used for that angle. */
    val SLOT_SAMPLE = linkedMapOf("face" to "face", "profile" to "profile", "front" to "g_front", "tq" to "g_tq", "side" to "g_side", "back" to "g_back")

    fun models(): List<Model> = listOf(
        Model(
            id = SIENNA, name = "Sienna Vale", age = 24, niche = "Fashion", look = SIENNA_LOOK, neverAdd = listOf("tattoos", "rings"),
            slots = SLOT_SAMPLE.map { (k, img) -> SheetSlot(k, ImageRef.asset(img)) }, outfitIds = listOf(GREEN, CRYSTAL),
        ),
        Model(id = NOOR, name = "Noor Adeyemi", age = 27, niche = "Beauty", slots = SLOT_SAMPLE.keys.map { SheetSlot(it) }),
    )

    fun outfits(): List<Outfit> = listOf(
        Outfit(GREEN, SIENNA, "Green set", "own", "Dark green cropped tee and drawstring shorts", listOf("g_front", "g_tq", "g_side", "g_back").map(ImageRef::asset)),
        Outfit(CRYSTAL, SIENNA, "Crystal dress", "describe", "Silver crystal cowl-neck mini dress", listOf("c_front", "c_tq", "c_face", "c_front").map(ImageRef::asset)),
    )

    private fun req(title: String, engine: Engine, steps: Int, outfit: String = GREEN) =
        JobRequest(title = title, modelId = SIENNA, outfitId = outfit, clipId = SAMPLE_CLIP, engine = engine.id, steps = steps)

    fun jobs(now: Long): List<Job> = listOf(
        Job("j1", "Kick test", SIENNA, "Sienna Vale", GREEN, req("Kick test", Engine.VIGGLE, 4), "done", 100.0, 1, 4, 4,
            "Done", 0.0, 95.0, 0.13, createdAt = now - 7_200_000, finishedAt = now - 7_000_000, thumb = ImageRef.asset("g_front")),
        Job("j2", "Bathroom trend", SIENNA, "Sienna Vale", CRYSTAL, req("Bathroom trend", Engine.H3, 30, CRYSTAL), "done", 100.0, 1, 30, 30,
            "Done", 0.0, 2760.0, 3.05, createdAt = now - 86_400_000, finishedAt = now - 83_640_000, thumb = ImageRef.asset("c_front")),
        Job("j0", "Mirror selfie", SIENNA, "Sienna Vale", GREEN, req("Mirror selfie", Engine.H3, 10), "failed", 18.0, 1, 3, 10,
            "Failed at step 3", 0.0, 608.0, 0.19, refunded = 0.19, error = "The GPU disconnected at step 3.", createdAt = now - 3_600_000, thumb = ImageRef.asset("g_tq")),
    )

    fun takes(now: Long): List<Take> = listOf(
        Take("t_j1", "take", "j1", 1, 1, "Kick test", "Fast · beta", "Fast · beta", 0.13, 7, "test", ImageRef.asset("g_front"), createdAt = now - 7_000_000),
        Take("t_j2", "take", "j2", 1, 1, "Bathroom trend", "30 steps", "Standard · 30 steps", 3.05, 42, "test", ImageRef.asset("c_front"), createdAt = now - 83_640_000),
        Take("t_g1", "take", null, 1, 1, "Living-room dance", "10 steps", "Standard · 10 steps", 0.67, 42, "test", ImageRef.asset("g_tq"), createdAt = now - 90_000_000),
        Take("t_g5", "take", null, 1, 1, "Living-room dance", "15 steps", "Standard · 15 steps", 0.99, 42, "test", ImageRef.asset("g_side"), createdAt = now - 95_000_000),
        Take("t_g4", "shot", null, 1, 1, "Shoot", "Shoot", "", 0.03, 0, "test", ImageRef.asset("c_front"), createdAt = now - 96_000_000),
        Take("t_g6", "shot", null, 1, 1, "Shoot", "Shoot", "", 0.03, 0, "test", ImageRef.asset("c_tq"), createdAt = now - 97_000_000),
    )

    fun balance() = Balance(balance = 6.07, month = 18.93, videos = 11)

    /** The good sample clip and the failing-clip example (third-party footage is never bundled; thumbnails are placeholders). */
    val sampleMeta = ClipMeta("Living-room dance", 9.4, 1080, 1920, 30)
    val badMeta = ClipMeta("Mirror trend (download)", 22.0, 1080, 1920, 30, people = 2, watermark = "TikTok logo")
}

/** Source clip checks. Same rules as server/mock/sim.js. People and watermark detection are server-side (mocked). */
object ClipRules {
    fun checks(m: ClipMeta): List<ClipCheck> = buildList {
        add(
            if (m.people == 1) ClipCheck("One person in frame", "Yes", "good")
            else ClipCheck("People in frame", "${m.people} found", "bad", "Crop it, or pick a clip with one person"),
        )
        add(
            if (m.watermark == null) ClipCheck("Watermark", "None", "good")
            else ClipCheck("Watermark", m.watermark, "bad", "Use the original file, not a download"),
        )
        val portrait = m.height >= m.width
        val sharp = minOf(m.width, m.height) >= 720
        add(
            when {
                !portrait -> ClipCheck("${m.width}×${m.height} · ${m.fps}fps", "Landscape", "bad", "Use a vertical 9:16 clip")
                !sharp -> ClipCheck("${m.width}×${m.height} · ${m.fps}fps", "Low res", "bad", "Use a clip at least 720 wide")
                else -> ClipCheck("${m.width}×${m.height} · ${m.fps}fps", "OK", "good")
            },
        )
        val len = Pricing.toFixed(m.durationSec, 1).removeSuffix(".0")
        add(
            if (m.durationSec <= Pricing.MAX_CLIP_SEC) ClipCheck("Length ${len}s", "Max 15s", "good")
            else ClipCheck("Length ${len}s", "Over 15s", "bad", "Trim to 15s or less"),
        )
        add(ClipCheck("Performer talking", if (m.talking) "Yes" else "No", "info"))
    }
}

/**
 * Where a job is after [elapsed] seconds of (simulated) GPU time. Each take: GPU start (30 s), the denoising steps,
 * then lip sync (4 min) if on. Viggle runs a fixed 4 steps.
 */
data class JobProgress(val progress: Double, val take: Int, val step: Int, val totalSteps: Int, val phase: String, val secondsLeft: Double)

object JobClock {
    fun progress(req: JobRequest, elapsed: Double): JobProgress {
        val spec = req.spec()
        val total = Pricing.totalSeconds(spec)
        val perTake = total / spec.takes
        val viggle = spec.engine == Engine.VIGGLE
        val totalSteps = if (viggle) 4 else spec.steps
        val startup = if (viggle) 0.0 else Pricing.GPU_STARTUP_MIN * 60
        val lip = if (!viggle && spec.lipSync) Pricing.LIP_SYNC_MIN * 60 else 0.0
        val stepsTime = perTake - startup - lip
        val e = elapsed.coerceIn(0.0, total)
        val take = minOf(spec.takes, floor(e / perTake).toInt() + 1)
        val inTake = e - (take - 1) * perTake
        val left = total - e
        val prefix = if (spec.takes > 1) "take $take/${spec.takes} · " else ""
        val step: Int
        val phase: String
        when {
            e >= total -> { step = totalSteps; phase = "Done" }
            inTake < startup -> { step = 0; phase = "${prefix}Starting GPU · ${leftText(left)}" }
            inTake < startup + stepsTime -> {
                step = minOf(totalSteps, floor((inTake - startup) / stepsTime * totalSteps).toInt() + 1)
                phase = "${prefix}step $step/$totalSteps · ${leftText(left)}"
            }
            else -> { step = totalSteps; phase = "${prefix}Lip sync · ${leftText(left)}" }
        }
        return JobProgress((e / total * 100).coerceIn(0.0, 100.0), take, step, totalSteps, phase, left)
    }

    /** "~6 min left" / "~40s left". */
    fun leftText(sec: Double): String = if (sec >= 60) "~${ceil(sec / 60).toInt()} min left" else "~${ceil(sec).toInt()}s left"

    /** The elapsed (simulated) seconds at which a failing job breaks: step 3 of take 1. */
    fun failAt(req: JobRequest): Double {
        val spec = req.spec()
        val perTake = Pricing.totalSeconds(spec) / spec.takes
        val viggle = spec.engine == Engine.VIGGLE
        val totalSteps = if (viggle) 4 else spec.steps
        val startup = if (viggle) 0.0 else Pricing.GPU_STARTUP_MIN * 60
        val lip = if (!viggle && spec.lipSync) Pricing.LIP_SYNC_MIN * 60 else 0.0
        return startup + (perTake - startup - lip) * 2.5 / totalSteps
    }

    fun clock(sec: Double) = formatClock(sec)
}
