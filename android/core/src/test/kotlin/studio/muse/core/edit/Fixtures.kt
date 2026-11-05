package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/** The shared editor fixtures (byte copies of server/api/test/fixtures/editor) and a tolerant JSON comparison. */
object Fixtures {
    fun load(name: String): JsonElement {
        val text = Fixtures::class.java.getResourceAsStream("/editor/$name")?.use { it.readBytes().decodeToString() } ?: error("missing fixture $name")
        return Json.parseToJsonElement(text)
    }

    /**
     * Fails unless [actual] equals [expected]: same keys (a null in either side counts as absent), same array lengths,
     * strings/booleans equal, numbers within [tol].
     */
    fun assertJson(where: String, expected: JsonElement?, actual: JsonElement?, tol: Double = 1e-6) {
        val e = expected.orNull(); val a = actual.orNull()
        when {
            e == null || a == null -> if (e != a) fail("$where: expected $e, got $a")
            e is JsonObject -> {
                if (a !is JsonObject) fail("$where: expected an object, got $a")
                val keys = (e.keys.filter { e[it].orNull() != null } + a.keys.filter { a[it].orNull() != null }).toSet()
                for (k in keys) assertJson("$where.$k", e[k], a[k], tol)
            }
            e is JsonArray -> {
                if (a !is JsonArray) fail("$where: expected a list, got $a")
                if (e.size != a.size) fail("$where: expected ${e.size} entries, got ${a.size}\n expected $e\n got      $a")
                e.indices.forEach { assertJson("$where.$it", e[it], a[it], tol) }
            }
            e is JsonPrimitive -> {
                if (a !is JsonPrimitive) fail("$where: expected $e, got $a")
                if (e.isString || a.isString || e.booleanOrNull != null) { if (e.content != a.content || e.isString != a.isString) fail("$where: expected $e, got $a") }
                else {
                    val x = e.doubleOrNull!!; val y = a.doubleOrNull ?: fail("$where: expected $x, got $a")
                    if (kotlin.math.abs(x - y) > tol) fail("$where: expected $x, got $y")
                }
            }
        }
    }

    private fun fail(m: String): Nothing = throw AssertionError(m)

    private fun JsonElement?.orNull(): JsonElement? = if (this == null || this is JsonNull) null else this
}

val JsonElement.obj: JsonObject get() = this as JsonObject
val JsonElement.arr: JsonArray get() = this as JsonArray
val JsonElement.str: String get() = (this as JsonPrimitive).content
val JsonElement.num: Double get() = (this as JsonPrimitive).doubleOrNull!!
