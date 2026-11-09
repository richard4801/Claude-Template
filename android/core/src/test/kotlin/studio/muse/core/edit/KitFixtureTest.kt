package studio.muse.core.edit

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/** Style kits: functions.json → kits (kitOf every fixture project, applyKit results, validateKit fields), from the TypeScript reference. */
class KitFixtureTest {
    private val k = Fixtures.load("functions.json").obj["kits"]!!.obj
    private val projects = Fixtures.load("projects.json").arr.map { EditJson.parse(it.obj["project"]!!) }

    @Test fun kitOfEveryProject() {
        for ((i, c) in k["kitOf"]!!.arr.withIndex()) Fixtures.assertJson("kitOf ${c.obj["name"]}", c.obj["kit"], encodeKit(kitOf(projects[i])))
    }

    @Test fun ownFontStaysOutOfKits() {
        val o = k["ownFont"]!!.obj
        val p = EditJson.parse(o["project"]!!)
        Fixtures.assertJson("kitOf own font", o["kit"], encodeKit(kitOf(p)))
    }

    @Test fun applyKits() {
        val kits = k["kits"]!!.arr.map { parseKit(it) }
        for (c in k["apply"]!!.arr) {
            val o = c.obj
            val got = applyKit(projects[o["project"]!!.num.toInt()], kits[o["kit"]!!.num.toInt()])
            Fixtures.assertJson("apply kit ${o["kit"]} to project ${o["project"]}", o["result"], EditJson.encode(got))
            assertEquals(null, problemOf(got)?.message)
        }
    }

    @Test fun validateKits() {
        for (c in k["validate"]!!.arr) {
            val want = c.obj["field"]?.takeIf { it !is JsonNull }?.let { (it as JsonPrimitive).content }
            val got = try { parseKit(c.obj["kit"]!!); null } catch (e: EditProblem) { e.field }
            assertEquals("${c.obj["kit"]}", want, got)
        }
    }
}
