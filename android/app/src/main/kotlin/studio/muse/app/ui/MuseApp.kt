package studio.muse.app.ui

import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawscope.rotate as drawRotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.statusBars
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.app.AppContainer
import studio.muse.app.data.Toast
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MuseMenu
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.hardShadow
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseRadii
import studio.muse.app.ui.theme.MuseRoles
import studio.muse.app.ui.theme.MuseTypeScale
import studio.muse.app.ui.theme.museFloat
import kotlin.random.Random

val LocalContainer = staticCompositionLocalOf<AppContainer> { error("no container") }
val LocalNav = staticCompositionLocalOf<Nav> { error("no nav") }
/** Celebrate: confetti in Creator Pop. */
val LocalCelebrate = staticCompositionLocalOf<() -> Unit> { {} }

object Routes {
    const val SPLASH = "splash"; const val WELCOME = "welcome"; const val SIGNIN = "signin"; const val SIGNUP = "signup"
    const val HOME = "home"; const val GALLERY = "gallery"; const val QUEUE = "queue"; const val SETTINGS = "settings"; const val CREDITS = "credits"
    const val PROFILE = "profile"; const val CREATE1 = "create1"; const val CREATE3 = "create3"; const val OUTFIT = "outfit"
    /** Photoshoot's old route: kept only so old links redirect to Suite → Photo ([redirect]). */
    const val SHOOT = "shoot"; const val SOURCE = "source"; const val DIRECT = "direct"; const val RESULT = "result/{id}"
    const val LORA = "lora"; const val ACCOUNTS = "accounts"; const val POST = "post/{id}"; const val POSTS = "posts"
    const val MEMBERS = "members"; const val INVITE = "invite"; const val STUDIO = "studio"
    const val ENHANCE = "enhance"; const val DRESSUP = "dressup"; const val IMAGE_MODELS = "imagemodels"; const val CATALOG = "catalog"; const val ARCHIVED = "archived"
    const val PROMPTS = "prompts"; const val PROMPT = "prompt/{key}"
    /** Prompt scripts (workstream 4): one script's rules, inputs, blocks and preview. */
    const val PROMPT_SCRIPT = "promptscript/{id}"
    fun promptScript(id: String) = "promptscript/$id"
    const val TEMPLATES = "templates"; const val TEMPLATE = "template/{id}"; const val TEMPLATE_USE = "template/{id}/use"; const val SAVE_TEMPLATE = "savetemplate/{id}"
    val TABS = setOf(HOME, GALLERY, QUEUE, SETTINGS, SUITE)
    fun result(id: String) = "result/$id"
    fun template(id: String) = "template/$id"
    fun prompt(key: String) = "prompt/$key"
    fun templateUse(id: String) = "template/$id/use"
    fun saveTemplate(shotId: String) = "savetemplate/$shotId"
    fun post(takeId: String) = "post/$takeId"
    /** The on-device video editor (plans/video-editor.md). */
    const val EDIT_VIDEO = "editvideo/{id}"
    fun editVideo(takeId: String) = "editvideo/$takeId"
    // AI suite (workstream 1): the Video suite and its modes; Edit top-level (workstream 3); the camera stage and Connections (workstream 2).
    const val SUITE = "suite"; const val SUITE_SHOT = "suite/shot"; const val SUITE_SWAP = "suite/swap"; const val SUITE_STORYBOARD = "suite/storyboard"
    const val SUITE_TAKE = "suite/take/{id}"; const val SUITE_ENGINES = "suite/engines"
    /** The video composer on a tool (shot, swap, recast, talking, ugc, extend); Shot and Character swap have their own routes too. */
    const val SUITE_COMPOSE = "suite/compose/{tool}"
    fun suiteTake(jobId: String) = "suite/take/$jobId"
    fun suiteCompose(tool: String) = "suite/compose/$tool"
    /** WS7: Share → MUSE asks what to do with the shared video (Recreate, Use for swap, Import to library). */
    const val SHARE = "share"
    /** WS7: Settings → Default models (owner): what Auto uses per kind of work. */
    const val DEFAULT_MODELS = "default-models"
    /** Settings redesign (2026-11-09): one page per section. */
    const val SETTINGS_ACCOUNT = "settings/account"; const val SETTINGS_STUDIO = "settings/studio"; const val SETTINGS_AI = "settings/ai"
    const val SETTINGS_PROVIDERS = "settings/providers"; const val SETTINGS_APPS = "settings/apps"; const val SETTINGS_ADVANCED = "settings/advanced"
    const val SETTINGS_GPUS = "settings/gpus"; const val SETTINGS_MODEL_STATUS = "settings/model-status"
    const val PROVIDER_MODELS = "settings/providers/{id}"
    fun providerModels(id: String) = "settings/providers/$id"
    const val CAMERA_STAGE = "camera-stage"; const val EDIT = "edit"; const val EDIT_TAKE = "edit/{id}"; const val CONNECTIONS = "connections"
    fun editTake(takeId: String) = "edit/$takeId"

