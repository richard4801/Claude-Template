package studio.muse.app.platform.edit

import androidx.media3.effect.MuseBlendOverlay
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.ui.screens.edit.EditSuiteViewModel
import studio.muse.core.edit.BlendMode
import studio.muse.core.edit.Fit
import studio.muse.core.edit.LayerRole
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.planRender

/**
 * What the compositor receives per layer (wave 1): the overlay's blend mode (read by MuseCompositorGlProgram, whose
 * shader is checked against the reference by android/tools/check_blend_shader.py) and a mirrored scale for flips.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class PlanCompositorSettingsTest {
    @Test fun blendModeAndMirrorReachTheOverlaySettings() {
        val base = EditSuiteViewModel.newProject("take_1", 10.0, SourceSize(1080, 1920, 30.0, true))
        val p = base.copy(
            assets = base.assets + studio.muse.core.edit.Asset("pip", studio.muse.core.edit.AssetKind.VIDEO, take = "t2", durationSec = 5.0, width = 1080, height = 1920),
            tracks = base.tracks + Track("v", TrackKind.VIDEO, items = listOf(VideoClip("p1", "pip", 0.0, 4.0, 1.0, startSec = 1.0, fit = Fit.CONTAIN,
                transform = Transform(scale = .5, flipX = true), blend = BlendMode.MULTIPLY))),
        )
        val plan = planRender(p, mapOf("src" to MediaInfo(10.0, 1080, 1920, 30.0, true), "pip" to MediaInfo(5.0, 1080, 1920, 30.0, true)))
        val layer = plan.layers.indexOfFirst { it.role == LayerRole.OVERLAY }
        val s = PlanCompositorSettings(plan).getOverlaySettings(layer, 2_000_000)
        assertEquals(BlendMode.MULTIPLY.ordinal, (s as MuseBlendOverlay).blendMode)
        assertEquals(true, s.scale.first < 0 && s.scale.second > 0)
        val main = PlanCompositorSettings(plan).getOverlaySettings(plan.layers.indexOfFirst { it.role == LayerRole.MAIN }, 2_000_000)
        assertEquals(0, (main as MuseBlendOverlay).blendMode)
    }
}
