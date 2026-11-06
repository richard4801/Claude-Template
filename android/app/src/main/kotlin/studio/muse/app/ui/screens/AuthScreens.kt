package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.platform.LocalAutofillManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.SignUpRequest
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

/** Exact attestation copy (app.js SCREENS.signup). Consent otherwise lives only in the Terms. */
const val ATTEST_1 = "I'm 18 or older. I'll only upload clips and images I have the rights to use, and only create original characters."
const val ATTEST_2 = "I'll label AI content when I post it."
const val TERMS_LINE = "By continuing you agree to the MUSE Terms and Acceptable Use Policy."

data class AuthState(
    val studio: String = "",
    val email: String = "",
    val password: String = "",
    /** "MUSE-XXXX-XXXX-XXXX" from the studio owner; the owner's own first code is free text. */
    val invite: String = "",
    val ag1: Boolean = false,
    val ag2: Boolean = false,
    /** Sign in's Remember me (on by default): keep the session and the email across restarts. */
    val remember: Boolean = true,
    val busy: Boolean = false,
    /** Friendly error shown under the form. */
    val error: String? = null,
)

/** Invite codes look like MUSE-7KQ2-XW9P-4HTD. Anything else is still sent (the owner's first code is free text). */
fun looksLikeInvite(code: String) = Regex("^MUSE-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$").matches(code.trim().uppercase())

class AuthViewModel(private val c: AppContainer) : ViewModel() {
    private val demo get() = c.prefs.value.useFake
    private val _s = MutableStateFlow(
        if (demo) AuthState(studio = "Jenne Studio", email = c.prefs.value.email.ifBlank { "jenne@studio.com" }, remember = c.prefs.value.rememberMe)
        else AuthState(email = c.prefs.value.email, remember = c.prefs.value.rememberMe),
    )
    val state: StateFlow<AuthState> = _s
    val isDemo get() = demo
    fun edit(f: (AuthState) -> AuthState) = _s.update { f(it).copy(error = null) }

    fun signIn(onDone: () -> Unit) {
        val s = _s.value
        if (s.email.isBlank() || s.password.isEmpty()) { _s.update { it.copy(error = "Enter your email and password.") }; return }
        viewModelScope.launch {
            _s.update { it.copy(busy = true, error = null) }
            val err = c.repo.signIn(s.email, s.password, s.remember)
            _s.update { it.copy(busy = false, error = err) }
            if (err == null) onDone()
        }
    }

    fun signUp(onDone: () -> Unit) {
        val s = _s.value
        if (!s.ag1 || !s.ag2) { _s.update { it.copy(error = "Tick both boxes to continue.") }; return }
        if (!demo && s.invite.isBlank()) { _s.update { it.copy(error = "MUSE is invite-only. Enter the invite code your studio owner sent you.") }; return }
        viewModelScope.launch {
            _s.update { it.copy(busy = true, error = null) }
            val err = c.repo.signUp(SignUpRequest(s.studio.trim(), s.email.trim(), s.password, s.ag1, s.ag2, s.invite.trim().ifBlank { null }))
            _s.update { it.copy(busy = false, error = err) }
            if (err == null) onDone()
        }
    }

    fun forgot() = if (demo) c.repo.toast("Reset link sent to ${_s.value.email} (demo)") else c.repo.toast("Password reset isn't in the app yet · ask your studio owner")
}

@Composable
fun authVm(): AuthViewModel {
    val c = LocalContainer.current
    return viewModel { AuthViewModel(c) }
}

@Composable
fun SplashScreen() {
    val m = muse
    val nav = LocalNav.current
    val c = LocalContainer.current
    val signedIn = c.prefs.collectAsState().value.token != null
    val next = { if (signedIn) nav.reset(Routes.HOME) else nav.go(Routes.WELCOME) }
    // The latest [next]: the saved session usually loads after the first frame, so the first one would still say signed out.
    val latestNext by androidx.compose.runtime.rememberUpdatedState(next)
    LaunchedEffect(Unit) { delay(2600); latestNext() }
    Box(Modifier.fillMaxSize().background(if (m.isD) m.t.blue else Color.Black).press { next() }) {
        if (m.isD) {
            val shape = RoundedCornerShape(22.dp)
            Box(Modifier.fillMaxSize().padding(start = 28.dp, end = 28.dp, top = 110.dp, bottom = 230.dp).hardShadow(6.dp, 22.dp).clip(shape).border(3.dp, Ink, shape)) {
                BrandArt(Modifier.fillMaxSize())
            }
        } else {
            BrandArt(Modifier.fillMaxSize())
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Transparent, .45f to Color.Transparent, 1f to Color.Black.copy(alpha = .65f))))
            Box(Modifier.fillMaxSize().statusBarsPadding()) { Viewfinder() }
        }
        Sticker("AI model studio", "yellow", -8f, Modifier.statusBarsPadding().padding(start = 28.dp, top = 100.dp))
        Column(Modifier.align(Alignment.BottomStart).navigationBarsPadding().padding(start = 28.dp, end = 28.dp, bottom = 60.dp)) {
            if (m.isD) {
                StrokeText("MUSE", m.type.wmXl, m.t.yellow)
            } else Wordmark(size = "xl", color = Color.White)
            Spacer(Modifier.height(10.dp))
            when {
                m.isA -> T("THE FACE OF YOUR VISION", m.type.mono.copy(fontSize = 16.sp, letterSpacing = .14.em), Color.White)
                m.isB -> T("● REC  00:00:00:00", m.type.mono.copy(fontSize = 14.sp, letterSpacing = .08.em), m.t.accent)
                m.isC -> T("Direct your AI model", m.type.body.copy(fontSize = 14.sp, letterSpacing = .08.em), Color.White)
                else -> T("make her move!", m.type.hand.copy(fontSize = 22.sp), Color.White, upper = true)
            }
            Spacer(Modifier.height(22.dp))
            Tiny("Tap to start", color = Color.White.copy(alpha = .75f))
        }
    }
}

