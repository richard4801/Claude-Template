package studio.muse.core.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull

/**
 * Edit sessions (workstream 3, plans/claude-editing.md A): the Kotlin port of the server's small JSON Patch
 * (server/api/src/editor/jsonpatch.ts; RFC 6902 subset add / remove / replace). Every change to a session's project
 * travels as a patch and undo is its inverse, so this must give the same patches as the server and the Mac app
 * (shared fixture `editor/jsonpatch.json`):
 *  - objects: keys in sorted order (UTF-16 code units, like JS `sort()`); only in b → add, only in a → remove, both → recurse;
 *  - arrays: same length → recurse per index; different length → replace the whole array;
 *  - anything else that differs → replace.
 */
data class PatchOp(val op: String, val path: String, val value: JsonElement? = null) {
    fun toJson(): JsonObject = buildJsonObject {
        put("op", JsonPrimitive(op)); put("path", JsonPrimitive(path))
        if (op != "remove") put("value", value ?: JsonNull)
    }

    companion object {
        fun of(el: JsonElement): PatchOp {
            val o = el as? JsonObject ?: throw PatchException("bad patch operation")
            val op = (o["op"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val path = (o["path"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            if (op == null || path == null || op !in setOf("add", "remove", "replace")) throw PatchException("bad patch operation")
            return PatchOp(op, path, o["value"])
        }
        fun listOf(el: JsonElement?): List<PatchOp> = (el as? JsonArray ?: throw PatchException("patch: a JSON Patch array")).map(::of)
    }
}

class PatchException(message: String) : Exception(message)

object JsonPatch {
    private fun esc(k: String) = k.replace("~", "~0").replace("/", "~1")
    private fun unesc(k: String) = k.replace("~1", "/").replace("~0", "~")

    /** Deep equality for JSON values (numbers by value: 1 == 1.0). */
    fun jsonEqual(a: JsonElement?, b: JsonElement?): Boolean {
        if (a == null || b == null) return a == null && b == null
        return when (a) {
            is JsonNull -> b is JsonNull
            is JsonPrimitive -> b is JsonPrimitive && b !is JsonNull && primEqual(a, b)
            is JsonArray -> b is JsonArray && a.size == b.size && a.indices.all { jsonEqual(a[it], b[it]) }
            is JsonObject -> b is JsonObject && a.size == b.size && a.keys.all { k -> k in b && jsonEqual(a[k], b[k]) }
        }
    }

    private fun primEqual(a: JsonPrimitive, b: JsonPrimitive): Boolean {
        if (a.isString || b.isString) return a.isString && b.isString && a.content == b.content
        val ab = a.booleanOrNull; val bb = b.booleanOrNull
        if (ab != null || bb != null) return ab == bb
        val an = a.doubleOrNull; val bn = b.doubleOrNull
        return if (an != null && bn != null) an == bn else a.content == b.content
    }

    /** The patch that turns [a] into [b]. */
    fun diff(a: JsonElement, b: JsonElement, path: String = ""): List<PatchOp> {
        if (jsonEqual(a, b)) return emptyList()
        if (a is JsonObject && b is JsonObject) {
            val out = ArrayList<PatchOp>()
            for (k in (a.keys + b.keys).toSortedSet()) { // String.compareTo compares UTF-16 code units, like JS sort()
                val p = "$path/${esc(k)}"
                val av = a[k]; val bv = b[k]
                when {
                    av == null -> out += PatchOp("add", p, bv)
                    bv == null -> out += PatchOp("remove", p)
                    else -> out += diff(av, bv, p)
                }
            }
            return out
        }
        if (a is JsonArray && b is JsonArray && a.size == b.size) return a.indices.flatMap { diff(a[it], b[it], "$path/$it") }
        return listOf(PatchOp("replace", path, b))
    }

    /** Applies [patch] to [doc] (never modified). Throws [PatchException] when a path doesn't fit the document. */
    fun apply(doc: JsonElement, patch: List<PatchOp>): JsonElement {
        var root: JsonElement = doc
        for (op in patch) {
            if (op.op !in setOf("add", "remove", "replace")) throw PatchException("bad patch operation")
            if (op.path == "") {
                if (op.op == "remove") throw PatchException("cannot remove the document")
                root = op.value ?: JsonNull
                continue
            }
            if (!op.path.startsWith("/")) throw PatchException("bad path ${op.path}")
            val parts = op.path.substring(1).split("/").map(::unesc)
            root = at(root, parts, 0, op)
        }
        return root
    }

    /** A copy of [cur] with [op] applied at parts[i..]. */
    private fun at(cur: JsonElement, parts: List<String>, i: Int, op: PatchOp): JsonElement {
        val k = parts[i]
        val last = i == parts.lastIndex
        fun no(): Nothing = throw PatchException("no ${op.path}")
        return when (cur) {
            is JsonArray -> {
                val list = cur.toMutableList()
                if (!last) {
                    val n = index(k) ?: no()
                    if (n < 0 || n >= list.size) no()
                    list[n] = at(list[n], parts, i + 1, op)
                } else {
                    val n = if (k == "-") list.size else index(k) ?: no()
                    if (n < 0 || n > list.size || (op.op != "add" && n >= list.size)) no()
                    when (op.op) {
                        "add" -> list.add(n, op.value ?: JsonNull)
                        "remove" -> list.removeAt(n)
                        else -> list[n] = op.value ?: JsonNull
                    }
                }
                JsonArray(list)
            }
            is JsonObject -> {
                val map = LinkedHashMap(cur)
                if (!last) {
                    val child = map[k] ?: no()
                    map[k] = at(child, parts, i + 1, op)
                } else {
                    if (op.op != "add" && k !in map) no()
                    if (op.op == "remove") map.remove(k) else map[k] = op.value ?: JsonNull
                }
                JsonObject(map)
            }
            else -> no()
        }
    }

    /** JS `Number(k)` + `Number.isInteger` for the indices we accept (plain decimal integers). */
    private fun index(k: String): Int? = if (k.isNotEmpty() && k.all { it.isDigit() }) k.toIntOrNull() else null

    fun encode(patch: List<PatchOp>): JsonArray = JsonArray(patch.map { it.toJson() })
}
