package studio.muse.app.mocks

import android.os.Looper
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
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
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * MOCKS for the owner's approval (plans/learning-editor-ui.md): the Android Playbook and Recipes screens in all four
 * themes, phone (390 dp) and tablet (1280 × 800). PNGs: app/build/outputs/roborazzi/learn_<theme>_<screen>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class LearningEditorMockTest(private val theme: String, private val screen: String) {
    companion object {
        val SCREENS = listOf(
            "edit_home", "playbook_rules", "playbook_suggestions", "playbook_history", "rule_editor", "rule_delete", "playbook_empty",
            "recipes", "recipes_loading", "recipes_empty", "recipe_detail", "recipe_detail_reference", "recipe_delete",
            "tablet_playbook", "tablet_recipes",
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.map { arrayOf<Any>(t, it) } }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        if (screen.startsWith("tablet")) RuntimeEnvironment.setQualifiers("w1280dp-h800dp-mdpi")
        if (screen == "recipe_detail" || screen == "recipe_detail_reference") RuntimeEnvironment.setQualifiers("w390dp-h1500dp-xhdpi")
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                when (screen) {
                    "edit_home" -> MockEditHome()
                    "playbook_rules" -> MockPlaybook(PlaybookTab.Rules, wide = false)
                    "playbook_suggestions" -> MockPlaybook(PlaybookTab.Suggestions, wide = false)
                    "playbook_history" -> MockPlaybook(PlaybookTab.History, wide = false)
                    "rule_editor" -> MockPlaybook(PlaybookTab.Rules, wide = false) { MockRuleEditor() }
                    "rule_delete" -> MockPlaybook(PlaybookTab.Rules, wide = false) { MockConfirm("Delete this rule?", null, "Delete rule") }
                    "playbook_empty" -> MockPlaybook(PlaybookTab.Rules, wide = false, empty = true)
                    "recipes" -> MockRecipes(wide = false)
                    "recipes_loading" -> MockRecipes(wide = false, loading = true)
                    "recipes_empty" -> MockRecipes(wide = false, empty = true)
                    "recipe_detail" -> MockRecipeDetail(sampleRecipes[0], panel = false)
                    "recipe_detail_reference" -> MockRecipeDetail(sampleRecipes[1], panel = false)
                    "recipe_delete" -> Box(Modifier.fillMaxSize()) {
                        MockRecipeDetail(sampleRecipes[0], panel = false)
                        MockConfirm("Delete this recipe?", "The edit and its video stay; only the saved recipe goes.", "Delete recipe")
                    }
                    "tablet_playbook" -> MockPlaybook(PlaybookTab.Rules, wide = true)
                    "tablet_recipes" -> MockRecipes(wide = true)
                }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/learn_${theme}_$screen.png")
    }
}
