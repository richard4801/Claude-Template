package studio.muse.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Edit templates (plans/edit-templates.md §3): the library of effects and transitions on the server
// (GET/POST /v1/editor/templates, POST /v1/editor/templates/{id}/apply, DELETE /v1/editor/templates/{id}). A template is
// one spec on the server, expanded there into ordinary project items: Apply is one change the edit session sends back.
// Not the photo presets and not caption kits; owner only. Decoding is lenient (unknown fields are ignored).

@Serializable
data class EditTemplateUpload(val uploadId: String)

@Serializable
data class EditTemplateParam(
    val key: String,
    val label: String = "",
    /** number | enum | bool | text | upload | times */
    val type: String = "text",
    val options: List<String> = emptyList(),
    val min: Double? = null,
    val max: Double? = null,
    val unit: String? = null,
    @SerialName("default") val defaultValue: JsonElement? = null,
)

@Serializable
data class EditTemplate(
    val id: String,
    val name: String = "",
    val description: String = "",
    /** transition | effect */
    val kind: String = "effect",
    /** clip | cut | edit */
    val target: String = "clip",
    /** live | matte | primitive | reference */
    val level: String = "live",
    /** ready | not_ready | needs_update */
    val state: String = "ready",
    val reason: String? = null,
    val requires: List<String> = emptyList(),
    val timing: String? = null,
    /** selected | note-cut: what "Apply to every…" covers. */
    val each: String? = null,
    val params: List<EditTemplateParam> = emptyList(),
    /** Needs a paid subject cut-out (Remove background), priced on Apply. */
    val paid: Boolean = false,
    val preview: EditTemplateUpload? = null,
    /** The pack's finished clip: reference only (it holds that video's footage). */
    val reference: EditTemplateUpload? = null,
    /** seed (made by Claude for the pack) | claude | owner */
    val by: String = "seed",
    val version: Int = 1,
)

@Serializable
data class EditTemplateCaptionStyle(val id: String, val name: String = "")

@Serializable
data class EditTemplateLibrary(val templates: List<EditTemplate> = emptyList(), val captionStyles: List<EditTemplateCaptionStyle> = emptyList())

@Serializable
data class EditTemplateApplyRequest(
    val sessionId: String,
    /** {itemId} | {cutAfter} | {itemIds} | {cutsAfter} | {each}; absent for a whole-edit template. */
    val target: JsonElement? = null,
    val params: JsonObject? = null,
    val dryRun: Boolean? = null,
    val confirm: Boolean? = null,
    val device: String? = null,
)

@Serializable
data class EditTemplateWaiting(val pendingId: String? = null)

@Serializable
data class EditTemplateApplyResult(
    val dryRun: Boolean = false,
    val applied: Boolean = false,
    val needsConfirmation: Boolean = false,
    val revision: Int? = null,
    /** A dry run's change (nothing saved). */
    val patch: JsonArray? = null,
    val added: List<String> = emptyList(),
    val notes: List<String> = emptyList(),
    val priceUsd: Double? = null,
    val estimateUsd: Double? = null,
    val waitingForOwner: List<EditTemplateWaiting> = emptyList(),
) {
    val price: Double? get() = priceUsd ?: estimateUsd
}

@Serializable
data class EditTemplateSaveFrom(val sessionId: String, val itemIds: List<String>, val cutAt: Double? = null)

@Serializable
data class EditTemplateSaveRequest(val name: String, val kind: String, val target: String? = null, val from: EditTemplateSaveFrom)

@Serializable
data class EditTemplateSaved(val template: EditTemplate, val saved: String = "")
