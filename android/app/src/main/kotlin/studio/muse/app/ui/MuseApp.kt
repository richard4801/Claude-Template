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
import androidx.compose.ui.unit.dp
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
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
import kotlin.random.Random

val LocalContainer = staticCompositionLocalOf<AppContainer> { error("no container") }
val LocalNav = staticCompositionLocalOf<Nav> { error("no nav") }
/** Celebrate: confetti in Creator Pop. */
val LocalCelebrate = staticCompositionLocalOf<() -> Unit> { {} }

object Routes {
    const val SPLASH = "splash"; const val WELCOME = "welcome"; const val SIGNIN = "signin"; const val SIGNUP = "signup"
    const val HOME = "home"; const val GALLERY = "gallery"; const val QUEUE = "queue"; const val SETTINGS = "settings"; const val CREDITS = "credits"
    const val PROFILE = "profile"; const val CREATE1 = "create1"; const val CREATE3 = "create3"; const val OUTFIT = "outfit"
    const val SHOOT = "shoot"; const val SOURCE = "source"; const val DIRECT = "direct"; const val RESULT = "result/{id}"
    const val LORA = "lora"; const val ACCOUNTS = "accounts"; const val POST = "post/{id}"; const val POSTS = "posts"
    const val MEMBERS = "members"; const val INVITE = "invite"; const val STUDIO = "studio"
    const val TEMPLATES = "templates"; const val TEMPLATE = "template/{id}"; const val TEMPLATE_USE = "template/{id}/use"; const val SAVE_TEMPLATE = "savetemplate/{id}"
    val TABS = setOf(HOME, GALLERY, QUEUE, SETTINGS)
    fun result(id: String) = "result/$id"
    fun template(id: String) = "template/$id"
    fun templateUse(id: String) = "template/$id/use"
    fun saveTemplate(shotId: String) = "savetemplate/$shotId"
    fun post(takeId: String) = "post/$takeId"
}

/** Navigation helpers (the prototype's go/back/tab). */
class Nav(val controller: NavHostController) {
    fun go(route: String) {
        if (controller.currentDestination?.route == route) return
        controller.navigate(route) { launchSingleTop = true }
    }

    fun back() {
        if (!controller.popBackStack()) controller.navigate(Routes.HOME)
    }

    fun tab(route: String) {
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
                    composable(Routes.SHOOT) { ShootScreen() }
                    composable(Routes.SOURCE) { SourceScreen() }
                    composable(Routes.DIRECT) { DirectScreen() }
                    composable(Routes.RESULT) { e -> ResultScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.LORA) { LoraScreen() }
                    composable(Routes.ACCOUNTS) { AccountsScreen() }
                    composable(Routes.POST) { e -> PostScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.POSTS) { PostsScreen() }
                    composable(Routes.MEMBERS) { MembersScreen() }
                    composable(Routes.INVITE) { InviteScreen() }
                    composable(Routes.STUDIO) { StudioSettingsScreen() }
                    composable(Routes.TEMPLATES) { TemplatesScreen() }
                    composable(Routes.TEMPLATE) { e -> TemplateDetailScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.TEMPLATE_USE) { e -> TemplateUseScreen(e.arguments?.getString("id") ?: "") }
                    composable(Routes.SAVE_TEMPLATE) { e -> SaveTemplateScreen(e.arguments?.getString("id") ?: "") }
                }
                val entry by nav.currentBackStackEntryAsState()
                FlashOnNav(theme, entry)
                UploadProgressHost(container)
                ToastHost(container)
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
    val shape = RoundedCornerShape(m.t.r)
    var mod = Modifier.statusBarsPadding().padding(start = 16.dp, end = 16.dp, top = 10.dp).fillMaxWidth()
    mod = if (m.isD) mod.hardShadow(4.dp, m.t.r).clip(shape).background(m.t.yellow).border(2.5.dp, Ink, shape) else mod.clip(shape).background(m.t.ink)
    Row(
        mod.align(Alignment.TopCenter).press { current = null; t.route?.let { nav.go(it) } }.padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (m.isD) Ink else m.t.bg
        Ic("spark", 18.dp, fg)
        T(t.message, m.type.body.copy(fontSize = androidx.compose.ui.unit.TextUnit(14f, androidx.compose.ui.unit.TextUnitType.Sp), fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), fg)
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

/** Bottom bar: Home · Gallery · + · Queue · You. Same in every theme. + opens a menu. */
@Composable
fun BoxScope.TabBar(active: String) {
    val m = muse
    val nav = LocalNav.current
    var plus by remember { mutableStateOf(false) }
    val items = listOf(Triple("home", "Home", Routes.HOME), Triple("grid", "Gallery", Routes.GALLERY), Triple("plus", "", ""), Triple("queue", "Queue", Routes.QUEUE), Triple("user", "You", Routes.SETTINGS))
    val bg = when { m.isA -> m.t.bg; m.isB -> Color(0xFF0B0C0D); m.isD -> Color.White; else -> m.t.surface }
    Column(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(bg).drawBehind {
            if (!m.isC) drawLine(if (m.isD) Ink else m.t.line, Offset(0f, 0f), Offset(size.width, 0f), (if (m.isD) 2.5.dp else m.t.stroke).toPx())
        }.navigationBarsPadding(),
    ) {
        Row(Modifier.fillMaxWidth().height(66.dp).padding(horizontal = 14.dp), horizontalArrangement = Arrangement.SpaceAround, verticalAlignment = Alignment.CenterVertically) {
            items.forEach { (icon, label, route) ->
                if (icon == "plus") {
                    Box {
                        val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
                        Box(
                            Modifier.size(50.dp).let { if (m.isD) it.hardShadow(3.dp, 999.dp) else it }.clip(shape).background(m.t.cta)
                                .let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.press { plus = true },
                            contentAlignment = Alignment.Center,
                        ) { Ic("plus", 24.dp, m.t.ctaInk) }
                        MuseMenu(plus, { plus = false }, listOf(
                            MenuItem("studio", "New video") { nav.go(Routes.SOURCE) },
                            MenuItem("camera", "Photoshoot") { nav.go(Routes.SHOOT) },
                            MenuItem("model", "New model") { nav.go(Routes.CREATE1) },
                        ))
                    }
                } else {
                    val on = route == active
                    val c = if (on) (if (m.isD) m.t.blue else m.t.accent) else m.t.muted
                    Column(Modifier.width(60.dp).press { if (!on) nav.tab(route) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Ic(icon, 22.dp, c)
                        T(label, m.type.tab.copy(fontWeight = if (on && m.isD) androidx.compose.ui.text.font.FontWeight.ExtraBold else null), c, upper = m.isA, maxLines = 1)
                    }
                }
            }
        }
    }
}
