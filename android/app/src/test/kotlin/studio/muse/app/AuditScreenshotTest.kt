package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.awaitCancellation
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
import studio.muse.app.data.ApiException
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Platform
import studio.muse.app.data.PostStats
import studio.muse.app.data.SampleData
import studio.muse.app.ui.screens.PostTime
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.Model
import studio.muse.app.data.MuseApi
import studio.muse.app.data.Outfit
import studio.muse.app.data.Post
import studio.muse.app.data.Take
import studio.muse.app.data.Template
import studio.muse.app.data.User
import studio.muse.app.data.Wallet
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes

/**
 * UX audit (plans/ux-audit-android.md): every top-level screen at the smallest phone width (360 dp) in all four themes,
 * plus the states a real studio hits that the demo never shows: a new member's empty studio, a slow first load and an
 * unreachable server. The 390 dp renders are ScreenshotTest's. PNGs: app/build/outputs/roborazzi/audit360_<theme>_<screen>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w360dp-h780dp-xhdpi")
class AuditScreenshotTest(private val theme: String, private val screen: String) {
    companion object {
        /** Demo studio (the owner), populated. */
        val DEMO = listOf(
            "welcome", "signin", "signup", "home", "gallery", "queue", "settings", "credits", "profile", "create1", "create3", "outfit",
            "photo", "result", "templates", "template_detail", "posts", "posts_posted", "post", "accounts", "lora", "members", "invite",
            "studio_settings", "prompts", "enhance", "outfits", "archived",
        )
        /** The real API as a new member: nothing made yet. */
        val EMPTY = listOf("home_empty", "gallery_empty", "queue_empty", "photo_empty", "posts_empty", "templates_empty", "settings_empty", "profile_empty", "credits_empty")
        /** The real API, first load still on its way / the server can't be reached. */
        val LOADING = listOf("home_loading", "gallery_loading", "home_error", "gallery_error")
        val SCREENS = DEMO + EMPTY + LOADING

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.map { arrayOf<Any>(t, it) } }
    }

    /** A real studio with nothing in it yet, seen by a member ([mode]: "empty", "loading" never answers, "error" can't connect). */
    private class StandIn(private val f: FakeMuseApi, private val mode: String) : MuseApi by f {
        private suspend fun <T> gate(empty: T): T = when (mode) {
            "loading" -> awaitCancellation()
            "error" -> throw ApiException("network", "Can't reach the server. Check your connection and try again.")
            else -> empty
        }
        override suspend fun me() = User("u_maya", "Jenne Studio", "maya@studio.com", "member")
        override suspend fun wallet() = Wallet("u_maya", "member", 0, 0.0)
        override suspend fun listModels(): List<Model> = gate(emptyList())
        override suspend fun listOutfits(): List<Outfit> = gate(emptyList())
        override suspend fun listJobs(): List<Job> = gate(emptyList())
        override suspend fun listTakes(): List<Take> = gate(emptyList())
        override suspend fun listPosts(state: String?): List<Post> = gate(emptyList())
        override suspend fun listTemplates(scope: String, q: String?, tag: String?): List<Template> = gate(emptyList())
    }

    @get:Rule val compose = createComposeRule()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test
    fun capture() {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val real = screen !in DEMO
        val mode = when { screen.endsWith("_loading") -> "loading"; screen.endsWith("_error") -> "error"; else -> "empty" }
        val prefs = if (real) AppPrefs(theme = theme, useFake = false, token = "t", studioName = "Jenne Studio", role = "member", email = "maya@studio.com")
        else AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")
        val c = AppContainer(scope, MemoryPrefs(prefs), fake, null, httpFactory = { StandIn(FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0), mode) })
        // Like ScreenshotTest: the demo model has TikTok + Instagram linked, one scheduled post and one posted with stats.
        if (!real) runBlocking {
            listOf(Platform.TIKTOK, Platform.INSTAGRAM).forEach { fake.debugPutAccount(Account(SampleData.DEMO, it.id, "@demo.model", 0)) }
            fake.debugPutPost(Post("p1", SampleData.DEMO, "t_g1", "Living-room dance", ImageRef.asset("g_tq"), listOf("tiktok", "instagram"), "",
                `when` = PostTime.iso(PostTime.slots().first()), state = "scheduled"))
            fake.debugPutPost(Post("p2", SampleData.DEMO, "t_j1", "Kick test with a much longer title than usual", ImageRef.asset("g_front"), listOf("tiktok", "instagram"), "",
                state = "posted", postedAt = System.currentTimeMillis() - 7_200_000, stats = PostStats(18_834, 2_201, 140)))
        }
        when (screen) {
            "posts_posted" -> c.drafts.postsTab.value = "posted"
        }
        val base = screen.substringBefore('_')
        val route = when (base) {
            "home" -> Routes.HOME; "gallery" -> Routes.GALLERY; "queue" -> Routes.QUEUE; "settings" -> Routes.SETTINGS; "credits" -> Routes.CREDITS
            "photo" -> Routes.SUITE_PHOTO; "posts" -> Routes.POSTS; "templates" -> Routes.TEMPLATES; "profile" -> Routes.PROFILE
            "studio" -> Routes.STUDIO; "template", "result", "post" -> Routes.HOME
            else -> screen
        }
        val pending = when (screen) {
            "result" -> Routes.result("j1"); "post" -> Routes.post("t_j1"); "template_detail" -> Routes.template("tpl_mirror-selfie"); else -> null
        }
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route, pending) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/audit360_${theme}_$screen.png")
    }
}
