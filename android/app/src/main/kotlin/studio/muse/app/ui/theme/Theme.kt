package studio.muse.app.ui.theme

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.R

/** The four approved themes. Each has its own layouts, motion and sounds, not just colours. */
enum class ThemeId(val key: String, val label: String) {
    A("a", "Editorial"), B("b", "Camera Body"), C("c", "Soft Tactile"), D("d", "Creator Pop");

    companion object {
        fun fromKey(k: String?): ThemeId = entries.firstOrNull { it.key == k } ?: A
    }
}

object Fonts {
    val instrumentSerif = FontFamily(Font(R.font.instrument_serif_400, FontWeight.Normal))
    val archivo = FontFamily(
        Font(R.font.archivo_400, FontWeight.Normal), Font(R.font.archivo_500, FontWeight.Medium),
        Font(R.font.archivo_600, FontWeight.SemiBold), Font(R.font.archivo_700, FontWeight.Bold),
    )
    val plexMono = FontFamily(Font(R.font.ibm_plex_mono_400, FontWeight.Normal), Font(R.font.ibm_plex_mono_500, FontWeight.Medium))
    val barlow = FontFamily(
        Font(R.font.barlow_400, FontWeight.Normal), Font(R.font.barlow_500, FontWeight.Medium),
        Font(R.font.barlow_600, FontWeight.SemiBold), Font(R.font.barlow_700, FontWeight.Bold),
    )
    val barlowCondensed = FontFamily(
        Font(R.font.barlow_condensed_500, FontWeight.Medium), Font(R.font.barlow_condensed_600, FontWeight.SemiBold),
        Font(R.font.barlow_condensed_700, FontWeight.Bold),
    )
    val jetbrainsMono = FontFamily(
        Font(R.font.jetbrains_mono_400, FontWeight.Normal), Font(R.font.jetbrains_mono_500, FontWeight.Medium),
        Font(R.font.jetbrains_mono_700, FontWeight.Bold),
    )
    val outfit = FontFamily(
        Font(R.font.outfit_300, FontWeight.Light), Font(R.font.outfit_400, FontWeight.Normal), Font(R.font.outfit_500, FontWeight.Medium),
        Font(R.font.outfit_600, FontWeight.SemiBold), Font(R.font.outfit_700, FontWeight.Bold),
    )
    val dmMono = FontFamily(Font(R.font.dm_mono_400, FontWeight.Normal), Font(R.font.dm_mono_500, FontWeight.Medium))
    val bricolage = FontFamily(Font(R.font.bricolage_grotesque_700, FontWeight.Bold), Font(R.font.bricolage_grotesque_800, FontWeight.ExtraBold))
    val figtree = FontFamily(
        Font(R.font.figtree_400, FontWeight.Normal), Font(R.font.figtree_500, FontWeight.Medium), Font(R.font.figtree_600, FontWeight.SemiBold),
        Font(R.font.figtree_700, FontWeight.Bold), Font(R.font.figtree_800, FontWeight.ExtraBold),
    )
    val marker = FontFamily(Font(R.font.permanent_marker_400, FontWeight.Normal))
}

/** Colour, radius, stroke and font tokens (prototype/screens/gen.py THEMES + the review fixes in build_proto.py). */
@Immutable
data class Tokens(
    val bg: Color, val surface: Color, val surface2: Color, val ink: Color, val muted: Color, val line: Color,
    val accent: Color, val accentInk: Color, val cta: Color, val ctaInk: Color, val good: Color, val warn: Color,
    val warnPillBg: Color, val warnPillInk: Color,
    val r: Dp, val rLg: Dp, val stroke: Dp,
    val display: FontFamily, val body: FontFamily, val mono: FontFamily,
    val dark: Boolean,
    val blue: Color = Color(0xFF1F4BFF), val yellow: Color = Color(0xFFFFE14D), val mint: Color = Color(0xFF39D98A),
    val pink: Color = Color(0xFFFF7EB6), val rec: Color = Color(0xFFE5483B),
)

