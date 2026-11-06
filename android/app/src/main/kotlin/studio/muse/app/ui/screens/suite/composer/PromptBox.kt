package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.data.SuiteLocation
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.MovePictogram
import studio.muse.app.ui.theme.muse

// AI suite (workstream 1): the composer's prompt box (plans/video-composer.md "Prompt box"). One text field; @ and #
// tokens sit inline as chips (PromptCodec), so the caret and backspace treat each as one unit. Typing @ or # opens a
// suggestion list; tapping a chip opens its sheet (a move's intensity, or Remove).

/** Draws each token character as its chip ("@Noor", "#Dolly in") on a tinted background. */
private class TokenTransformation(val tokens: PromptTokens, val chipBg: Color, val ink: Color, val accent: Color) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val d = PromptCodec.display(tokens, text.text)
        val out = buildAnnotatedString {
            append(d.text)
            d.chips.forEach { (r, _) ->
                addStyle(SpanStyle(background = chipBg, color = ink, fontWeight = FontWeight.SemiBold), r.first, r.last + 1)
                addStyle(SpanStyle(color = accent), r.first + 1, r.first + 2)
            }
        }
        return TransformedText(out, object : OffsetMapping {
            override fun originalToTransformed(offset: Int) = d.fieldToDisplay(offset)
            override fun transformedToOriginal(offset: Int) = d.displayToField(offset)
        })
    }

    override fun equals(other: Any?) = other is TokenTransformation && other.tokens == tokens && other.chipBg == chipBg
    override fun hashCode() = tokens.hashCode()
}

/** A suggestion under the prompt while @ or # is being typed. */
sealed interface Suggestion {
    data class Character(val model: Model) : Suggestion
    data class Dress(val outfit: Outfit) : Suggestion
    data class Move(val move: studio.muse.app.data.SuiteMoveOption) : Suggestion
    data class Place(val location: SuiteLocation) : Suggestion
    /** "+ New location": pick a photo, name it, and it joins the library. */
    data object NewPlace : Suggestion
}

/**
 * The suggestions for a trigger: @ = the studio's characters, the picked one's outfits and the studio's locations, ending
 * with "+ New location"; # = moves matching the word.
 */
fun suggestions(tr: Trigger?, models: List<Model>, outfits: List<Outfit>, cat: CameraCatalog, talkOnly: Boolean, locations: List<SuiteLocation> = emptyList(), places: Boolean = true): List<Suggestion> {
    tr ?: return emptyList()
    val q = tr.query.lowercase()
    return if (tr.char == '@') {
        models.filter { q.isEmpty() || it.name.lowercase().contains(q) }.map { Suggestion.Character(it) } +
            outfits.filter { q.isEmpty() || it.name.lowercase().contains(q) }.map { Suggestion.Dress(it) } +
            (if (places) locations.filter { q.isEmpty() || it.name.lowercase().contains(q) }.map { Suggestion.Place(it) } + Suggestion.NewPlace else emptyList())
    } else PromptTokens.searchMoves(cat, tr.query).filter { !talkOnly || it.talkSafe }.take(10).map { Suggestion.Move(it) }
}

/**
 * The prompt box. [tokens] is the prompt; [onChange] gets every edit. [onPick] inserts a suggestion at the trigger and
 * returns the new tokens (or the reason it was refused, shown by the caller). [onToken] opens a chip's sheet.
 */
