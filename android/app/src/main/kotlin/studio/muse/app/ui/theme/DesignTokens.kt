package studio.muse.app.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.core.DesignTokens

// The design-direction tokens (plans/design-direction.md §2–§4) for Compose. The values live in core's DesignTokens, shared
// with the contrast tests; the Mac has the same names (Roles / TypeScale / Space). New and restyled screens use these;
// the older Tokens/MuseType stay until each screen is restyled.

/** Colour roles (§2). Components use roles, never a literal colour. */
@Immutable
data class MuseRoles(
    val canvas: Color, val raised: Color, val field: Color, val ink: Color, val ink2: Color, val hairline: Color,
    /** The selection mark and focus ring, once per region. In Creator Pop it is a fill only; its selection outline is [selection]. */
    val accent: Color,
    /** Text links. */
    val link: Color,
    /** The one primary button per screen, and its label. */
    val action: Color, val onAction: Color,
    val positive: Color, val caution: Color, val danger: Color,
    /** The outline that marks the current selection: accent, except Creator Pop's ink (its pink is too light for a line). */
    val selection: Color,
) {
    companion object {
        private fun c(v: Long) = Color(0xFF000000 or v)
        private fun from(r: DesignTokens.Roles, selection: Long = r.accent) = MuseRoles(
            c(r.canvas), c(r.raised), c(r.field), c(r.ink), c(r.ink2), c(r.hairline), c(r.accent), c(r.link), c(r.action), c(r.onAction),
            c(r.positive), c(r.caution), c(r.danger), c(selection),
        )
        private val byTheme = ThemeId.entries.associateWith { id ->
            val r = DesignTokens.roles(id.key[0])
            from(r, selection = if (id == ThemeId.D) r.ink else r.accent)
        }
        fun of(id: ThemeId): MuseRoles = byTheme.getValue(id)

        /** The camera bag (pickers, rig drums) is dark in every theme (§9). */
        val bag: MuseRoles = from(DesignTokens.bag)

        /** The Video suite redesign's roles (DesignTokens.suite): Camera Body's lifted dark, the light themes unchanged. */
        fun suite(id: ThemeId): MuseRoles = if (id == ThemeId.B) from(DesignTokens.suite('b')) else of(id)
    }
}

/** Type scale (§3): the same steps in every theme, two families per theme. Numbers that line up use [tabular]. */
@Immutable
data class MuseTypeScale(
    val display: TextStyle, val title: TextStyle, val heading: TextStyle, val body: TextStyle,
    val label: TextStyle, val caption: TextStyle, val micro: TextStyle,
    val displayFamily: FontFamily, val textFamily: FontFamily,
) {
    companion object {
        private val trim = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)
        private fun w(v: Int) = FontWeight(v)
        private fun style(f: FontFamily, s: DesignTokens.Step, weight: FontWeight = w(s.weight)) =
            TextStyle(fontFamily = f, fontSize = s.size.sp, lineHeight = s.lineHeight.sp, fontWeight = weight, lineHeightStyle = trim)

        private val byTheme = ThemeId.entries.associateWith { id ->
            val (display, text) = when (id) {
                ThemeId.A -> Fonts.instrumentSerif to Fonts.archivo
                ThemeId.B -> Fonts.barlowCondensed to Fonts.barlow
                ThemeId.C -> Fonts.outfit to Fonts.outfit
                ThemeId.D -> Fonts.bricolage to Fonts.figtree
            }
            // The display face's own weight: Instrument Serif has one; the bundled Barlow Condensed and Bricolage start at 500/700.
            val displayWeight = when (id) { ThemeId.A -> FontWeight.Normal; ThemeId.B -> FontWeight.SemiBold; ThemeId.C -> FontWeight.Medium; ThemeId.D -> FontWeight.Bold }
            MuseTypeScale(
                display = style(display, DesignTokens.display, displayWeight),
                title = style(text, DesignTokens.title), heading = style(text, DesignTokens.heading), body = style(text, DesignTokens.body),
                label = style(text, DesignTokens.label), caption = style(text, DesignTokens.caption), micro = style(text, DesignTokens.micro),
                displayFamily = display, textFamily = text,
            )
        }
        fun of(id: ThemeId): MuseTypeScale = byTheme.getValue(id)

        /** Tabular figures for prices, timecode, mm and f-stops. */
        fun tabular(s: TextStyle): TextStyle = s.copy(fontFeatureSettings = "tnum")
    }
}

/** Spacing on the 4/8 grid (§4). Inside a group s2, between groups s5, between sections s6. */
object MuseSpace {
    val s1: Dp = DesignTokens.space[0].dp
    val s2: Dp = DesignTokens.space[1].dp
    val s3: Dp = DesignTokens.space[2].dp
    val s4: Dp = DesignTokens.space[3].dp
    val s5: Dp = DesignTokens.space[4].dp
    val s6: Dp = DesignTokens.space[5].dp
    val s7: Dp = DesignTokens.space[6].dp
    /** Screen gutter on a phone; 24 on a tablet. */
    val gutter: Dp = s4
    val gutterTablet: Dp = s5
}

/** Radii by hierarchy (§4): container (sheets, media tiles) > control (buttons, fields) > chip. */
@Immutable
data class MuseRadii(val container: Dp, val control: Dp, val chip: Dp) {
    companion object {
        private val byTheme = ThemeId.entries.associateWith { id ->
            val r = DesignTokens.radii(id.key[0])
            MuseRadii(r.container.dp, r.control.dp, r.chip.dp)
        }
        fun of(id: ThemeId): MuseRadii = byTheme.getValue(id)
    }
}

val Muse.roles: MuseRoles get() = rolesOverride ?: MuseRoles.of(id)
val Muse.scale: MuseTypeScale get() = MuseTypeScale.of(id)
val Muse.radii: MuseRadii get() = MuseRadii.of(id)

/**
 * The one shadow (`float`, §4), for things that float over content: phone sheets, menus, popovers, toasts. No glow;
 * none in Camera Body. Compose's shadow takes an elevation, so the 12/32 spec maps to 12 dp with the theme's ink as colour.
 */
fun Modifier.museFloat(m: Muse, shape: Shape): Modifier {
    val f = DesignTokens.float(m.id.key[0]) ?: return this
    val c = m.roles.ink.copy(alpha = f.alpha.toFloat())
    return shadow(f.y.dp, shape, clip = false, ambientColor = c, spotColor = c)
}