    /** Photo tool (workstream 3): the AI suite composer on Photo. */
    val SUITE_PHOTO = suiteCompose("photo")

    /**
     * Routes that moved (workstream 3): Photoshoot is now the Photo tool on the composer, so an old link to it ("shoot",
     * "shoot/…", "shoot?…", from a notification or an older build) opens Suite → Photo. Every other route is unchanged.
     */
    fun redirect(route: String): String = if (route == SHOOT || route.startsWith("$SHOOT/") || route.startsWith("$SHOOT?")) SUITE_PHOTO else route
}

/** Navigation helpers (the prototype's go/back/tab). */
class Nav(val controller: NavHostController) {
    fun go(to: String) {
        val route = Routes.redirect(to)
        if (controller.currentDestination?.route == route) return
        controller.navigate(route) { launchSingleTop = true }
    }

    fun back() {
        if (!controller.popBackStack()) controller.navigate(Routes.HOME)
    }

    fun tab(to: String) {
        val route = Routes.redirect(to)
        controller.navigate(route) {
            popUpTo(Routes.HOME) { saveState = false; inclusive = route == Routes.HOME }
            launchSingleTop = true
        }
    }

    /** Clears the stack (sign in / sign out / model saved). */
    fun reset(route: String) {
        controller.navigate(route) { popUpTo(0) { inclusive = true }; launchSingleTop = true }
    }
}