@Composable
fun PromptBox(
    tokens: PromptTokens, placeholder: String, models: List<Model>, outfits: List<Outfit>, cat: CameraCatalog, talkOnly: Boolean,
    onChange: (PromptTokens) -> Unit, onPick: (PromptTokens, Caret, Suggestion) -> PromptTokens?, onToken: (Long) -> Unit, modifier: Modifier = Modifier,
    minHeight: androidx.compose.ui.unit.Dp = 52.dp, maxHeight: androidx.compose.ui.unit.Dp = 132.dp, locations: List<SuiteLocation> = emptyList(),
    /** Test hook: the field starts with this caret (an open @ menu in screenshots). */
    initialCaret: Int? = null,
) {
    val m = muse
    val encoded = PromptCodec.encode(tokens)
    var field by remember { mutableStateOf(TextFieldValue(encoded, TextRange(initialCaret?.coerceIn(0, encoded.length) ?: encoded.length))) }
    // An outside change (a move added from the picker, a preset): take it, caret at the end.
    LaunchedEffect(encoded) { if (field.text != encoded) field = TextFieldValue(encoded, TextRange(encoded.length)) }
    val latest by rememberUpdatedState(tokens)
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val trigger = if (field.selection.collapsed) PromptCodec.triggerAt(field.text, field.selection.start) else null
    val list = suggestions(trigger, models, outfits, cat, talkOnly, locations)
    val transformation = remember(tokens, m.t.surface2) { TokenTransformation(tokens, m.t.surface2, m.t.ink, m.t.accent) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().heightIn(min = minHeight, max = maxHeight).padding(vertical = 4.dp)) {
            BasicTextField(
                field,
                { v ->
                    val clean = v.text.take(2000)
                    field = v.copy(text = clean)
                    onChange(PromptCodec.decode(latest, clean))
                },
                Modifier.fillMaxWidth().semantics { contentDescription = "Prompt. $placeholder" }.pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        val up = waitForUpOrCancellation(PointerEventPass.Initial) ?: return@awaitEachGesture
                        val l = layout ?: return@awaitEachGesture
                        if ((up.position - down.position).getDistance() > 24f) return@awaitEachGesture
                        val o = l.getOffsetForPosition(up.position)
                        val d = PromptCodec.display(latest, PromptCodec.encode(latest))
                        d.chips.firstOrNull { (r, _) -> o in r }?.let { (_, p) -> onToken(p.key) }
                    }
                },
                textStyle = m.type.body.copy(fontSize = 16.sp, lineHeight = 25.sp, color = m.t.ink),
                cursorBrush = SolidColor(m.t.accent),
                visualTransformation = transformation,
                onTextLayout = { layout = it },
                decorationBox = { inner ->
                    Box {
                        if (field.text.isEmpty()) T(placeholder, m.type.body.copy(fontSize = 16.sp, lineHeight = 25.sp), m.t.muted.copy(alpha = .85f))
                        inner()
                    }
                },
            )
        }
        if (trigger != null && list.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                list.forEach { sg ->
                    SuggestionChip(sg) {
                        val (s2, c2) = PromptCodec.dropTrigger(field.text, trigger, field.selection.start)
                        val base = PromptCodec.decode(latest, s2)
                        val next = onPick(base, PromptCodec.caretAt(base, c2), sg) ?: return@SuggestionChip
                        val e = PromptCodec.encode(next)
                        val caret = (c2 + (e.length - s2.length)).coerceIn(0, e.length)
                        field = TextFieldValue(e, TextRange(caret))
                    }
                }
            }
        }
    }
}

@Composable
private fun SuggestionChip(s: Suggestion, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    val label = when (s) {
        is Suggestion.Character -> "@" + s.model.name; is Suggestion.Dress -> "@" + s.outfit.name; is Suggestion.Move -> "#" + s.move.label
        is Suggestion.Place -> "@" + s.location.name; Suggestion.NewPlace -> "+ New location"
    }
    Row(Modifier.height(48.dp).press(onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Add $label" }, verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.height(36.dp).clip(shape).background(m.t.surface2).border(1.dp, m.t.line, shape).padding(start = 4.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(28.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 6.dp)).background(m.t.ink), contentAlignment = Alignment.Center) {
                when (s) {
                    is Suggestion.Character -> RefImage(s.model.cover, Modifier.size(28.dp), 20)
                    is Suggestion.Dress -> RefImage(s.outfit.front, Modifier.size(28.dp), 20)
                    is Suggestion.Move -> MovePictogram(s.move.id, s.move.category, Modifier.size(28.dp), ink = m.t.bg, accent = m.t.accent)
                    is Suggestion.Place -> RefImage(s.location.image, Modifier.size(28.dp), 50)
                    Suggestion.NewPlace -> T("+", m.type.body.copy(fontSize = 18.sp, fontWeight = FontWeight.Bold), m.t.bg)
                }
            }
            T(label, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
        }
    }
}
