package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.performSemanticsAction
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
            "splash", "welcome", "signin", "signup", "home", "profile", "create1", "create3", "outfit",
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
            // Keep add-on engine ready (owner only, Settings → Engines): the cost warning on switch-on, the owner's indicator (on, getting ready)
            // and the 5-minute warning. No nudge, switch or bar for members.
            "warm_confirm", "warm_bar", "warm_starting", "warm_warning",
            // Video options (app clean-up): Render (Draft default, HD) and the Edit add-on (no steps, no start-up), Upscale coming soon on a take.
            "quality_draft", "quality_hd", "quality_edit", "result_upscale",
            // Model tools (plans/api.md "Model tools"): the owner's image models and catalog picker, Enhance setup and review,
            // Dress up setup and the Both side-by-side review, archived models.
            "image_models", "catalog", "enhance_setup", "enhance_review", "dressup_setup", "dressup_review", "archived",
            // The prompt library (2026-11-05): owner Settings → Prompts and one prompt's editor. (Photoshoot's screens moved to the Photo tool: SuitePhotoScreenshotTest.)
            "prompts", "prompt_edit",
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
        // The demo model has TikTok + Instagram linked, one scheduled post and one posted with stats (like the prototype review state).
        runBlocking {
            listOf(Platform.TIKTOK, Platform.INSTAGRAM).forEach { fake.debugPutAccount(Account(SampleData.DEMO, it.id, "@demo.model", 0)) }
            fake.debugPutPost(Post("p1", SampleData.DEMO, "t_g1", "Living-room dance", ImageRef.asset("g_tq"), listOf("tiktok", "instagram"), "",
                `when` = PostTime.iso(PostTime.slots().first()), state = "scheduled"))
            fake.debugPutPost(Post("p2", SampleData.DEMO, "t_j1", "Kick test", ImageRef.asset("g_front"), listOf("tiktok"), "", state = "posted",
                postedAt = System.currentTimeMillis() - 7_200_000, stats = PostStats(1834, 201, 14)))
        }
        val cands = LoraSim.candidates()
        val lora = when (screen) {
            "lora_gen" -> Lora(SampleData.DEMO, state = "building")
            "lora_review" -> Lora(SampleData.DEMO, state = "review", candidates = cands)
            "lora_ready_to_train" -> Lora(SampleData.DEMO, state = "review", candidates = cands)
            "lora_training" -> LoraSim.parts(40.0).let { (ph, vi) -> Lora(SampleData.DEMO, state = "training", candidates = cands, progress = 40.0, photo = ph, video = vi) }
            "lora_done", "profile_lora" -> Lora(SampleData.DEMO, 1, "ready", candidates = cands, progress = 100.0, trainedOn = 27)
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
            "source", "direct" -> c.drafts.video.update { it.copy(clip = sample) }
            "source_bad" -> c.drafts.video.update {
                it.copy(clip = Clip(SampleData.BAD_CLIP, "Mirror trend (download)", 22.0, 1080, 1920, 30, ClipRules.checks(SampleData.badMeta)), showBadExample = true)
            }
            "members_send" -> c.drafts.memberOpen.value = "u_maya"
            "templates_mine" -> c.drafts.templateFilter.value = studio.muse.app.data.TemplateFilter(tab = "mine")
            "template_use" -> c.drafts.templateUse.value = studio.muse.app.data.TemplateUseDraft("tpl_mirror-selfie")
            "template_use_prompt" -> c.drafts.templateUse.value = studio.muse.app.data.TemplateUseDraft("tpl_maya_walk", direction = "sitting on the steps, looking back over her shoulder", shuffleSeed = 7, showPrompt = true)
            "prompts" -> runBlocking { fake.savePrompt("style.house", "realistic phone photo, visible skin texture, true colour, no filter") }
            "prompt_edit" -> runBlocking { fake.savePrompt("refs.pose", "Copy the pose and framing from image {refIndex}, but keep her own hands.") }
            "warm_confirm" -> c.warmUi.confirm()
            "quality_draft" -> c.drafts.video.update { it.copy(clip = sample.copy(id = "clip_7s", durationSec = 7.0)) }
            "quality_hd" -> c.drafts.video.update { it.copy(clip = sample.copy(id = "clip_7s", durationSec = 7.0)).pick(studio.muse.core.VideoOption.HD) }
            "quality_edit" -> c.drafts.video.update { it.copy(clip = sample).pick(studio.muse.core.VideoOption.EDIT) }
            "warm_bar", "warm_warning" -> runBlocking {
                val t = System.currentTimeMillis()
                // Ready 15 min ago with no render since: the idle auto-off is 5 min away (the warning's moment).
                val ready = t - 15 * 60_000L
                fake.debugSetWarm(studio.muse.app.data.WarmGpu("warm", startedAt = t - 42 * 60_000L - 20_000, readyAt = ready, minutes = 42, costUsd = 2.80,
                    ratePerHour = 3.99, canExtend = true))
                if (screen == "warm_warning") c.warmUi.banner.value = studio.muse.app.data.WarmWarning("idle", ready + 20 * 60_000L, "Add-on engine turns off in 5 min (no renders)")
            }
            "warm_starting" -> runBlocking {
                val t = System.currentTimeMillis()
                fake.debugSetWarm(studio.muse.app.data.WarmGpu("starting", startedAt = t - 2 * 60_000L - 10_000, minutes = 2, costUsd = 0.13, ratePerHour = 3.99, canExtend = true))
            }
            "invite_code" -> c.drafts.lastInvite.value = InviteCreated("MUSE-7KQ2-XW9P-4HTD", "inv1", "maya@studio.com", "member", System.currentTimeMillis() + 14 * 86_400_000L,
                shareText = "You're invited to MUSE, the AI model studio. 1) Download: https://muse.example/get 2) Sign up with this invite code: MUSE-7KQ2-XW9P-4HTD (email: maya@studio.com). The code works once and expires in 14 days.")
            "queue_waiting" -> runBlocking {
                val req = JobRequest("Mirror dance", SampleData.DEMO, SampleData.GREEN, SampleData.SAMPLE_CLIP)
                val total = Pricing.totalSeconds(req.spec())
                val now = System.currentTimeMillis()
                fake.debugPut(Job("jw", "Mirror dance", SampleData.DEMO, "Demo model", SampleData.GREEN, req, "running", 0.0, phase = "Waiting for a GPU", secondsLeft = total,
                    totalSeconds = total, cost = Pricing.totalCost(req.spec()), createdAt = now, thumb = ImageRef.asset("g_front"), queuePosition = 2, etaSeconds = total + 240, warmupCost = 0.03))
                fake.debugPut(Job("jp", "Kick test", SampleData.DEMO, "Demo model", SampleData.GREEN, req.copy(title = "Kick test"), "running", 0.0, phase = "Paused", secondsLeft = total,
                    totalSeconds = total, cost = Pricing.totalCost(req.spec()), createdAt = now - 1000, thumb = ImageRef.asset("g_tq"), blocked = "owner_balance_low"))
            }
            "result_specs" -> runBlocking {
                fake.debugPutTake(Take("t_spec", "take", null, 1, 1, "Living-room dance", "Take 1", "Edit", 0.67, 4211, thumb = ImageRef.asset("g_front"),
                    createdAt = System.currentTimeMillis(), durationSec = 5.2, width = 768, height = 1344))
            }
            "result_upscale" -> runBlocking {
                fake.debugPutTake(Take("t_up", "take", null, 1, 1, "Kitchen", "Draft", "Draft · 768P", 0.14, 4211, thumb = ImageRef.asset("g_tq"),
                    createdAt = System.currentTimeMillis(), videoUrl = "/uploads/r/j/take_1.mp4", durationSec = 6.4, width = 768, height = 1344))
            }
            "catalog" -> { c.drafts.catalogStep.value = "upscale"; c.drafts.catalogFor.value = "settings" }
            "dressup_setup" -> c.drafts.dressUp.value = studio.muse.app.data.DressUpDraft(ImageRef.asset("c_front"), "Silver night", "both")
            "archived" -> runBlocking { fake.archiveModel(SampleData.NOOR, true) }
            "queue_run" -> runBlocking {
                val req = JobRequest("Living-room dance", SampleData.DEMO, SampleData.GREEN, SampleData.SAMPLE_CLIP)
                val total = Pricing.totalSeconds(req.spec())
                val p = JobClock.progress(req, total * .42)
                fake.debugPut(Job("jr", "Living-room dance", SampleData.DEMO, "Demo model", SampleData.GREEN, req, "running", p.progress, p.take, p.step, p.totalSteps,
                    p.phase, p.secondsLeft, total, Pricing.totalCost(req.spec()), createdAt = System.currentTimeMillis(), thumb = studio.muse.app.data.ImageRef.asset("g_front")))
            }
        }
        // Enhance / Dress up review: start a run on the demo engine and let it finish (it returns the sheet's own stills).
        val toolRun = when (screen) {
            "enhance_review" -> runBlocking { fake.startEnhance(SampleData.DEMO, studio.muse.app.data.EnhanceRequest()) }
            "dressup_review" -> runBlocking { fake.startDressUp(SampleData.DEMO, studio.muse.app.data.DressUpRequest(ImageRef.asset("c_front"), "Silver night", "both")) }
            else -> null
        }
        if (toolRun != null) {
            repeat(40) { idle() }
            runBlocking {
                val r = fake.toolRun(toolRun.id)
                check(r.state == "review") { "run still ${r.state}" }
                if (screen == "enhance_review") {
                    fake.decideTool(r.id, "face", studio.muse.app.data.DecideRequest("keep"))
                    fake.decideTool(r.id, "back", studio.muse.app.data.DecideRequest("reject"))
                } else {
                    fake.pickTool(r.id, "a")
                    fake.decideTool(r.id, "front", studio.muse.app.data.DecideRequest("keep", "b"))
                }
                c.repo.putTool(fake.toolRun(r.id))
            }
            if (screen == "enhance_review") c.drafts.enhance.value = studio.muse.app.data.EnhanceDraft(runId = toolRun.id)
            else c.drafts.dressUp.value = studio.muse.app.data.DressUpDraft(ImageRef.asset("c_front"), "Silver night", "both", runId = toolRun.id)
        }
        val route = when (screen) {
            "image_models" -> Routes.IMAGE_MODELS
            "catalog" -> Routes.CATALOG
            "enhance_setup", "enhance_review" -> Routes.ENHANCE
            "dressup_setup", "dressup_review" -> Routes.DRESSUP
            "archived" -> Routes.ARCHIVED
            "prompts" -> Routes.PROMPTS
            "prompt_edit" -> Routes.SETTINGS
            "source_bad" -> Routes.SOURCE
            "queue_run" -> Routes.QUEUE
            "result", "post", "post_schedule", "result_specs", "result_upscale" -> Routes.HOME
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
            "quality_draft", "quality_hd", "quality_edit" -> Routes.DIRECT
            "warm_confirm", "warm_starting" -> Routes.STUDIO
            "warm_bar", "warm_warning" -> Routes.HOME
            else -> if (screen.startsWith("lora")) Routes.LORA else screen
        }
        compose.mainClock.autoAdvance = false
        val pending = when (screen) { "result" -> Routes.result("j1"); "result_specs" -> Routes.result("t_spec"); "result_upscale" -> Routes.result("t_up"); "post", "post_schedule" -> Routes.post("t_j1")
            "template_detail", "template_edit" -> Routes.template("tpl_mirror-selfie"); "template_detail_other" -> Routes.template("tpl_maya_walk")
            "template_use" -> Routes.templateUse("tpl_mirror-selfie"); "template_use_prompt" -> Routes.templateUse("tpl_maya_walk")
            "save_template" -> Routes.saveTemplate("t_g4"); "prompt_edit" -> Routes.prompt("refs.pose"); else -> null }
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
            runBlocking { check(fake.templatePrompt("tpl_maya_walk", studio.muse.app.data.TemplatePromptRequest(SampleData.DEMO)).text.contains("Template: Golden hour walk")) }
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
