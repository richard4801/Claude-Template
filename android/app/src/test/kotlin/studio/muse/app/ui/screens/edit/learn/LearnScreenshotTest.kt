package studio.muse.app.ui.screens.edit.learn

import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.FakeLearn
import studio.muse.app.ui.screens.edit.EditHomeContent
import studio.muse.app.ui.screens.edit.TakeChoice
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * The learning editor as built (plans/learning-editor-ui.md, the owner-approved mocks and notes), all four themes, phone
 * (390 dp) and tablet (1280 × 800), on demo's /v1/learn data. Pictures: stand-ins for the owner's own frames (soft colour
 * fields, no people), and a reference without a poster as the plain tinted tile.
 * PNGs: app/build/outputs/roborazzi/learn_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class LearnScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        val STATES = listOf(
            "edit_home", "playbook_rules", "playbook_suggestions", "playbook_history", "rule_editor", "rule_new", "rule_delete", "playbook_empty", "playbook_loading",
            "playbook_error", "recipes", "recipes_loading", "recipes_empty", "recipes_no_results", "recipe_detail", "recipe_detail_reference", "recipe_delete",
            "tablet_playbook", "tablet_recipes",
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> STATES.map { arrayOf<Any>(t, it) } }
    }

    @get:Rule val compose = createComposeRule()

    /** A stand-in for a frame of the owner's video: a soft colour field. */
    private fun frame(seed: Int) = Bitmap.createBitmap(36, 64, Bitmap.Config.ARGB_8888).also { b ->
        for (y in 0 until 64) for (x in 0 until 36) b.setPixel(x, y, android.graphics.Color.HSVToColor(floatArrayOf((seed * 47 + y * 2f) % 360, .32f, .42f + x / 120f)))
    }.asImageBitmap()

    @Test fun capture() {
        if (state.startsWith("tablet")) RuntimeEnvironment.setQualifiers("w1280dp-h800dp-mdpi")
        if (state.startsWith("recipe_detail")) RuntimeEnvironment.setQualifiers("w390dp-h1400dp-xhdpi")
        val recipes = FakeLearn.recipes()
        val frames = recipes.mapIndexed { i, r -> r.id to frame(i) }.toMap()
        val picture: RecipePicture = { e, mod ->
            if (e.isReference && e.id == "rcp_4") TintedTile(mod) // a reference whose poster has expired
            else Image(frames.getValue(e.id), null, mod, contentScale = ContentScale.Crop)
        }
        val pb = PlaybookUi(rules = FakeLearn.rules(), lessons = FakeLearn.lessons(), corrections = FakeLearn.corrections())
        val rx = RecipesUi(all = recipes.map { it.copy(recipe = null) }, gaps = FakeLearn.gaps())
        val detail = RecipeDetailUi(recipes[0], nearest = recipes.drop(1).take(3).mapIndexed { i, r -> r.copy(distance = .2 + i * .25) })
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                when (state) {
                    "edit_home" -> EditHomeContent(listOf(TakeChoice("e1", "Morning café", "Edited", null, 15.0, true, true)), onBack = {}, onOpen = {}, onRecreate = {}, onLearn = {})
                    "playbook_rules" -> PlaybookContent(pb, {}) {}
                    "playbook_suggestions" -> PlaybookContent(pb.copy(tab = PlaybookTab.SUGGESTIONS), {}) {}
                    "playbook_history" -> PlaybookContent(pb.copy(tab = PlaybookTab.HISTORY), {}) {}
                    "rule_editor" -> PlaybookContent(pb.copy(editor = FakeLearn.rules()[6].let { RuleDraft(it.id, it.text, it.area, it.evidence) }), {}) {}
                    "rule_new" -> PlaybookContent(pb.copy(editor = RuleDraft(area = "look", evidence = FakeLearn.rules()[6].evidence.take(2))), {}) {}
                    "rule_delete" -> PlaybookContent(pb.copy(deleting = "rule_2"), {}) {}
                    "playbook_empty" -> PlaybookContent(PlaybookUi(rules = emptyList(), lessons = emptyList(), corrections = emptyList()), {}) {}
                    "playbook_loading" -> PlaybookContent(PlaybookUi(), {}) {}
                    "playbook_error" -> PlaybookContent(PlaybookUi(error = "Couldn't load the playbook · check your connection"), {}) {}
                    "recipes" -> RecipesContent(rx, picture, {}) {}
                    "recipes_loading" -> RecipesContent(RecipesUi(), picture, {}) {}
                    "recipes_empty" -> RecipesContent(RecipesUi(all = emptyList()), picture, {}) {}
                    "recipes_no_results" -> RecipesContent(rx.copy(query = "dance party"), picture, {}) {}
                    "recipe_detail" -> RecipesContent(rx.copy(detail = detail), picture, {}) {}
                    "recipe_detail_reference" -> RecipesContent(rx.copy(detail = RecipeDetailUi(recipes[1], detail.nearest)), picture, {}) {}
                    "recipe_delete" -> RecipesContent(rx.copy(detail = detail.copy(deleting = true)), picture, {}) {}
                    "tablet_playbook" -> PlaybookContent(pb, {}) {}
                    "tablet_recipes" -> RecipesContent(rx.copy(detail = detail), picture, {}) {}
                }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/learn_${theme}_$state.png")
    }
}
