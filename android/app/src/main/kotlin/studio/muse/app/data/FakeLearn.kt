package studio.muse.app.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** Demo mode's learning editor (workstream 3's `/v1/learn/*`): the studio's playbook, lessons, corrections, library and gaps. */
object FakeLearn {
    private const val H = 3_600_000L
    private const val D = 24 * H
    private fun ago(ms: Long) = System.currentTimeMillis() - ms

    fun rules(): List<LearnRule> = listOf(
        LearnRule("rule_1", "Keep captions above the chin, never over the face.", "captions", "owner", pinned = true, createdAt = ago(9 * D)),
        LearnRule("rule_2", "Two or three words per caption page, word pop style.", "captions", "claude",
            evidence = List(3) { LearnEvidence("correction", "${10 + it}", "Moved Claude's captions", ago((it + 1) * D)) }, createdAt = ago(4 * D)),
        LearnRule("rule_3", "First cut by 0.8 s.", "pacing", "learned", pinned = true,
            evidence = listOf(LearnEvidence("post", "p1", "1.2k views, 42% completion", ago(6 * D)), LearnEvidence("post", "p2", "860 views", ago(3 * D))), createdAt = ago(6 * D)),
        LearnRule("rule_4", "Hold the last shot at least 1.5 s so the call to action can be read.", "pacing", "owner", createdAt = ago(8 * D)),
        LearnRule("rule_5", "No glitch transitions.", "transition", "owner", pinned = true, createdAt = ago(12 * D)),
        LearnRule("rule_6", "Whip pans only on a strong beat.", "transition", "claude",
            evidence = List(2) { LearnEvidence("correction", "${20 + it}", "Undid Claude's whip", ago((it + 2) * D)) }, createdAt = ago(2 * D)),
        LearnRule("rule_7", "Golden warmth at 70% or less when skin fills the frame.", "look", "claude",
            evidence = List(4) { LearnEvidence("correction", "${30 + it}", "Changed the look after Claude's “Look Film”", ago((it + 1) * 2 * D)) }, createdAt = ago(D)),
    )

    fun lessons(): List<LearnLesson> = listOf(
        LearnLesson("look", "Look", 4, 1, ago(2 * D), listOf("Changed the look after Claude's “Look Film”", "Lowered Golden warmth to 70%"), listOf(31, 32, 33, 34)),
        LearnLesson("captions", "Captions", 3, 0, ago(D), listOf("Moved the captions from lower third to top"), listOf(11, 12, 13)),
        LearnLesson("pacing", "Trim", 2, 0, ago(3 * D), listOf("Trimmed the first shot from 1.4 s to 0.8 s"), listOf(41, 42)),
    )

    fun corrections(): List<LearnCorrection> = listOf(
        LearnCorrection(51, kind = "change", area = "look", what = "Changed the look from Film to Golden warmth", createdAt = ago(2 * H)),
        LearnCorrection(50, kind = "change", area = "captions", what = "Moved the captions from lower third to top", createdAt = ago(26 * H)),
        LearnCorrection(49, kind = "undo", area = "transition", what = "Undid Claude's glitch transition at 0:04", createdAt = ago(30 * H)),
        LearnCorrection(48, kind = "change", area = "pacing", what = "Trimmed the first shot from 1.4 s to 0.8 s", createdAt = ago(3 * D)),
        LearnCorrection(47, kind = "change", area = "audio", what = "Turned the music down 3 dB under the voice-over", createdAt = ago(5 * D)),
    )

    fun recipes(): List<LearnRecipeEntry> {
        val body = Json.parseToJsonElement(FakeRecipes.cafeTrendJson()).jsonObject
        fun f(d: Double, shots: Double, cpm: Double, bpm: Double) = mapOf("durationSec" to d, "shots" to shots, "cutsPerMin" to cpm, "bpm" to bpm)
        return listOf(
            LearnRecipeEntry("rcp_1", "edit", takeId = "demo_edit_1", name = "Morning café", summary = "Seven shots cut on the beat, a hook up top and a warm film look",
                tags = listOf("own-edit", "warm", "fast-cuts", "text"), features = f(15.0, 7.0, 28.0, 118.0),
                performance = LearnPerformance(posts = 1, views = 1200, likes = 80, comments = 6, saves = 12, avgWatchSec = 6.5, completion = .42), createdAt = ago(2 * D), recipe = body),
            LearnRecipeEntry("rcp_2", "reference", referenceId = "rx_demo_1", name = "Tuff edit", summary = "Three beats: a pan, a push-in, a still with a caption",
                tags = listOf("reference", "fast-cuts", "transition-flash"), features = f(4.4, 3.0, 27.0, 120.0), createdAt = ago(3 * D), recipe = body),
            LearnRecipeEntry("rcp_3", "edit", takeId = "demo_edit_2", name = "Living room dance", summary = "",
                tags = listOf("own-edit", "fast-cuts", "high-energy"), features = f(12.0, 9.0, 40.0, 124.0),
                performance = LearnPerformance(posts = 1, views = 860, likes = 51, comments = 3, completion = .38), createdAt = ago(4 * D), recipe = body),
            LearnRecipeEntry("rcp_4", "reference", referenceId = "rx_demo_2", name = "Day in my life", summary = "Seven shots cut on the beat, a warm film look",
                tags = listOf("reference", "calm", "warm", "text"), features = f(15.0, 6.0, 24.0, 96.0), createdAt = ago(6 * D), recipe = body),
            LearnRecipeEntry("rcp_5", "edit", takeId = "demo_edit_3", name = "Kitchen walk", summary = "",
                tags = listOf("own-edit", "slow-cuts", "calm"), features = f(8.0, 4.0, 22.0, 90.0), createdAt = ago(8 * D), recipe = body),
        )
    }

    fun gaps(): List<LearnGap> = listOf(
        LearnGap("transition:unknown", "transition", "A transition MUSE couldn’t name", 4, listOf(LearnGapExample(note = "A spin with a light leak, in Tuff edit at 0:02")), ago(D)),
        LearnGap("effect:lens-flare", "effect", "Lens flare", 1, listOf(LearnGapExample(note = "Over the window shot in Day in my life")), ago(3 * D)),
    )

    @Suppress("unused") private fun JsonObject.keep() = this
}
