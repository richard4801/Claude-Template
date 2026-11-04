package studio.muse.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
        assertEquals("about \$0.10", PhotoPricing.about(PhotoPricing.sheetAngles(PhotoPrices(), 1)))
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

class RealClipPricingTest {
    @Test fun realClipLengthDrivesTheFullOption() {
        val spec = RenderSpec(use = ClipUse.FULL, clipSeconds = 12.0)
        assertEquals(12.0, spec.lengthSec, 0.0)
        assertEquals(10 * Pricing.secPerLen(12.0) / 60 + 0.5, Pricing.estMin(spec), 1e-12)
        assertEquals("Full 12s · ~${Pricing.jsRound(10 * Pricing.secPerLen(12.0) / 60 + 0.5)}m · ${Pricing.money((10 * Pricing.secPerLen(12.0) / 60 + 0.5) / 60 * 3.99)}", Pricing.sourceOption(ClipUse.FULL, 10, 12.0))
    }

    @Test fun clipsAreCappedAt15SecondsAndShortClipsShortenTheFirstOption() {
        assertEquals(15.0, RenderSpec(use = ClipUse.FULL, clipSeconds = 22.0).lengthSec, 0.0)
        assertEquals(3.0, RenderSpec(use = ClipUse.FIRST, clipSeconds = 3.0).lengthSec, 0.0)
        assertEquals(5.2, RenderSpec(use = ClipUse.FIRST, clipSeconds = 9.0).lengthSec, 0.0)
    }

    @Test fun loraPricesMatchTheSpec() {
        assertEquals("\$6.65", Pricing.money(Pricing.loraTrainCost))
        assertEquals("about \$3.03", PhotoPricing.about(PhotoPricing.loraSet(PhotoPrices())))
        assertEquals(100, Pricing.loraTrainMinutes)
    }
}

/** Replicate (Draft / Standard / HD): checked against replicate_pricing_fixture.json (generated with JavaScript's toFixed). */
class ReplicatePricingTest {
    private val rows = Json.parseToJsonElement(javaClass.getResource("/replicate_pricing_fixture.json")!!.readText()).jsonArray

    @Test fun everyFixtureRowMatches() {
        assertEquals(135, rows.size)
        for (row in rows) {
            val o = row.jsonObject
            val clip = o["clipSeconds"]!!.jsonPrimitive.let { if (it.content == "null") null else it.double }
            val spec = RenderSpec(engine = Engine.REPLICATE, quality = Quality.fromId(o["quality"]!!.jsonPrimitive.content), takes = o["takes"]!!.jsonPrimitive.int, clipSeconds = clip)
            val ctx = spec.toString()
            assertEquals(ctx, o["seconds"]!!.jsonPrimitive.int, spec.replicateSeconds)
            assertEquals(ctx, o["cost"]!!.jsonPrimitive.double, Pricing.totalCost(spec), 0.0)
            assertEquals(ctx, o["costLabel"]!!.jsonPrimitive.content, Pricing.money(Pricing.totalCost(spec)))
            assertEquals(ctx, o["priceLine"]!!.jsonPrimitive.content, Pricing.priceLine(spec))
            assertEquals(ctx, o["genLabel"]!!.jsonPrimitive.content, Pricing.genLabel(spec))
        }
    }

    @Test fun ownerExampleSevenSecondsStandard() {
        val spec = RenderSpec(engine = Engine.REPLICATE, quality = Quality.STANDARD, clipSeconds = 7.0)
        assertEquals("about \$0.56 · 7 s", Pricing.priceLine(spec))
        assertEquals("Standard · 768P", Pricing.engineLabel(spec))
        assertEquals("HD · 2K", Pricing.engineLabel(spec.copy(quality = Quality.HD)))
        assertEquals("Edit", Pricing.engineLabel(RenderSpec()))
        assertEquals("Fast · beta", Pricing.engineLabel(RenderSpec(engine = Engine.VIGGLE)))
        assertEquals("about \$0.67", Pricing.optionPriceLine(RenderSpec()))
        // The server's live price wins over the built-in default.
        assertEquals("about \$0.70 · 7 s", Pricing.priceLine(spec.copy(pricePerSec = 0.10)))
    }

