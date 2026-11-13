package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.theme.Ic
import studio.muse.core.edit.PreviewView
import studio.muse.core.edit.SafeZone

// Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md): each app's generic chrome drawn
// over the edit (our own drawing: grey bars for text, Phosphor glyphs for buttons; no logos, no brand colours, no
// platform type) and the red safe-area box. The same drawing as the Mac (Views/Edit/EditPlatformChrome.swift). The chrome
// fills the canvas exactly: the canvas is what gets posted, so nothing is cropped.

/** The safe box's red (the Edit guide's colour on both apps). */
val SafeRed = Color(0xFFFF5A5F)

/** The chrome for a view over a [w]×[h] canvas: the phone layouts on portrait, the landscape players on 16:9; Clean draws nothing. */
@Composable
fun EditPlatformChrome(view: PreviewView, landscape: Boolean, w: Dp, h: Dp) {
    if (view == PreviewView.CLEAN) return
    if (landscape) LandscapeChrome(view, w, h) else PhoneChrome(view, w, h)
}

/** The red dashed box: where the app leaves the picture clear (approximate). */
@Composable
fun SafeBoxGuide(zone: SafeZone, name: String) {
    Canvas(Modifier.fillMaxSize().semantics { contentDescription = "Red box: $name. Keep faces and words inside it." }) {
        drawRect(SafeRed.copy(alpha = .95f), Offset(size.width * zone.x.toFloat(), size.height * zone.y.toFloat()),
            Size(size.width * zone.w.toFloat(), size.height * zone.h.toFloat()),
            style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 3.dp.toPx()))))
    }
}

@Composable
private fun ChromeBar(w: Dp, h: Dp, dim: Boolean = false) =
    Box(Modifier.size(w, h).clip(RoundedCornerShape(h / 2)).background(Color.White.copy(alpha = if (dim) .55f else .85f)))

@Composable
private fun Glyph(name: String, size: Dp, count: Boolean = true) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(size * .12f)) {
        Ic(name, size * .8f, Color.White)
        if (count) ChromeBar(size * .7f, maxOf(3.dp, size * .2f))
    }
}

@Composable
private fun Avatar(d: Dp) = Box(Modifier.size(d).clip(CircleShape).background(Color.White.copy(alpha = .75f)).border(1.5.dp, Color.White, CircleShape))