@Composable
fun MuseApp(
    container: AppContainer, startRoute: String = Routes.SPLASH, pendingRoute: String? = null, onRouteConsumed: () -> Unit = {},
    pendingHandoff: String? = null, onHandoffConsumed: () -> Unit = {},
) {
    val prefs by container.prefs.collectAsState()
    val theme = ThemeId.fromKey(prefs.theme)
    MuseTheme(theme) {
        val nav = rememberNavController()
        val n = remember(nav) { Nav(nav) }
        val confetti = remember { mutableStateListOf<Long>() }
        val celebrate: () -> Unit = remember { { confetti.add(System.nanoTime()) } }
        LaunchedEffect(pendingRoute) {
            if (pendingRoute != null) { delay(50); n.go(pendingRoute); onRouteConsumed() }
        }
        // A "time to post" notification was tapped: once the posts are loaded, open the first platform's handoff.
        val context = androidx.compose.ui.platform.LocalContext.current
        LaunchedEffect(pendingHandoff) {
            val id = pendingHandoff ?: return@LaunchedEffect
            val post = kotlinx.coroutines.withTimeoutOrNull(5000) { container.repo.state.first { s -> s.posts.any { it.id == id } } }?.posts?.first { it.id == id }
            val platform = post?.platforms?.firstOrNull()?.let { studio.muse.app.data.Platform.of(it) }
            if (post != null && platform != null) openHandoff(context, container, post, platform)
            onHandoffConsumed()
        }
        // The session ended on the server (signed out elsewhere, switched off by the owner): back to sign-in.
        LaunchedEffect(container) {
            container.repo.signedOut.collect { msg ->
                n.reset(Routes.SIGNIN)
                container.repo.toast(msg)
            }
        }
        CompositionLocalProvider(LocalContainer provides container, LocalNav provides n, LocalCelebrate provides celebrate) {
            Box(Modifier.fillMaxSize().background(muse.t.bg)) {
                // Keep add-on engine ready (owner only): a small indicator (and its 5-minute warning) above every screen while it's on.
                // Members never load it, and this checks the role again so nothing of it can show for them.
                val warmScope = rememberCoroutineScope()
                val warmFlow = remember(container) { container.repo.state.map { s -> s.warm?.takeIf { s.wallet?.owner ?: (s.balance.role == "owner") } }.distinctUntilChanged() }
                val warmState by warmFlow.collectAsState(null)
                val warmOn = warmState?.takeIf { it.on }
                val warmBanner by container.warmUi.banner.collectAsState()
                val warmPrompt by container.warmUi.prompt.collectAsState()
                val notifPermission = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { }
                Column(Modifier.fillMaxSize()) {
                if (warmOn != null) {
                    WarmBar(warmOn, { warmScope.launch { container.repo.setWarm(false) } })
                    warmBanner?.let { b ->
                        WarmWarningBanner(b, { container.warmUi.banner.value = null; warmScope.launch { container.repo.keepWarm() } }, { container.warmUi.banner.value = null })
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth().let { if (warmOn != null) it.consumeWindowInsets(WindowInsets.statusBars) else it }) {
                NavHost(
                    nav, startDestination = startRoute, modifier = Modifier.fillMaxSize(),
                    enterTransition = { enterFor(theme, 1) }, exitTransition = { exitFor(theme, 1) },
                    popEnterTransition = { enterFor(theme, -1) }, popExitTransition = { exitFor(theme, -1) },
                ) {
                    composable(Routes.SPLASH) { SplashScreen() }
                    composable(Routes.WELCOME) { WelcomeScreen() }
                    composable(Routes.SIGNIN) { SignInScreen() }
                    composable(Routes.SIGNUP) { SignUpScreen() }
                    composable(Routes.HOME) { HomeScreen() }
                    composable(Routes.GALLERY) { GalleryScreen() }
                    composable(Routes.QUEUE) { QueueScreen() }
                    composable(Routes.SETTINGS) { SettingsScreen() }
                    composable(Routes.CREDITS) { CreditsScreen() }
                    composable(Routes.PROFILE) { ProfileScreen() }
                    composable(Routes.CREATE1) { CreateBasicsScreen() }
                    composable(Routes.CREATE3) { CharacterSheetScreen() }
                    composable(Routes.OUTFIT) { OutfitScreen() }
                    // Photoshoot is the Photo tool now (workstream 3): an old "shoot" route that reaches the graph directly opens Suite → Photo.
                    composable(Routes.SHOOT) { LaunchedEffect(Unit) { nav.navigate(Routes.SUITE_PHOTO) { popUpTo(Routes.SHOOT) { inclusive = true }; launchSingleTop = true } } }
                    composable(Routes.SOURCE) { SourceScreen() }
                    composable(Routes.DIRECT) { DirectScreen() }
                    composable(Routes.RESULT) { e -> ResultScreen(e.arguments?.getString("id") ?: "") }
                    // "Edit video" on a take opens the Edit suite (workstream 3).
                    composable(Routes.EDIT_VIDEO) { e -> studio.muse.app.ui.screens.edit.EditSuiteScreen(e.arguments?.getString("id"), onBack = { n.back() }) }
                    // AI suite (workstream 1)
                    composable(Routes.SUITE) { studio.muse.app.ui.screens.suite.SuiteHubScreen() }
                    composable(Routes.SUITE_SHOT) { studio.muse.app.ui.screens.suite.composer.SuiteComposerScreen("shot") }
                    composable(Routes.SUITE_SWAP) { studio.muse.app.ui.screens.suite.composer.SuiteComposerScreen("swap") }
                    composable(Routes.SUITE_COMPOSE) { e -> studio.muse.app.ui.screens.suite.composer.SuiteComposerScreen(e.arguments?.getString("tool")) }
                    composable(Routes.SUITE_STORYBOARD) { studio.muse.app.ui.screens.suite.SuiteStoryboardScreen() }
                    composable(Routes.SUITE_TAKE) { e -> studio.muse.app.ui.screens.suite.SuiteResultScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.SUITE_ENGINES) { studio.muse.app.ui.screens.suite.SuiteEnginesScreen() }
                    composable(Routes.CAMERA_STAGE) { studio.muse.app.ui.screens.camera.CameraStageScreen() }
                    composable(Routes.EDIT) { studio.muse.app.ui.screens.edit.EditSuiteScreen(null, onBack = { n.back() }) }
                    composable(Routes.SHARE) { studio.muse.app.ui.screens.ShareChooserScreen() } // WS7
                    composable(Routes.DEFAULT_MODELS) { studio.muse.app.ui.screens.DefaultModelsScreen() } // WS7
                    composable(Routes.SETTINGS_ACCOUNT) { studio.muse.app.ui.screens.AccountSettingsScreen() }
                    composable(Routes.SETTINGS_STUDIO) { studio.muse.app.ui.screens.StudioSectionScreen() }
                    composable(Routes.SETTINGS_AI) { studio.muse.app.ui.screens.AiSpendingScreen() }
                    composable(Routes.SETTINGS_PROVIDERS) { studio.muse.app.ui.screens.ProvidersScreen() }
                    composable(Routes.SETTINGS_APPS) { studio.muse.app.ui.screens.AppsDevicesScreen() }
                    composable(Routes.SETTINGS_ADVANCED) { studio.muse.app.ui.screens.AdvancedSettingsScreen() }
                    composable(Routes.SETTINGS_GPUS) { studio.muse.app.ui.screens.OwnGpusScreen() }
                    composable(Routes.SETTINGS_MODEL_STATUS) { studio.muse.app.ui.screens.ModelStatusScreen() }
                    composable(Routes.PROVIDER_MODELS) { e -> studio.muse.app.ui.screens.ProviderModelsScreen(e.arguments?.getString("id").orEmpty()) }
                    composable(Routes.EDIT_TAKE) { e -> studio.muse.app.ui.screens.edit.EditSuiteScreen(e.arguments?.getString("id"), onBack = { n.back() }) }
                    composable(Routes.CONNECTIONS) { studio.muse.app.ui.screens.camera.ConnectionsScreen(onBack = { n.back() }) }
                    composable(Routes.LORA) { LoraScreen() }
                    composable(Routes.ACCOUNTS) { AccountsScreen() }
                    composable(Routes.POST) { e -> PostScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.POSTS) { PostsScreen() }
                    composable(Routes.MEMBERS) { MembersScreen() }
                    composable(Routes.INVITE) { InviteScreen() }
                    composable(Routes.STUDIO) { StudioSettingsScreen() }
                    composable(Routes.TEMPLATES) { TemplatesScreen() }
                    composable(Routes.ENHANCE) { EnhanceScreen() }
                    composable(Routes.DRESSUP) { DressUpScreen() }
                    composable(Routes.IMAGE_MODELS) { ImageModelsScreen() }
                    composable(Routes.CATALOG) { CatalogScreen() }
                    composable(Routes.ARCHIVED) { ArchivedModelsScreen() }
                    composable(Routes.PROMPTS) { PromptsScreen() }
                    composable(Routes.PROMPT) { e -> PromptEditScreen(e.arguments?.getString("key") ?: "") }
                    composable(Routes.PROMPT_SCRIPT) { e -> PromptScriptScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.TEMPLATE) { e -> TemplateDetailScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.TEMPLATE_USE) { e -> TemplateUseScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.SAVE_TEMPLATE) { e -> SaveTemplateScreen(e.arguments?.getString("id") ?: "") }
                }
                }
                }
                val entry by nav.currentBackStackEntryAsState()
                FlashOnNav(theme, entry)
                UploadProgressHost(container)
                ToastHost(container)
                warmPrompt?.let { kind ->
                    WarmPrompt(kind, warmState, onYes = {
                        container.warmUi.dismiss()
                        // The owner's ongoing notification needs the permission (asked once, like on the first Generate).
                        if (android.os.Build.VERSION.SDK_INT >= 33 && !prefs.notifAsked) {
                            warmScope.launch { container.prefsStore.update { it.copy(notifAsked = true) } }
                            runCatching { notifPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS) }
                        }
                        warmScope.launch { container.repo.setWarm(true) }
                    }, onNo = { container.warmUi.dismiss() })
                }
                ConfettiLayer(confetti)
            }
        }
    }
}

