package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import studio.muse.app.data.WarmGpu
import studio.muse.app.data.WarmUi
import studio.muse.app.ui.screens.warmCostLine
import studio.muse.app.ui.screens.warmLive

/** Keep GPU warm: when the nudge shows, the cost line, and the bar's live minutes and cost. */
class WarmUiTest {
    private val off = WarmGpu()

    @Test fun nudgesWhenCreatingStartsAndNothingIsWarm() {
        val ui = WarmUi()
        ui.enterFlow()
        ui.creatingStarted(off)
        assertEquals(WarmUi.NUDGE, ui.prompt.value)
    }

    @Test fun oncePerFlowNeverMidFlowAndAgainNextTime() {
        val ui = WarmUi()
        ui.enterFlow()                    // New video
        ui.creatingStarted(off)           // clip picked
        ui.dismiss()                      // Not now
        ui.enterFlow(); ui.leaveFlow()    // → Video studio (both on screen during the transition)
        ui.creatingStarted(off)           // opening Generate in the same flow: no second nudge
        assertNull(ui.prompt.value)
        ui.leaveFlow()                    // left the flow (Queue after Generate)
        ui.enterFlow()
        ui.creatingStarted(off)           // the next time creating starts
        assertEquals(WarmUi.NUDGE, ui.prompt.value)
    }

    @Test fun noNudgeWhenWarmNotAllowedOrUnknown() {
        listOf(WarmGpu("warm", startedAt = 1), WarmGpu("starting", startedAt = 1), WarmGpu(allowed = false), null).forEach { w ->
            val ui = WarmUi()
            ui.enterFlow()
            ui.creatingStarted(w)
            assertNull("$w", ui.prompt.value)
        }
    }

    @Test fun everySwitchOnAsks() {
        val ui = WarmUi()
        repeat(3) { ui.confirm(); assertEquals(WarmUi.CONFIRM, ui.prompt.value); ui.dismiss() }
    }

    @Test fun costLineAndLiveBar() {
        assertEquals("About \$4/hour from your credit while it's on, and it turns off by itself after 20 min without renders.", warmCostLine(off))
        val t0 = 1_000_000_000L
        val w = WarmGpu("warm", startedAt = t0, minutes = 41, costUsd = 41 * 3.99 / 60)
        val (min, cost) = warmLive(w, t0 + 42 * 60_000L + 5_000)
        assertEquals(42, min)
        assertEquals(2.793, cost, 1e-3) // "$2.79 so far"
    }
}
