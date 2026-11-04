package studio.muse.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** Checks the Kotlin port against values produced by running prototype/app/app.js itself (see pricing_fixture.json). */
class PricingTest {
    private val fixture = Json.parseToJsonElement(javaClass.getResource("/pricing_fixture.json")!!.readText()).jsonArray

    @Test fun everyFixtureRowMatchesTheJs() {
        assertEquals(216, fixture.size)
        for (row in fixture) {
            val o = row.jsonObject
            val spec = RenderSpec(
                engine = Engine.fromId(o["engine"]!!.jsonPrimitive.content),
                use = ClipUse.fromId(o["use"]!!.jsonPrimitive.content),
                steps = o["steps"]!!.jsonPrimitive.int,
                lipSync = o["lip"]!!.jsonPrimitive.boolean,
            )
            val ctx = spec.toString()
            assertEquals(ctx, o["estMin"]!!.jsonPrimitive.double, Pricing.estMin(spec), 1e-9)
            assertEquals(ctx, o["estCost"]!!.jsonPrimitive.double, Pricing.estCost(spec), 1e-9)
            assertEquals(ctx, o["costLabel"]!!.jsonPrimitive.content, Pricing.money(Pricing.estCost(spec)))
            assertEquals(ctx, o["genLabel"]!!.jsonPrimitive.content, Pricing.genLabel(spec))
            assertEquals(ctx, o["stepsDelta"]!!.jsonPrimitive.content, Pricing.stepsDelta(spec))
            assertEquals(ctx, o["sourceOption"]!!.jsonPrimitive.content, Pricing.sourceOption(spec.use, spec.steps))
        }
    }

    @Test fun recommendedDefaultIsTenStepsAbout67Cents() {
        val spec = RenderSpec()
        assertEquals(10, spec.steps)
        assertEquals("Generate · 10 min · \$0.67", Pricing.genLabel(spec))
        assertEquals("Recommended", Pricing.stepsBadge(10))
        assertEquals("Rarely worth it", Pricing.stepsBadge(11))
        assertEquals("Below tested range", Pricing.stepsBadge(9))
        assertEquals("TOO FEW?", Pricing.stepsBadge(4, loud = true))
    }

    @Test fun stepsAreClampedTo4Through30() {
        assertEquals(4, Pricing.clampSteps(1))
        assertEquals(30, Pricing.clampSteps(99))
        assertEquals(17, Pricing.clampSteps(17))
    }

    @Test fun takesMultiplyTimeAndCost() {
        val one = RenderSpec()
        val three = one.copy(takes = 3)
        assertEquals(Pricing.estCost(one) * 3, Pricing.totalCost(three), 1e-12)
        assertEquals("Generate · 30 min · \$2.02 · 3 takes", Pricing.genLabel(three))
    }

    @Test fun moneyMatchesJsToFixedRounding() {
        // 1.005 is 1.00499999999999989... in binary, so JS prints 1.00 (Java's %.2f would print 1.01).
        assertEquals("\$1.00", Pricing.money(1.005))
        assertEquals("\$0.13", Pricing.money(0.125)) // exact tie rounds up, like JS
        assertEquals("\$6.07", Pricing.money(6.07))
        assertEquals("\$0.06", Pricing.money(Pricing.fillAnglesCost(3)))
    }

    @Test fun balanceCoversNineVideosAtTenSteps() {
        assertEquals(9, Pricing.videosLeft(6.07))
    }

    @Test fun clocks() {
        assertEquals("05:35", formatClock(335.0))
        assertEquals("00:01:35", formatTimecode(95.0))
        assertEquals("00:46:00", formatTimecode(2760.0))
    }
}