private val easeA = CubicBezierEasing(.22f, .61f, .36f, 1f)
private val easeB = CubicBezierEasing(.4f, 0f, .2f, 1f)

/** Per-theme screen motion (app.js MOTION). */
private fun AnimatedContentTransitionScope<NavBackStackEntry>.enterFor(t: ThemeId, dir: Int): EnterTransition = when (t) {
    ThemeId.A -> fadeIn(tween(460, easing = easeA)) + slideInVertically(tween(460, easing = easeA)) { (if (dir > 0) 18 else -18) * 3 }
    ThemeId.B -> slideInHorizontally(tween(230, easing = easeB)) { w -> if (dir > 0) w else -w * 3 / 10 }
    ThemeId.C -> slideInHorizontally(spring(dampingRatio = .78f, stiffness = 380f)) { w -> if (dir > 0) w else -w / 4 } + scaleIn(spring(dampingRatio = .78f, stiffness = 380f), initialScale = .96f)
    ThemeId.D -> slideInVertically(spring(dampingRatio = .62f, stiffness = 420f)) { h -> if (dir > 0) h * 4 / 10 else -h * 4 / 10 } +
        scaleIn(spring(dampingRatio = .62f, stiffness = 420f), initialScale = .85f) + fadeIn(tween(200))
}

