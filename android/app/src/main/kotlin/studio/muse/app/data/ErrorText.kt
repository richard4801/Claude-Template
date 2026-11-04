package studio.muse.app.data

/**
 * Plain, friendly wording for every API error code (plans/api.md). Codes whose server message carries the useful detail
 * (validation, over-allocation) keep the server's message.
 */
object ErrorText {
    const val NOT_ENOUGH_CREDIT = "Not enough credit. Ask the studio owner for more."
    /** The owner's own spending power is the studio balance they load (plans/api.md "App clean-up" §4). */
    const val NOT_ENOUGH_STUDIO = "Not enough in the studio balance · add a top-up in Credit"
    /** Every failed render and photo: nothing technical, and no charge. */
    const val WENT_WRONG = "Something went wrong · you weren't charged"

    /** Codes that end the session: the app goes back to sign-in. */
    val SIGN_OUT_CODES = setOf("unauthorized", "account_disabled")

    fun of(e: ApiException): String = of(e.code, e.message)

    fun of(code: String, serverMessage: String?): String {
        val server = serverMessage?.trim().orEmpty()
        return when (code) {
            "invite_required" -> "MUSE is invite-only. Enter the invite code your studio owner sent you."
            "invite_invalid" -> if (server.contains("different email", ignoreCase = true)) "That invite is for a different email address. Use the email it was sent to."
                else "That invite code isn't valid or has expired. Check it, or ask the studio owner for a new one."
            "email_taken" -> "That email already has an account. Sign in instead."
            "bad_credentials" -> "Wrong email or password."
            "account_disabled" -> "This account is switched off. Ask the studio owner to turn it back on."
            "rate_limited" -> "Too many tries. Wait a minute, then try again."
            "unauthorized" -> "Your session has ended. Please sign in again."
            "attestation_required" -> "Tick both boxes to continue."
            "owner_only" -> "Only the studio owner can do that."
            "insufficient_tokens" -> NOT_ENOUGH_CREDIT
            "insufficient_balance" -> NOT_ENOUGH_STUDIO
            "over_job_limit" -> "This costs more than the per-job limit. Try fewer takes or a lighter option."
            "over_user_day_limit" -> "You've reached your daily spending cap. Try again tomorrow, or ask the studio owner to raise it."
            "over_day_limit" -> "The studio's daily spending cap is reached. Try again tomorrow."
            // The server says "You can send at most 500 tokens ($5.00): …"; keep only the dollars.
            "over_allocation" -> Regex("""\(\$([\d.,]+)\)""").find(server)?.let { "You can send at most $${it.groupValues[1]}. The rest of the studio balance is already with members or on hold." }
                ?: "That's more than the studio balance has free. Add a top-up first."
            "balance_unavailable" -> "The studio balance can't be read right now. Try again shortly."
            "topup_unavailable" -> "Top-ups are recorded by the studio owner."
            "engine_unavailable" -> "This option isn't available right now. Try another one."
            "image_engine_failed" -> "Something went wrong making the photos · you weren't charged"
            "provider_refused" -> "This was refused by the content filter · you weren't charged"
            "provider_rate_limited" -> "Busy right now · you weren't charged. Try again in a minute."
            "provider_out_of_credit" -> "Something went wrong · you weren't charged. The studio owner has been told."
            "upscale_unavailable" -> "Upscale is coming soon."
            "clip_failed_checks" -> "Fix the clip checks first."
            "not_found" -> "That's no longer there. Pull to refresh."
            "busy" -> "That's already in progress. Wait for it to finish."
            "upload_missing" -> "The file didn't finish uploading. Try again."
            "upload_failed" -> "The upload didn't go through. Check your connection and try again."
            "too_large" -> "That file is too large to upload."
            "offline" -> "Can't reach the MUSE server. Check your connection."
            "bad_response" -> "The server sent something this app version can't read. Update MUSE."
            "server_error" -> "Something went wrong on the server. Try again."
            "bad_signature" -> "The upload link expired. Try again."
            "warm_not_allowed" -> "Only the studio owner can do that."
            "owner_balance_low" -> NOT_ENOUGH_STUDIO
            "no_gpu_free" -> "Every add-on engine is busy right now. Try again when a render finishes."
            "no_gpu_available" -> "No add-on engine is free right now. Try again in a minute."
            "not_warm" -> "The add-on engine isn't on any more."
            else -> Credit.dollarize(server).ifBlank { "Something went wrong." }
        }
    }
}