/** A phone app's layout: status bar, top bar, the right-hand rail, the caption block and the bottom navigation. */
@Composable
private fun PhoneChrome(view: PreviewView, w: Dp, h: Dp) {
    val k = w.value / 300f
    val nav = (56 * k).dp
    val icon = (26 * k).dp
    fun d(v: Number) = (v.toFloat() * k).dp
    Box(Modifier.size(w, h).semantics { contentDescription = "${view.label} layout" }) {
        Row(Modifier.fillMaxWidth().padding(start = d(18), end = d(18), top = d(8)), horizontalArrangement = Arrangement.SpaceBetween) {
            ChromeBar(d(28), d(7)); ChromeBar(d(40), d(7))
        }
        // Top bar.
        when (view) {
            PreviewView.TIKTOK -> Box(Modifier.fillMaxWidth().padding(start = d(14), end = d(14), top = d(32))) {
                Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(d(14))) { ChromeBar(d(50), d(8), dim = true); ChromeBar(d(44), d(8)) }
                Box(Modifier.align(Alignment.CenterEnd)) { Ic("magnifying-glass", d(18), Color.White) }
            }
            PreviewView.REELS -> Row(Modifier.fillMaxWidth().padding(start = d(14), end = d(14), top = d(32)), verticalAlignment = Alignment.CenterVertically) {
                ChromeBar(d(54), d(10)); Spacer(Modifier.weight(1f)); Ic("camera", d(18), Color.White)
            }
            PreviewView.SHORTS -> Row(Modifier.fillMaxWidth().padding(start = d(14), end = d(14), top = d(30)), horizontalArrangement = Arrangement.spacedBy(d(16), Alignment.End)) {
                Ic("magnifying-glass", d(18), Color.White); Ic("dots-three-vertical", d(18), Color.White)
            }
            else -> Row(Modifier.fillMaxWidth().padding(start = d(14), end = d(14), top = d(30)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(14))) {
                Ic("caret-left", d(18), Color.White); ChromeBar(d(48), d(10)); Spacer(Modifier.weight(1f)); Ic("magnifying-glass", d(18), Color.White); Ic("user-circle", d(18), Color.White)
            }
        }
        // Right-hand rail.
        Column(Modifier.align(Alignment.BottomEnd).padding(end = d(10), bottom = nav + d(16)), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(d(16))) {
            when (view) {
                PreviewView.TIKTOK -> {
                    Avatar(d(40)); Glyph("heart", icon); Glyph("chat-circle-dots", icon); Glyph("bookmark-simple", icon); Glyph("share-fat", icon)
                    Box(Modifier.size(d(32)).clip(CircleShape).background(Color(0xFF333333)).border(d(5), Color(0xFF121212), CircleShape))
                }
                PreviewView.REELS -> {
                    Glyph("heart", icon); Glyph("chat-circle", icon); Glyph("paper-plane-tilt", icon); Glyph("dots-three-vertical", icon, count = false)
                    Box(Modifier.size(d(26)).clip(RoundedCornerShape(d(5))).background(Color.White.copy(alpha = .6f)))
                }
                PreviewView.SHORTS -> {
                    Glyph("thumbs-up", icon); Glyph("thumbs-down", icon, count = false); Glyph("chat-circle-dots", icon); Glyph("share-fat", icon); Glyph("arrows-clockwise", icon)
                    Box(Modifier.size(d(28)).clip(RoundedCornerShape(d(6))).background(Color.White.copy(alpha = .6f)))
                }
                else -> { Glyph("thumbs-up", icon); Glyph("chat-circle", icon); Glyph("share-fat", icon); Glyph("dots-three", icon, count = false) }
            }
        }
        // Caption block.
        val cw = w * .62f
        Column(Modifier.align(Alignment.BottomStart).padding(start = d(12), bottom = nav + d(14)).width(cw), verticalArrangement = Arrangement.spacedBy(d(6))) {
            when (view) {
                PreviewView.TIKTOK -> ChromeBar(cw * .4f, d(9))
                PreviewView.REELS -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(8))) {
                    Avatar(d(26)); ChromeBar(cw * .34f, d(9))
                    Box(Modifier.size(d(46), d(20)).border(d(1.2), Color.White.copy(alpha = .8f), RoundedCornerShape(d(6))))
                }
                PreviewView.SHORTS -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(8))) {
                    Avatar(d(26)); ChromeBar(cw * .3f, d(9)); Box(Modifier.size(d(60), d(22)).clip(RoundedCornerShape(d(11))).background(Color.White.copy(alpha = .9f)))
                }
                else -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(8))) {
                    Avatar(d(26)); ChromeBar(cw * .3f, d(9)); Box(Modifier.size(d(44), d(20)).clip(RoundedCornerShape(d(6))).background(Color.White.copy(alpha = .25f)))
                }
            }
            ChromeBar(cw * .92f, d(7), dim = true)
            ChromeBar(cw * .64f, d(7), dim = true)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(6))) { Ic("music-note", d(11), Color.White); ChromeBar(cw * .52f, d(6), dim = true) }
        }
        // Bottom navigation.
        val navIcons = when (view) {
            PreviewView.TIKTOK -> listOf("house", "users-three", "plus-square", "chat-circle", "user")
            PreviewView.REELS -> listOf("house", "magnifying-glass", "plus-square", "film-strip", "user-circle")
            PreviewView.SHORTS -> listOf("house", "lightning", "plus-circle", "play-circle", "user-circle")
            else -> listOf("house", "video", "users-three", "bag", "bell")
        }
        Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(nav).background(Color.Black.copy(alpha = .92f)).padding(bottom = d(6)),
            verticalAlignment = Alignment.CenterVertically) {
            navIcons.forEach { n -> Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Ic(n, d(18), Color.White) } }
        }
    }
}

/** A landscape player's chrome: the title row on top and the controls along the bottom. */
@Composable
private fun LandscapeChrome(view: PreviewView, w: Dp, h: Dp) {
    val k = w.value / 640f
    fun d(v: Number) = (v.toFloat() * k).dp
    BoxWithConstraints(Modifier.size(w, h).semantics { contentDescription = "${view.label} layout" }) {
        Box(Modifier.fillMaxWidth().height(h * .16f).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .55f), Color.Transparent))))
        Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(h * .18f).background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = .6f)))))
        Row(Modifier.fillMaxWidth().padding(start = d(16), end = d(16), top = d(14)), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(10))) {
            Box(Modifier.size(d(26)).clip(CircleShape).background(Color.White.copy(alpha = .75f)))
            ChromeBar(d(if (view == PreviewView.YOUTUBE) 180 else 120), d(10))
            Spacer(Modifier.weight(1f))
            if (view == PreviewView.YOUTUBE) { Ic("clock", d(15), Color.White); Ic("share-fat", d(15), Color.White) }
        }
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(start = d(14), end = d(14), bottom = d(10)), verticalArrangement = Arrangement.spacedBy(d(8))) {
            Box(Modifier.fillMaxWidth().height(d(3)).clip(RoundedCornerShape(d(2))).background(Color.White.copy(alpha = .35f))) {
                Box(Modifier.fillMaxWidth(.28f).height(d(3)).background(Color.White))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(d(14))) {
                Ic("play", d(15), Color.White)
                if (view == PreviewView.YOUTUBE) Ic("skip-forward", d(15), Color.White)
                Ic("speaker-high", d(15), Color.White)
                ChromeBar(d(70), d(7), dim = true)
                Spacer(Modifier.weight(1f))
                Ic("closed-captioning", d(15), Color.White); Ic("dots-three-vertical", d(15), Color.White); Ic("arrows-out-simple", d(15), Color.White)
            }
        }
    }
}