@Composable
fun WelcomeScreen() {
    val m = muse
    val nav = LocalNav.current
    Box(Modifier.fillMaxSize().background(m.t.bg).statusBarsPadding()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Row(Modifier.fillMaxWidth().height(388.dp).padding(start = 20.dp, end = 20.dp, top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val shape = RoundedCornerShape(m.t.rLg)
                fun Modifier.tile() = this.clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }
                Box(Modifier.weight(1.25f).fillMaxHeight().tile()) { AssetImage("g_front", Modifier.fillMaxSize(), 15); Viewfinder() }
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.weight(1f).fillMaxWidth().tile()) { AssetImage("c_face", Modifier.fillMaxSize(), 20) }
                    Box(Modifier.weight(1f).fillMaxWidth().tile()) { AssetImage("c_tq", Modifier.fillMaxSize(), 20); PlayBadge() }
                }
            }
            Column(Modifier.padding(horizontal = 20.dp).padding(top = 22.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (m.isA) T("CREATE YOUR\nAI MODEL.", m.type.hero.copy(fontSize = 62.sp, lineHeight = 54.sp), m.t.ink)
                else T("Create your AI model.\nDirect every shot.", m.type.hero, m.t.ink, upper = m.isB)
                T("Build an original persona, lock her identity, then put her into real clips with the motion kept frame for frame.", m.type.body, m.t.muted)
                Cta("Get started", { nav.go(Routes.SIGNUP) }, Modifier.fillMaxWidth())
                T("I already have an account", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink,
                    Modifier.fillMaxWidth().press { nav.go(Routes.SIGNIN) }.padding(vertical = 8.dp), align = TextAlign.Center)
            }
        }
        Sticker("identity locked", "pink", 6f, Modifier.align(Alignment.TopEnd).padding(end = 26.dp, top = 300.dp))
    }
}

@Composable
private fun AuthFrame(content: @Composable () -> Unit) {
    val nav = LocalNav.current
    Box(Modifier.fillMaxSize().background(muse.t.bg).statusBarsPadding()) {
        Column(Modifier.fillMaxSize()) {
            TopBar("", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                content()
            }
        }
    }
}

@Composable
fun SignInScreen() {
    val m = muse
    val nav = LocalNav.current
    val vm = authVm()
    val s by vm.state.collectAsState()
    AuthFrame {
        Column {
            Wordmark(size = "md")
            Spacer(Modifier.height(14.dp))
            H2("Welcome back")
            T("Sign in to your studio.", m.type.body, m.t.muted)
        }
        Field("Email") {
            Input(s.email, { v -> vm.edit { it.copy(email = v) } }, keyboard = androidx.compose.ui.text.input.KeyboardType.Email, placeholder = "you@example.com",
                autofill = ContentType.Username + ContentType.EmailAddress)
        }
        Field("Password") {
            Input(s.password, { v -> vm.edit { it.copy(password = v) } }, password = true, placeholder = "••••••••••", autofill = ContentType.Password, trailing = {
                T("Forgot?", m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), m.link, Modifier.press { vm.forgot() }.padding(8.dp))
            })
        }
        Check("Remember me", s.remember, { vm.edit { it.copy(remember = !it.remember) } })
        s.error?.let { NoteBox(it, warn = true) }
        // After a good sign-in, commit() lets the phone's password manager offer to save the email and password.
        val autofill = LocalAutofillManager.current
        val done: () -> Unit = { autofill?.commit(); nav.reset(Routes.HOME) }
        Cta(if (s.busy) "Signing in…" else "Sign in", { vm.signIn(done) }, Modifier.fillMaxWidth(), busy = s.busy)
        // Apple / Google sign-in only exist in Demo mode for now: the MUSE server is email + invite only.
        if (vm.isDemo) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.weight(1f).height(1.dp).background(m.t.line)); Tiny("or"); Box(Modifier.weight(1f).height(1.dp).background(m.t.line))
            }
            Sso("apple", "Continue with Apple") { vm.signIn { nav.reset(Routes.HOME) } }
            Sso("google", "Continue with Google") { vm.signIn { nav.reset(Routes.HOME) } }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            Tiny("New here? ")
            T("Create an account", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.link, Modifier.press { nav.go(Routes.SIGNUP) })
        }
    }
}

