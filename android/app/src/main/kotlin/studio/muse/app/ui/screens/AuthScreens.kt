package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.flow.first
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
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

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

/** The splash stays at least this long, so a fast launch doesn't flash it. */
const val SPLASH_MIN_MS = 300L

@Composable
fun SplashScreen() {
    val m = muse
    val nav = LocalNav.current
    val c = LocalContainer.current
    var left by remember { mutableStateOf(false) }
    val go = { signedIn: Boolean -> if (!left) { left = true; if (signedIn) nav.reset(Routes.HOME) else nav.go(Routes.WELCOME) } }
    // Show until ready (owner decision 2026-11-06, plans/perf-audit.md): leave as soon as the saved session has loaded, which
    // decides the first screen, with a short minimum so the splash doesn't flash. No fixed hold.
    LaunchedEffect(Unit) {
        val start = android.os.SystemClock.uptimeMillis()
        val signedIn = c.prefsStore.prefs.first().token != null
        delay((SPLASH_MIN_MS - (android.os.SystemClock.uptimeMillis() - start)).coerceAtLeast(0))
        go(signedIn)
    }
    val scope = rememberCoroutineScope()
    Box(Modifier.fillMaxSize().background(m.roles.canvas).press { scope.launch { go(c.prefsStore.prefs.first().token != null) } }) {
        Column(Modifier.align(Alignment.BottomStart).navigationBarsPadding().padding(start = MuseSpace.s6, end = MuseSpace.s6, bottom = MuseSpace.s7)) {
            // The wordmark is the brand mark: the display face, larger than any screen title.
            T("MUSE", m.scale.display.copy(fontSize = 56.sp, lineHeight = 60.sp), m.roles.ink)
            Spacer(Modifier.height(MuseSpace.s2))
            Body("AI model studio")
            Spacer(Modifier.height(MuseSpace.s6))
            Caption("Tap to start")
        }
    }
}

@Composable
fun WelcomeScreen() {
    val m = muse
    val nav = LocalNav.current
    Box(Modifier.fillMaxSize().background(m.roles.canvas).statusBarsPadding()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            Row(Modifier.fillMaxWidth().height(388.dp).padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s2), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                val shape = containerShape()
                Box(Modifier.weight(1.25f).fillMaxHeight().clip(shape)) { AssetImage("g_front", Modifier.fillMaxSize(), 15) }
                Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    Box(Modifier.weight(1f).fillMaxWidth().clip(shape)) { AssetImage("c_face", Modifier.fillMaxSize(), 20) }
                    Box(Modifier.weight(1f).fillMaxWidth().clip(shape)) { AssetImage("c_tq", Modifier.fillMaxSize(), 20) }
                }
            }
            Column(Modifier.padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s6, bottom = MuseSpace.s6), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                DisplayTitle("Create your AI model. Direct every shot.")
                Body("Build an original persona, lock her identity, then put her into real clips with the motion kept frame for frame.")
                Spacer(Modifier.height(MuseSpace.s3))
                PrimaryButton("Get started", { nav.go(Routes.SIGNUP) }, Modifier.fillMaxWidth())
                SecondaryButton("I already have an account", { nav.go(Routes.SIGNIN) }, Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun AuthFrame(content: @Composable () -> Unit) {
    val nav = LocalNav.current
    Box(Modifier.fillMaxSize().background(muse.roles.canvas).statusBarsPadding()) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = MuseSpace.s6),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
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
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            DisplayTitle("Welcome back")
            Body("Sign in to your studio.")
        }
        Labeled("Email") {
            Input(s.email, { v -> vm.edit { it.copy(email = v) } }, keyboard = androidx.compose.ui.text.input.KeyboardType.Email, placeholder = "you@example.com",
                autofill = ContentType.Username + ContentType.EmailAddress, calm = true)
        }
        Labeled("Password") {
            Input(s.password, { v -> vm.edit { it.copy(password = v) } }, password = true, placeholder = "Your password", autofill = ContentType.Password, calm = true, trailing = {
                TextAction("Forgot?", { vm.forgot() }, Modifier.padding(end = MuseSpace.s1))
            })
        }
        Check("Remember me", s.remember, { vm.edit { it.copy(remember = !it.remember) } }, Modifier.heightIn(min = 48.dp))
        s.error?.let { Notice(it, tone = NoticeTone.DANGER) }
        // After a good sign-in, commit() lets the phone's password manager offer to save the email and password.
        val autofill = LocalAutofillManager.current
        val done: () -> Unit = { autofill?.commit(); nav.reset(Routes.HOME) }
        PrimaryButton(if (s.busy) "Signing in…" else "Sign in", { vm.signIn(done) }, Modifier.fillMaxWidth(), busy = s.busy)
        // Apple / Google sign-in only exist in Demo mode for now: the MUSE server is email + invite only.
        if (vm.isDemo) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Sso("apple", "Continue with Apple") { vm.signIn { nav.reset(Routes.HOME) } }
            Sso("google", "Continue with Google") { vm.signIn { nav.reset(Routes.HOME) } }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Caption("New here?")
            TextAction("Create an account", { nav.go(Routes.SIGNUP) })
        }
    }
}

@Composable
private fun Sso(icon: String, label: String, onClick: () -> Unit) = SecondaryButton(label, onClick, Modifier.fillMaxWidth(), icon = icon)

@Composable
fun SignUpScreen() {
    val m = muse
    val nav = LocalNav.current
    val vm = authVm()
    val s by vm.state.collectAsState()
    AuthFrame {
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            DisplayTitle(if (vm.isDemo) "Create your studio" else "Join your studio")
            Body(if (vm.isDemo) "One account for all your models." else "MUSE is invite-only. Use the code your studio owner sent you.")
        }
        // On the server the studio comes from the invite; the name only matters in Demo mode.
        if (vm.isDemo) Labeled("Studio name") { Input(s.studio, { v -> vm.edit { it.copy(studio = v) } }, calm = true) }
        Labeled("Invite code") {
            Input(s.invite, { v -> vm.edit { it.copy(invite = v.take(80)) } }, placeholder = "MUSE-XXXX-XXXX-XXXX", calm = true)
            if (s.invite.isNotBlank() && !looksLikeInvite(s.invite)) Caption("Not the usual MUSE-XXXX-XXXX-XXXX shape. That's fine for the owner's first code.")
            else if (vm.isDemo) Caption("Not needed in Demo mode.")
        }
        Labeled("Email") {
            Input(s.email, { v -> vm.edit { it.copy(email = v) } }, keyboard = androidx.compose.ui.text.input.KeyboardType.Email, placeholder = "The email your invite was sent to",
                autofill = ContentType.Username + ContentType.EmailAddress, calm = true)
        }
        Labeled("Password") { Input(s.password, { v -> vm.edit { it.copy(password = v) } }, password = true, placeholder = "8 or more characters", autofill = ContentType.NewPassword, calm = true) }
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            Check(ATTEST_1, s.ag1, { vm.edit { it.copy(ag1 = !it.ag1) } })
            Check(ATTEST_2, s.ag2, { vm.edit { it.copy(ag2 = !it.ag2) } })
        }
        s.error?.let { Notice(it, tone = NoticeTone.DANGER) }
        val autofill = LocalAutofillManager.current
        PrimaryButton(if (s.busy) "Creating account…" else "Create account", { vm.signUp { autofill?.commit(); nav.reset(Routes.HOME) } }, Modifier.fillMaxWidth(), off = !(s.ag1 && s.ag2), busy = s.busy)
        Caption(TERMS_LINE, Modifier.fillMaxWidth())
    }
}