private fun AnimatedContentTransitionScope<NavBackStackEntry>.exitFor(t: ThemeId, dir: Int): ExitTransition = when (t) {
    ThemeId.A -> fadeOut(tween(460, easing = easeA))
    ThemeId.B -> slideOutHorizontally(tween(230, easing = easeB)) { w -> if (dir > 0) -w * 3 / 10 else w } + fadeOut(tween(230), targetAlpha = .5f)
    ThemeId.C -> slideOutHorizontally(tween(520)) { w -> if (dir > 0) -w / 4 else w } + scaleOut(tween(520), targetScale = .94f) + fadeOut(tween(520), targetAlpha = .6f)
    ThemeId.D -> scaleOut(tween(300), targetScale = .9f) + fadeOut(tween(300))
}

/** Camera Body's shutter flash on navigation. */
@Composable
private fun BoxScope.FlashOnNav(theme: ThemeId, entry: NavBackStackEntry?) {
    val a = remember { Animatable(0f) }
    LaunchedEffect(entry?.id) {
        if (theme == ThemeId.B && entry != null) { a.snapTo(.5f); a.animateTo(0f, tween(280)) }
    }
    if (a.value > 0f) Box(Modifier.matchParentSize().graphicsLayer { alpha = a.value }.background(Color.White))
}

@Composable
private fun BoxScope.ToastHost(container: AppContainer) {
    var current by remember { mutableStateOf<Toast?>(null) }
    val nav = LocalNav.current
    LaunchedEffect(container) {
        container.repo.toasts.collect { t ->
            current = t
            launch { delay(3200); if (current?.id == t.id) current = null }
        }
    }
    val t = current ?: return
    val m = muse
    val r = MuseRoles.of(m.id)
    // A toast floats over content: ink on canvas, the one float shadow, no icon.
    val shape = RoundedCornerShape(MuseRadii.of(m.id).control)
    Row(
        Modifier.statusBarsPadding().padding(start = 16.dp, end = 16.dp, top = 10.dp).fillMaxWidth().align(Alignment.TopCenter)
            .museFloat(m, shape).clip(shape).background(r.ink).press { current = null; t.route?.let { nav.go(it) } }.padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(t.message, MuseTypeScale.of(m.id).label, r.canvas)
    }
}


