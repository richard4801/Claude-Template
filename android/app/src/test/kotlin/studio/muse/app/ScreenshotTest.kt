package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.Account
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Lora
import studio.muse.app.data.LoraSim
import studio.muse.app.data.Platform
import studio.muse.app.data.Post
import studio.muse.app.data.PostStats
import studio.muse.app.data.TopUpRequest
import studio.muse.app.data.Wallet
import studio.muse.app.data.InviteCreated
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.PostTime
import studio.muse.app.data.Clip
import studio.muse.app.data.ClipRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.JobClock
import studio.muse.app.data.JobRequest
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.core.Pricing

/**
 * Renders the key screens in all four themes with Robolectric + Roborazzi (no emulator needed).
 * Run `./gradlew :app:recordRoborazziDebug`; PNGs land in app/build/outputs/roborazzi/.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ScreenshotTest(private val theme: String, private val screen: String) {
    companion object {
        val SCREENS = listOf(
            "splash", "welcome", "signin", "signup", "home", "profile", "create1", "create3", "outfit", "shoot", "shoot_prompt",
            "source", "source_bad", "direct", "queue", "queue_run", "result", "gallery", "settings", "credits",
            "profile_lora", "lora_intro", "lora_gen", "lora_review", "lora_ready_to_train", "lora_training", "lora_done",
            "accounts", "post", "post_schedule", "posts", "posts_posted",
            // Real backend (2026-11-04): sign-up with an invite, credit in dollars, owner screens, queue states, take specs.
            "signin_server", "signup_server", "credit_member", "members", "members_send", "invite", "invite_code", "studio_settings",
            "queue_waiting", "result_specs",
            // Sign-in (2026-11-04): password eye shown/hidden, Remember me off, sign-up's eye.
            "signin_typed_server", "signin_shown_server", "signin_noremember_server", "signup_shown_server",
            // Photo templates (plans/templates.md): library, detail (owner and someone else's), using one (locked prompt line), Save as template.
            "templates", "templates_mine", "template_detail", "template_detail_other", "template_edit", "template_use", "template_use_prompt", "save_template",
            "shoot_templates",
            // Keep GPU warm: the nudge when creating starts, the cost warning on switch-on, the bar (warm, starting) and the 5-minute warning.
            "warm_nudge", "warm_confirm", "warm_bar", "warm_starting", "warm_warning",
            // Video quality picker (Replicate): Draft (default), HD, and Exact edit (steps + Keep GPU warm).
            "quality_draft", "quality_hd", "quality_exact",
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.map { arrayOf<Any>(t, it) } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun capture() {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        // Demo mode (the in-app fake) as the owner; the *_server screens use the real-API flavour, signed out (no network).
        val server = screen.endsWith("_server")
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = !server, token = if (server) null else "t", studioName = "Jenne Studio", role = "owner",
            email = if (server) "" else "jenne@studio.com")), fake, null)
        if (screen == "credit_member") fake.debugWallet = Wallet("u_maya", "member", 1_250, 12.5, 67, 0.67, 0.67, 4.02)
        // Sienna has TikTok + Instagram linked, one scheduled post and one posted with stats (like the prototype review state).
        runBlocking {
            listOf(Platform.TIKTOK, Platform.INSTAGRAM).forEach { fake.debugPutAccount(Account(SampleData.SIENNA, it.id, "@sienna.vale", 0)) }
            fake.debugPutPost(Post("p1", SampleData.SIENNA, "t_g1", "Living-room dance", ImageRef.asset("g_tq"), listOf("tiktok", "instagram"), "",
                `when` = PostTime.iso(PostTime.slots().first()), state = "scheduled"))
            fake.debugPutPost(Post("p2", SampleData.SIENNA, "t_j1", "Kick test", ImageRef.asset("g_front"), listOf("tiktok"), "", state = "posted",
                postedAt = System.currentTimeMillis() - 7_200_000, stats = PostStats(1834, 201, 14)))
        }
        val cands = LoraSim.candidates()
        val lora = when (screen) {
            "lora_gen" -> Lora(SampleData.SIENNA, state = "building")
            "lora_review" -> Lora(SampleData.SIENNA, state = "review", candidates = cands)
            "lora_ready_to_train" -> Lora(SampleData.SIENNA, state = "review", candidates = cands)
            "lora_training" -> LoraSim.parts(40.0).let { (ph, vi) -> Lora(SampleData.SIENNA, state = "training", candidates = cands, progress = 40.0, photo = ph, video = vi) }
            "lora_done", "profile_lora" -> Lora(SampleData.SIENNA, 1, "ready", candidates = cands, progress = 100.0, trainedOn = 27)
            else -> null
        }
        runBlocking {
            lora?.let { fake.debugPutLora(it) }
            if (screen == "lora_ready_to_train") fake.topUp(TopUpRequest(25.0))
        }
        val sample = Clip(SampleData.SAMPLE_CLIP, "Living-room dance", 9.4, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta))
        when (screen) {
            "create3" -> runBlocking {
                c.drafts.modelId.value = SampleData.NOOR
                listOf("face" to "face", "profile" to "profile", "front" to "g_front").forEach { (k, img) ->
                    fake.setSlot(SampleData.NOOR, k, studio.muse.app.data.SetSlotRequest(studio.muse.app.data.ImageRef.asset(img)))
                }
            }
            "post_schedule" -> c.drafts.postStartScheduled.value = true
            "posts_posted" -> c.drafts.postsTab.value = "posted"
            "shoot_prompt" -> c.drafts.shoot.update { it.copy(tool = "spark", direction = "laughing mid-step, hair blowing") }
            "source", "direct" -> { c.drafts.video.update { it.copy(clip = sample) }; c.warmUi.creatingStarted(null) }
            "source_bad" -> c.drafts.video.update {
                it.copy(clip = Clip(SampleData.BAD_CLIP, "Mirror trend (download)", 22.0, 1080, 1920, 30, ClipRules.checks(SampleData.badMeta)), showBadExample = true)
            }
            "members_send" -> c.drafts.memberOpen.value = "u_maya"
            "templates_mine" -> c.drafts.templateFilter.value = studio.muse.app.data.TemplateFilter(tab = "mine")
            "template_use" -> c.drafts.templateUse.value = studio.muse.app.data.TemplateUseDraft("tpl_mirror-selfie")
            "template_use_prompt" -> c.drafts.templateUse.value = studio.muse.app.data.TemplateUseDraft("tpl_maya_walk", direction = "sitting on the steps, looking back over her shoulder", shuffleSeed = 7, showPrompt = true)
            "shoot_templates" -> c.drafts.shoot.update { it.copy(tool = "model") }
            "warm_nudge" -> c.drafts.video.update { it.copy(clip = sample, engine = studio.muse.core.Engine.H3) }
            "warm_confirm" -> { c.drafts.video.update { it.copy(clip = sample, engine = studio.muse.core.Engine.H3) }; c.warmUi.creatingStarted(null); c.warmUi.confirm() }
            "quality_draft" -> c.drafts.video.update { it.copy(clip = sample.copy(id = "clip_7s", durationSec = 7.0)) }
            "quality_hd" -> c.drafts.video.update { it.copy(clip = sample.copy(id = "clip_7s", durationSec = 7.0)).pick(studio.muse.core.VideoOption.HD) }
            "quality_exact" -> c.drafts.video.update { it.copy(clip = sample).pick(studio.muse.core.VideoOption.EXACT) }
            "warm_bar", "warm_warning" -> runBlocking {
                val t = System.currentTimeMillis()
                // Ready 15 min ago with no render since: the idle auto-off is 5 min away (the warning's moment).
                val ready = t - 15 * 60_000L
                fake.debugSetWarm(studio.muse.app.data.WarmGpu("warm", startedAt = t - 42 * 60_000L - 20_000, readyAt = ready, minutes = 42, costUsd = 2.80,
                    ratePerHour = 3.99, canExtend = true))
                if (screen == "warm_warning") c.warmUi.banner.value = studio.muse.app.data.WarmWarning("idle", ready + 20 * 60_000L, "Warm GPU turns off in 5 min (no renders)")
            }
            "warm_starting" -> runBlocking {
                c.drafts.video.update { it.copy(clip = sample, engine = studio.muse.core.Engine.H3) }
                c.warmUi.creatingStarted(null)
                val t = System.currentTimeMillis()
                fake.debugSetWarm(studio.muse.app.data.WarmGpu("starting", startedAt = t - 2 * 60_000L - 10_000, minutes = 2, costUsd = 0.13, ratePerHour = 3.99, canExtend = true))
            }
            "invite_code" -> c.drafts.lastInvite.value = InviteCreated("MUSE-7KQ2-XW9P-4HTD", "inv1", "maya@studio.com", "member", System.currentTimeMillis() + 14 * 86_400_000L,
                shareText = "You're invited to MUSE, the AI model studio. 1) Download: https://muse.example/get 2) Sign up with this invite code: MUSE-7KQ2-XW9P-4HTD (email: maya@studio.com). The code works once and expires in 14 days.")
            "queue_waiting" -> runBlocking {
                val req = JobRequest("Mirror dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP)
                val total = Pricing.totalSeconds(req.spec())
                val now = System.currentTimeMillis()
                fake.debugPut(Job("jw", "Mirror dance", SampleData.SIENNA, "Sienna Vale", SampleData.GREEN, req, "running", 0.0, phase = "Waiting for a GPU", secondsLeft = total,
                    totalSeconds = total, cost = Pricing.totalCost(req.spec()), createdAt = now, thumb = ImageRef.asset("g_front"), queuePosition = 2, etaSeconds = total + 240, warmupCost = 0.03))
                fake.debugPut(Job("jp", "Kick test", SampleData.SIENNA, "Sienna Vale", SampleData.GREEN, req.copy(title = "Kick test"), "running", 0.0, phase = "Paused", secondsLeft = total,
                    totalSeconds = total, cost = Pricing.totalCost(req.spec()), createdAt = now - 1000, thumb = ImageRef.asset("g_tq"), blocked = "owner_balance_low"))
            }
            "result_specs" -> runBlocking {
                fake.debugPutTake(Take("t_spec", "take", null, 1, 1, "Living-room dance", "Take 1", "Standard · 10 steps", 0.67, 4211, thumb = ImageRef.asset("g_front"),
                    createdAt = System.currentTimeMillis(), durationSec = 5.2, width = 768, height = 1344))
            }
            "queue_run" -> runBlocking {
                val req = JobRequest("Living-room dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP)
                val total = Pricing.totalSeconds(req.spec())
                val p = JobClock.progress(req, total * .42)
                fake.debugPut(Job("jr", "Living-room dance", SampleData.SIENNA, "Sienna Vale", SampleData.GREEN, req, "running", p.progress, p.take, p.step, p.totalSteps,
                    p.phase, p.secondsLeft, total, Pricing.totalCost(req.spec()), createdAt = System.currentTimeMillis(), thumb = studio.muse.app.data.ImageRef.asset("g_front")))
            }
        }
        val route = when (screen) {
            "shoot_prompt" -> Routes.SHOOT
            "source_bad" -> Routes.SOURCE
            "queue_run" -> Routes.QUEUE
            "result", "post", "post_schedule", "result_specs" -> Routes.HOME
            "signin_server", "signin_typed_server", "signin_shown_server", "signin_noremember_server" -> Routes.SIGNIN
            "signup_server", "signup_shown_server" -> Routes.SIGNUP
            "credit_member" -> Routes.CREDITS
            "members_send" -> Routes.MEMBERS
            "invite", "invite_code" -> Routes.INVITE
            "studio_settings" -> Routes.STUDIO
            "queue_waiting" -> Routes.QUEUE
            "profile_lora" -> Routes.PROFILE
            "posts_posted" -> Routes.POSTS
            "templates", "templates_mine" -> Routes.TEMPLATES
            "template_detail", "template_detail_other", "template_edit", "template_use", "template_use_prompt", "save_template" -> Routes.HOME
            "shoot_templates" -> Routes.SHOOT
            "warm_nudge", "warm_confirm", "warm_starting", "quality_draft", "quality_hd", "quality_exact" -> Routes.DIRECT
            "warm_bar", "warm_warning" -> Routes.HOME
            else -> if (screen.startsWith("lora")) Routes.LORA else screen
        }
        compose.mainClock.autoAdvance = false
        val pending = when (screen) { "result" -> Routes.result("j1"); "result_specs" -> Routes.result("t_spec"); "post", "post_schedule" -> Routes.post("t_j1")
            "template_detail", "template_edit" -> Routes.template("tpl_mirror-selfie"); "template_detail_other" -> Routes.template("tpl_maya_walk")
            "template_use" -> Routes.templateUse("tpl_mirror-selfie"); "template_use_prompt" -> Routes.templateUse("tpl_maya_walk")
            "save_template" -> Routes.saveTemplate("t_g4"); else -> null }
        compose.setContent { MuseApp(c, route, pending) }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        if (screen in setOf("signin_typed_server", "signin_shown_server", "signup_shown_server")) {
            val fields = compose.onAllNodes(hasSetTextAction())
            val pw = if (screen.startsWith("signup")) 2 else 1 // sign-up: invite, email, password
            if (screen.startsWith("signin")) fields[0].performTextInput("maya@studio.com")
            fields[pw].performTextInput("correct horse")
            if (screen != "signin_typed_server") compose.onNodeWithContentDescription("Show password").performClick()
        }
        if (screen == "signin_noremember_server") compose.onNodeWithText("Remember me").performClick()
        if (screen == "template_edit") compose.onNodeWithText("Edit").performClick()
        if (screen == "template_use_prompt") {
            // The prompt view for someone else's template: one locked "Template: …" line, the hidden layers never arrive.
            // (No compose waits here: the canvas animates, so the UI never goes idle with a paused clock.)
            runBlocking { check(fake.templatePrompt("tpl_maya_walk", studio.muse.app.data.TemplatePromptRequest(SampleData.SIENNA)).text.contains("Template: Golden hour walk")) }
        }
        repeat(2) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        when (screen) {
            "signin_shown_server", "signup_shown_server" -> compose.onNodeWithContentDescription("Hide password").assertExists()
            "signin_typed_server", "signin_server", "signup_server" -> compose.onNodeWithContentDescription("Show password").assertExists()
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/${theme}_$screen.png")
    }
}