/** Type scale per theme. Sizes are CSS px on a 390-wide phone, which map 1:1 to sp. */
@Immutable
data class MuseType(
    val body: TextStyle, val tiny: TextStyle, val lbl: TextStyle, val h2: TextStyle, val h3: TextStyle, val hero: TextStyle,
    val wm: TextStyle, val wmMd: TextStyle, val wmXl: TextStyle, val featName: TextStyle, val cta: TextStyle, val cta2: TextStyle,
    val tab: TextStyle, val tool: TextStyle, val chip: TextStyle, val seg: TextStyle, val pill: TextStyle, val topTitle: TextStyle,
    val stepNum: TextStyle, val mono: TextStyle, val menu: TextStyle, val hand: TextStyle,
)

@Immutable
data class Muse(val id: ThemeId, val t: Tokens, val type: MuseType) {
    val isA get() = id == ThemeId.A
    val isB get() = id == ThemeId.B
    val isC get() = id == ThemeId.C
    val isD get() = id == ThemeId.D
}

private val tight = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.Both)

private fun ts(f: FontFamily, size: TextUnit, w: FontWeight = FontWeight.Normal, ls: TextUnit = TextUnit.Unspecified, lh: TextUnit = TextUnit.Unspecified, c: Color = Color.Unspecified) =
    TextStyle(fontFamily = f, fontSize = size, fontWeight = w, letterSpacing = ls, lineHeight = lh, color = c, lineHeightStyle = if (lh != TextUnit.Unspecified) tight else null)

fun tokensFor(id: ThemeId): Tokens = when (id) {
    ThemeId.A -> Tokens(
        bg = Color(0xFFEFEBE3), surface = Color(0xFFF8F5EF), surface2 = Color(0xFFE7E1D6), ink = Color(0xFF141210), muted = Color(0xFF6E675E),
        line = Color(0xFFCFC7BA), accent = Color(0xFFB5121B), accentInk = Color.White, cta = Color(0xFF141210), ctaInk = Color(0xFFF8F5EF),
        good = Color(0xFF2F6B3A), warn = Color(0xFF9A5B00), warnPillBg = Color(0xFFF6E2C0), warnPillInk = Color(0xFF6B3F00),
        r = 2.dp, rLg = 2.dp, stroke = 1.dp, display = Fonts.instrumentSerif, body = Fonts.archivo, mono = Fonts.plexMono, dark = false,
    )
    ThemeId.B -> Tokens(
        bg = Color(0xFF0D0E0F), surface = Color(0xFF17191B), surface2 = Color(0xFF212427), ink = Color(0xFFECEAE5), muted = Color(0xFFA9A6A0),
        line = Color(0xFF2C3033), accent = Color(0xFFF2A93B), accentInk = Color(0xFF1A1205), cta = Color(0xFFF2A93B), ctaInk = Color(0xFF1A1205),
        good = Color(0xFF7BD88F), warn = Color(0xFFF2A93B), warnPillBg = Color(0xFF3A2B14), warnPillInk = Color(0xFFF2B45A),
        r = 10.dp, rLg = 14.dp, stroke = 1.dp, display = Fonts.barlowCondensed, body = Fonts.barlow, mono = Fonts.jetbrainsMono, dark = true,
    )
    ThemeId.C -> Tokens(
        bg = Color(0xFFE7E2D9), surface = Color(0xFFF3F0EA), surface2 = Color(0xFFEAE5DC), ink = Color(0xFF23262A), muted = Color(0xFF5E5C57),
        line = Color(0xFFD9D3C8), accent = Color(0xFF6E8465), accentInk = Color.White, cta = Color(0xFF5A6E52), ctaInk = Color.White,
        good = Color(0xFF4E6B45), warn = Color(0xFF9A6B2A), warnPillBg = Color(0xFFF6E2C0), warnPillInk = Color(0xFF6B3F00),
        r = 18.dp, rLg = 28.dp, stroke = 1.dp, display = Fonts.outfit, body = Fonts.outfit, mono = Fonts.dmMono, dark = false,
    )
    ThemeId.D -> Tokens(
        bg = Color(0xFFFFF6EC), surface = Color.White, surface2 = Color(0xFFFFEBD8), ink = Color(0xFF111111), muted = Color(0xFF55504A),
        line = Color(0xFF111111), accent = Color(0xFFFF7EB6), accentInk = Color(0xFF111111), cta = Color(0xFFFF7EB6), ctaInk = Color(0xFF111111),
        good = Color(0xFF0E8A4F), warn = Color(0xFFB45A00), warnPillBg = Color(0xFFF6E2C0), warnPillInk = Color(0xFF6B3F00),
        r = 14.dp, rLg = 20.dp, stroke = 2.5.dp, display = Fonts.bricolage, body = Fonts.figtree, mono = Fonts.figtree, dark = false,
    )
}

