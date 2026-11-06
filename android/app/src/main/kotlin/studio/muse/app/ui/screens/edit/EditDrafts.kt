package studio.muse.app.ui.screens.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.io.File

/**
 * Edit sessions (workstream 3): this device's unsent edits per take, kept so they survive the app closing (written on
 * change, cleared once the session has them). [base] is the project they were made on, [project] the edited one, so
 * reopening can re-apply just this device's changes on top of the session's latest.
 */
interface EditDrafts {
    fun read(takeId: String): Pair<JsonObject, JsonObject>?
    fun write(takeId: String, base: JsonObject, project: JsonObject)
    fun clear(takeId: String)
}

/** One JSON file per take in [dir] (`{base, project}`). Unreadable files count as none. */
class FileEditDrafts(private val dir: File) : EditDrafts {
    private fun file(takeId: String) = File(dir, takeId.replace(Regex("[^A-Za-z0-9_-]"), "_") + ".json")

    override fun read(takeId: String): Pair<JsonObject, JsonObject>? = runCatching {
        val o = Json.parseToJsonElement(file(takeId).readText()) as JsonObject
        (o["base"] as JsonObject) to (o["project"] as JsonObject)
    }.getOrNull()

    override fun write(takeId: String, base: JsonObject, project: JsonObject) {
        runCatching {
            dir.mkdirs()
            val tmp = File(dir, file(takeId).name + ".tmp")
            tmp.writeText(JsonObject(mapOf("base" to base, "project" to project)).toString())
            tmp.renameTo(file(takeId))
        }
    }

    override fun clear(takeId: String) { file(takeId).delete() }
}
