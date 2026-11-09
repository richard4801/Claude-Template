package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import studio.muse.app.data.WarmGpu
import studio.muse.app.data.WarmUi
import studio.muse.app.ui.screens.warmCostLine
import studio.muse.app.ui.screens.warmLive

/** Keep add-on engine ready (owner only): no nudge any more, every switch-on asks, the cost line, the live indicator. */
class WarmUiTest {
    private val off = WarmGpu()

    @Test fun nothingPromptsByItself() {
        assertNull(WarmUi().prompt.value)
        assertNull(WarmUi().banner.value)
    }

    @Test fun everySwitchOnAsks() {
        val ui = WarmUi()
        repeat(3) { ui.confirm(); assertEquals(WarmUi.CONFIRM, ui.prompt.value); ui.dismiss(); assertNull(ui.prompt.value) }
    }

    @Test fun costLineAndLiveIndicator() {
        assertEquals("Keeps a GPU ready so Edit renders start right away. About \$4/hour from the studio balance while it's on, and it turns off by itself after 20 min without renders.", warmCostLine(off))
        val t0 = 1_000_000_000L
        val w = WarmGpu("warm", startedAt = t0, minutes = 41, costUsd = 41 * 3.99 / 60)
        val (min, cost) = warmLive(w, t0 + 42 * 60_000L + 5_000)
        assertEquals(42, min)
        assertEquals(2.793, cost, 1e-3)
    }
}
