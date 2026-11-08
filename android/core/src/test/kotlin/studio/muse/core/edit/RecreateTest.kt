package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecreateTest {
    private val fill = RecreateJson.fill(
        """{"referenceId":"rx_1","slots":[
             {"slotId":"s1","state":"matched","takeId":"t1","score":0.82,"reason":"Your take has the same pan"},
             {"slotId":"s2","state":"to_generate","estimate":{"amount":0.64,"label":"$0.64"}},
             {"slotId":"s3","state":"to_generate","estimate":{"amount":0.64}}]}""",
    )

    @Test fun readsTheFill() {
        assertEquals(3, fill.slots.size)
        assertEquals("t1", fill.slot("s1")?.takeId)
        assertEquals(0.64, fill.slot("s2")?.estimate!!, 1e-9)
        assertEquals(1.28, fill.generateTotal(), 1e-9)
    }

    @Test fun theCostLineIsBuiltFromTheFill() {
        assertEquals("1 from your takes, 2 to generate · $1.28 in all", RecreateText.makingSummary(fill))
        // The slot estimates' prices win; a shot that can't be made is said and left out of the total.
        assertEquals("1 from your takes, 1 to generate, 1 can’t be made · $0.70 in all",
            RecreateText.makingSummary(fill, prices = mapOf("s2" to 0.70), unavailable = setOf("s3")))
        // Started here: generating, nothing more to pay.
        assertEquals("1 from your takes, 2 generating", RecreateText.makingSummary(fill, generating = setOf("s2", "s3")))
        val none = fill.copy(slots = fill.slots.map { it.copy(state = "matched") })
        assertEquals("3 from your takes · nothing to pay", RecreateText.makingSummary(none))
    }

    @Test fun theConfirmationSaysWhatIsMadeAndCharged() {
        assertEquals("The 2 new shots are made with your model and charged to the studio. 1 shot comes from your takes. They take a few minutes; you can leave this page meanwhile.",
            RecreateText.confirmMessage(paid = 2, yours = 1, cant = 0))
        assertEquals("3 shots come from your takes. Nothing is generated or charged.", RecreateText.confirmMessage(0, 3, 0))
        assertEquals("A 2 s shot, cut to 1.2 s", RecreateText.madeLength(2.0, 1.167))
        assertEquals("A 2 s shot", RecreateText.madeLength(2.0, 2.0))
    }

    @Test fun readsEstimateApplyAndMatch() {
        val e = RecreateJson.estimate(kotlinx.serialization.json.Json.parseToJsonElement(
            """{"slotId":"s2","request":{},"estimate":{"estimate":0.64,"seconds":2,"ok":true,"buttonLabel":"Generate"}}"""))
        assertTrue(e.ok); assertEquals(0.64, e.amount, 1e-9); assertEquals(2.0, e.seconds, 1e-9)
        val bad = RecreateJson.estimate(kotlinx.serialization.json.Json.parseToJsonElement(
            """{"slotId":"s2","estimate":{"estimate":0,"seconds":2,"ok":false,"message":"Too short for this quality"}}"""))
        assertEquals("Too short for this quality", bad.problem)
        val a = RecreateJson.apply(kotlinx.serialization.json.Json.parseToJsonElement(
            """{"sessionId":"es_1","revision":4,"missing":[],"waiting":["s3"],"match":{"overall":0.86,"cuts":0.97,"perSlot":[{"slotId":"s1","score":0.93}]}}"""))
        assertEquals(4, a.revision); assertEquals(listOf("s3"), a.waiting)
        assertEquals(0.86, a.match?.overall!!, 1e-9); assertEquals(0.93, a.match?.perSlot?.get("s1")!!, 1e-9)
        assertNull(a.match?.text)
        assertEquals("86%", RecreateText.percent(a.match?.overall)); assertEquals("–", RecreateText.percent(null))
    }

    @Test fun swatchesAreSoftenedLikeTheMac() {
        // The Mac's example (RecreateSwatches, owner note 1): the same hues, calm, dark to light.
        val soft = RecreateSwatches.soften(listOf("#286521", "#8987ED", "#0BF802", "#E3CA8A", "#F8FA02"))
        assertEquals(listOf("#446540", "#7C7BC2", "#C2AE7B", "#7EC27B", "#C1C27B"), soft)
        soft.forEach { assertTrue(RecreateSwatches.saturation(it) <= RecreateSwatches.MAX_SATURATION) }
        assertEquals(3, RecreateSwatches.soften(listOf("#FF0000")).size)
        assertEquals(5, RecreateSwatches.soften(List(8) { "#2${it}4060" }).size)
        assertTrue(RecreateSwatches.soften(listOf("nope")).isEmpty())
    }

    @Test fun slotsKeepTheirServerIds() {
        val r = RecipeJson.reference(javaClass.getResource("/recipe-v1.json")!!.readText()).recipe!!
        assertEquals(listOf("s1", "s2", "s3"), r.slots.map { it.id })
        assertEquals("9:16", r.aspect)
    }
}
