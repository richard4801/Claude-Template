package studio.muse.core

/**
 * The design-direction tokens as plain values (plans/design-direction.md §2–§4), shared by the app's theme and the
 * contrast tests. Colours are 0xRRGGBB. The Mac keeps the same values in MuseCore/DesignTokens.swift.
 */
object DesignTokens {
    /** One colour per role; the roles are the same in all four themes (§2). */
    data class Roles(
        val canvas: Long, val raised: Long, val field: Long, val ink: Long, val ink2: Long, val hairline: Long,
        /** The selection mark, focus ring. In Creator Pop it is a fill only (pink under ink text); its selection outline is ink. */
        val accent: Long,
        /** Text links: the accent where it reads as text, Creator Pop's cobalt otherwise. */
        val link: Long,
        val action: Long, val onAction: Long,
        val positive: Long, val caution: Long, val danger: Long,
    )

    /** container > control > chip (§4). 999 = fully round. */
    data class Radii(val container: Int, val control: Int, val chip: Int)

    /** The one `float` shadow (§4): y offset and blur in dp/pt, colour = the theme's ink at [alpha]. Null in Camera Body (no shadows). */
    data class FloatShadow(val y: Int, val blur: Int, val alpha: Double)

    /** One step of the type scale (§3). */
    data class Step(val size: Int, val lineHeight: Int, val weight: Int, val display: Boolean = false)

    /** Two families per theme (§3): display for titles only, text for everything else. */
    data class Families(val display: String, val text: String)

    fun roles(theme: Char): Roles = when (theme.lowercaseChar()) {
        'a' -> Roles(0xEFEBE3, 0xF8F5EF, 0xE7E1D6, 0x141210, 0x67605A, 0xCFC7BA, 0xB5121B, 0xB5121B, 0x141210, 0xF8F5EF, 0x2F6B3A, 0x8A5200, 0xB5121B)
        'b' -> Roles(0x0D0E0F, 0x17191B, 0x212427, 0xECEAE5, 0xA9A6A0, 0x2C3033, 0xF2A93B, 0xF2A93B, 0xF2A93B, 0x1A1205, 0x7BD88F, 0xF2C14E, 0xFF6B5E)
        'c' -> Roles(0xE7E2D9, 0xF3F0EA, 0xEAE5DC, 0x23262A, 0x5E5C57, 0xD9D3C8, 0x4E6B45, 0x4E6B45, 0x4E6B45, 0xFFFFFF, 0x4E6B45, 0x7F5418, 0xA8382F)
        'd' -> Roles(0xFFF6EC, 0xFFFFFF, 0xFFEBD8, 0x111111, 0x55504A, 0x111111, 0xFF7EB6, 0x1F4BFF, 0xFF7EB6, 0x111111, 0x0E7A45, 0x9A4D00, 0xC8102E)
        else -> error("Unknown theme $theme")
    }

    /**
     * The camera bag (pickers, rig drums) is dark in every theme (§9, design/direction/render.py BAG). Accent and action
     * use Camera Body's amber, the one accent that reads on this dark.
     */
    val bag = Roles(
        canvas = 0x141414, raised = 0x141414, field = 0x1E1F21, ink = 0xECEAE5, ink2 = 0xA9A6A0, hairline = 0x2C3033,
        accent = 0xF2A93B, link = 0xF2A93B, action = 0xF2A93B, onAction = 0x1A1205,
        positive = 0x7BD88F, caution = 0xF2C14E, danger = 0xFF6B5E,
    )

    fun radii(theme: Char): Radii = when (theme.lowercaseChar()) {
        'a' -> Radii(4, 2, 2)
        'b' -> Radii(14, 10, 8)
        'c' -> Radii(24, 16, 12)
        'd' -> Radii(16, 12, 999)
        else -> error("Unknown theme $theme")
    }

    fun float(theme: Char): FloatShadow? = if (theme.lowercaseChar() == 'b') null else FloatShadow(y = 12, blur = 32, alpha = 0.14)

    fun families(theme: Char): Families = when (theme.lowercaseChar()) {
        'a' -> Families("Instrument Serif", "Archivo")
        'b' -> Families("Barlow Condensed", "Barlow")
        'c' -> Families("Outfit", "Outfit")
        'd' -> Families("Bricolage Grotesque", "Figtree")
        else -> error("Unknown theme $theme")
    }

    /** The scale is the same in every theme (§3). */
    val display = Step(28, 32, 400, display = true)
    val title = Step(20, 26, 600)
    val heading = Step(16, 22, 600)
    val body = Step(15, 21, 400)
    val label = Step(14, 18, 500)
    val caption = Step(13, 18, 400)
    val micro = Step(11, 14, 500)

    /** 4/8 grid (§4). */
    val space = intArrayOf(4, 8, 12, 16, 24, 32, 48)

    /** WCAG relative luminance and contrast ratio. */
    fun luminance(rgb: Long): Double {
        fun ch(shift: Int): Double {
            val c = ((rgb shr shift) and 0xFF).toDouble() / 255.0
            return if (c <= 0.03928) c / 12.92 else Math.pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0)
    }

    fun contrast(a: Long, b: Long): Double {
        val la = luminance(a); val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }
}
