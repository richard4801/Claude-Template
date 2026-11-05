package studio.muse.app.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * Demo mode's prompt scripts (plans/api.md "Prompt scripts"): GET /v1/prompt-scripts as the server answers it for a studio
 * that has edited nothing (resources/prompt_scripts.json, written by server/api/scripts/gen-prompt-scripts.ts), the
 * server's rule validation (same messages) and an approximate preview. On the real API the server owns all of this.
 */
class FakePromptScripts(private val library: FakePromptLibrary, private val now: () -> Long = System::currentTimeMillis) {
    private val base: PromptScriptsList = DEFAULTS
    private val saved = mutableMapOf<String, Pair<List<Rule>, Long>>()

    fun list(): PromptScriptsList = base.copy(scripts = base.scripts.map(::view))
    fun get(id: String): ScriptView = view(def(id))

    fun save(id: String, rules: List<Rule>): ScriptView {
        val s = def(id)
        validate(s, base.ops, rules)?.let { throw ApiException("script_invalid", it) }
        val clean = clean(rules)
        if (clean == clean(s.defaultRules)) saved.remove(id) else saved[id] = clean to now()
        return get(id)
    }
    fun reset(id: String): ScriptView { def(id); saved.remove(id); return get(id) }

    /** POST /v1/prompt-scripts/preview, approximately: the script run on its samples with the chosen blocks' texts. */
    fun preview(id: String, inputs: JsonObject?, rules: List<Rule>?, texts: Map<String, String>?, direction: String?): ScriptPreview {
        val s = get(id)
        rules?.let { r -> validate(s, base.ops, r)?.let { throw ApiException("script_invalid", it) } }
        val all = JsonObject(s.inputs.associate { it.name to (it.sample ?: JsonNull) } + (inputs ?: emptyMap()))
        val text = { key: String -> texts?.get(key)?.takeIf { key in s.blocks } ?: library.text(key) }
        return run(s, all, rules ?: s.rules, text, (direction ?: "smiling, glancing at the camera").replace(Regex("\\s+"), " ").trim().take(500))
    }

    private fun def(id: String) = base.scripts.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Prompt script not found")
    private fun view(s: ScriptView): ScriptView = saved[s.id]?.let { (r, at) -> s.copy(rules = r, overridden = true, updatedAt = at, updatedBy = "jenne@studio.com") } ?: s

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        /** The server's scripts on their default rules (the same file the server checks is current). */
        val DEFAULTS: PromptScriptsList by lazy {
            FakePromptScripts::class.java.getResource("/prompt_scripts.json")?.readText()
                ?.let { json.decodeFromString(PromptScriptsList.serializer(), it) } ?: PromptScriptsList()
        }
        private val ID = Regex("^[A-Za-z0-9._-]{1,60}$")

        /** What the server stores: no `enabled: true`, no `optional/locked: false`, labels trimmed. */
        fun clean(rules: List<Rule>) = rules.map { r ->
            r.copy(label = r.label.trim(), optional = r.optional?.takeIf { it }, locked = r.locked?.takeIf { it }, enabled = r.enabled?.takeIf { !it },
                conds = r.conds.map { c -> c.copy(value = c.value?.takeIf { it !is JsonNull }) })
        }

        /** The input a condition reads: an input of the script, or "item.<field>" of the list its place repeats over. */
        fun inputFor(s: ScriptView, name: String, target: String): InputDef? {
            if (!name.startsWith("item.")) return s.inputs.firstOrNull { it.name == name }
            val each = (if (target.startsWith("@")) s.values.firstOrNull { "@${it.name}" == target }?.each else s.sections.firstOrNull { it.id == target }?.each) ?: return null
            return s.inputs.firstOrNull { it.name == each }?.fields?.firstOrNull { it.name == name.removePrefix("item.") }
        }

