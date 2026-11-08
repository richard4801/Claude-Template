package studio.muse.app.ui.screens.claude

// Draws ChatMarkdown's blocks in the chat (plans/claude-chat-android.md): headings on the type scale, lists with real
// markers, quotes with a rule, code in the text face's monospace with horizontal scroll and Copy, tables that scroll
// sideways, links that open in the browser. Colours are the theme's roles; nothing here is decoration.

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/** Colours and type the Markdown uses (the chat passes the theme's roles). */
data class MdStyle(val body: TextStyle, val ink: Color, val ink2: Color, val link: Color, val codeBg: Color, val rule: Color)

@Composable
fun mdStyle(): MdStyle {
    val m = muse
    // Creator Pop's hairline is solid ink, kept for its primary action and selection: rules here use the tonal field instead.
    return MdStyle(m.scale.body.copy(color = m.roles.ink), m.roles.ink, m.roles.ink2, m.roles.link, m.roles.field, if (m.isD) m.roles.field else m.roles.hairline)
}

/** A reply as Markdown. [streaming]: still arriving, so half-typed markers are held back instead of shown. */
@Composable
fun ChatMarkdownText(text: String, streaming: Boolean, modifier: Modifier = Modifier, style: MdStyle = mdStyle()) {
    val blocks = remember(text, streaming) { ChatMarkdown.parse(text, streaming) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        blocks.forEach { MdBlockView(it, style) }
    }
}

@Composable
private fun MdBlockView(b: MdBlock, st: MdStyle) {
    val m = muse
    when (b) {
        is MdBlock.Paragraph -> Text(annotate(b.inline, st), style = st.body)
        is MdBlock.Heading -> {
            val hs = when (b.level) {
                1 -> m.scale.title
                2 -> m.scale.heading.copy(fontSize = 17.sp, lineHeight = 23.sp)
                else -> m.scale.heading
            }
            Text(annotate(b.inline, st), Modifier.padding(top = MuseSpace.s1).semantics { heading() }, style = hs.copy(color = st.ink, fontWeight = FontWeight.SemiBold))
        }
        is MdBlock.CodeBlock -> CodeBlockView(b, st)
        is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
            Box(Modifier.width(3.dp).fillMaxHeight().clip(RoundedCornerShape(2.dp)).background(st.rule))
            Column(Modifier.padding(start = MuseSpace.s3), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                val quoted = st.copy(body = st.body.copy(color = st.ink2), ink = st.ink2)
                b.blocks.forEach { MdBlockView(it, quoted) }
            }
        }
        is MdBlock.ListBlock -> Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
            val widest = b.items.maxOfOrNull { (it.number ?: 0).toString().length } ?: 1
            b.items.forEachIndexed { idx, it ->
                Row(Modifier.padding(start = (it.level * 18).dp)) {
                    val marker = when {
                        it.checked != null -> null
                        b.ordered && it.level == 0 -> "${it.number ?: (idx + 1)}."
                        else -> if (it.level == 0) "•" else "◦"
                    }
                    Box(Modifier.widthIn(min = if (b.ordered) (10 + widest * 9).dp else 16.dp), contentAlignment = Alignment.TopStart) {
                        if (marker != null) Text(marker, style = st.body.copy(color = st.ink2, fontFeatureSettings = "tnum"))
                        else Box(Modifier.padding(top = 2.dp)) { Ic(if (it.checked == true) "check-square" else "square", 16.dp, st.ink2) }
                    }
                    Text(annotate(it.inline, st), Modifier.padding(start = MuseSpace.s1), style = st.body)
                }
            }
        }
        is MdBlock.Table -> TableView(b, st)
        MdBlock.Rule -> Box(Modifier.fillMaxWidth().padding(vertical = MuseSpace.s1).height(1.dp).background(st.rule))
    }
}