fun typeFor(id: ThemeId, t: Tokens): MuseType {
    val body = ts(t.body, 15.sp, lh = 21.sp)
    val tiny = ts(t.body, 12.5.sp, lh = 17.sp)
    val mono = ts(t.mono, 12.5.sp)
    return when (id) {
        ThemeId.A -> MuseType(
            body = body, tiny = tiny,
            lbl = ts(t.mono, 11.5.sp, FontWeight.Medium, ls = 0.1.em),
            h2 = ts(t.display, 42.sp, lh = 40.sp), h3 = ts(t.body, 17.sp, FontWeight.Bold),
            hero = ts(t.display, 56.sp, lh = 50.sp), wm = ts(t.display, 28.sp, ls = 0.08.em), wmMd = ts(t.display, 44.sp, ls = 0.08.em),
            wmXl = ts(t.display, 118.sp, ls = 0.02.em, lh = 100.sp), featName = ts(t.display, 40.sp, lh = 36.sp),
            cta = ts(t.mono, 13.sp, FontWeight.Medium, ls = 0.12.em), cta2 = ts(t.body, 15.sp, FontWeight.SemiBold),
            tab = ts(t.mono, 11.sp, ls = 0.06.em), tool = ts(t.mono, 11.sp, ls = 0.06.em), chip = ts(t.body, 13.sp),
            seg = ts(t.mono, 13.5.sp, FontWeight.SemiBold, ls = 0.1.em), pill = ts(t.mono, 11.5.sp, FontWeight.Bold, ls = 0.1.em),
            topTitle = ts(t.body, 16.sp, FontWeight.Bold), stepNum = ts(t.display, 84.sp, lh = 72.sp), mono = mono,
            menu = ts(t.mono, 12.sp, ls = 0.06.em), hand = ts(Fonts.marker, 15.sp),
        )
        ThemeId.B -> MuseType(
            body = body, tiny = tiny,
            lbl = ts(t.mono, 11.5.sp, FontWeight.Medium, ls = 0.08.em),
            h2 = ts(t.display, 30.sp, FontWeight.SemiBold, ls = 0.04.em, lh = 32.sp), h3 = ts(t.body, 17.sp, FontWeight.Bold),
            hero = ts(t.display, 38.sp, FontWeight.SemiBold, ls = 0.04.em, lh = 39.sp), wm = ts(t.display, 22.sp, FontWeight.SemiBold, ls = 0.32.em),
            wmMd = ts(t.display, 36.sp, FontWeight.SemiBold, ls = 0.32.em), wmXl = ts(t.display, 64.sp, FontWeight.SemiBold, ls = 0.3.em),
            featName = ts(t.display, 30.sp, FontWeight.SemiBold, ls = 0.04.em, lh = 32.sp),
            cta = ts(t.body, 16.sp, FontWeight.Bold), cta2 = ts(t.body, 15.sp, FontWeight.SemiBold),
            tab = ts(t.body, 11.5.sp), tool = ts(t.body, 11.5.sp), chip = ts(t.body, 14.sp),
            seg = ts(t.body, 13.5.sp, FontWeight.SemiBold), pill = ts(t.body, 11.5.sp, FontWeight.Bold),
            topTitle = ts(t.mono, 13.sp, FontWeight.Medium, ls = 0.14.em), stepNum = ts(t.mono, 52.sp), mono = mono,
            menu = ts(t.body, 14.5.sp), hand = ts(Fonts.marker, 15.sp),
        )
        ThemeId.C -> MuseType(
            body = body, tiny = tiny,
            lbl = ts(t.body, 13.sp, FontWeight.Medium),
            h2 = ts(t.display, 32.sp, FontWeight.Medium, ls = (-0.02).em, lh = 34.sp), h3 = ts(t.body, 17.sp, FontWeight.Bold),
            hero = ts(t.display, 40.sp, FontWeight.Medium, ls = (-0.025).em, lh = 41.sp), wm = ts(t.display, 20.sp, FontWeight.Medium, ls = 0.3.em),
            wmMd = ts(t.display, 36.sp, FontWeight.Medium, ls = 0.3.em), wmXl = ts(t.display, 56.sp, FontWeight.Medium, ls = 0.32.em),
            featName = ts(t.display, 30.sp, FontWeight.Medium, ls = (-0.02).em, lh = 32.sp),
            cta = ts(t.body, 16.sp, FontWeight.Bold), cta2 = ts(t.body, 15.sp, FontWeight.SemiBold),
            tab = ts(t.body, 11.5.sp), tool = ts(t.body, 11.5.sp), chip = ts(t.body, 14.sp),
            seg = ts(t.body, 13.5.sp, FontWeight.SemiBold), pill = ts(t.body, 11.5.sp, FontWeight.Bold),
            topTitle = ts(t.body, 16.sp, FontWeight.Bold), stepNum = ts(t.display, 64.sp, FontWeight.Light, ls = (-0.04).em, lh = 64.sp), mono = mono,
            menu = ts(t.body, 14.5.sp), hand = ts(Fonts.marker, 15.sp),
        )
        ThemeId.D -> MuseType(
            body = body, tiny = tiny,
            lbl = ts(t.body, 11.5.sp, FontWeight.SemiBold, ls = 0.08.em),
            h2 = ts(t.display, 30.sp, FontWeight.ExtraBold, ls = (-0.02).em, lh = 32.sp), h3 = ts(t.body, 17.sp, FontWeight.Bold),
            hero = ts(t.display, 42.sp, FontWeight.ExtraBold, ls = (-0.02).em, lh = 43.sp), wm = ts(t.display, 30.sp, FontWeight.ExtraBold, ls = (-0.02).em),
            wmMd = ts(t.display, 36.sp, FontWeight.ExtraBold), wmXl = ts(t.display, 96.sp, FontWeight.ExtraBold, ls = (-0.02).em, lh = 90.sp),
            featName = ts(t.display, 30.sp, FontWeight.ExtraBold, ls = (-0.02).em, lh = 32.sp),
            cta = ts(t.display, 18.sp, FontWeight.ExtraBold), cta2 = ts(t.body, 15.sp, FontWeight.SemiBold),
            tab = ts(t.body, 11.5.sp), tool = ts(t.body, 11.5.sp), chip = ts(t.body, 14.sp),
            seg = ts(t.body, 13.5.sp, FontWeight.SemiBold), pill = ts(t.body, 11.5.sp, FontWeight.Bold),
            topTitle = ts(t.body, 16.sp, FontWeight.Bold), stepNum = ts(t.display, 52.sp, FontWeight.ExtraBold, lh = 52.sp), mono = mono,
            menu = ts(t.body, 14.5.sp, FontWeight.Bold), hand = ts(Fonts.marker, 15.sp),
        )
    }
}

fun museFor(id: ThemeId): Muse {
    val t = tokensFor(id)
    return Muse(id, t, typeFor(id, t))
}

val LocalMuse = staticCompositionLocalOf { museFor(ThemeId.A) }

/** Shortcut inside composables. */
val muse: Muse @Composable get() = LocalMuse.current

@Composable
fun MuseTheme(id: ThemeId, content: @Composable () -> Unit) {
    val m = museFor(id)
    val t = m.t
    val scheme = if (t.dark) darkColorScheme(primary = t.accent, onPrimary = t.accentInk, background = t.bg, surface = t.surface, onSurface = t.ink, onBackground = t.ink)
    else lightColorScheme(primary = t.accent, onPrimary = t.accentInk, background = t.bg, surface = t.surface, onSurface = t.ink, onBackground = t.ink)
    MaterialTheme(colorScheme = scheme) {
        CompositionLocalProvider(
            LocalMuse provides m,
            LocalContentColor provides t.ink,
            LocalTextSelectionColors provides TextSelectionColors(t.accent, t.accent.copy(alpha = 0.3f)),
        ) { content() }
    }
}