        private fun condError(s: ScriptView, ops: List<CondOpInfo>, c: Cond, target: String): String? {
            val def = inputFor(s, c.input, target) ?: return "Unknown input \"${c.input}\""
            val op = ops.firstOrNull { it.id == c.op }
            if (op == null || def.type !in op.types) return "\"${def.label}\" can't use the test \"${c.op}\""
            val opts = def.options.map { it.id }
            val v = c.value
            val p = v as? JsonPrimitive
            return when (c.op) {
                "empty", "notEmpty" -> null
                "in", "notIn" -> if (v !is JsonArray || v.isEmpty() || !v.all { (it as? JsonPrimitive)?.isString == true && it.content in opts })
                    "Pick one or more of ${opts.joinToString(", ")} for \"${def.label}\"" else null
                "has", "hasNot" -> if (p == null || !p.isString || (opts.isNotEmpty() && p.content !in opts)) "Pick one of ${opts.joinToString(", ")} for \"${def.label}\"" else null
                "atLeast", "atMost" -> if (p == null || p.isString || p.doubleOrNull == null) "\"${def.label}\" needs a number" else null
                else -> when (def.type) {
                    "bool" -> if (p == null || p.isString || p.booleanOrNull == null) "\"${def.label}\" is yes or no" else null
                    "number" -> if (p == null || p.isString || p.doubleOrNull == null) "\"${def.label}\" needs a number" else null
                    "enum" -> if (p == null || !p.isString || p.content !in opts) "Pick one of ${opts.joinToString(", ")} for \"${def.label}\"" else null
                    else -> if (p == null || !p.isString || p.content.length > 200) "\"${def.label}\" needs a short text" else null
                }
            }
        }

        /** The server's validateRules: why [rules] can't be saved for [s], or null. */
        fun validate(s: ScriptView, ops: List<CondOpInfo>, rules: List<Rule>): String? {
            if (rules.size > 60) return "At most 60 rules"
            val ids = mutableSetOf<String>()
            val targets = s.targets.map { it.id }
            for (r in rules) {
                if (!ID.matches(r.id)) return "Each rule needs an id"
                if (!ids.add(r.id)) return "Two rules are called \"${r.id}\""
                if (r.label.isBlank() || r.label.length > 120) return "Give rule \"${r.id}\" a short name"
                if (r.target !in targets) return "Rule \"${r.label}\": unknown place \"${r.target}\""
                if (r.block !in s.blocks) return "Rule \"${r.label}\": this script can't use the block \"${r.block}\""
                if (r.conds.size > 8) return "Rule \"${r.label}\": at most 8 conditions"
                for (c in r.conds) condError(s, ops, c, r.target)?.let { return "Rule \"${r.label}\": $it" }
            }
            for (d in s.defaultRules.filter { it.isLocked }) {
                val r = rules.firstOrNull { it.id == d.id } ?: return "\"${d.label}\" is required and can't be removed"
                if (!r.isOn || r.target != d.target || r.block != d.block || clean(listOf(r))[0].conds != d.conds || (r.optional == true) != (d.optional == true) || !r.isLocked)
                    return "\"${d.label}\" is locked: only its text can be changed (Settings → Prompts → its block)"
            }
            return null
        }

        private fun scalar(v: JsonElement?): Any? = when (v) {
            null, is JsonNull -> null
            is JsonPrimitive -> if (v.isString) v.content else v.booleanOrNull ?: v.doubleOrNull
            else -> v
        }
        private fun same(a: Any?, b: Any?) = if (a is Number && b is Number) a.toDouble() == b.toDouble() else a == b
        private fun isEmpty(v: JsonElement?) = v == null || v is JsonNull || (v is JsonPrimitive && v.isString && v.content.isBlank()) || (v is JsonArray && v.isEmpty())

        /** The server's condHolds. */
        fun holds(c: Cond, inputs: JsonObject, item: JsonObject?): Boolean {
            val v = if (c.input.startsWith("item.")) item?.get(c.input.removePrefix("item.")) else inputs[c.input]
            val sv = scalar(v)
            val want = scalar(c.value)
            val list = (v as? JsonArray)?.map { scalar(it) }
            val opts = (c.value as? JsonArray)?.map { scalar(it)?.toString() }
            return when (c.op) {
                "is" -> same(sv, want) || (sv == null && want == false)
                "isNot" -> !(same(sv, want) || (sv == null && want == false))
                "in" -> opts != null && sv?.toString() in opts
                "notIn" -> opts != null && sv?.toString() !in opts
                "atLeast" -> sv is Double && want is Double && sv >= want
                "atMost" -> sv is Double && want is Double && sv <= want
                "has" -> list != null && list.any { same(it, want) }
                "hasNot" -> list == null || list.none { same(it, want) }
                "empty" -> isEmpty(v)
                "notEmpty" -> !isEmpty(v)
                else -> false
            }
        }