/** "Uploading · 42%" with a bar, while a reference image or clip goes up. */
@Composable
private fun BoxScope.UploadProgressHost(container: AppContainer) {
    val p by container.repo.uploadProgress.collectAsState()
    val v = p ?: return
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(start = 16.dp, end = 16.dp, bottom = 96.dp).fillMaxWidth()
            .clip(shape).background(m.t.ink).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        T(if (v >= 1f) "Checking…" else "Uploading · ${(v * 100).toInt()}%", m.type.tiny.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), m.t.bg)
        studio.muse.app.ui.components.Bar(v, Modifier.fillMaxWidth(), m.t.accent, 4.dp, m.t.bg.copy(alpha = .25f))
    }
}

/** Creator Pop confetti (theme D only). */
@Composable
private fun BoxScope.ConfettiLayer(bursts: MutableList<Long>) {
    val m = muse
    val last = bursts.lastOrNull() ?: return
    if (!m.isD) return
    val prog = remember(last) { Animatable(0f) }
    LaunchedEffect(last) { prog.animateTo(1f, tween(1600, easing = LinearEasing)); bursts.clear() }
    val pieces = remember(last) { List(40) { Triple(Random.nextFloat(), Random.nextFloat() * .25f, it % 5) } }
    val cols = listOf(Color(0xFFFF7EB6), Color(0xFFFFE14D), Color(0xFF39D98A), Color(0xFF1F4BFF), Color.White)
    Box(Modifier.matchParentSize().drawBehind {
        pieces.forEach { (x, d, c) ->
            val p = ((prog.value - d) / (1f - d)).coerceIn(0f, 1f)
            if (p <= 0f) return@forEach
            val y = -20f + p * (size.height + 40f)
            val px = x * size.width
            drawRotate(p * 540f, Offset(px, y)) {
                drawRect(cols[c], Offset(px - 5.dp.toPx(), y), androidx.compose.ui.geometry.Size(10.dp.toPx(), 14.dp.toPx()))
                drawRect(Ink, Offset(px - 5.dp.toPx(), y), androidx.compose.ui.geometry.Size(10.dp.toPx(), 14.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(2.dp.toPx()))
            }
        }
    })
}

/** One tab of the bottom bar: its Phosphor icon, its sentence-case name and the route it opens. */
data class TabItem(val icon: String, val label: String, val route: String)

/**
 * The bottom bar's five tabs (design/direction/render.py, approved 2026-11-06): Home, Suite, Library, Queue, You. No centre "+":
 * creating lives on Home ("New shot" opens Suite → Shot; "New model") and in Suite (Shot, Character swap, Photo, Storyboard, Edit).
 */
val TAB_ITEMS = listOf(
    TabItem("house", "Home", Routes.HOME),
    TabItem("video-camera", "Suite", Routes.SUITE),
    TabItem("squares-four", "Library", Routes.GALLERY),
    TabItem("stack", "Queue", Routes.QUEUE),
    TabItem("user", "You", Routes.SETTINGS),
)

/**
 * Bottom bar, the same in every theme: canvas, one hairline on top, five equal tabs. Inactive tabs are ink2; the active tab is
 * the theme's selection colour (accent; Creator Pop's ink), with a short bar of it above the icon. Labels in the text face, sentence case.
 */
@Composable
fun BoxScope.TabBar(active: String) {
    val m = muse
    val r = m.roles
    val nav = LocalNav.current
    Column(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(r.canvas).drawBehind {
            drawLine(r.hairline, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx())
        }.navigationBarsPadding(),
    ) {
        Row(Modifier.fillMaxWidth().height(64.dp), verticalAlignment = Alignment.CenterVertically) {
            TAB_ITEMS.forEach { t ->
                val on = t.route == active
                val c = if (on) r.selection else r.ink2
                Column(
                    Modifier.weight(1f).fillMaxHeight().press { if (!on) nav.tab(t.route) }
                        .semantics(mergeDescendants = true) { selected = on; role = Role.Tab; contentDescription = t.label }
                        .testTag("tab_${t.route}"),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    Box(Modifier.width(24.dp).height(2.dp).background(if (on) r.selection else Color.Transparent))
                    Spacer(Modifier.height(MuseSpace.s2))
                    Ic(t.icon, 24.dp, c)
                    Spacer(Modifier.height(MuseSpace.s1))
                    T(t.label, m.scale.micro, c, maxLines = 1)
                }
            }
        }
    }
}