/** A code block: the language and Copy on top, the code in monospace, scrolling sideways (never wrapped). */
@Composable
private fun CodeBlockView(b: MdBlock.CodeBlock, st: MdStyle) {
    val m = muse
    val clip = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { delay(1500); copied = false } }
    val shape = RoundedCornerShape(m.radii.control)
    Column(Modifier.fillMaxWidth().clip(shape).background(st.codeBg)) {
        Row(Modifier.fillMaxWidth().padding(start = MuseSpace.s3), verticalAlignment = Alignment.CenterVertically) {
            T(b.language?.takeIf { it.isNotBlank() } ?: "Code", m.scale.caption, st.ink2, Modifier.weight(1f), maxLines = 1)
            Row(Modifier.heightIn(min = 40.dp).press(enabled = b.code.isNotEmpty()) { clip.setText(AnnotatedString(b.code)); copied = true }
                .padding(horizontal = MuseSpace.s3).semantics { role = Role.Button; contentDescription = if (copied) "Copied" else "Copy code" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Ic(if (copied) "check" else "copy", 16.dp, st.ink2)
                T(if (copied) "Copied" else "Copy", m.scale.caption, st.ink2, maxLines = 1)
            }
        }
        Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = MuseSpace.s3, end = MuseSpace.s3, bottom = MuseSpace.s3)) {
            Text(b.code.ifEmpty { " " }, softWrap = false,
                style = st.body.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 19.sp, color = st.ink))
        }
    }
}

/** A table: a header row in semibold, cells sized to their content (64–260 dp), scrolling sideways when wide. */
@Composable
private fun TableView(t: MdBlock.Table, st: MdStyle) {
    val m = muse
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val cols = t.header.size
    if (cols == 0) return
    val all = listOf(t.header) + t.rows
    val widths: List<Dp> = remember(t, st.body) {
        List(cols) { c ->
            val px = all.maxOf { r -> r.getOrNull(c)?.let { measurer.measure(ChatMarkdown.plain(it), st.body.copy(fontWeight = FontWeight.SemiBold)).size.width } ?: 0 }
            with(density) { px.toDp() + 24.dp }.coerceIn(64.dp, 260.dp)
        }
    }
    val shape = RoundedCornerShape(m.radii.control)
    Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
        Column(Modifier.clip(shape).border(1.dp, st.rule, shape)) {
            all.forEachIndexed { ri, row ->
                Row(Modifier.let { if (ri == 0) it.background(st.codeBg) else it }) {
                    for (c in 0 until cols) {
                        val align = when (t.align.getOrElse(c) { Align.START }) { Align.START -> TextAlign.Start; Align.CENTER -> TextAlign.Center; Align.END -> TextAlign.End }
                        Text(annotate(row.getOrNull(c).orEmpty(), st), Modifier.width(widths[c]).padding(horizontal = MuseSpace.s3, vertical = MuseSpace.s2),
                            style = st.body.copy(fontWeight = if (ri == 0) FontWeight.SemiBold else st.body.fontWeight, textAlign = align, fontSize = 14.sp, lineHeight = 20.sp))
                    }
                }
                if (ri < all.lastIndex) Box(Modifier.width(widths.fold(0.dp) { a, b -> a + b }).height(1.dp).background(st.rule))
            }
        }
    }
}

/** Inline spans as styled text; links open in the browser through the text's own link handling. */
fun annotate(xs: List<Md>, st: MdStyle): AnnotatedString = buildAnnotatedString {
    fun go(list: List<Md>) {
        list.forEach { x ->
            when (x) {
                is Md.Text -> append(x.text)
                Md.Break -> append('\n')
                is Md.Bold -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { go(x.children) }
                is Md.Italic -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { go(x.children) }
                is Md.Strike -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { go(x.children) }
                is Md.Code -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace, fontSize = .9.em, background = st.codeBg)) { append(" "); append(x.text); append(" ") }
                is Md.Link -> if (ChatMarkdown.openable(x.url)) {
                    withLink(LinkAnnotation.Url(x.url, TextLinkStyles(SpanStyle(color = st.link, textDecoration = TextDecoration.Underline)))) { go(x.children) }
                } else go(x.children)
            }
        }
    }
    go(xs)
}