    @Test fun pickerMapsToEngineAndQuality() {
        assertEquals(listOf("Draft", "Standard", "HD"), VideoOption.RENDER.map { it.label })
        assertEquals(listOf("Edit", "Fast · beta"), VideoOption.ADDONS.map { it.label })
        assertEquals(VideoOption.HD, VideoOption.of(Engine.REPLICATE, Quality.HD))
        assertEquals(VideoOption.EDIT, VideoOption.of(Engine.H3, Quality.HD))
        assertEquals(VideoOption.FAST, VideoOption.of(Engine.VIGGLE, Quality.HD))
        assertEquals(VideoOption.EDIT, VideoOption.fromId("exact")) // the old id
        assertEquals(VideoOption.DRAFT, VideoOption.fromId(null))
        assertEquals("Quick preview · 768P", VideoOption.DRAFT.detail)
        assertEquals(Quality.DRAFT, RenderSpec(engine = Engine.REPLICATE).quality)
        assertEquals(listOf("1080p" to (1080 to 1920), "2K" to (1440 to 2560), "4K" to (2160 to 3840)), UpscaleSize.entries.map { it.label to (it.width to it.height) })
    }

    @Test fun nothingMembersReadNamesAProviderOrHardware() {
        val words = Regex("(?i)gpu|runpod|replicate|\\bh3\\b|\\blite\\b|steps|warm|start-up")
        for (o in VideoOption.entries) { assertFalse(o.label, words.containsMatchIn(o.label)); assertFalse(o.detail, words.containsMatchIn(o.detail)) }
        for (q in Quality.entries) assertFalse(q.detail, words.containsMatchIn(q.detail))
    }
}

/** Pass-through photo estimates: checked against photo_pricing_fixture.json (generated with JavaScript's toFixed). */
class PhotoPricingTest {
    private val fx = Json.parseToJsonElement(javaClass.getResource("/photo_pricing_fixture.json")!!.readText()).jsonObject

    @Test fun everyFixtureRowMatches() {
        val pj = fx["params"]!!.jsonObject
        val p = PhotoPrices(pj["perRun"]!!.jsonPrimitive.double, pj["perInputMp"]!!.jsonPrimitive.double, pj["perOutputMp"]!!.jsonPrimitive.double,
            pj["perEdit"]!!.jsonPrimitive.double, pj["refMp"]!!.jsonPrimitive.double, pj["maxRefs"]!!.jsonPrimitive.int, pj["loraShots"]!!.jsonPrimitive.int)
        assertEquals(PhotoPrices(), p)
        val rows = fx["rows"]!!.jsonArray
        assertEquals(94, rows.size)
        for (row in rows) {
            val o = row.jsonObject
            val count = o["count"]!!.jsonPrimitive.int
            val refs = o["refs"]!!.jsonPrimitive.int
            val v = when (o["kind"]!!.jsonPrimitive.content) {
                "shoot" -> PhotoPricing.shoot(p, count, refs)
                "outfitSet" -> PhotoPricing.outfitSet(p, refs)
                "sheetAngles" -> PhotoPricing.sheetAngles(p, count, refs)
                else -> PhotoPricing.loraSet(p, refs)
            }
            assertEquals(o.toString(), o["estimate"]!!.jsonPrimitive.double, v, 0.0)
            assertEquals(o.toString(), o["label"]!!.jsonPrimitive.content, PhotoPricing.about(v))
        }
    }

    @Test fun theUsualEstimates() {
        val p = PhotoPrices()
        assertEquals("about \$0.46", PhotoPricing.about(PhotoPricing.shoot(p)))
        assertEquals("about \$0.19", PhotoPricing.about(PhotoPricing.outfitSet(p)))
        assertEquals("about \$0.10", PhotoPricing.about(PhotoPricing.sheetAngles(p, 1)))
    }
}