        private fun on(r: Rule, inputs: JsonObject, item: JsonObject?) =
            r.isOn && !(r.optional == true && scalar(inputs["presets"]) == false) && r.conds.all { holds(it, inputs, item) }

        private fun itemText(v: JsonElement?): String = when (v) {
            null, is JsonNull -> ""
            is JsonArray -> v.joinToString(", ") { itemText(it) }
            is JsonPrimitive -> v.doubleOrNull?.takeIf { !v.isString && it == Math.floor(it) }?.toLong()?.toString() ?: v.content
            else -> v.toString()
        }

        /**
         * The runner, approximately (no section aliases; a place takes every matching rule when it repeats per item or is a
         * video script's Details, else the first): value slots, then places in order, "lines" or "heading:\nbody" blocks.
         */
        fun run(s: ScriptView, inputs: JsonObject, rules: List<Rule>, text: (String) -> String, direction: String): ScriptPreview {
            val fired = mutableListOf<String>()
            val vars = s.vars.associate { it.name to it.sample }.toMutableMap()
            for (slot in s.values) {
                if (slot.each != null) {
                    // A per-item value: the first matching rule per item, each piece after itemPrefix, joined with join.
                    val pieces = mutableListOf<String>()
                    for (item in (inputs[slot.each] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()) {
                        val r = rules.firstOrNull { it.target == "@${slot.name}" && on(it, inputs, item) } ?: continue
                        val t = FakePromptLibrary.fill(text(r.block), vars + item.mapValues { itemText(it.value) }).trim()
                        if (t.isNotEmpty()) { fired += r.id; pieces += (slot.itemPrefix ?: "") + t }
                    }
                    vars[slot.name] = if (pieces.isNotEmpty()) (slot.prefix ?: "") + pieces.joinToString(slot.join ?: "") else ""
                    continue
                }
                val r = rules.firstOrNull { it.target == "@${slot.name}" && on(it, inputs, null) }
                if (r == null) { vars.putIfAbsent(slot.name, ""); continue }
                fired += r.id
                val t = FakePromptLibrary.fill(text(r.block), vars).trim()
                vars[slot.name] = if (t.isNotEmpty()) (slot.prefix ?: "") + t else ""
            }
            val parts = mutableListOf<ScriptPart>()
            for (sec in s.sections) {
                val items: List<JsonObject?> = sec.each?.let { e -> (inputs[e] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList() } ?: listOf(null)
                for (item in items) {
                    var matched = rules.filter { it.target == sec.id && on(it, inputs, item) }
                    if (sec.kind == "user" && direction.isBlank()) matched = emptyList()
                    if (sec.each == null && !(s.id.startsWith("video.") && sec.id == "detailed")) matched = matched.take(1)
                    val v = vars + (item?.mapValues { itemText(it.value) } ?: emptyMap()) + (if (sec.kind == "user") mapOf("direction" to direction) else emptyMap())
                    val texts = matched.map { it.id to FakePromptLibrary.fill(text(it.block), v).trim() }.filter { it.second.isNotEmpty() }
                    if (texts.isEmpty()) continue
                    fired += texts.map { it.first }
                    parts += ScriptPart(sec.id, sec.id, sec.kind, texts.joinToString(" ") { it.second }, texts.map { it.first })
                }
            }
            val out = if (s.format == "lines") parts.joinToString("\n") { it.text } else {
                val chunks = mutableListOf<String>()
                for (p in parts) {
                    val h = s.sections.firstOrNull { it.id == p.section }?.heading
                    if (h != null || chunks.isEmpty()) chunks += if (h != null) "$h\n${p.text}" else p.text else chunks[chunks.size - 1] = chunks.last() + "\n${p.text}"
                }
                if (chunks.isEmpty()) "" else chunks.joinToString("\n\n") + "\n"
            }
            return ScriptPreview(s.id, out, parts, fired, inputs)
        }
    }
}