@Composable
private fun Sso(icon: String, label: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    var mod = Modifier.fillMaxWidth().height(52.dp)
    mod = if (m.isC) mod.softShadow(999.dp).clip(shape).background(m.t.surface) else mod.clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
    Row(mod.press(onClick = onClick), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Ic(icon, 20.dp); Spacer(Modifier.width(10.dp)); T(label, m.type.body.copy(fontWeight = FontWeight.SemiBold), m.t.ink)
    }
}

@Composable
fun SignUpScreen() {
    val m = muse
    val nav = LocalNav.current
    val vm = authVm()
    val s by vm.state.collectAsState()
    AuthFrame {
        Column {
            H2(if (vm.isDemo) "Create your studio" else "Join your studio")
            T(if (vm.isDemo) "One account for all your models." else "MUSE is invite-only. Use the code your studio owner sent you.", m.type.body, m.t.muted)
        }
        // On the server the studio comes from the invite; the name only matters in Demo mode.
        if (vm.isDemo) Field("Studio name") { Input(s.studio, { v -> vm.edit { it.copy(studio = v) } }) }
        Field("Invite code") {
            Input(s.invite, { v -> vm.edit { it.copy(invite = v.take(80)) } }, placeholder = "MUSE-XXXX-XXXX-XXXX")
            if (s.invite.isNotBlank() && !looksLikeInvite(s.invite)) Tiny("Not the usual MUSE-XXXX-XXXX-XXXX shape. That's fine for the owner's first code.")
            else if (vm.isDemo) Tiny("Not needed in Demo mode.")
        }
        Field("Email") {
            Input(s.email, { v -> vm.edit { it.copy(email = v) } }, keyboard = androidx.compose.ui.text.input.KeyboardType.Email, placeholder = "The email your invite was sent to",
                autofill = ContentType.Username + ContentType.EmailAddress)
        }
        Field("Password") { Input(s.password, { v -> vm.edit { it.copy(password = v) } }, password = true, placeholder = "8 or more characters", autofill = ContentType.NewPassword) }
        Check(ATTEST_1, s.ag1, { vm.edit { it.copy(ag1 = !it.ag1) } })
        Check(ATTEST_2, s.ag2, { vm.edit { it.copy(ag2 = !it.ag2) } })
        s.error?.let { NoteBox(it, warn = true) }
        val autofill = LocalAutofillManager.current
        Cta(if (s.busy) "Creating account…" else "Create account", { vm.signUp { autofill?.commit(); nav.reset(Routes.HOME) } }, Modifier.fillMaxWidth(), off = !(s.ag1 && s.ag2), busy = s.busy)
        T(TERMS_LINE, m.type.tiny, m.t.muted, Modifier.fillMaxWidth(), align = TextAlign.Center)
    }
}

/**
 * The splash art: an abstract brand gradient with soft light shapes (no person, owner decision 2026-11-04) until the owner
 * supplies a new image.
 */
@Composable
fun BrandArt(modifier: Modifier = Modifier) {
    val m = muse
    val a = m.t.accent
    androidx.compose.foundation.Canvas(modifier.background(Brush.linearGradient(listOf(Color(0xFF1B1726), a.copy(alpha = .85f), Color(0xFF0E0D12))))) {
        val w = size.width; val h = size.height
        drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = .28f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(w * .72f, h * .28f), radius = w * .7f),
            radius = w * .7f, center = androidx.compose.ui.geometry.Offset(w * .72f, h * .28f))
        drawCircle(Brush.radialGradient(listOf(m.t.yellow.copy(alpha = .22f), Color.Transparent), center = androidx.compose.ui.geometry.Offset(w * .18f, h * .62f), radius = w * .55f),
            radius = w * .55f, center = androidx.compose.ui.geometry.Offset(w * .18f, h * .62f))
        drawCircle(Color.White.copy(alpha = .10f), radius = w * .36f, center = androidx.compose.ui.geometry.Offset(w * .5f, h * .42f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f))
        drawCircle(Color.White.copy(alpha = .06f), radius = w * .52f, center = androidx.compose.ui.geometry.Offset(w * .5f, h * .42f),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f))
    }
}
